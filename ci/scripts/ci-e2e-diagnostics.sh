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
# Shard 5 ALSO runs tests/email/email-roundtrip.spec.ts, whose failure is a
# mail DELIVERY problem, not a login one (sender -> external echo group ->
# receiver inbox). The login-shaped capture above is blind to it: a fixed
# `--tail` of the Stalwart log can cover only a few seconds under IMAP-auth
# churn (pipeline #1597: 300 lines = a 28s window that MISSED the echo-group
# send and any inbound echo), the auth/oauth grep filters delivery lines out,
# and Postfix (the inbound MX the echo returns through) was never captured at
# all. So we ALSO capture, time-windowed (not line-capped): the Stalwart mail
# round-trip/delivery lines and the infra-mail Postfix inbound-MX log — naming
# WHICH leg of the round-trip broke (outbound reject vs. reflector latency vs.
# inbound loss).
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
# Time window for components where line-capping loses the signal (Stalwart's
# mail-delivery trace, Postfix). The whole e2e shard runs in well under this, so
# a time window captures the round-trip's outbound send + inbound echo that a
# fixed --tail (28s under IMAP-auth churn, #1597) drops on the floor.
LOG_SINCE="${MT_DIAG_LOG_SINCE:-15m}"

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

dump_component() {  # namespace selector friendly-name [since]
  # Pass a 4th arg (e.g. "$LOG_SINCE") to capture by time window instead of a
  # fixed line tail — use it for components whose log churns past LOG_TAIL lines
  # in seconds (Stalwart, Postfix), so the failure window isn't truncated away.
  local ns="$1" sel="$2" name="$3" since="${4:-}"
  echo ""
  echo "------------------------------------------------------------------"
  echo "  ${name}   (ns=${ns}, selector=${sel})"
  echo "------------------------------------------------------------------"
  dump_pod_diagnostics "$ns" "$sel"
  echo ""
  if [[ -n "$since" ]]; then
    echo ">>> ${name} current logs (since ${since}, all containers):"
    kubectl logs -n "$ns" -l "$sel" --since="$since" --all-containers=true --timestamps 2>&1 \
      | sed 's/^/    /'
  else
    echo ">>> ${name} current logs (last ${LOG_TAIL} lines, all containers):"
    kubectl logs -n "$ns" -l "$sel" --tail="$LOG_TAIL" --all-containers=true --timestamps 2>&1 \
      | sed 's/^/    /'
  fi
  echo ""
  echo ">>> ${name} PREVIOUS logs (only if a container restarted):"
  kubectl logs -n "$ns" -l "$sel" --previous --tail="$LOG_TAIL" --all-containers=true 2>/dev/null \
    | sed 's/^/    /' || echo "    (no previous container)"
}

# Roundcube — the OIDC client. DB-schema / session / oauth-state errors land here.
dump_component "$NS_WEBMAIL" "app=roundcube" "ROUNDCUBE"

# The 300-line tail above MISSES the container entrypoint/startup, which is where
# any schema-init attempt (or its absence) shows up. Capture the FIRST lines of
# the CURRENT roundcube log so the NEXT failure tells us WHETHER the entrypoint
# tried to build the schema at all (pipeline #1571: DB exists but is empty).
echo ""
echo ">>> ROUNDCUBE STARTUP (first 150 log lines — entrypoint / schema-init attempt):"
_rc_startup="$(kubectl logs -n "$NS_WEBMAIL" -l app=roundcube -c roundcube --tail=-1 --timestamps 2>/dev/null | head -150)"
if [[ -z "$_rc_startup" ]]; then
  echo "    (no startup logs captured)"
else
  printf '%s\n' "$_rc_startup" | sed 's/^/    /'
fi
echo ""
echo ">>> ROUNDCUBE schema/init markers (grep over full current log):"
_rc_markers="$(kubectl logs -n "$NS_WEBMAIL" -l app=roundcube -c roundcube --tail=-1 2>/dev/null \
  | grep -iE 'initdb|updatedb|installto|create table|creating|initializ|schema|waiting for|wait for db|database .*(does not exist|not exist)|relation .*does not exist|system' \
  | head -80)"
if [[ -z "$_rc_markers" ]]; then
  # ABSENCE is itself the key signal: in this config the DB is wired via a mounted
  # custom.config.php db_dsnw (NOT ROUNDCUBEMAIL_DB_* env), so the stock image's
  # auto-init (gated on ROUNDCUBEMAIL_DB_TYPE) never fires -> trigger (b).
  echo "    (no schema/init markers found)"
else
  printf '%s\n' "$_rc_markers" | sed 's/^/    /'
fi

# ── Roundcube OIDC login OUTCOMES (per-user) + the oauth-flow error behind a fail ─
# The shard-5 "Echo Group" round-trip failure (pipeline #1580) was a REAL failed
# login for the RECEIVER user — roundcube logged `userlogins: Failed login for
# e2e-mailrcv` while the SENDER (e2e-mailrt) logged in fine, and NO Stalwart IMAP
# auth was even attempted for the receiver. So the failure is in Roundcube's OIDC
# leg (code->token exchange / userinfo), BEFORE IMAP. The 300-line tail + schema +
# Stalwart greps above do not surface it. Capture, over the FULL current log:
#   (1) every per-user login outcome, making the sender-OK / receiver-FAIL
#       asymmetry explicit, and
#   (2) the oauth-flow error detail (token/code/state/userinfo) that names WHY a
#       given user's OIDC login failed.
# Fetch the full current log ONCE, then grep it twice.
_rc_full="$(kubectl logs -n "$NS_WEBMAIL" -l app=roundcube -c roundcube --tail=-1 --timestamps 2>/dev/null)"
echo ""
echo ">>> ROUNDCUBE per-user login outcomes (userlogins: Successful/Failed login for <user>):"
_rc_logins="$(printf '%s\n' "$_rc_full" | grep -iE 'userlogins:|login for ' | tail -n 40)"
if [[ -z "$_rc_logins" ]]; then
  echo "    (no per-user login-outcome lines captured — check log_logins / window)"
else
  printf '%s\n' "$_rc_logins" | sed 's/^/    /'
fi
echo ""
echo ">>> ROUNDCUBE oauth-flow errors (the WHY behind a Failed login — token/code/state/userinfo):"
_rc_oauth="$(printf '%s\n' "$_rc_full" \
  | grep -iE 'oauth|/login/oauth|_action=oauth|invalid_grant|invalid_token|token.*(error|fail|invalid|expired|reject)|userinfo|id_?token|oidc|state mismatch|csrf|curl|could not|unable to' \
  | grep -ivE 'GET /static\.php|\.woff2|\.css|\.js"|blank\.webp|googiespell|tinymce' \
  | sed -E 's/(code|session_state|state|id_token_hint)=[^&" ]*/\1=REDACTED/g' \
  | tail -n 60)"
if [[ -z "$_rc_oauth" ]]; then
  echo "    (no oauth-flow error lines found)"
else
  printf '%s\n' "$_rc_oauth" | sed 's/^/    /'
fi

# Stalwart — the OAUTHBEARER token validator + IMAP backend. Token-decode /
# unauthorized errors here mean the OIDC->IMAP auth leg failed. Capture the log
# by TIME WINDOW (not a 300-line tail): under e2e IMAP-auth churn a fixed tail
# covers only ~28s and drops the round-trip's send/echo lines (#1597).
dump_component "$NS_MAIL" "app=stalwart" "STALWART" "$LOG_SINCE"
echo ""
echo ">>> STALWART auth/oauth/token highlights (grep over last 1000 lines):"
kubectl logs -n "$NS_MAIL" -l app=stalwart --tail=1000 --all-containers=true 2>/dev/null \
  | grep -iE 'oauth|bearer|token|jwt|jwks|unauthor|decode|introspect|oidc|authenticat' \
  | tail -n 60 | sed 's/^/    /' || echo "    (no auth-related lines found)"

# ── Mail round-trip / delivery (the email-roundtrip shard-5 failure) ──────────
# email-roundtrip.spec.ts sends e2e-mailrt -> external echo group -> e2e-mailrcv
# and fails if the echo never lands in the receiver's inbox within 120s. Surface
# the whole round-trip from Stalwart's side over the same time window: the
# OUTBOUND submission (from=e2e-mailrt, to=<echo group>) and its remote-delivery
# RESULT (completed / dsn-perm-fail / bounce / null-mx), plus any INBOUND echo
# back (rcpt-to / message-ingest to e2e-mailrcv). The to=<...> field names the
# echo-group domain without needing its secret here. Delivery-result lines key
# off queueId (not user), so they're matched broadly and bounded by tail.
echo ""
echo ">>> STALWART mail round-trip / delivery (grep over --since=${LOG_SINCE} window):"
kubectl logs -n "$NS_MAIL" -l app=stalwart --since="$LOG_SINCE" --all-containers=true --timestamps 2>/dev/null \
  | grep -iE 'e2e-mailr(t|cv)|queue-message|mail-from|rcpt-to|delivery\.(attempt|domain|completed|null-mx)|dsn-(perm-fail|temp-fail|success)|queue-dsn|bounce|reject|message-ingest' \
  | tail -n 120 | sed 's/^/    /' || echo "    (no mail-delivery lines found in window)"

# Postfix — the inbound MX the echo returns through (Internet -> NodeBalancer:25
# -> infra-mail Postfix -> per-tenant Stalwart). infra-mail is SHARED across all
# tenants, so deliberately do NOT dump its full log (that would surface other
# tenants' envelope metadata into this log): capture pod health + a grep SCOPED
# to the round-trip users only. The inbound echo is addressed to e2e-mailrcv, so
# the user-scoped grep is both tighter and sufficient — no match => the echo
# never re-entered the cluster MX (outbound-reject or reflector-side); present
# here but absent from Stalwart => the loss is the Postfix->Stalwart hop.
echo ""
echo "------------------------------------------------------------------"
echo "  POSTFIX (inbound MX)   (ns=infra-mail, selector=app=postfix)"
echo "------------------------------------------------------------------"
dump_pod_diagnostics "infra-mail" "app=postfix"
echo ""
echo ">>> POSTFIX round-trip lines (e2e-mailrt/e2e-mailrcv only, over --since=${LOG_SINCE}):"
kubectl logs -n "infra-mail" -l app=postfix --since="$LOG_SINCE" --all-containers=true --timestamps 2>/dev/null \
  | grep -iE 'e2e-mailr(t|cv)' \
  | tail -n 80 | sed 's/^/    /' || echo "    (no postfix round-trip lines found in window)"

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
    echo ">>> ${p} error/warn/token + OIDC code->token exchange highlights (last 1000 lines):"
    kubectl logs -n "$NS_AUTH" "$p" --tail=1000 2>/dev/null \
      | grep -iE 'error|warn|invalid|token|client|roundcube|reject|redirect_uri|invalid_grant|code_to_token|login_error|session_state|expired|not active|grant_type' \
      | tail -n 60 | sed 's/^/    /' || echo "    (none)"
  done <<< "$_kc_pods"
fi

# ── Live DB + PgBouncer introspection ─────────────────────────────────────────
# Both sections need the PG admin password and reach the DB through PgBouncer the
# same way real pods do. We fetch the password ONCE and guard both sections on it.
# Read-only throughout (no DROP) — so unlike dev-bringup's reset block, a bad
# tenant name or missing secret just SKIPS (best-effort: never exit non-zero).
# Sanitize the slash in E2E_SHARD ("5/10") so pod names stay valid DNS-1123 labels.
_diag_suffix="${CI_PIPELINE_NUMBER:-x}-${E2E_SHARD//\//-}"
_pg_pwd="$(kubectl get secret postgres-credentials -n infra-db -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d)"

echo ""
echo "------------------------------------------------------------------"
echo "  ROUNDCUBE DATABASE (live introspection)   (db=roundcube_${E2E_TENANT})"
echo "------------------------------------------------------------------"
if [[ -z "$_pg_pwd" ]]; then
  echo "    (postgres-credentials secret in infra-db unavailable — skipping DB introspection)"
elif [[ ! "$E2E_TENANT" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  # Allowlist-validate BEFORE interpolating the tenant into the DB name / SQL
  # (defends against SQL/identifier injection — mirrors dev-bringup's guard).
  echo "    (suspicious tenant name '$E2E_TENANT' — skipping DB introspection)"
else
  echo ">>> Introspecting roundcube_${E2E_TENANT} via PgBouncer (postgres:15-alpine throwaway pod):"
  _rc_db_out="$(kubectl run "rc-diag-db-${_diag_suffix}" --rm -i --restart=Never \
    --image=postgres:15-alpine --quiet -n default --pod-running-timeout=120s \
    --env "PGHOST=pgbouncer.infra-db.svc.cluster.local" \
    --env "PGUSER=postgres" \
    --env "PGPASSWORD=$_pg_pwd" \
    --env "PGDATABASE=roundcube_${E2E_TENANT}" \
    -- psql -v ON_ERROR_STOP=0 \
       -c "\echo '--- public tables ---'" \
       -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1;" \
       -c "\echo '--- table count ---'" \
       -c "SELECT count(*) AS public_table_count FROM information_schema.tables WHERE table_schema='public';" \
       -c "\echo '--- roundcube schema version (errors if system table missing) ---'" \
       -c "SELECT value FROM system WHERE name='roundcube-version';" 2>&1)"
  printf '%s\n' "$_rc_db_out" | sed 's/^/    /'
  echo ""
  echo "    INTERPRETATION:"
  echo "      • 'database \"roundcube_...\" does not exist' (maybe PgBouncer-cached as"
  echo "        server_login_retry) -> DB MISSING (trigger-a / #1547 family)."
  echo "      • connects but ZERO public tables           -> DB exists, schema NEVER"
  echo "        built (#1571 cause); read ROUNDCUBE STARTUP above for whether the"
  echo "        entrypoint even tried (no init markers -> trigger b)."
fi

echo ""
echo "------------------------------------------------------------------"
echo "  PGBOUNCER (admin console)   (host=pgbouncer.infra-db.svc.cluster.local)"
echo "------------------------------------------------------------------"
if [[ -z "$_pg_pwd" ]]; then
  echo "    (postgres-credentials secret in infra-db unavailable — skipping pgbouncer dump)"
else
  echo ">>> SHOW DATABASES / POOLS / SERVERS (surfaces a stale/negative cached roundcube entry):"
  _pgb_out="$(kubectl run "rc-diag-pgb-${_diag_suffix}" --rm -i --restart=Never \
    --image=postgres:15-alpine --quiet -n default --pod-running-timeout=120s \
    --env "PGHOST=pgbouncer.infra-db.svc.cluster.local" \
    --env "PGUSER=postgres" \
    --env "PGPASSWORD=$_pg_pwd" \
    --env "PGDATABASE=pgbouncer" \
    -- psql -v ON_ERROR_STOP=0 \
       -c "SHOW DATABASES;" \
       -c "SHOW POOLS;" \
       -c "SHOW SERVERS;" 2>&1)"
  if [[ -z "$_pgb_out" ]]; then
    echo "    (pgbouncer admin not accessible — no output)"
  else
    printf '%s\n' "$_pgb_out" | sed 's/^/    /'
  fi
fi

echo ""
echo "=================================================================="
echo "  HOW TO READ THIS (see memory project_shard5_10_roundcube_login_root_cause):"
echo "   • roundcube 'DB Error: column ... does not exist'      -> DB schema"
echo "   • stalwart  OAUTHBEARER / 'Failed to decode token' /"
echo "               'unauthorized'                              -> Stalwart token validation"
echo "   • roundcube session / oauth-state / redirect errors    -> Roundcube 1.7 / session store"
echo "   • keycloak  invalid_client / redirect_uri              -> Keycloak client config"
echo "   • roundcube 'relation \"session\" does not exist' + DB introspection shows"
echo "     0 public tables -> DB created EMPTY, schema NEVER built (#1571 cause)."
echo "     Then read ROUNDCUBE STARTUP / schema-init markers: NO init lines ->"
echo "     entrypoint never auto-inits (trigger b); init attempted but errored /"
echo "     'database does not exist' -> trigger a/c."
echo "   • DB introspection shows 'database \"...\" does not exist' -> DB MISSING /"
echo "     PgBouncer-cached (#1547 cause)."
echo '   • pgbouncer SHOW DATABASES / SHOW SERVERS with a stale/absent roundcube'
echo '     entry corroborates a drop/recreate cache window.'
echo "   • ROUNDCUBE per-user login outcomes: one user 'Successful login' but"
echo "     another 'Failed login' (e.g. sender e2e-mailrt OK, receiver e2e-mailrcv"
echo "     FAIL) with NO Stalwart IMAP auth for the failed user -> the failure is in"
echo "     Roundcube's OIDC leg (code->token / userinfo), NOT IMAP/schema/principal"
echo "     (shard-5 Echo Group, pipeline #1580). Read the oauth-flow errors + the"
echo "     keycloak code->token highlights for that user to name WHY."
echo "   • browser-side [roundcube-stuck:*] lines in the e2e log show WHERE"
echo "     the browser stopped (Keycloak vs webmail-no-inbox)."
echo "   • email-roundtrip (shard-5) — read STALWART mail round-trip + POSTFIX:"
echo "     OUTBOUND from=e2e-mailrt to=<echo group> then dsn-perm-fail/bounce/"
echo "     reject -> outbound leg broke; queued+completed but NO inbound echo to"
echo "     e2e-mailrcv (no rcpt-to / message-ingest, nothing in Postfix) -> the"
echo "     external reflector didn't return in time (120s budget vs #419 cold"
echo "     edge); echo present in POSTFIX but not Stalwart -> Postfix->Stalwart"
echo "     hop. No outbound at all in-window -> send never left Roundcube."
echo "=================================================================="
exit 0
