#!/usr/bin/env bash
set -euo pipefail

# CI Deploy App — runs a single deploy script for one tenant.
#
# Used by the parallel app deploy CI steps. Handles vault decryption,
# submodule init, tenant resolution, and config loading identically to
# ci-deploy.sh, then runs a single deploy-<app>.sh script.
#
# Usage:
#   ci/scripts/ci-deploy-app.sh <env> <mode>
#
# Modes:
#   prep            — create_env --prep-only (namespaces, TLS, DNS, Keycloak)
#   finalize        — create_env --finalize-only (cleanup, probes, health checks)
#   matrix          — apps/deploy-matrix.sh
#   nextcloud       — apps/deploy-nextcloud.sh (includes Collabora if enabled)
#   jitsi           — apps/deploy-jitsi.sh + metrics exporter
#   stalwart        — apps/deploy-stalwart.sh
#   roundcube       — apps/deploy-roundcube.sh
#   calendar        — apps/deploy-calendar-automation.sh
#   email-probe     — apps/deploy-email-probe.sh
#   portals         — apps/deploy-admin-portal.sh + deploy-account-portal.sh
#   remint-caldav-tokens — re-mint CalDAV tokens + restart calendar-automation
#                          (cold-start gap #17: run AFTER create-test-users so
#                           late-created e2e users get tokens; calendar-automation
#                           only reads the Secret at startup)
#
# Required environment variables:
#   DEPLOY_VAULT_PASSWORD — Ansible Vault password
#   GITHUB_PAT            — GitHub PAT for private config submodules
#   CI_VALKEY_PASSWORD    — Valkey password for tenant lease resolution

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"

MT_ENV="${1:?Usage: ci-deploy-app.sh <env> <mode>}"
MODE="${2:?Usage: ci-deploy-app.sh <env> <mode>}"

: "${DEPLOY_VAULT_PASSWORD:?DEPLOY_VAULT_PASSWORD is required}"

echo "=== CI Deploy App: env=$MT_ENV mode=$MODE pipeline=#${CI_PIPELINE_NUMBER:-unknown} ==="

# ── Decrypt vault ────────────────────────────────────────────────
VAULT_FILE="/home/woodpecker/deploy-vaults/deploy-vault-${MT_ENV}.vault"
if [[ ! -f "$VAULT_FILE" ]]; then
  echo "ERROR: Deploy vault not found: $VAULT_FILE"
  exit 1
fi

WORK_DIR=$(mktemp -d /tmp/mt-deploy-XXXXXX)
chmod 0700 "$WORK_DIR"

_cleanup() {
  # On-demand-dev heartbeat — touch the bucket so the idle reaper sees this
  # CI step as recent activity. Mirrors ci-deploy.sh; runs on every exit for
  # dev only. Tolerant of failure.
  if [[ "$MT_ENV" == "dev" ]] && [[ -n "${DEV_STATE_BUCKET:-}" ]]; then
    "$REPO_ROOT/scripts/dev-heartbeat.sh" || true
  fi
  rm -rf "$WORK_DIR"
  if [[ -d "$REPO_ROOT/config/tenants" ]]; then
    find "$REPO_ROOT/config/tenants" -name "*.secrets.yaml" -newer "$0" -delete 2>/dev/null || true
  fi
}
trap _cleanup EXIT

ansible-vault decrypt "$VAULT_FILE" \
  --vault-password-file <(echo "$DEPLOY_VAULT_PASSWORD") \
  --output "$WORK_DIR/secrets.tar.gz"
tar xzf "$WORK_DIR/secrets.tar.gz" -C "$WORK_DIR"
rm -f "$WORK_DIR/secrets.tar.gz"

# ── Set up environment ───────────────────────────────────────────
# For dev, refetch the kubeconfig from the Linode API so we hit the live
# cluster. Each Woodpecker workflow has its own workspace; the
# kubeconfig the bringup writes is not visible here. See ci-deploy.sh
# for details.
if [[ "$MT_ENV" == "dev" ]] && [[ -n "${LINODE_CLI_TOKEN:-}" ]]; then
  if ci_fetch_dev_kubeconfig "$WORK_DIR/kubeconfig.yaml"; then
    echo "Fetched fresh kubeconfig from Linode API for env=dev"
  else
    echo "WARNING: Linode kubeconfig fetch failed; falling back to vault copy"
  fi
fi
export KUBECONFIG="$WORK_DIR/kubeconfig.yaml"
export MT_TERRAFORM_OUTPUTS_FILE="$WORK_DIR/terraform-outputs.env"

[[ -f "$KUBECONFIG" ]] || { echo "ERROR: kubeconfig.yaml not found in vault"; exit 1; }
[[ -f "$MT_TERRAFORM_OUTPUTS_FILE" ]] || { echo "ERROR: terraform-outputs.env not found in vault"; exit 1; }

# Source the terraform outputs so child scripts (dev-heartbeat.sh) see
# DEV_STATE_BUCKET / DEV_STATE_S3_*. Prod / prod-eu have these as empty
# strings, harmless.
set -a
# shellcheck disable=SC1090
source "$MT_TERRAFORM_OUTPUTS_FILE"
set +a

# ── Clone private config submodules ───────────────────────────────
cd "$REPO_ROOT"
if [[ -n "${GITHUB_PAT:-}" ]]; then
  git config --global url."https://x-access-token:${GITHUB_PAT}@github.com/".insteadOf "git@github.com:"
fi
git submodule update --init config/platform config/tenants || {
  echo "ERROR: Failed to init config submodules"
  exit 1
}

# ── Copy secrets from vault ──────────────────────────────────────
if [[ -d "$WORK_DIR/tenants" ]]; then
  for tenant_secrets_dir in "$WORK_DIR/tenants"/*/; do
    [[ -d "$tenant_secrets_dir" ]] || continue
    tenant_name=$(basename "$tenant_secrets_dir")
    target_dir="$REPO_ROOT/config/tenants/$tenant_name"
    if [[ -d "$target_dir" ]]; then
      cp "$tenant_secrets_dir"/*.secrets.yaml "$target_dir/" 2>/dev/null || true
    fi
  done
else
  echo "ERROR: No tenants/ directory in vault archive"
  exit 1
fi

# ── Resolve tenant ───────────────────────────────────────────────
: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"
source "$REPO_ROOT/ci/scripts/ci-resolve-tenant.sh"
if [[ -z "${E2E_TENANT:-}" ]]; then
  echo "ERROR: Could not resolve leased tenant from Valkey"
  exit 1
fi
echo "Resolved tenant: $E2E_TENANT"

# Renew the lease and reverse-lookup keys now that we've resolved the tenant.
# The prep step's renewal loop dies when prep exits, so the TTL has been counting
# down through all the parallel app deploy steps. Without this renewal, the keys
# can expire before the finalize step runs (the aggregate time of parallel steps
# can exceed the TTL even though each individual step is short).
_POOL=$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)
if [[ -n "$_POOL" ]]; then
  vcli EXPIRE "ci-lease-${_POOL}" 1000 >/dev/null 2>&1 || true
  vcli EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" 1000 >/dev/null 2>&1 || true
fi

# ── Pre-load tenant config for app deploy modes ─────────────────
# Source config loading so env vars are available for inline deploy logic
# (e.g., Jitsi metrics exporter, Collabora check)
export MT_ENV MT_TENANT="$E2E_TENANT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/args.sh"
# Set MT_NESTING_LEVEL=0 so deploy scripts run their own helm repo setup.
# Unlike create_env (which sets nesting=1 to skip repo adds in sub-scripts),
# each parallel CI step runs independently and needs its own repos.
export MT_NESTING_LEVEL=0

# Do NOT set SKIP_HELM_REPO_UPDATE — each parallel step needs to add
# its own helm repos since the prep step only adds repos needed for
# the prep phase (cert-manager, etc.), not app-specific repos like ananace.

# ── Dispatch ─────────────────────────────────────────────────────
case "$MODE" in
  prep)
    echo "=== Running create_env --prep-only ==="
    "$REPO_ROOT/scripts/create_env" -e "$MT_ENV" -t "$E2E_TENANT" --prep-only
    ;;

  finalize)
    echo "=== Running create_env --finalize-only ==="
    "$REPO_ROOT/scripts/create_env" -e "$MT_ENV" -t "$E2E_TENANT" --finalize-only
    ;;

  matrix)
    echo "=== Deploying Matrix ==="
    "$REPO_ROOT/apps/deploy-matrix.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0
    ;;

  nextcloud)
    echo "=== Deploying Nextcloud ==="
    # Load tenant config for Collabora check
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    # Deploy Collabora first if enabled (must be ready before Nextcloud)
    if [ "${OFFICE_ENABLED:-false}" = "true" ]; then
      echo "  Deploying Collabora CODE..."
      helm repo add collabora https://collaboraonline.github.io/online/ 2>/dev/null || true
      helm repo update >/dev/null 2>&1
      kubectl create namespace "$NS_OFFICE" --dry-run=client -o yaml | kubectl apply -f -
      pushd "$REPO_ROOT/apps" >/dev/null
        helmfile -e "$MT_ENV" -l name=collabora-online sync
      popd >/dev/null
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=collabora-online \
        -n "$NS_OFFICE" --timeout=300s
      echo "  Collabora deployed"
    fi

    "$REPO_ROOT/apps/deploy-nextcloud.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0
    ;;

  jitsi)
    echo "=== Deploying Jitsi ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    "$REPO_ROOT/apps/deploy-jitsi.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0

    # Deploy Jitsi metrics exporter and ServiceMonitors
    envsubst '${TURN_SERVER_IP}' < "$REPO_ROOT/apps/manifests/jitsi/jitsi-metrics-exporter.yaml" | \
      sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

    if kubectl get deployment jitsi-metrics-exporter -n "$NS_JITSI" >/dev/null 2>&1; then
      kubectl rollout restart deployment/jitsi-metrics-exporter -n "$NS_JITSI"
    fi
    kubectl wait --for=condition=available deployment/jitsi-metrics-exporter -n "$NS_JITSI" --timeout=120s || \
      echo "WARNING: Metrics exporter may not be ready yet"

    for manifest in jitsi-metrics-exporter-servicemonitor jvb-servicemonitor jicofo-servicemonitor jitsi-alerting-rules; do
      cat "$REPO_ROOT/apps/manifests/jitsi/${manifest}.yaml" | \
        sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -
    done
    kubectl delete prometheusrule jitsi-turn-alerts -n "$NS_JITSI" 2>/dev/null || true
    echo "Jitsi monitoring resources deployed"
    ;;

  stalwart)
    echo "=== Deploying Stalwart ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    if [ "${MAIL_ENABLED:-false}" = "true" ]; then
      "$REPO_ROOT/apps/deploy-stalwart.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0

      # Provision the shared `mailer@` principal + smtp-credentials Secret
      # before the chart-backed callers (matrix, nextcloud) deploy. Those
      # pipelines add `depends_on: - deploy-dev-stalwart` so they serialise
      # behind this step.
      echo "=== Provisioning SMTP service accounts ==="
      set +e
      "$REPO_ROOT/scripts/provision-smtp-service-accounts" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0
      rc=$?
      set -e
      case "$rc" in
        0|2) : ;;  # 0 = changed, 2 = no-op — both OK
        *) echo "FATAL: provision-smtp-service-accounts failed (exit $rc)"; exit "$rc" ;;
      esac

      # Drift-correct the Keycloak realm SMTP config now that creds exist.
      # Non-fatal — ensure-keycloak-smtp can be re-run manually.
      echo "=== Drift-correcting Keycloak realm SMTP ==="
      "$REPO_ROOT/apps/scripts/ensure-keycloak-smtp.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0 || \
        echo "WARNING: ensure-keycloak-smtp failed (non-fatal)"
    else
      echo "Stalwart: skipping (mail_enabled is not true)"
    fi
    ;;

  roundcube)
    echo "=== Deploying Roundcube ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    if [ "${WEBMAIL_ENABLED:-false}" = "true" ]; then
      "$REPO_ROOT/apps/deploy-roundcube.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0
    else
      echo "Roundcube: skipping (webmail_enabled is not true)"
    fi
    ;;

  calendar)
    echo "=== Deploying Calendar Automation ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    if [ "${CALENDAR_ENABLED:-false}" = "true" ] && [ "${MAIL_ENABLED:-false}" = "true" ] && [ "${FILES_ENABLED:-false}" = "true" ]; then
      if [ -f "$REPO_ROOT/apps/deploy-calendar-automation.sh" ]; then
        "$REPO_ROOT/apps/deploy-calendar-automation.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0 || \
          echo "WARNING: calendar automation deploy failed (non-fatal)"
      fi
    else
      echo "Calendar Automation: skipping (requires calendar+mail+files enabled)"
    fi
    ;;

  email-probe)
    echo "=== Deploying Email Probe ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    if [ "${EMAIL_PROBE_ENABLED:-false}" = "true" ] && [ "${MAIL_ENABLED:-false}" = "true" ]; then
      if [ -f "$REPO_ROOT/apps/deploy-email-probe.sh" ]; then
        "$REPO_ROOT/apps/deploy-email-probe.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0 || \
          echo "WARNING: email probe deploy failed (non-fatal)"
      fi
    else
      echo "Email Probe: skipping (requires email_probe+mail enabled)"
    fi
    ;;

  portals)
    echo "=== Deploying Portals ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    # Load release version for portal containers
    source "$REPO_ROOT/scripts/lib/release.sh"
    _mt_load_release_version

    if [ "${ADMIN_PORTAL_ENABLED:-false}" = "true" ]; then
      "$REPO_ROOT/apps/deploy-admin-portal.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0
    fi
    if [ "${ACCOUNT_PORTAL_ENABLED:-false}" = "true" ]; then
      "$REPO_ROOT/apps/deploy-account-portal.sh" -e "$MT_ENV" -t "$E2E_TENANT" --nesting-level=0
    fi
    ;;

  remint-caldav-tokens)
    # Cold-start gap #17 — re-mint CalDAV tokens AFTER create-test-users.
    #
    # apps/deploy-calendar-automation.sh mints per-user CalDAV app-passwords at
    # calendar-automation deploy time, enumerating the users that exist *then*.
    # The fixed mail user `e2e-mailrt` is created later, in the create-test-users
    # step of deploy-dev-finalize (it was moved there to fix pipeline #1258's
    # OIDC-404). calendar-automation reads the token Secret only once at startup
    # (server.js loadCaldavTokens()), so without a re-mint + restart the 3
    # calendar-external-invite e2e tests time out waiting for CalDAV events
    # (admin creds can't write another user's calendar).
    #
    # This re-mints (now that e2e-mailrt exists), rollout-restarts the
    # calendar-automation Deployment so it reloads the Secret, and hard-asserts
    # the e2e-mailrt token is present (project rule: fail loudly, never skip).
    #
    # Deferred prod ordering gap (real users created after a calendar-automation
    # deploy) is OUT OF SCOPE — tracked in GitHub issue #412.
    echo "=== Re-minting CalDAV tokens (cold-start gap #17) ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    if [ "${CALENDAR_ENABLED:-false}" != "true" ] || [ "${MAIL_ENABLED:-false}" != "true" ] || [ "${FILES_ENABLED:-false}" != "true" ]; then
      echo "Calendar/mail/files not all enabled for tenant $E2E_TENANT — nothing to re-mint"
      echo "=== CI Deploy App complete: env=$MT_ENV mode=$MODE ==="
      exit 0
    fi

    mt_require_commands kubectl jq

    # calendar-automation shares the Stalwart (mail) namespace.
    export NS_MAIL="$NS_STALWART"

    # Nextcloud admin credentials live in a K8s Secret (auto-generated by the
    # Helm chart), NOT in tenant config — read them the same way
    # deploy-calendar-automation.sh does.
    NEXTCLOUD_ADMIN_PASSWORD=$(kubectl get secret nextcloud -n "$NS_FILES" \
      -o jsonpath='{.data.nextcloud-password}' 2>/dev/null | base64 -d || echo "")
    if [ -z "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
      echo "FATAL: could not read Nextcloud admin password from secret 'nextcloud' in $NS_FILES"
      exit 1
    fi
    export NEXTCLOUD_ADMIN_PASSWORD

    # Fail-fast on the inputs the KC→Nextcloud provisioning + mint require.
    # On this CI re-mint path these are non-optional: if any are missing the
    # provisioning silently no-ops and e2e-mailrt never gets a token (the exact
    # silent-skip failure mode this fix exists to eliminate).
    : "${KEYCLOAK_ADMIN_PASSWORD:?FATAL: KEYCLOAK_ADMIN_PASSWORD required for CalDAV re-mint (KC->Nextcloud provisioning)}"
    : "${AUTH_HOST:?FATAL: AUTH_HOST required for CalDAV re-mint}"
    : "${TENANT_KEYCLOAK_REALM:?FATAL: TENANT_KEYCLOAK_REALM required for CalDAV re-mint}"
    : "${NS_FILES:?FATAL: NS_FILES required for CalDAV re-mint}"
    : "${NS_MAIL:?FATAL: NS_MAIL required for CalDAV re-mint}"

    source "$REPO_ROOT/apps/scripts/mint-caldav-tokens.sh"
    mt_mint_caldav_tokens

    # calendar-automation reads the Secret only at startup. The Secret-only
    # mutation does not change the deployment's CONFIG_CHECKSUM annotation, so
    # an explicit rollout restart is required to reload the tokens.
    echo "Restarting calendar-automation Deployment to reload CalDAV tokens..."
    kubectl rollout restart deploy/calendar-automation -n "$NS_MAIL"
    kubectl rollout status deploy/calendar-automation -n "$NS_MAIL" --timeout=180s

    # Hard assertion: the e2e mail-roundtrip user MUST have a token now, or the
    # calendar-external-invite tests will time out exactly as before. Key form
    # is "<user>@<E2E_BASE_DOMAIN>" (ci-create-test-users.sh: EMAIL_DOMAIN=E2E_BASE_DOMAIN;
    # server.js keys caldavTokens by the user email).
    : "${E2E_BASE_DOMAIN:?FATAL: E2E_BASE_DOMAIN required to assert e2e-mailrt token}"
    EXPECTED_KEY="e2e-mailrt@${E2E_BASE_DOMAIN}"
    echo "Asserting CalDAV token present for ${EXPECTED_KEY}..."
    if kubectl get secret calendar-automation-caldav-tokens -n "$NS_MAIL" \
         -o jsonpath='{.data.caldav-tokens\.json}' 2>/dev/null | base64 -d \
         | jq -e --arg k "$EXPECTED_KEY" 'has($k)' >/dev/null 2>&1; then
      echo "OK: CalDAV token present for ${EXPECTED_KEY}"
    else
      echo "FATAL: no CalDAV token for ${EXPECTED_KEY} after re-mint."
      echo "       calendar-external-invite e2e tests would time out. Failing the build."
      echo "       Tokens present for (keys):"
      kubectl get secret calendar-automation-caldav-tokens -n "$NS_MAIL" \
        -o jsonpath='{.data.caldav-tokens\.json}' 2>/dev/null | base64 -d \
        | jq -r 'keys[]' 2>/dev/null | sed 's/^/         /' || echo "         (secret missing or unparseable)"
      exit 1
    fi
    ;;

  *)
    echo "ERROR: Unknown mode: $MODE"
    echo "Valid modes: prep, finalize, matrix, nextcloud, jitsi, stalwart, roundcube, calendar, email-probe, portals, remint-caldav-tokens"
    exit 1
    ;;
esac

echo "=== CI Deploy App complete: env=$MT_ENV mode=$MODE ==="
