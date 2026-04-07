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
    # VM hostnames to never delete (even if offline during maintenance)
    VM_PATTERNS="postgres-|postfix-relay-|router-|ci-server"

    log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }

    log "Fetching nodes from Headscale at ${HEADSCALE_URL}..."
    NODES=$(curl -sf --max-time 30 \
      -H "Authorization: Bearer $HEADSCALE_API_KEY" \
      "${HEADSCALE_URL}/api/v1/node") || { log "ERROR: Failed to list nodes"; exit 1; }

    NODE_COUNT=$(echo "$NODES" | jq '.nodes | length')
    log "Total nodes: $NODE_COUNT"

    # Find stale nodes: offline + matching pod patterns + not matching VM patterns
    STALE_IDS=$(echo "$NODES" | jq -r --arg pods "$POD_PATTERNS" --arg vms "$VM_PATTERNS" '
      .nodes[]
      | select(.online == false)
      | select(.givenName // .name | test($pods))
      | select(.givenName // .name | test($vms) | not)
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
      if curl -sf --max-time 15 -X DELETE \
        -H "Authorization: Bearer $HEADSCALE_API_KEY" \
        "${HEADSCALE_URL}/api/v1/node/${nid}" > /dev/null; then
        log "  Deleted: id=$nid $NAME"
        DELETED=$((DELETED + 1))
      else
        log "  ERROR: Failed to delete id=$nid $NAME"
        FAILED=$((FAILED + 1))
      fi
    done

    log "Cleanup complete: $DELETED deleted, $FAILED failed"
    [ "$FAILED" -eq 0 ] || exit 1
