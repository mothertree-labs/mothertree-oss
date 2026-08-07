apiVersion: v1
kind: ConfigMap
metadata:
  name: acme-challenge-cleanup-config
  namespace: ${NS_CERTMANAGER}
  labels:
    app: acme-challenge-cleanup
data:
  cleanup.sh: |
    #!/bin/sh
    set -eu

    # Prune orphaned cert-manager DNS-01 challenge records.
    #
    # cert-manager creates ephemeral `_acme-challenge.<name>` TXT records during
    # DNS-01 validation and deletes them once the challenge is solved. When a
    # cluster is torn down mid-challenge (e.g. the ephemeral dev clusters, which
    # share this same Cloudflare zone), those records are orphaned and never
    # cleaned up. Over time they fill the zone's record quota and cert-manager
    # starts getting Cloudflare error 81045 ("Record quota exceeded"), which
    # wedges every renewal in the zone.
    #
    # This job lists TXT records in the infra zone and deletes any
    # `_acme-challenge.*` record older than MAX_AGE_MINUTES. The age threshold
    # protects records belonging to an in-flight challenge (which complete within
    # minutes); anything older is definitively an orphan. Deletes are idempotent
    # (a concurrent janitor in another env may have already removed a record), so
    # running this in more than one environment against the shared zone is safe.
    #
    # Set DRY_RUN=1 to log what would be deleted without deleting anything.

    : "${CF_API_TOKEN:?CF_API_TOKEN not set}"
    : "${CF_ZONE_NAME:?CF_ZONE_NAME not set}"
    MAX_AGE_MINUTES="${MAX_AGE_MINUTES:-360}"
    DRY_RUN="${DRY_RUN:-0}"

    API="https://api.cloudflare.com/client/v4"
    AUTH="Authorization: Bearer ${CF_API_TOKEN}"

    log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] [acme-cleanup] $*"; }

    # ---------------------------------------------------------------------------
    # Resolve the zone id from its name (the token can list its own zones; this
    # mirrors the fallback in deploy_infra and avoids depending on a templated id)
    # ---------------------------------------------------------------------------
    ZONE_ID=$(curl -sf --max-time 30 -H "$AUTH" \
      "${API}/zones?name=${CF_ZONE_NAME}" | jq -r '.result[0].id // empty')
    if [ -z "$ZONE_ID" ]; then
      log "ERROR: could not resolve zone id for ${CF_ZONE_NAME}"
      exit 1
    fi
    log "zone ${CF_ZONE_NAME} = ${ZONE_ID}; pruning _acme-challenge TXT older than ${MAX_AGE_MINUTES}m (dry_run=${DRY_RUN})"

    # ---------------------------------------------------------------------------
    # Collect stale record ids (paginated). Only TXT records whose name starts
    # with `_acme-challenge.` and whose created_on is older than the threshold.
    # ---------------------------------------------------------------------------
    STALE=$(mktemp)
    page=1
    while : ; do
      RESP=$(curl -sf --max-time 30 -H "$AUTH" \
        "${API}/zones/${ZONE_ID}/dns_records?type=TXT&per_page=100&page=${page}")
      if [ "$(echo "$RESP" | jq -r '.success')" != "true" ]; then
        log "ERROR listing records (page ${page}): $(echo "$RESP" | jq -c '.errors')"
        rm -f "$STALE"; exit 1
      fi
      echo "$RESP" | jq -r --argjson maxage "$MAX_AGE_MINUTES" '
        .result[]
        | select(.type == "TXT")
        | select(.name | test("^_acme-challenge\\."))
        | select(.created_on != null)
        | select((.created_on | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < (now - ($maxage * 60)))
        | "\(.id)\t\(.name)"' >> "$STALE"
      TOTAL=$(echo "$RESP" | jq -r '.result_info.total_count')
      PERPAGE=$(echo "$RESP" | jq -r '.result_info.per_page')
      if [ $((page * PERPAGE)) -ge "$TOTAL" ]; then break; fi
      page=$((page + 1))
    done

    COUNT=$(wc -l < "$STALE" | tr -d ' ')
    log "found ${COUNT} stale _acme-challenge TXT record(s)"

    DELETED=0
    FAILED=0
    while IFS="$(printf '\t')" read -r id name; do
      [ -z "$id" ] && continue
      # Defence in depth: never touch a record that is not an _acme-challenge TXT.
      case "$name" in
        _acme-challenge.*) : ;;
        *) log "SKIP (safety) unexpected name: $name"; continue ;;
      esac

      if [ "$DRY_RUN" = "1" ]; then
        log "  DRY_RUN would delete: $name ($id)"
        DELETED=$((DELETED + 1))
        continue
      fi

      DRESP=$(curl -s --max-time 15 -X DELETE -H "$AUTH" \
        "${API}/zones/${ZONE_ID}/dns_records/${id}")
      if [ "$(echo "$DRESP" | jq -r '.success')" = "true" ]; then
        log "  deleted: $name ($id)"
        DELETED=$((DELETED + 1))
        continue
      fi
      # Idempotent: a concurrent janitor may have already deleted it. Re-check
      # existence and treat the delete as done ONLY if the record genuinely no
      # longer exists (Cloudflare code 81044). Any other failure (e.g. 403 auth,
      # rate limit) is a real error and must be counted as such — masking it
      # would violate the repo's fail-fast rule and hide a broken token.
      CHECK=$(curl -s --max-time 15 -H "$AUTH" \
        "${API}/zones/${ZONE_ID}/dns_records/${id}")
      if echo "$CHECK" | jq -e '(.success == false) and ([.errors[]?.code] | any(. == 81044))' >/dev/null 2>&1; then
        log "  already gone: $name ($id)"
        DELETED=$((DELETED + 1))
      else
        log "  ERROR deleting $name ($id): $(echo "$DRESP" | jq -c '.errors')"
        FAILED=$((FAILED + 1))
      fi
    done < "$STALE"
    rm -f "$STALE"

    log "cleanup complete: ${DELETED} pruned, ${FAILED} failed"
    [ "$FAILED" -eq 0 ] || exit 1
