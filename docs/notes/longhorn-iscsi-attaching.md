# Longhorn: all volumes stuck in `attaching` after a Talos upgrade

## Symptom

After a Talos node upgrade, **every** Longhorn volume is stuck and no workload
that uses a PVC can start. Pods sit in `ContainerCreating` with events like:

```
AttachVolume.Attach failed for volume "pvc-..." : rpc error: code = Aborted
desc = volume pvc-... is not ready for workloads
```

Longhorn custom resources show:

```sh
export KUBECONFIG=./kubeconfig

kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROB:.status.robustness'
# STATE = attaching, ROBUSTNESS = unknown  (for many/all volumes)

kubectl -n longhorn-system get engines.longhorn.io \
  -o custom-columns='NAME:.metadata.name,STATE:.status.currentState'
# many engines stuck in  starting  (and flipping starting -> error)
```

## Root cause

The Talos upgrade bumped the **`iscsi-tools` system extension** to a newer
**open-iscsi** release, and that release **renamed a node-database parameter**.

In the incident this runbook was written for (Talos `v1.13.7` → `v1.13.8`,
open-iscsi `2.1.11` → `2.1.12`) the rename was:

```
node.session.conn_reopen_log_freq   (open-iscsi 2.1.11, old name)
node.session.sess_reopen_log_freq   (open-iscsi 2.1.12, new name)
```

A handful of cached iSCSI node records under `/var/lib/iscsi/nodes/` were still
written in the **old** format. `iscsiadm` reads the **entire** `nodes/`
directory on **every** call and aborts on the first file it cannot parse:

```
iSCSI ERROR: Unknown parameter name node.session.conn_reopen_log_freq
iSCSI ERROR: config file /var/lib/iscsi/nodes/iqn.2019-10.io.longhorn:pvc-.../default invalid. ... exit status 7
```

Because a single bad file breaks **all** `iscsiadm` commands, no Longhorn engine
can start its iSCSI frontend, so every volume stalls in `attaching`. Only a few
stale records need to be malformed to take the whole node down.

## Confirming the diagnosis

Look at the `longhorn-manager` logs for the frontend-startup failure:

```sh
kubectl -n longhorn-system logs -l app=longhorn-manager --tail=400 \
  | grep -i 'startup frontend\|exit status 7\|Unknown parameter'
```

The iSCSI node database lives inside the **iscsid extension's mount namespace**,
which has no shell. Reach its files from any `longhorn-manager` pod through
`/host/proc/<iscsid-pid>/root/…` (the pod mounts `/host/proc` and ships
coreutils). Find the pid by scanning `/host/proc/*/comm` for `iscsid`:

```sh
POD=$(kubectl -n longhorn-system get pod -l app=longhorn-manager \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n longhorn-system exec "$POD" -c longhorn-manager -- sh -c '
  PID=$(for c in /host/proc/*/comm; do
          grep -q "^iscsid$" "$c" 2>/dev/null && \
          { echo "$c" | sed "s#/host/proc/##;s#/comm##"; break; }
        done)
  ROOT=/host/proc/$PID/root/var/lib/iscsi/nodes
  echo "offending files:"; grep -rl conn_reopen_log_freq "$ROOT"/ 2>/dev/null
  echo "iscsiadm version:"; nsenter --mount=/host/proc/$PID/ns/mnt -- iscsiadm --version
'
```

> Substitute `conn_reopen_log_freq` for whatever unrecognized parameter name the
> log reports, if a different open-iscsi version renamed a different key.

## Fix

Rename the stale parameter in every offending file, on **every** node, so the
current `iscsiadm` can parse the database again. This is a metadata-only edit —
it touches iSCSI discovery cache records, **not** any volume data.

```sh
export KUBECONFIG=./kubeconfig

kubectl -n longhorn-system get pod -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}' \
| while IFS='|' read POD NODE; do
  echo "=== $NODE ($POD) ==="
  kubectl -n longhorn-system exec "$POD" -c longhorn-manager -- sh -c '
    PID=$(for c in /host/proc/*/comm; do
            grep -q "^iscsid$" "$c" 2>/dev/null && \
            { echo "$c" | sed "s#/host/proc/##;s#/comm##"; break; }
          done)
    ISCSI=/host/proc/$PID/root/var/lib/iscsi
    # keep backups OUTSIDE nodes/ (iscsiadm scans nodes/ recursively!)
    mkdir -p "$ISCSI/nodes-bak"
    for f in $(grep -rl conn_reopen_log_freq "$ISCSI/nodes"/ 2>/dev/null); do
      cp -a "$f" "$ISCSI/nodes-bak/$(echo "$f" | tr "/" "_").bak"
      sed -i "s/node.session.conn_reopen_log_freq/node.session.sess_reopen_log_freq/" "$f"
      echo "  fixed: $f"
    done
    echo "  remaining bad files: $(grep -rl conn_reopen_log_freq "$ISCSI/nodes"/ 2>/dev/null | wc -l)"
    echo "  iscsiadm parse test (want: no error lines):"
    nsenter --mount=/host/proc/$PID/ns/mnt -- iscsiadm -m node 2>&1 \
      | grep -iE "error|invalid" | head -3
  '
done
```

> ⚠️ **Do not leave `.bak` files inside `nodes/`.** `iscsiadm` scans that
> directory recursively, so a backup with the old parameter re-breaks the fix.
> Put backups in a sibling directory (`nodes-bak/`) as above.

Once `iscsiadm -m node` returns cleanly on all nodes, Longhorn recovers on its
own — no restart required. Engines start, volumes attach, and any `degraded`
volumes rebuild their replicas automatically. Verify:

```sh
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='STATE:.status.state' --no-headers | sort | uniq -c
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='ROB:.status.robustness' --no-headers | sort | uniq -c
kubectl get pods -A | grep -vE 'Running|Completed'
```

## Aftermath / collateral

- **`degraded` volumes** rebuild replicas on their own; wait for them to reach
  `healthy`. Watch progress with the engine `rebuildStatus`.
- **`faulted` volumes** whose replicas all failed *during* the outage (auto-
  salvage couldn't run while iSCSI was dead) may need manual salvage. In this
  cluster the only faulted volumes were ephemeral `actions-runner-system`
  `-work` scratch PVCs — disposable; the Actions Runner Controller reprovisions
  fresh ones, so they can just be deleted.

## Preventing recurrence

This is a recurring **class** of problem: any Talos / `iscsi-tools` upgrade that
changes an open-iscsi node-DB parameter name can strand stale records the same
way. After a Talos upgrade that touches storage, if PVCs hang in `attaching`,
check `longhorn-manager` logs for `Unknown parameter name … exit status 7`
first — the fix above (rename the offending key, per node) applies regardless of
which parameter was renamed.
