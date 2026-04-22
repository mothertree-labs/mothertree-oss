#!/bin/bash
# Shared helper: export SMTP_RELAY_* env vars from the `smtp-credentials`
# K8s Secret into the caller's environment, for helmfile render-time value
# injection (Synapse extraSecrets, Nextcloud mail.smtp.*).
#
# The Secret is written by scripts/provision-smtp-service-accounts after
# Stalwart is up. In create_env the provisioner runs before Matrix/Nextcloud,
# so by the time deploy-matrix.sh or deploy-nextcloud.sh call this helper
# the Secret is present.
#
# On a fresh tenant where Stalwart hasn't been deployed yet (e.g. --prep-only,
# or a standalone deploy-matrix run), the Secret is missing — we export empty
# strings and emit a warning. Synapse / Nextcloud still render with empty
# SMTP fields and mail simply won't work until provision runs and a
# subsequent sync picks up the creds.

# Guard against double-sourcing
if [ "${_MT_SMTP_CREDS_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_SMTP_CREDS_LOADED=1

# mt_export_smtp_relay_env <namespace>
#
# Reads smtp-credentials Secret from <namespace> and exports:
#   SMTP_RELAY_HOST, SMTP_RELAY_PORT, SMTP_RELAY_USERNAME, SMTP_RELAY_PASSWORD
mt_export_smtp_relay_env() {
  local ns="$1"
  : "${ns:?mt_export_smtp_relay_env requires a namespace argument}"
  : "${KUBECONFIG:?KUBECONFIG must be set}"

  if kubectl --kubeconfig "$KUBECONFIG" -n "$ns" get secret smtp-credentials >/dev/null 2>&1; then
    local raw
    raw=$(kubectl --kubeconfig "$KUBECONFIG" -n "$ns" get secret smtp-credentials -o json)
    SMTP_RELAY_HOST=$(echo "$raw" | jq -r '.data.SMTP_RELAY_HOST // "" | @base64d')
    SMTP_RELAY_PORT=$(echo "$raw" | jq -r '.data.SMTP_RELAY_PORT // "" | @base64d')
    SMTP_RELAY_USERNAME=$(echo "$raw" | jq -r '.data.SMTP_RELAY_USERNAME // "" | @base64d')
    SMTP_RELAY_PASSWORD=$(echo "$raw" | jq -r '.data.SMTP_RELAY_PASSWORD // "" | @base64d')
  else
    # Emit a warning if a common print helper is available; otherwise stderr.
    if declare -F print_warning >/dev/null 2>&1; then
      print_warning "smtp-credentials Secret not found in $ns; outbound mail will be disabled until provisioning completes"
    else
      echo "[WARN] smtp-credentials Secret not found in $ns; outbound mail will be disabled until provisioning completes" >&2
    fi
    SMTP_RELAY_HOST=""
    SMTP_RELAY_PORT=""
    SMTP_RELAY_USERNAME=""
    SMTP_RELAY_PASSWORD=""
  fi
  export SMTP_RELAY_HOST SMTP_RELAY_PORT SMTP_RELAY_USERNAME SMTP_RELAY_PASSWORD
}
