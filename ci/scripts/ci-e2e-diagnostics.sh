#!/usr/bin/env bash
# On-failure diagnostic dump for the Roundcube-login e2e shards (5 & 10).
#
# WHY THIS EXISTS
# --------------
# Shards 5 (tests/email/roundcube-basic.spec.ts) and 10
# (tests/sso/cross-app-sso.spec.ts "SSO to Roundcube") fail together whenever
# Roundcube's OIDC login never reaches the inbox (the ROUNDCUBE_INBOX selector
# never appears -> 60s timeout). The Playwright output only ever says "inbox
# never appeared" — it cannot say WHICH layer broke (Stalwart OAUTHBEARER token
# validation / Roundcube app+session / Keycloak / DB schema). Because nobody
# ever saw the real error, every past debugging cycle GUESSED a layer, patched
# static state for it, got a lucky green, and the failure came back. See memory
# project_shard5_10_roundcube_login_root_cause.
#
# This step captures the server-side evidence (roundcube + stalwart + keycloak
# pod logs/state) AT THE MOMENT OF FAILURE, while the failing pods are still
# live, so the NEXT failure NAMES the layer instead of needing CI archaeology.
#
# CONTRACT
# --------
# - Runs ONLY as a `when: status: [failure]` step inside e2e-shard-5/10, so it
#   adds zero latency to green runs and zero new DAG edges.
# - Best-effort: it must NEVER mask the real test failure. It always exits 0
#   (the shard's failure status already stands), and every external call is
#   guarded so a missing cluster / expired lease just degrades to a warning.
# - Keeps LINODE_CLI_TOKEN out of the Playwright-execution step: this is a
#   separate step with its own minimal env.

# Best-effort throughout: no -e, no pipefail (every call is individually
# guarded). We control failure explicitly via warn+exit 0.
set +e +o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"   # provides vcli()
# shellcheck source=../../scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"           # provides dump_pod_diagnostics, print_status

LOG_TAIL="${MT_DIAG_LOG_TAIL:-300}"

echo "=================================================================="
echo "  E2E ROUNDCUBE-LOGIN FAILURE DIAGNOSTICS"
echo "  shard=${E2E_SHARD:-?}  pipeline=#${CI_PIPELINE_NUMBER:-?}"
echo "=================================================================="

# ── Resolve the leased tenant (namespaces = tn-<tenant>-{webmail,mail}) ───────
# 1) Prefer the file the e2e step wrote THIS run — lease-independent, so it
#    survives a PR lease (1000s) expiring during a long (<=15m) shard.
# 2) Fall back to the Valkey reverse-lookup if the file is missing.
E2E_TENANT=""
if [[ -f "$REPO_ROOT/.e2e-tenant" ]]; then
  E2E_TENANT="$(tr -d '[:space:]' < "$REPO_ROOT/.e2e-tenant" 2>/dev/null)"
fi
if [[ -z "$E2E_TENANT" && -n "${CI_VALKEY_PASSWORD:-}" && -n "${CI_PIPELINE_NUMBER:-}" ]]; then
  LEASED_POOL="$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null)"
  if [[ -n "$LEASED_POOL" ]]; then
    POOL_KEY="$(echo "$LEASED_POOL" | tr '[:lower:]-' '[:upper:]_')"
    _tvar="E2E_${POOL_KEY}_TENANT"
    E2E_TENANT="${!_tvar:-}"
  fi
fi
if [[ -z "$E2E_TENANT" ]]; then
  echo "WARNING: could not resolve the leased tenant (no .e2e-tenant file and no"
  echo "         live Valkey lease). Cannot locate tenant namespaces — skipping dump."
  exit 0
fi
echo "Leased tenant: ${E2E_TENANT}"

# ── Fetch a live dev kubeconfig (cluster is still up right after e2e) ─────────
if [[ -z "${LINODE_CLI_TOKEN:-}" ]]; then
  echo "WARNING: LINODE_CLI_TOKEN not set in this step's env — cannot fetch a"
  echo "         kubeconfig; no pod logs available. Wire linode_token into the step."
  exit 0
fi
KCFG="$(mktemp -t ci-e2e-diag-kcfg-XXXXXX)"
trap 'rm -f "$KCFG"' EXIT
if ! ci_fetch_dev_kubeconfig "$KCFG"; then
  echo "WARNING: could not fetch dev kubeconfig (cluster reaped, or Linode API"
  echo "         issue) — no pod logs available."
  exit 0
fi
export KUBECONFIG="$KCFG"

NS_WEBMAIL="tn-${E2E_TENANT}-webmail"
NS_MAIL="tn-${E2E_TENANT}-mail"
NS_AUTH="infra-auth"

dump_component() {  # namespace selector friendly-name
  local ns="$1" sel="$2" name="$3"
  echo ""
  echo "------------------------------------------------------------------"
  echo "  ${name}   (ns=${ns}, selector=${sel})"
  echo "------------------------------------------------------------------"
  dump_pod_diagnostics "$ns" "$sel"
  echo ""
  echo ">>> ${name} current logs (last ${LOG_TAIL} lines, all containers):"
  kubectl logs -n "$ns" -l "$sel" --tail="$LOG_TAIL" --all-containers=true --timestamps 2>&1 \
    | sed 's/^/    /'
  echo ""
  echo ">>> ${name} PREVIOUS logs (only if a container restarted):"
  kubectl logs -n "$ns" -l "$sel" --previous --tail="$LOG_TAIL" --all-containers=true 2>/dev/null \
    | sed 's/^/    /' || echo "    (no previous container)"
}

# Roundcube — the OIDC client. DB-schema / session / oauth-state errors land here.
dump_component "$NS_WEBMAIL" "app=roundcube" "ROUNDCUBE"

# Stalwart — the OAUTHBEARER token validator + IMAP backend. Token-decode /
# unauthorized errors here mean the OIDC->IMAP auth leg failed.
dump_component "$NS_MAIL" "app=stalwart" "STALWART"
echo ""
echo ">>> STALWART auth/oauth/token highlights (grep over last 1000 lines):"
kubectl logs -n "$NS_MAIL" -l app=stalwart --tail=1000 --all-containers=true 2>/dev/null \
  | grep -iE 'oauth|bearer|token|jwt|jwks|unauthor|decode|introspect|oidc|authenticat' \
  | tail -n 60 | sed 's/^/    /' || echo "    (no auth-related lines found)"

# Keycloak — token issuance / redirect_uri / invalid_client errors. Helm-managed,
# so match pods by name rather than a fixed label.
echo ""
echo "------------------------------------------------------------------"
echo "  KEYCLOAK   (ns=${NS_AUTH})"
echo "------------------------------------------------------------------"
_kc_pods="$(kubectl get pods -n "$NS_AUTH" -o name 2>/dev/null | grep -i keycloak)"
if [[ -z "$_kc_pods" ]]; then
  echo "    (no keycloak pods found in ${NS_AUTH})"
else
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    echo ">>> ${p} error/warn/token highlights (last 1000 lines):"
    kubectl logs -n "$NS_AUTH" "$p" --tail=1000 2>/dev/null \
      | grep -iE 'error|warn|invalid|token|client|roundcube|reject|redirect_uri' \
      | tail -n 40 | sed 's/^/    /' || echo "    (none)"
  done <<< "$_kc_pods"
fi

echo ""
echo "=================================================================="
echo "  HOW TO READ THIS (see memory project_shard5_10_roundcube_login_root_cause):"
echo "   • roundcube 'DB Error: column ... does not exist'      -> DB schema"
echo "   • stalwart  OAUTHBEARER / 'Failed to decode token' /"
echo "               'unauthorized'                              -> Stalwart token validation"
echo "   • roundcube session / oauth-state / redirect errors    -> Roundcube 1.7 / session store"
echo "   • keycloak  invalid_client / redirect_uri              -> Keycloak client config"
echo "   • browser-side [roundcube-stuck:*] lines in the e2e log show WHERE"
echo "     the browser stopped (Keycloak vs webmail-no-inbox)."
echo "=================================================================="
exit 0
