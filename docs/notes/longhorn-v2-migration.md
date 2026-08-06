# Migrating Longhorn to the V2 Data Engine (SPDK / NVMe-TCP)

A step-by-step guide for moving this cluster's Longhorn volumes from the **V1**
data engine (iSCSI-based) to the **V2** data engine (SPDK + NVMe/TCP), on Talos.

**Why:** V2 replaces the host `open-iscsi` frontend with in-kernel `nvme_tcp`,
removing the dependency that caused the "all PVCs stuck `attaching`" outage
(see [longhorn-iscsi-attaching.md](longhorn-iscsi-attaching.md)). There is no
persistent userspace iSCSI node database to go stale across a Talos upgrade.

> **Read this first.** V1 and V2 volumes coexist in the same cluster, so this is
> a **gradual, reversible-per-workload** migration — not a big-bang cutover.
> V1 stays the default until you flip it. Do not delete V1 volumes until their
> V2 replacements are validated.

---

## 0. Decisions & prerequisites (do not skip)

### 0.1 The gating requirement: a dedicated raw disk per node
V2 uses **block-type** disks — a raw block device, **not** a filesystem path.
It **cannot** reuse the existing `/var/mnt/longhorn` filesystem disk. You need a
spare disk or partition on **every** node (`aje`, `oba`, `oya`).

Confirm what's available on each node before doing anything else:

```sh
export KUBECONFIG=./kubeconfig
for N in aje oba oya; do
  echo "=== $N ==="
  POD=$(kubectl -n longhorn-system get pod -l app=longhorn-manager \
        --field-selector spec.nodeName=$N -o jsonpath='{.items[0].metadata.name}')
  kubectl -n longhorn-system exec "$POD" -c longhorn-manager -- \
    sh -c 'ls -l /host/dev/disk/by-id/ 2>/dev/null | grep -vE "part[0-9]"'
done
```

Pick a **stable** path (`/dev/disk/by-id/...`) for each node's V2 disk. Never
use `/dev/sdb` — it can renumber across reboots.

> No spare disk? Options: add a physical/virtual disk, carve a partition, or
> stop here — V2 is not viable without dedicated block storage.

### 0.2 Resource budget (permanent, per node)
- **2 GiB RAM** locked by HugePages (`1024 × 2 MiB`).
- **~1 dedicated CPU core** — the SPDK poller busy-polls (constant usage).

### 0.3 Verify feature parity for *your* workloads (Longhorn 1.12)
Check the 1.12 docs for V2 support of anything you rely on:
- **RWX** volumes (historically V1-only), **encryption**, **backing images**,
  **volume cloning**, and the exact **snapshot/backup** feature set.
- Recurring jobs / trim behavior.

List what uses each feature today:

```sh
kubectl get pvc -A -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in d["items"]:
    print(p["metadata"]["namespace"], p["metadata"]["name"],
          "|".join(p["spec"].get("accessModes",[])), p["spec"].get("storageClassName"))'
```

Anything `ReadWriteMany` must stay on V1 until you've confirmed V2 RWX in 1.12.

### 0.4 Have a working backup target (strongly recommended)
Back up every volume you care about **before** touching node config. Confirm the
backup target is set and healthy in the Longhorn UI (`Settings → General →
Backup Target`) or:

```sh
kubectl -n longhorn-system get backuptarget -o custom-columns=\
'NAME:.metadata.name,URL:.spec.backupTargetURL,AVAILABLE:.status.available'
```

---

## 1. Talos machine-config changes

Two patches enable the V2 runtime. **These require a reboot per node** — apply
them **one node at a time** (staged), never all at once.

### 1.1 HugePages — `talos/patches/global/machine-sysctls.yaml`
Add:

```yaml
machine:
  sysctls:
    vm.nr_hugepages: "1024"   # 1024 * 2MiB = 2GiB reserved for SPDK (Longhorn V2)
```

### 1.2 Kernel modules — `talos/patches/global/machine-kernel.yaml`
Add the V2 modules alongside the existing `nbd`:

```yaml
machine:
  kernel:
    modules:
      - name: nbd
      - name: nvme_tcp          # V2 frontend transport (replaces iSCSI)
      - name: uio_pci_generic   # SPDK device binding
      # - name: vfio_pci        # alternative to uio_pci_generic if needed
```

### 1.3 Apply staged, one node at a time
Regenerate config with talhelper and apply per node, rebooting and verifying
before moving on. Example for the first node:

```sh
cd talos
task talos:generate-config      # or: talhelper genconfig  (match your justfile/taskfile)

# apply to ONE node, with reboot
talosctl -n 172.24.20.13 apply-config -f clusterconfig/*-aje.yaml   # aje
talosctl -n 172.24.20.13 reboot
```

Wait for the node to rejoin `Ready`, run the §2 verification, and only then
proceed to `oba` (172.24.20.14) and `oya` (172.24.20.12).

> Staged application is itself a mitigation for the original outage class: if a
> change breaks storage, it breaks **one** node, not the cluster.

---

## 2. Verify the V2 environment on each node

After each node reboots, confirm the runtime is ready:

```sh
export KUBECONFIG=./kubeconfig
N=aje   # repeat for oba, oya
POD=$(kubectl -n longhorn-system get pod -l app=longhorn-manager \
      --field-selector spec.nodeName=$N -o jsonpath='{.items[0].metadata.name}')

echo "--- hugepages (want HugePages_Total >= 1024) ---"
kubectl -n longhorn-system exec "$POD" -c longhorn-manager -- \
  sh -c 'grep -i hugepages /host/proc/meminfo'

echo "--- kernel modules (want nvme_tcp + uio_pci_generic) ---"
kubectl -n longhorn-system exec "$POD" -c longhorn-manager -- \
  sh -c 'grep -E "nvme_tcp|uio_pci_generic" /host/proc/modules'
```

Once all three nodes pass, confirm the V2 **instance-manager** pods are healthy
(they only run once hugepages exist — before this they may have been crash-looping
because `v2DataEngine: true` was already set):

```sh
kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager \
  -o wide
kubectl -n longhorn-system get instancemanager \
  -o custom-columns='NAME:.metadata.name,ENGINE:.spec.dataEngine,STATE:.status.currentState'
```

You want a `Running` V2 (`dataEngine: v2`) instance-manager on every node.

---

## 3. Add a V2 block disk to each node

Register the raw disk from §0.1 as a `block`-type Longhorn disk. Edit each
`nodes.longhorn.io` resource and add an entry under `spec.disks` (do this via
the UI **Node → Edit Disks**, or by patching the CR):

```sh
# Example: add a block disk on node aje. Repeat per node with that node's path.
kubectl -n longhorn-system patch nodes.longhorn.io aje --type merge -p '{
  "spec": {
    "disks": {
      "v2-disk-nvme0": {
        "path": "/dev/disk/by-id/REPLACE-WITH-STABLE-ID",
        "diskType": "block",
        "allowScheduling": true,
        "storageReserved": 0,
        "tags": ["v2"]
      }
    }
  }
}'
```

Verify all three block disks are schedulable:

```sh
kubectl -n longhorn-system get nodes.longhorn.io -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for n in d["items"]:
    for name,dk in (n["spec"].get("disks") or {}).items():
        if dk.get("diskType")=="block":
            print(n["metadata"]["name"], name, dk.get("path"),
                  "sched=", dk.get("allowScheduling"))'
```

The `v2` tag lets the StorageClass in §4 target these disks explicitly.

---

## 4. Create a V2 StorageClass

Add a new StorageClass (keep the V1 ones as default for now). Create
`kubernetes/apps/longhorn-system/longhorn/storageclass/v2.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-v2
provisioner: driver.longhorn.io
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
parameters:
  dataEngine: v2
  numberOfReplicas: "3"
  diskSelector: "v2"          # pin to the block disks tagged in §3
  dataLocality: disabled
  staleReplicaTimeout: "30"
```

Add it to the kustomization and let Flux reconcile:

```sh
# add ./v2.yaml to storageclass/kustomization.yaml resources, then:
flux -n longhorn-system reconcile kustomization <ks-name> --with-source
kubectl get storageclass longhorn-v2
```

---

## 5. Smoke-test with a throwaway volume

Prove the whole path works before migrating real data:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: v2-smoke, namespace: default }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn-v2
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: v2-smoke, namespace: default }
spec:
  containers:
    - name: c
      image: busybox
      command: ["sh","-c","echo ok > /data/test && sleep 3600"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: v2-smoke }
EOF

kubectl wait --for=condition=Ready pod/v2-smoke --timeout=120s
kubectl exec v2-smoke -- cat /data/test        # -> ok
kubectl delete pod/v2-smoke pvc/v2-smoke
```

If the PVC binds, the pod attaches, and the volume shows `dataEngine: v2` and
`robustness: healthy`, the platform is ready.

---

## 6. Migrate a workload's data (per volume)

**There is no in-place V1 → V2 conversion.** You copy data into a new V2 PVC.
Do this one workload at a time. Two methods — pick per workload.

### Method A — offline `rsync` copy (RWO, self-contained, recommended)
Best when you don't want to rely on the backup target. The app is down during
the copy.

1. **Scale the workload down** (so the V1 volume detaches cleanly):

   ```sh
   kubectl -n <ns> scale deploy/<app> --replicas=0     # or statefulset
   ```

2. **Create the V2 PVC** (same size, `longhorn-v2` class):

   ```sh
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata: { name: <app>-data-v2, namespace: <ns> }
   spec:
     accessModes: ["ReadWriteOnce"]
     storageClassName: longhorn-v2
     resources: { requests: { storage: <SIZE> } }
   EOF
   ```

3. **Run a copy Job** mounting both PVCs:

   ```sh
   kubectl apply -f - <<EOF
   apiVersion: batch/v1
   kind: Job
   metadata: { name: migrate-<app>, namespace: <ns> }
   spec:
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: copy
             image: instrumentisto/rsync-ssh
             command: ["rsync","-aHAX","--numeric-ids","--info=progress2","/src/","/dst/"]
             volumeMounts:
               - { name: src, mountPath: /src }
               - { name: dst, mountPath: /dst }
         volumes:
           - name: src
             persistentVolumeClaim: { claimName: <app>-data }      # old V1 PVC
           - name: dst
             persistentVolumeClaim: { claimName: <app>-data-v2 }   # new V2 PVC
   EOF
   kubectl -n <ns> wait --for=condition=complete job/migrate-<app> --timeout=1h
   ```

4. **Repoint the workload** at the V2 PVC (edit the Deployment/StatefulSet volume
   claim, or your app's HelmRelease/kustomize values), then scale back up:

   ```sh
   kubectl -n <ns> scale deploy/<app> --replicas=1
   ```

5. **Validate** the app reads its data, then delete the copy Job. Keep the old
   V1 PVC until you're confident, then delete it to reclaim space.

> **StatefulSets:** the PVC name is templated (`<claim>-<sts>-0`) and immutable.
> Migrate by copying into a new V2 PVC, deleting the StatefulSet with
> `--cascade=orphan`, recreating it with the V2 `volumeClaimTemplate` /
> pre-created V2 PVCs, then scaling up.

### Method B — backup & restore (uses the backup target)
1. Back up the V1 volume (UI or a one-off `Backup` CR / recurring job).
2. Restore the backup **into a new V2 volume** (restore dialog lets you pick the
   V2 data engine / disk). 
3. Create a PVC/PV bound to the restored V2 volume and repoint the workload.

Use this when volumes are large and you'd rather stream through object storage,
or you want a restore-tested backup as part of the move.

---

## 7. Flip the default (optional, after everything is migrated)

Once all workloads run on V2 and are validated:
- Point `defaultLonghornStaticStorageClass` / your default StorageClass at
  `longhorn-v2`, or mark it default and unmark the V1 class.
- Optionally reclaim the V1 filesystem disks (only after **all** V1 volumes are
  gone) and drop `v2DataEngine` special-casing.

---

## 8. Rollback

Per workload, before you delete the V1 PVC, rollback is trivial: scale down,
repoint the workload back at the original V1 PVC, scale up. The V1 data is
untouched until you explicitly delete it.

Cluster-level: to fully back out, migrate workloads back to a V1 StorageClass
(same rsync method in reverse), then remove the V2 block disks, revert the two
Talos patches, and reboot nodes staged. HugePages/modules are additive and
harmless to leave in place if you're undecided.

---

## Quick verification cheatsheet

```sh
export KUBECONFIG=./kubeconfig
# Volumes by data engine + robustness
kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c '
import json,sys,collections
d=json.load(sys.stdin); c=collections.Counter()
for v in d["items"]:
    c[(v["spec"].get("dataEngine"), v["status"].get("robustness"))]+=1
for k,n in sorted(c.items()): print(n, k)'

# V2 instance managers healthy on all nodes
kubectl -n longhorn-system get instancemanager \
  -o custom-columns='NAME:.metadata.name,ENGINE:.spec.dataEngine,NODE:.spec.nodeID,STATE:.status.currentState'
```
