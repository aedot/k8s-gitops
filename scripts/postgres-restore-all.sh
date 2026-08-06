#!/usr/bin/env bash
#
# postgres-restore-all.sh — reconcile + re-seed the CNPG postgres apps from
# their NFS logical dumps after the switch to empty (initdb) bootstrap.
#
# For each app it:
#   1. reconciles the Flux Kustomization (pulls the merged initdb override),
#   2. deletes the existing Cluster so CNPG re-bootstraps it EMPTY,
#      (CNPG will not re-bootstrap a Cluster that already exists — it must be
#       recreated for initdb to take effect; this also removes its PVCs),
#   3. waits for the fresh empty Cluster to become Ready,
#   4. triggers the <app>-postgres-restore Job and follows it to completion.
#
# DESTRUCTIVE: step 2 deletes each Cluster and its data volumes. Requires a
# confirmation per app unless --yes is passed. Use --dry-run to preview.
#
# Usage:
#   ./postgres-restore-all.sh [--yes] [--dry-run] [--no-restore-empty] \
#                             [--apps "lubelog teslamate"]
#
# Flags:
#   --yes               skip the per-app "delete cluster?" confirmation
#   --dry-run           print the commands without running the mutating ones
#   --no-restore-empty  skip the restore Job for apps with no NFS dump (tracearr)
#   --apps "a b c"      restrict to a subset (default: all six)
#
set -uo pipefail

# ---- app -> namespace, and whether an NFS dump exists to restore from --------
# has_dump=no  -> cluster is bootstrapped empty and the restore is a no-op
#                 (the Job will fail to find a file); harmless, app self-inits.
declare -A NS=(
  [baby-tracker]=selfhosted
  [lubelog]=selfhosted
  [sparkyfitness]=selfhosted
  [teslamate]=selfhosted
  [tracearr]=media
  [readmeabook]=media
)
declare -A HAS_DUMP=(
  [baby-tracker]=yes
  [lubelog]=yes
  [sparkyfitness]=yes
  [teslamate]=yes
  [tracearr]=no      # no dump on the NFS share — comes up empty
  [readmeabook]=yes
)

FLUX_NS="${FLUX_NS:-}"   # override the Flux Kustomization namespace; empty = use
                         # each app's own namespace (these CRs are stamped into
                         # apps/<ns>/kustomization.yaml -> namespace: <ns>)
CLUSTER_READY_TIMEOUT="${CLUSTER_READY_TIMEOUT:-600}"   # seconds
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-3600}"              # seconds (teslamate is big)

APPS="baby-tracker lubelog sparkyfitness teslamate tracearr readmeabook"
ASSUME_YES=0; DRY_RUN=0; RESTORE_EMPTY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-restore-empty) RESTORE_EMPTY=0; shift ;;
    --apps) APPS="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

run() {   # run a mutating command (respects --dry-run)
  echo "+ $*"
  [[ "$DRY_RUN" == 1 ]] && return 0
  "$@"
}

confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  read -r -p "  → delete cluster ${1}-db in ns/${2} and re-bootstrap EMPTY? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

wait_cluster_ready() {   # ns app
  local ns="$1" app="$2" deadline=$(( $(date +%s) + CLUSTER_READY_TIMEOUT ))
  echo "  waiting for ${app}-db to be Ready (timeout ${CLUSTER_READY_TIMEOUT}s)..."
  [[ "$DRY_RUN" == 1 ]] && { echo "  (dry-run: skip wait)"; return 0; }
  while :; do
    local ready phase
    ready=$(kubectl -n "$ns" get cluster "${app}-db" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "")
    phase=$(kubectl -n "$ns" get cluster "${app}-db" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "${ready:-0}" -ge 1 ]]; then
      echo "  ${app}-db ready (${ready} instance(s), phase: ${phase})"
      return 0
    fi
    [[ $(date +%s) -ge $deadline ]] && { echo "  TIMEOUT waiting for ${app}-db (phase: ${phase})" >&2; return 1; }
    sleep 5
  done
}

wait_cronjob() {   # ns app  — ensure Flux has created the restore CronJob
  local ns="$1" app="$2" deadline=$(( $(date +%s) + 120 ))
  [[ "$DRY_RUN" == 1 ]] && return 0
  while ! kubectl -n "$ns" get cronjob "${app}-postgres-restore" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $deadline ]] && { echo "  restore CronJob not found for ${app}" >&2; return 1; }
    sleep 3
  done
}

do_app() {
  local app="$1" ns="${NS[$1]}" dump="${HAS_DUMP[$1]}"
  echo
  echo "=============================================================="
  echo " ${app}  (ns/${ns}, nfs-dump: ${dump})"
  echo "=============================================================="

  local fns="${FLUX_NS:-$ns}"   # Flux Kustomization lives in the app's namespace

  # 1. reconcile the merged config
  run flux -n "$fns" reconcile kustomization "$app" --with-source || \
    echo "  WARN: reconcile failed/absent for ${app} (continuing)"

  # 2. recreate the cluster empty
  if kubectl -n "$ns" get cluster "${app}-db" >/dev/null 2>&1; then
    if confirm "$app" "$ns"; then
      run kubectl -n "$ns" delete cluster "${app}-db" --wait=true
    else
      echo "  skipped delete for ${app}; leaving existing cluster as-is."
      return 0
    fi
  else
    echo "  no existing ${app}-db cluster; Flux will create it fresh."
  fi

  # let Flux recreate the empty cluster, then wait for readiness
  run flux -n "$fns" reconcile kustomization "$app" || true
  wait_cluster_ready "$ns" "$app" || { echo "  ABORT ${app}: cluster not ready"; return 1; }

  # 3. restore from NFS
  if [[ "$dump" == "no" && "$RESTORE_EMPTY" == 0 ]]; then
    echo "  ${app} has no NFS dump and --no-restore-empty set; leaving cluster empty."
    return 0
  fi
  wait_cronjob "$ns" "$app" || { echo "  ABORT ${app}: no restore CronJob"; return 1; }
  local job="${app}-restore-$(date +%s)"
  run kubectl -n "$ns" create job --from="cronjob/${app}-postgres-restore" "$job"
  [[ "$DRY_RUN" == 1 ]] && return 0

  echo "  following ${job} ..."
  kubectl -n "$ns" wait --for=condition=complete "job/${job}" --timeout="${RESTORE_TIMEOUT}s" &
  local waitpid=$!
  kubectl -n "$ns" logs -f "job/${job}" 2>/dev/null || true
  wait "$waitpid" 2>/dev/null
  if kubectl -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}' | grep -q 1; then
    echo "  ✅ ${app} restore complete"
  else
    if [[ "$dump" == "no" ]]; then
      echo "  ℹ️  ${app} restore Job did not succeed — expected (no NFS dump); cluster stays empty."
    else
      echo "  ❌ ${app} restore Job did NOT succeed — investigate: kubectl -n ${ns} logs job/${job}"
    fi
  fi
}

echo "Apps: $APPS"
echo "Flux Kustomization namespace: ${FLUX_NS:-<per-app>}   dry-run: $DRY_RUN   assume-yes: $ASSUME_YES"
for app in $APPS; do
  [[ -z "${NS[$app]:-}" ]] && { echo "unknown app: $app" >&2; continue; }
  do_app "$app"
done
echo
echo "Done."
