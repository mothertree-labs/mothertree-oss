#!/usr/bin/env bash
# dev-cert-cache.sh — persist the dev wildcard/apex TLS secrets across on-demand
# dev-cluster rebuilds, so a freshly-reaped cluster RESTORES the existing valid
# certificate instead of re-issuing it from Let's Encrypt.
#
# Why: the reaper rebuilds the dev cluster frequently, and each fresh cluster
# re-issues the same `*.dev.<domain>` wildcard from scratch (cert-manager issues
# because the target Secret is absent). >5 rebuilds/week trips LE's "Certificates
# per Exact Set of Identifiers" limit (5 / 168h), which is account/identifier-
# level — rebuilding does NOT help — and blocks every pipeline leasing that
# tenant at deploy-dev-stalwart (which mounts wildcard-tls-<tenant> as a required
# volume) until the window rolls. See the cert-manager memory.
#
# How: on restore we apply the cached Secret into NS_MATRIX *before* create_env
# applies the Certificate. cert-manager then adopts the present, valid, spec-
# matching Secret and marks the Certificate Ready with NO new ACME Order
# (verified empirically). Issuance drops from once-per-rebuild to ~once-per-50d.
#
# Usage:
#   dev-cert-cache.sh backup  <NS_MATRIX> <TENANT_NAME>
#   dev-cert-cache.sh restore <NS_MATRIX> <TENANT_NAME>
#
# DEV-ONLY + OPTIONAL: no-op unless DEV_STATE_BUCKET + DEV_STATE_S3_{ENDPOINT,
# KEY,SECRET} are set (ci-deploy.sh sets these only for env=dev, from
# terraform-outputs.dev.env). Prod doesn't churn, so it neither needs nor
# configures this. This is a rate-limit optimization, not correctness: on any
# S3/cert problem we warn and let cert-manager issue normally — so we do NOT use
# `set -e` and every path returns 0.
#
# Requires (all present on the CI box / deploy env): kubectl (uses ambient
# KUBECONFIG), aws, jq, openssl, base64.
set -uo pipefail

ACTION="${1:-}"
NS_MATRIX="${2:-}"
TENANT_NAME="${3:-}"

# Secrets to persist (both are per-tenant in NS_MATRIX; apex shares the same
# churn risk even though only the wildcard bucket is exhausted today).
SECRETS=("wildcard-tls-${TENANT_NAME}" "apex-tls-${TENANT_NAME}")

# Restore/keep only certs valid comfortably beyond cert-manager's renewBefore so
# it won't immediately renew an adopted cert and re-issue. The wildcard template
# (apps/manifests/wildcard/certificate.yaml.tpl) sets no custom renewBefore, so
# cert-manager's default (~1/3 of a 90d LE cert ≈ 30d) applies. 40d gives margin.
# If a renewBefore is ever added to the template, raise this above it.
RENEW_MARGIN_DAYS=40
CHECKEND_SECS=$(( RENEW_MARGIN_DAYS * 86400 ))

log()  { echo "[dev-cert-cache] $*"; }
warn() { echo "[dev-cert-cache] WARN: $*" >&2; }

if [ "$ACTION" != "backup" ] && [ "$ACTION" != "restore" ]; then
  echo "usage: $0 {backup|restore} <NS_MATRIX> <TENANT_NAME>" >&2
  exit 2
fi
if [ -z "$NS_MATRIX" ] || [ -z "$TENANT_NAME" ]; then
  echo "usage: $0 {backup|restore} <NS_MATRIX> <TENANT_NAME>" >&2
  exit 2
fi

# --- Guard: dev-only (positive assertion, not just credential-absence) ---------
# Persisting a TLS *private key* to object storage is only ever appropriate for
# the throwaway dev wildcard. Refuse on any other environment even if dev-state
# creds happen to be present (guards against env contamination ever uploading a
# prod key). MT_ENV is exported by scripts/lib/config.sh.
if [ "${MT_ENV:-}" != "dev" ]; then
  log "MT_ENV='${MT_ENV:-unset}' is not 'dev' — refusing ${ACTION} (dev-only feature)"
  exit 0
fi

# --- Guard: dev-state cache configured? ----------------------------------------
if [ -z "${DEV_STATE_BUCKET:-}" ] || [ -z "${DEV_STATE_S3_ENDPOINT:-}" ] \
   || [ -z "${DEV_STATE_S3_KEY:-}" ] || [ -z "${DEV_STATE_S3_SECRET:-}" ]; then
  log "dev-state S3 not configured (no cache) — skipping ${ACTION}"
  exit 0
fi

# S3 auth + endpoint normalization, mirroring scripts/dev-heartbeat.sh. The
# Linode bucket hostname includes the bucket prefix; aws-cli wants the cluster
# endpoint, so strip everything up to the first dot.
export AWS_ACCESS_KEY_ID="$DEV_STATE_S3_KEY"
export AWS_SECRET_ACCESS_KEY="$DEV_STATE_S3_SECRET"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
case "$DEV_STATE_S3_ENDPOINT" in
  https://*) ENDPOINT_URL="$DEV_STATE_S3_ENDPOINT" ;;
  *)         ENDPOINT_URL="https://${DEV_STATE_S3_ENDPOINT#*.}" ;;
esac

s3_key_for() { echo "s3://${DEV_STATE_BUCKET}/certs/${1}.json"; }

# cert_valid <pem-on-stdin> → 0 if the cert is valid and not within the renew
# margin of expiry, else nonzero.
cert_valid() { openssl x509 -checkend "$CHECKEND_SECS" -noout >/dev/null 2>&1; }

backup_secret() {
  local secret="$1" key json crt
  key="$(s3_key_for "$secret")"

  if ! kubectl get secret "$secret" -n "$NS_MATRIX" >/dev/null 2>&1; then
    log "backup: secret ${secret} not present in ${NS_MATRIX} — skip"
    return 0
  fi

  # Only cache a cert with comfortable life left (don't seed a soon-to-renew one).
  crt="$(kubectl get secret "$secret" -n "$NS_MATRIX" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null)"
  if [ -z "$crt" ] || ! printf '%s' "$crt" | cert_valid; then
    log "backup: ${secret} missing/expiring within ${RENEW_MARGIN_DAYS}d — skip"
    return 0
  fi

  # Strip cluster-instance + status fields; KEEP type, data, and the
  # cert-manager.io/* + reflector annotations (cert-manager matches on the
  # issuer-name/kind/group + certificate-name annotations to adopt the secret).
  json="$(kubectl get secret "$secret" -n "$NS_MATRIX" -o json 2>/dev/null | jq -S '
    del(
      .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
      .metadata.generation, .metadata.managedFields, .metadata.ownerReferences,
      .metadata.selfLink, .metadata.namespace,
      .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
      .status
    )')"
  if [ -z "$json" ]; then
    warn "backup: failed to render ${secret} json — skip"
    return 0
  fi

  if printf '%s' "$json" | aws s3 cp - "$key" \
       --endpoint-url "$ENDPOINT_URL" --content-type "application/json" --no-progress >/dev/null 2>&1; then
    log "backup: cached ${secret} → ${key}"
  else
    warn "backup: S3 upload of ${secret} failed (non-fatal)"
  fi
  return 0
}

restore_secret() {
  local secret="$1" key json crt
  key="$(s3_key_for "$secret")"

  # Live secret wins: never clobber a cert already present in the cluster.
  if kubectl get secret "$secret" -n "$NS_MATRIX" >/dev/null 2>&1; then
    log "restore: ${secret} already present in ${NS_MATRIX} — leave it"
    return 0
  fi

  json="$(aws s3 cp "$key" - --endpoint-url "$ENDPOINT_URL" --no-progress 2>/dev/null)"
  if [ -z "$json" ]; then
    log "restore: no cached ${secret} at ${key} — cert-manager will issue fresh"
    return 0
  fi

  # Defense-in-depth: only ever apply a Secret named exactly as expected into
  # NS_MATRIX. Refuse anything else (a poisoned/wrong cached object, or a
  # cluster-scoped kind that would ignore -n) before it reaches kubectl apply.
  local kind name
  kind="$(printf '%s' "$json" | jq -r '.kind // empty' 2>/dev/null)"
  name="$(printf '%s' "$json" | jq -r '.metadata.name // empty' 2>/dev/null)"
  if [ "$kind" != "Secret" ] || [ "$name" != "$secret" ]; then
    warn "restore: cached object for ${secret} is not the expected Secret (kind=${kind:-?} name=${name:-?}) — refusing"
    return 0
  fi

  # Validate the cached cert still has comfortable life; otherwise let it issue.
  crt="$(printf '%s' "$json" | jq -r '.data["tls.crt"] // empty' 2>/dev/null | base64 -d 2>/dev/null)"
  if [ -z "$crt" ] || ! printf '%s' "$crt" | cert_valid; then
    log "restore: cached ${secret} missing/expiring within ${RENEW_MARGIN_DAYS}d — skip (issue fresh)"
    return 0
  fi

  if printf '%s' "$json" | kubectl apply -n "$NS_MATRIX" -f - >/dev/null 2>&1; then
    log "restore: applied cached ${secret} into ${NS_MATRIX} (cert-manager will adopt, no re-issue)"
  else
    warn "restore: kubectl apply of cached ${secret} failed (non-fatal; will issue fresh)"
  fi
  return 0
}

for secret in "${SECRETS[@]}"; do
  if [ "$ACTION" = "backup" ]; then
    backup_secret "$secret"
  else
    restore_secret "$secret"
  fi
done

exit 0
