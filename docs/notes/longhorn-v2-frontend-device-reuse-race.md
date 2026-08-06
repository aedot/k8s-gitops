# Longhorn v2 (v1.12.0): NVMe/TCP frontend device-number-reuse race → app ext4 read-only

## Summary
On a pure-v2 (SPDK/NVMe-TCP) Longhorn v1.12.0 cluster, volumes intermittently have their
EngineFrontend torn down with `robustness=faulted` even though replicas are healthy. Each
event drops the node-side block device for a moment; any app with an in-flight write sees
EIO and the kernel remounts its ext4 **read-only** (`errors=remount-ro`). Longhorn then
reconnects and reports the volume `healthy` again, masking the disruption — but the app's
mount stays read-only until the pod is restarted.

Crash-on-write apps (e.g. VictoriaLogs) CrashLoop; tolerant apps (Prometheus WAL, Gatus
SQLite) keep running and silently fail writes.

## Root cause
The frontend is set to error by a **validation failure**, logged in the instance-manager:

```
level=error msg="Setting engine frontend to error state due to validation failure"
  engineFrontendName=pvc-2c1b459a-...-ef-0
  error="failed to get devices for address 10.42.0.77:24513 and nqn
         nqn.2023-01.io.longhorn.spdk:volume-pvc-2c1b459a-...:
         no subsystem found for NVMe device /dev/nvme31n1"
```

At the same millisecond, `/dev/nvme31n1` was being removed because a **different** volume
(`pvc-9350a15c`, controller `nvme31`) was detaching:

```
msg="Removing linear dm device" controllerName=nvme31 name=pvc-9350a15c-... namespaceName=nvme31n1
```

So volume A's frontend validation resolved by device path to `/dev/nvme31n1`, which volume B
had just freed → "no subsystem found" → frontend errored → volume A faulted → ext4 read-only.
This is a **device-number-reuse race in the v2 NVMe/TCP initiator/frontend under concurrent
attach/detach**. The dm-linear wrapper is meant to insulate against nvme renumbering, but the
frontend validation step still resolves by the raw `/dev/nvmeXn1` path and trips over it.

Not resource exhaustion: instance-manager containers had 0 restarts; no OOM, hugepage, or
SPDK reactor-stall signatures.

## Amplifiers (this cluster)
- `replicaAutoBalance: best-effort` — continuous balance-driven replica rebuilds.
- `concurrent-replica-rebuild-per-node-limit: 5` (default) — up to 5 concurrent rebuilds/node,
  maximizing the window for two volumes to collide on a device number.
- Feedback loop: each flap fails a replica → rebuild → more concurrent attach/detach → more races.
- 3 nodes × replicaCount 3 = replicas already fully spread and node-local, so auto-balance and
  data-locality had no legitimate work — pure churn.

## Mitigation applied (GitOps)
`kubernetes/apps/longhorn-system/longhorn/app/helmrelease.yaml` `defaultSettings`:
- `replicaAutoBalance: disabled`
- `concurrentReplicaRebuildPerNodeLimit: "1"`

Reduces how often the race fires (fewer/serialized concurrent ops). Does NOT eliminate the
underlying bug — a Longhorn fix (upgrade when patched) or v1 rollback is the real resolution.

## Triage runbook (when it recurs)
1. Find flapped volumes: `kubectl -n longhorn-system get events --field-selector reason=DetachedUnexpectedly`.
2. Map volume → PVC → pod (PV name == `spec.volumeName`).
3. Confirm read-only (don't trust the flap alone — many flaps don't flip ext4):
   - shell pods: `grep " ext4 " /proc/mounts` → look for `ro` / `emergency_ro`.
   - distroless: check app logs for write errors (Prometheus "read-only file system",
     SQLite "disk I/O error (778)").
4. Fix = restart the pod (fresh rw remount): `kubectl rollout restart` / `delete pod`.
5. If a volume's own data is unrecoverable and it's reconstructible (logs/cache), recreate the
   PVC empty (scale workload to 0 → delete PVC → scale up; reclaimPolicy=Delete frees the PV).

## Environment
Longhorn v1.12.0 (manager + instance-manager), v2 data engine only (v1 disabled),
Talos v1.13.8 / kernel 6.18.x, k8s v1.36.3, 3 control-plane nodes, NVMe/TCP frontend
(`frontend=spdk-tcp-blockdev`, ublk not in use).
