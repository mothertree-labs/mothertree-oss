apiVersion: v1
kind: ConfigMap
metadata:
  name: headscale-cleanup-config
  namespace: ${NS_DB}
  labels:
    app: headscale-cleanup
data:
  cleanup.sh: |
    #!/bin/sh
    set -eu

    # Headscale stale node cleanup
    # Deletes offline nodes matching K8s pod name patterns.
    # VMs and online nodes are always preserved.

    : "${HEADSCALE_API_KEY:?HEADSCALE_API_KEY not set}"
    : "${HEADSCALE_URL:?HEADSCALE_URL not set}"

    # K8s pod name patterns (ephemeral, create new Tailscale registrations on restart)
    POD_PATTERNS="pgbouncer-|postfix-|pg-metrics-bridge-"
    # Sidecars with a FIXED-name state Secret keep one node across pod restarts
    # (metrics federation pair: prom-mesh-<env> / prom-eu-bridge-<env>). Their
    # node is merely offline during a Recreate rollout or a cluster outage, so
    # it is only stale once it has been offline longer than
    # PERSISTENT_STALE_HOURS (7 days) — an identity abandoned by a deleted state
    # Secret, a rebuilt cluster, or the pre-2026-09 per-pod layout (which
    # registered a new node on every pod recreation).
    PERSISTENT_PATTERNS="prom-eu-bridge-|prom-mesh-"
    PERSISTENT_STALE_HOURS="${PERSISTENT_STALE_HOURS:-168}"
    # VM hostnames to never delete (even if offline during maintenance)
    VM_PATTERNS="postgres-|postfix-relay-|router-|ci-server"

    log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }

    # The bearer token reaches curl through a config file on stdin, never argv
    # (argv is readable by every process in the pod via /proc).
    hs_curl() { printf 'header = "Authorization: Bearer %s"\n' "$HEADSCALE_API_KEY" | curl -sf --config - "$@"; }

    log "Fetching nodes from Headscale at ${HEADSCALE_URL}..."
    NODES=$(hs_curl --max-time 30 "${HEADSCALE_URL}/api/v1/node") || { log "ERROR: Failed to list nodes"; exit 1; }

    NODE_COUNT=$(echo "$NODES" | jq '.nodes | length')
    log "Total nodes: $NODE_COUNT"

    # Find stale nodes: offline + not a VM + (ephemeral pod pattern, or a
    # persistent pattern that has been offline for PERSISTENT_STALE_HOURS).
    # lastSeen carries fractional seconds, which jq's fromdateiso8601 rejects.
    NOW=$(date -u +%s)
    STALE_IDS=$(echo "$NODES" | jq -r --arg pods "$POD_PATTERNS" --arg vms "$VM_PATTERNS" \
      --arg persist "$PERSISTENT_PATTERNS" --argjson cutoff "$((NOW - PERSISTENT_STALE_HOURS * 3600))" '
      .nodes[]
      | select(.online == false)
      | select(.givenName // .name | test($vms) | not)
      | select(
          (.givenName // .name | test($pods))
          or (
            (.givenName // .name | test($persist))
            and (((.lastSeen // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $cutoff)
          )
        )
      | .id
    ')

    ONLINE_PODS=$(echo "$NODES" | jq -r --arg pods "$POD_PATTERNS" '
      [.nodes[] | select(.online == true) | select(.givenName // .name | test($pods))] | length
    ')

    STALE_COUNT=$(echo "$STALE_IDS" | grep -c . 2>/dev/null || echo 0)
    log "Online pod nodes: $ONLINE_PODS"
    log "Stale pod nodes to delete: $STALE_COUNT"

    if [ "$STALE_COUNT" -eq 0 ]; then
      log "Nothing to clean up"
      exit 0
    fi

    DELETED=0
    FAILED=0
    for nid in $STALE_IDS; do
      NAME=$(echo "$NODES" | jq -r --arg id "$nid" '.nodes[] | select(.id == ($id | tostring)) | .givenName // .name')
      if hs_curl --max-time 15 -X DELETE "${HEADSCALE_URL}/api/v1/node/${nid}" > /dev/null; then
        log "  Deleted: id=$nid $NAME"
        DELETED=$((DELETED + 1))
      else
        log "  ERROR: Failed to delete id=$nid $NAME"
        FAILED=$((FAILED + 1))
      fi
    done

    log "Cleanup complete: $DELETED deleted, $FAILED failed"
    [ "$FAILED" -eq 0 ] || exit 1
