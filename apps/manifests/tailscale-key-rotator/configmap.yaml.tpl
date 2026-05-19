apiVersion: v1
kind: ConfigMap
metadata:
  name: tailscale-rotator-config
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
data:
  # Component config: name|acl_tag|k8s_secret|namespace|deployment
  components.conf: |
    pgbouncer|tag:pgbouncer|pgbouncer-tailscale-auth|${NS_DB}|deployment/pgbouncer
    metrics|tag:monitoring|pg-metrics-bridge-tailscale-auth|${NS_DB}|deployment/pg-metrics-bridge
    router|tag:router|tailscale-router-auth|${NS_INGRESS_INTERNAL}|deployment/tailscale-router

  rotate.sh: |
    #!/bin/sh
    set -eu

    # Tailscale pre-auth key rotator
    # Checks key expiry via Headscale REST API, creates replacements,
    # patches K8s secrets, and restarts affected deployments.

    THRESHOLD_DAYS=30
    KEY_EXPIRATION_SECONDS=7776000  # 90 days

    : "${HEADSCALE_API_KEY:?HEADSCALE_API_KEY not set}"

    log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
    die() { log "ERROR: $*" >&2; exit 1; }

    # Resolve Headscale user ID for 'infra'
    log "Connecting to Headscale at ${HEADSCALE_URL}..."
    USERS=$(curl -sf --max-time 30 \
      -H "Authorization: Bearer $HEADSCALE_API_KEY" \
      "${HEADSCALE_URL}/api/v1/user") || die "Failed to connect to Headscale API"

    USER_ID=$(echo "$USERS" | jq -r '.users[] | select(.name == "infra") | .id')
    [ -n "$USER_ID" ] || die "Could not find Headscale user 'infra'"
    log "Headscale user 'infra' id=$USER_ID"

    # Fetch all pre-auth keys
    KEYS=$(curl -sf --max-time 30 \
      -H "Authorization: Bearer $HEADSCALE_API_KEY" \
      "${HEADSCALE_URL}/api/v1/preauthkey") || die "Failed to list pre-auth keys"

    NOW_EPOCH=$(date +%s)
    THRESHOLD_EPOCH=$((NOW_EPOCH + THRESHOLD_DAYS * 86400))
    ROTATED=0
    ERRORS=0

    while IFS='|' read -r comp tag secret ns deploy; do
      # Skip blank lines and comments
      [ -z "$comp" ] && continue
      echo "$comp" | grep -q '^#' && continue

      log "--- Component: $comp (tag=$tag) ---"

      # Check if the namespace exists (e.g. infra-mail may not exist in prod-eu)
      if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        log "  Namespace $ns does not exist, skipping"
        continue
      fi

      # Check if the deployment exists
      deploy_kind="${deploy%%/*}"
      deploy_name="${deploy#*/}"
      if ! kubectl get "$deploy_kind" "$deploy_name" -n "$ns" >/dev/null 2>&1; then
        log "  Deployment $deploy not found in $ns, skipping"
        continue
      fi

      # Find the best (longest-lived) valid key for this tag
      BEST_EXPIRY=$(echo "$KEYS" | jq -r --arg tag "$tag" '
        [.preAuthKeys[]
         | select(.reusable == true and ((.aclTags // []) | index($tag)))
         | .expiration
        ] | map(sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | max // 0
      ')

      if [ "$BEST_EXPIRY" -eq 0 ]; then
        log "  No valid key found for tag $tag — creating new key"
      elif [ "$BEST_EXPIRY" -lt "$THRESHOLD_EPOCH" ]; then
        DAYS_LEFT=$(( (BEST_EXPIRY - NOW_EPOCH) / 86400 ))
        log "  Key expires in ${DAYS_LEFT} days — rotating"
      else
        DAYS_LEFT=$(( (BEST_EXPIRY - NOW_EPOCH) / 86400 ))
        log "  Key valid for ${DAYS_LEFT} more days — no rotation needed"
        continue
      fi

      # Calculate expiration timestamp (90 days from now)
      EXPIRY_ISO=$(date -u -d "@$((NOW_EPOCH + KEY_EXPIRATION_SECONDS))" '+%Y-%m-%dT%H:%M:%SZ')

      # Create new key via Headscale API
      log "  Creating new key (tag=$tag, expires=$EXPIRY_ISO)..."
      CREATE_RESP=$(curl -sf --max-time 30 \
        -X POST \
        -H "Authorization: Bearer $HEADSCALE_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"user\":\"$USER_ID\",\"reusable\":true,\"expiration\":\"$EXPIRY_ISO\",\"aclTags\":[\"$tag\"]}" \
        "${HEADSCALE_URL}/api/v1/preauthkey") || { log "  ERROR: Failed to create key"; ERRORS=$((ERRORS+1)); continue; }

      NEW_KEY=$(echo "$CREATE_RESP" | jq -r '.preAuthKey.key // empty')
      [ -n "$NEW_KEY" ] || { log "  ERROR: No key in API response (length=${#CREATE_RESP})"; ERRORS=$((ERRORS+1)); continue; }
      log "  New key created (${#NEW_KEY} chars)"

      # Patch K8s secret
      log "  Patching secret $secret in $ns..."
      kubectl create secret generic "$secret" -n "$ns" \
        --from-literal=TS_AUTHKEY="$NEW_KEY" \
        --dry-run=client -o yaml | kubectl apply -f - || { log "  ERROR: Failed to patch secret"; ERRORS=$((ERRORS+1)); continue; }

      # Restart deployment
      log "  Restarting $deploy in $ns..."
      kubectl rollout restart "$deploy" -n "$ns" || { log "  ERROR: Failed to restart deployment"; ERRORS=$((ERRORS+1)); continue; }

      ROTATED=$((ROTATED+1))
      log "  Done"
    done < /config/components.conf

    log "=== Rotation complete: $ROTATED rotated, $ERRORS errors ==="
    [ "$ERRORS" -eq 0 ] || exit 1
