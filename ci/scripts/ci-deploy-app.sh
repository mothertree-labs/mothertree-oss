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
#   imaps-readiness — FATAL gate: prove an authenticated IMAPS session to the
#                          EXTERNAL Stalwart endpoint the e2e tests use is
#                          establishable before e2e runs (cold-start gap #20)
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

ci_decrypt_vault "$VAULT_FILE" "$MT_ENV" "$WORK_DIR/secrets.tar.gz"
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

      # Cold-start gap #19: FATAL gate — prove the Keycloak→Stalwart SMTP
      # submission path (connect+STARTTLS+AUTH) actually works before e2e
      # (shard-6 onboarding/magic-link) depends on it. This is the on-demand-dev
      # split-pipeline hook; create_env carries an identical gate but only its
      # --prep-only/--finalize-only phases run here, so the monolithic mail
      # block (and its gate) is skipped on this path. Deliberately a SEPARATE
      # explicitly-fatal call, NOT folded into ensure-keycloak-smtp above —
      # that call is swallowed by `|| echo WARNING` (cold-start gap #17 lesson:
      # ci-deploy-app.sh's `|| echo WARNING` must never mask a hard gate).
      echo "=== Cold-start gate #19: Stalwart SMTP submission readiness ==="
      source "$REPO_ROOT/scripts/lib/smtp-credentials.sh"
      mt_export_smtp_relay_env "$NS_ADMIN"
      export NS_AUTH="${NS_AUTH:-infra-auth}"
      if [ -z "${SMTP_RELAY_HOST:-}" ] || [ -z "${SMTP_RELAY_USERNAME:-}" ] || [ -z "${SMTP_RELAY_PASSWORD:-}" ]; then
        echo "FATAL: smtp-credentials in $NS_ADMIN missing/incomplete after provisioning"; exit 1
      fi
      if ! mt_wait_for_stalwart_submission; then
        echo "FATAL: cold-start gate #19 — Stalwart SMTP submission connect/AUTH not usable"
        exit 1
      fi
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

    # Nextcloud admin credentials live in the `nextcloud-credentials` K8s
    # Secret (created by deploy-nextcloud.sh; the chart's `existingSecret`),
    # NOT in tenant config. We read it the same way deploy-calendar-automation.sh
    # does, but on the re-mint path the password is NOT functionally required:
    # it's only used for the optional admin password drift-correction
    # (occ user:resetpassword, `|| true`), which deploy-dev-calendar already
    # performed ~minutes earlier in this same pipeline. The real token mint
    # authenticates as root (occ user:add) / www-data
    # (create-caldav-tokens.php), never as admin. So a read failure here is a
    # warning, not fatal — failing hard would skip the re-mint and leave
    # e2e-mailrt without a token (the exact regression this fix targets).
    NEXTCLOUD_ADMIN_PASSWORD=$(kubectl get secret nextcloud-credentials -n "$NS_FILES" \
      -o jsonpath='{.data.nextcloud-password}' 2>/dev/null | base64 -d || echo "")
    if [ -z "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
      echo "WARNING: could not read Nextcloud admin password from secret 'nextcloud-credentials' in $NS_FILES"
      echo "         Proceeding without it — the admin drift-correction is skipped;"
      echo "         token minting does not depend on it. (Tracked: investigate the"
      echo "         secret-read failure separately if it recurs.)"
      NEXTCLOUD_ADMIN_PASSWORD=""
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

  imaps-readiness)
    # Cold-start gap #20 — FATAL gate for the EXTERNAL IMAPS path the e2e
    # tests use.
    #
    # Pinned root cause (controlled experiment): a cold Stalwart delivers
    # mail in ~48ms — there is NO data-path latency. The e2e symptom
    # `[imap] Delivery SLOW: ~110s after 1 poll(s)` is 100% the e2e IMAP
    # client (CI box → external IMAPS endpoint) being unable to ESTABLISH a
    # session for ~110s on cold-start (NodeBalancer / :993 / cert
    # convergence); once connected the message is instantly present
    # (`1 matched` on poll #1).
    #
    # Cold-start gate #19 (mt_wait_for_stalwart_submission) guards the
    # in-cluster Keycloak→Stalwart :588 SMTP-submission path, but NOTHING
    # guards the external IMAPS :993 path the e2e shards actually connect to,
    # and on a main-push that path is unguarded entirely. This step converts
    # the silent in-shard 110s stall into an explicit, loud, attributed
    # pre-e2e wait that self-heals (the connect just needs the external edge
    # to converge).
    #
    # Mirrors gate #19's bounded-poll + fail-closed + clear-logging style,
    # but runs FROM THE CI BOX against the external IMAPS endpoint
    # (E2E_STALWART_IMAP_HOST:E2E_STALWART_IMAP_PORT) — exactly the path the
    # e2e/helpers/imap.ts client takes — NOT from an in-cluster pod (that
    # would take the internal ClusterIP path and false-green).
    #
    # Lives here (a finalize-sibling that runs on BOTH pull_request and
    # push:main, like create-test-users/remint-caldav-tokens — gap-#18
    # lesson) and is wired AFTER remint-caldav-tokens so the e2e-mailrt user
    # already exists; we authenticate as that exact user (the one the
    # calendar-external-invite shards use) so the gate exercises the literal
    # path under test.
    echo "=== Cold-start gate #20: external IMAPS session readiness ==="
    source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config

    if [ "${MAIL_ENABLED:-false}" != "true" ]; then
      echo "Mail not enabled for tenant $E2E_TENANT — no external IMAPS path to gate"
      echo "=== CI Deploy App complete: env=$MT_ENV mode=$MODE ==="
      exit 0
    fi

    # ci-resolve-tenant.sh (sourced above) already mapped the leased pool's
    # E2E_STALWART_IMAP_HOST / E2E_STALWART_IMAP_PORT / E2E_STALWART_ADMIN_PASSWORD
    # to their standard names — the same vars e2e/helpers/imap.ts reads.
    : "${E2E_STALWART_IMAP_HOST:?FATAL: E2E_STALWART_IMAP_HOST required (pool secret e2e_poolN_stalwart_imap_host)}"
    : "${E2E_STALWART_IMAP_PORT:?FATAL: E2E_STALWART_IMAP_PORT required (pool secret e2e_poolN_stalwart_imap_port)}"
    : "${E2E_STALWART_ADMIN_PASSWORD:?FATAL: E2E_STALWART_ADMIN_PASSWORD required (pool secret e2e_poolN_stalwart_admin_password)}"
    : "${E2E_BASE_DOMAIN:?FATAL: E2E_BASE_DOMAIN required to build the e2e-mailrt master username}"

    # Master-user auth username form, copied EXACTLY from
    # e2e/helpers/imap.ts :: connectAsMaster: it tries "<localpart>%master"
    # first (and "<email>%master" as a fallback). e2e-mailrt is the fixed
    # mail-roundtrip user created by ci-create-test-users.sh as
    # e2e-mailrt@${E2E_BASE_DOMAIN}; the calendar-external-invite shards
    # authenticate as exactly this principal.
    MASTER_USER="e2e-mailrt"
    MASTER_USER_EMAIL="e2e-mailrt@${E2E_BASE_DOMAIN}"

    GATE_DEADLINE="${MT_IMAPS_GATE_DEADLINE:-240}"
    echo "Cold-start gate #20: verifying authenticated IMAPS session"
    echo "  from CI box → ${E2E_STALWART_IMAP_HOST}:${E2E_STALWART_IMAP_PORT}"
    echo "  (TLS connect + LOGIN as ${MASTER_USER}%master + SELECT INBOX + LOGOUT), deadline ${GATE_DEADLINE}s"

    # Dependency-light: python3 stdlib imaplib (no npm ci needed here — this
    # workflow may not have run it; sibling CI scripts already shell out to
    # python3 the same way). Password is fed via STDIN, never argv/env, so it
    # is not visible in the process list or /proc/<pid>/environ (mirrors
    # gate #19 in scripts/lib/common.sh). Host/port/user are non-secret env.
    _imaps_py='
import os, sys, ssl, time, imaplib
host = os.environ["IHOST"]
port = int(os.environ["IPORT"])
ulocal = os.environ["IUSER_LOCAL"]
uemail = os.environ["IUSER_EMAIL"]
deadline = time.time() + float(os.environ["IDEADLINE"])
pw = sys.stdin.readline().rstrip("\n")
# Dev/CI uses self-signed certs; mirror imap.ts rejectUnauthorized:false.
# Cert validity is a separate gap with its own gate — do not couple this
# connect-readiness probe to cert-manager convergence.
ctx = ssl._create_unverified_context()
# Same candidate order as e2e/helpers/imap.ts connectAsMaster
# (candidates = [userEmail, username]): full email first, then localpart,
# each as "<name>%master".
candidates = [uemail + "%master", ulocal + "%master"]
attempt = 0
last = "(no attempt)"
while time.time() < deadline:
    attempt += 1
    for cand in candidates:
        M = None
        try:
            M = imaplib.IMAP4_SSL(host, port, ssl_context=ctx, timeout=15)
            M.login(cand, pw)
            typ, _ = M.select("INBOX")
            if typ != "OK":
                raise RuntimeError("SELECT INBOX returned %s" % typ)
            M.logout()
            print("STALWART_IMAPS_PROBE_OK attempt=%d %s:%d LOGIN=%s"
                  % (attempt, host, port, cand))
            sys.exit(0)
        except Exception as e:
            last = "%s as %s: %s" % (type(e).__name__, cand, e)
            try:
                if M is not None:
                    M.logout()
            except Exception:
                pass
    print("  attempt %d IMAPS session not ready yet: %s" % (attempt, last),
          flush=True)
    time.sleep(10)
print("STALWART_IMAPS_PROBE_FAIL last_error: %s" % last)
sys.exit(1)
'
    _gate_rc=0
    printf '%s' "$E2E_STALWART_ADMIN_PASSWORD" | \
      IHOST="$E2E_STALWART_IMAP_HOST" \
      IPORT="$E2E_STALWART_IMAP_PORT" \
      IUSER_LOCAL="$MASTER_USER" \
      IUSER_EMAIL="$MASTER_USER_EMAIL" \
      IDEADLINE="$GATE_DEADLINE" \
      python3 -c "$_imaps_py" || _gate_rc=$?

    if [ "$_gate_rc" -ne 0 ]; then
      echo "FATAL: cold-start gate #20 — external IMAPS session to" \
           "${E2E_STALWART_IMAP_HOST}:${E2E_STALWART_IMAP_PORT} not establishable" \
           "within ${GATE_DEADLINE}s as ${MASTER_USER}%master."
      echo "       This is the external edge (NodeBalancer/:993/cert) NOT having"
      echo "       converged — it is the exact ~110s cold-connect stall the e2e"
      echo "       calendar-external-invite shards would otherwise hit silently."
      echo "       Failing the build loudly (hard gate; never silently skipped)."
      exit 1
    fi
    echo "OK: external IMAPS session to ${E2E_STALWART_IMAP_HOST}:${E2E_STALWART_IMAP_PORT} is usable"
    ;;

  *)
    echo "ERROR: Unknown mode: $MODE"
    echo "Valid modes: prep, finalize, matrix, nextcloud, jitsi, stalwart, roundcube, calendar, email-probe, portals, remint-caldav-tokens, imaps-readiness"
    exit 1
    ;;
esac

echo "=== CI Deploy App complete: env=$MT_ENV mode=$MODE ==="
