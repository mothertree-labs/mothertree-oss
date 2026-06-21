#!/bin/bash
# Shared utility functions for Mothertree deploy scripts
#
# Source this from any deploy script to get common helper functions:
#   source "${REPO_ROOT}/scripts/lib/common.sh"
#
# Provides:
#   print_status, print_success, print_warning, print_error  — colored output
#   poll_job_complete   — wait for a K8s Job to complete
#   poll_pod_ready      — wait for a pod to become ready
#   poll_condition      — generic polling with pattern matching
#   dump_pod_diagnostics — dump pod describe + events for debugging
#   wait_for_dns        — wait for DNS resolution inside a namespace
#   read_k8s_secret     — read a secret key from a K8s Secret
#   mt_require_commands — verify required CLI tools are available

# Guard against double-sourcing
if [ "${_MT_COMMON_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Colored output helpers
# ---------------------------------------------------------------------------
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ---------------------------------------------------------------------------
# mt_require_commands — verify required CLI tools are available
# Usage: mt_require_commands kubectl helm yq
# ---------------------------------------------------------------------------
mt_require_commands() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      print_error "$cmd is not installed or not in PATH"
      exit 1
    fi
  done
}

# ---------------------------------------------------------------------------
# dump_pod_diagnostics — dump pod info + events for debugging failures
# Usage: dump_pod_diagnostics <namespace> <label-selector>
# ---------------------------------------------------------------------------
dump_pod_diagnostics() {
    local namespace="$1"
    local selector="$2"
    print_status "Diagnostics: pods matching selector '$selector' in namespace '$namespace'"
    kubectl get pods -n "$namespace" -l "$selector" -o wide || true
    local pod_name
    pod_name=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    if [ -n "$pod_name" ]; then
        echo ""
        print_status "Diagnostics: describe pod $namespace/$pod_name"
        kubectl describe pod -n "$namespace" "$pod_name" || true
    fi
    echo ""
    print_status "Diagnostics: recent events in namespace '$namespace'"
    kubectl get events -n "$namespace" --sort-by=.lastTimestamp | tail -n 80 || true
}

# ---------------------------------------------------------------------------
# poll_condition — generic polling with pattern matching
# Usage: poll_condition <check_command> <success_pattern> <timeout> <interval> <description>
# ---------------------------------------------------------------------------
poll_condition() {
    local check_cmd="$1"
    local success_pattern="$2"
    local timeout="${3:-300}"
    local interval="${4:-5}"
    local description="${5:-condition}"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local result
        result=$(eval "$check_cmd" 2>&1) || true

        if echo "$result" | grep -qE "$success_pattern"; then
            return 0
        fi

        # Check for failure conditions
        if echo "$result" | grep -qiE "CrashLoopBackOff|Error|Failed|ImagePullBackOff"; then
            print_error "Detected failure while waiting for $description: $result"
            return 1
        fi

        echo "  Waiting for $description... (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    print_error "Timeout waiting for $description after ${timeout}s"
    return 1
}

# ---------------------------------------------------------------------------
# poll_job_complete — wait for a K8s Job to finish (respects backoffLimit)
# Usage: poll_job_complete <namespace> <job-name> [timeout] [interval]
# ---------------------------------------------------------------------------
poll_job_complete() {
    local namespace="$1"
    local job_name="$2"
    local timeout="${3:-180}"
    local interval="${4:-5}"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local job_status
        job_status=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.conditions[*].type}' 2>&1) || true

        if echo "$job_status" | grep -q "Complete"; then
            return 0
        fi

        # Only fail when the Job itself is marked Failed (all retries exhausted per backoffLimit)
        if echo "$job_status" | grep -q "Failed"; then
            print_error "Job $job_name failed (all retries exhausted)"
            kubectl logs -n "$namespace" "job/$job_name" --tail=50 || true
            return 1
        fi

        # Get pod info for status display only (don't fail on individual pod failures - let K8s retry)
        local pod_phase
        pod_phase=$(kubectl get pods -n "$namespace" -l "job-name=$job_name" -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null) || true
        local failed_count
        failed_count=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.failed}' 2>/dev/null) || true
        local backoff_limit
        backoff_limit=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.spec.backoffLimit}' 2>/dev/null) || true

        # Show current status in wait message (include retry info if pods have failed)
        local display_status="${pod_phase:-pending}"
        [ -n "$job_status" ] && display_status="$job_status"
        if [ -n "$failed_count" ] && [ "$failed_count" != "0" ]; then
            display_status="$display_status (retries: $failed_count/${backoff_limit:-0})"
        fi
        echo "  Waiting for job $job_name... status=$display_status (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    print_error "Timeout waiting for job $job_name after ${timeout}s"
    kubectl logs -n "$namespace" "job/$job_name" --tail=50 || true
    return 1
}

# ---------------------------------------------------------------------------
# poll_pod_ready — wait for a pod to become ready (detects CrashLoop etc.)
# Usage: poll_pod_ready <namespace> <label-selector> [timeout] [interval]
# ---------------------------------------------------------------------------
poll_pod_ready() {
    local namespace="$1"
    local selector="$2"
    local timeout="${3:-300}"
    local interval="${4:-5}"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        # Build a JSON-lines list of non-terminating pods (no deletionTimestamp).
        # This avoids picking a Terminating pod stuck on a dead node, which would
        # cause every subsequent check to read stale status or hang on exec.
        local _pod_json
        _pod_json=$(kubectl get pods -n "$namespace" -l "$selector" \
            -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.conditions[?(@.type=="PodScheduled")].status}{"|"}{.spec.nodeName}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
            | grep '^|' | head -1) || true

        # Parse fields: |name|phase|ready|scheduled|node|waitReason
        local pod_name pod_phase ready_status scheduled_status pod_node waiting_reason
        pod_name=$(echo "$_pod_json" | cut -d'|' -f2)
        pod_phase=$(echo "$_pod_json" | cut -d'|' -f3)
        ready_status=$(echo "$_pod_json" | cut -d'|' -f4)
        scheduled_status=$(echo "$_pod_json" | cut -d'|' -f5)
        pod_node=$(echo "$_pod_json" | cut -d'|' -f6)
        waiting_reason=$(echo "$_pod_json" | cut -d'|' -f7)

        if [ "$ready_status" = "True" ]; then
            print_success "Pod ready: $pod_name"
            return 0
        fi

        # Check for failure conditions
        if echo "$waiting_reason" | grep -qE "CrashLoopBackOff|ImagePullBackOff|ErrImagePull"; then
            print_error "Pod failed with: $waiting_reason"
            kubectl logs -n "$namespace" -l "$selector" --tail=30 || true
            return 1
        fi

        # Fail fast if the pod is Pending and unschedulable for >60s
        # (Common on single-node Linode when exceeding max attached volume count.)
        if [ "$pod_phase" = "Pending" ] && [ "${scheduled_status:-}" = "False" ] && [ -z "${pod_node:-}" ]; then
            if [ $elapsed -ge 60 ]; then
                print_error "Pod is Pending and unscheduled (no node assigned). This is not a readiness issue; it's a scheduling constraint."
                dump_pod_diagnostics "$namespace" "$selector"
                return 1
            fi
        fi

        # Build status display
        local display_status="${pod_phase:-no-pod}"
        [ -n "$waiting_reason" ] && display_status="$pod_phase/$waiting_reason"

        echo "  Waiting for pod ($selector)... status=$display_status (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    print_error "Timeout waiting for pod ($selector) after ${timeout}s"
    dump_pod_diagnostics "$namespace" "$selector"
    return 1
}

# ---------------------------------------------------------------------------
# wait_for_dns — wait for DNS resolution inside a K8s namespace
# Usage: wait_for_dns <namespace> <hostname> [timeout] [interval]
# ---------------------------------------------------------------------------
wait_for_dns() {
    local namespace="$1"
    local hostname="$2"
    local timeout="${3:-60}"
    local interval="${4:-5}"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        # Unique pod name per attempt so we never hit "AlreadyExists" on retries
        local pod_name="dns-check-$$-${elapsed}"
        if kubectl run "$pod_name" --image=busybox --rm --attach --restart=Never -n "$namespace" \
            --command -- nslookup "$hostname" >/dev/null 2>&1; then
            return 0
        fi
        echo "  Waiting for DNS ($hostname)... (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

# ---------------------------------------------------------------------------
# read_k8s_secret — read a key from a K8s Secret (base64-decoded)
# Usage: read_k8s_secret <namespace> <secret-name> <key>
# Returns the decoded value, or empty string if not found.
#
# Used to avoid regenerating passwords on every create_env run. Without this,
# a freshly generated password would mismatch any consumer that wasn't also
# restarted in the same deploy (e.g., Synapse holds a DB password in memory).
# ---------------------------------------------------------------------------
read_k8s_secret() {
    local ns="$1" secret="$2" key="$3"
    kubectl get secret "$secret" -n "$ns" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

# --- Conditional restart: only restart pods when config actually changed ---
# Avoids disrupting in-flight work (video calls, editing sessions, active
# logins) during routine deploys where nothing has actually changed.
#
# Usage:
#   mt_reset_change_tracker            # call once at top of deploy script
#   mt_apply kubectl apply -f foo.yaml # replaces bare kubectl apply
#   mt_apply kubectl apply -f <(envsubst < foo.tpl)  # works with process substitution
#   mt_restart_if_changed deployment/foo -n "$NS"     # replaces kubectl rollout restart
_mt_deploy_changed=false

mt_reset_change_tracker() {
    _mt_deploy_changed=false
}

mt_apply() {
    local output rc=0
    output=$("$@" 2>&1) || rc=$?
    printf '%s\n' "$output"
    if printf '%s\n' "$output" | grep -qE ' (configured|created)$'; then
        _mt_deploy_changed=true
    fi
    return $rc
}

mt_has_changes() {
    [[ "$_mt_deploy_changed" == "true" ]]
}

mt_restart_if_changed() {
    if mt_has_changes; then
        print_status "Config changes detected, restarting $*..."
        kubectl rollout restart "$@"
    else
        print_status "No config changes detected, skipping restart of $*"
    fi
}

# ---------------------------------------------------------------------------
# mt_set_env — set KEY=VALUE in a dotenv file (update if exists, append if not)
# Usage: mt_set_env <key> <value> <file>
# ---------------------------------------------------------------------------
mt_set_env() {
    local key="$1" value="$2" file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i'' "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# ---------------------------------------------------------------------------
# PostgreSQL helpers (connects via PgBouncer to external PG VM)
# ---------------------------------------------------------------------------

# Read the PostgreSQL superuser password from the postgres-credentials K8s Secret.
# This secret is created by deploy-pgbouncer.sh during deploy_infra.
mt_pg_password() {
    kubectl get secret postgres-credentials -n "${NS_DB:-infra-db}" \
        -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d
}

# Run psql against the external PG VM via PgBouncer.
# Uses a temporary pod with the postgres:17-alpine image.
# Usage: mt_psql [-d dbname] -c "SQL..."
#        echo "SQL" | mt_psql [-d dbname]
mt_psql() {
    local ns="${NS_DB:-infra-db}"
    local pg_pass
    pg_pass=$(mt_pg_password)
    if [ -z "$pg_pass" ]; then
        print_error "Could not read postgres-credentials secret in $ns"
        return 1
    fi
    kubectl run -i --rm "psql-$(date +%s)" \
        --namespace="$ns" \
        --image=postgres:17-alpine \
        --restart=Never \
        --env="PGPASSWORD=$pg_pass" \
        --command -- psql -h pgbouncer -U postgres -v ON_ERROR_STOP=1 "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Cold-start readiness gates (on-demand-dev Phase 3)
# ---------------------------------------------------------------------------
# Helmfile `wait: true` and `kubectl rollout status` only confirm pods are
# Ready — they don't confirm the application's external endpoints are actually
# serving. On a fresh cold-cycle these helpers protect the rest of the deploy
# (and downstream CI steps) from racing the application's warm-up window.
# See on-demand-dev/03-phase3-ci-orchestration.md §B for the empirical
# evidence (CI pipelines #1163, #1164) that motivates each gate.
# ---------------------------------------------------------------------------

# Wait for Keycloak's OIDC discovery endpoint to actually serve.
# Use this from any path that depends on Keycloak being usable (not just up).
#
# Usage: mt_wait_for_keycloak_oidc [realm]   (default realm: "master")
# Required env: AUTH_HOST
#
# The master realm is always present and exercises the full HTTP stack
# (ingress + Keycloak + realm machinery). Pass a tenant realm explicitly when
# you need to gate on that specific realm being registered and serving.
mt_wait_for_keycloak_oidc() {
    local realm="${1:-master}"
    # Probe Keycloak via the kubectl API-server proxy rather than the public
    # ingress hostname. The Keycloak Helm chart has `ingress.enabled: false`
    # (Mothertree creates per-tenant auth ingresses later, in
    # apps/deploy-matrix.sh), so there is no ingress for `auth.${AUTH_HOST}`
    # at deploy_infra time on a cold-started cluster — the warm-cluster
    # case only worked because per-tenant ingresses persisted from prior
    # deploys. Pipelines #1252/#1253/#1254/#1257 surfaced this.
    #
    # The kubectl proxy reads through the kubeconfig already in scope; no
    # DNS, no TLS, no ingress dependency. Works for both master and tenant
    # realms (the realm name is just part of the path).
    if [ -z "${KUBECONFIG:-}" ]; then
        print_error "mt_wait_for_keycloak_oidc: KUBECONFIG is not set"
        return 1
    fi
    local proxy_path="/api/v1/namespaces/infra-auth/services/keycloak-keycloakx-http:http/proxy/realms/${realm}/.well-known/openid-configuration"
    # 180 iterations × 5s = 900s (15 min). Cold-start Keycloak — image
    # pull on a brand-new node pool + JGroups cluster init + Quarkus boot
    # + master realm import — has been observed at ~6-8 min in pipeline
    # #1252/#1253. Warm-restart still responds in 30-90s.
    print_status "Waiting for Keycloak OIDC discovery (in-cluster, realm=$realm)"
    local i
    for i in $(seq 1 180); do
        if kubectl --kubeconfig="$KUBECONFIG" --request-timeout=5s \
               get --raw="$proxy_path" >/dev/null 2>&1; then
            print_success "Keycloak OIDC discovery responsive after $((i*5))s (realm=$realm)"
            return 0
        fi
        sleep 5
    done
    print_error "Keycloak OIDC discovery never became responsive via kubectl proxy (900s, realm=$realm)"
    return 1
}

# Wait for Stalwart's REST API to respond without 5xx.
# Use this before any script triggers /api/principal/* calls (admin-portal,
# account-portal, provision-smtp-service-accounts). Pod-Ready isn't enough —
# the REST API can return 5xx for ~30-60s after pod-Ready on first deploy
# (negative-RCPT cache warm-up + OIDC directory lookups).
#
# Usage: mt_wait_for_stalwart [mail_host]
# Required env: MAIL_HOST (or pass mail_host as $1)
#
# This is intentionally a *warning*, not an error: admin-portal retries on
# 5xx, and a slow Stalwart shouldn't block the entire deploy. The warning
# surfaces the issue in CI logs for diagnosis if downstream calls flake.
mt_wait_for_stalwart() {
    local mail_host="${1:-${MAIL_HOST:-}}"
    if [ -z "$mail_host" ]; then
        print_warning "mt_wait_for_stalwart: MAIL_HOST not set, skipping"
        return 0
    fi
    local url="https://${mail_host}/api/principal"
    print_status "Waiting for Stalwart REST API: $url"
    local code="000" i
    for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$url" 2>/dev/null || echo "000")
        # 200 / 401 / 403 all mean the REST layer is responding (auth-required
        # responses count). 5xx or "000" (timeout/refused) mean keep waiting.
        if [[ "$code" =~ ^(200|401|403)$ ]]; then
            print_success "Stalwart REST API responsive after $((i*5))s (HTTP $code)"
            return 0
        fi
        sleep 5
    done
    print_warning "Stalwart REST API never became responsive (last code: $code) — proceeding"
    return 0
}

# Wait until the Stalwart SMTP *submission* path is genuinely usable —
# i.e. a client can connect, STARTTLS, and SASL-auth as the shared `mailer@`
# principal on port 588 (then NOOP/QUIT — no MAIL/RCPT/DATA).
#
# Scope is deliberately connect+STARTTLS+AUTH, NOT recipient acceptance. Every
# failure we have evidence for (1307/1308: `MailConnectException: Connection
# refused`, `Password based SMTP connect failed`) is connect/AUTH stage — that
# is the deterministic cold-start blocker and exactly what Keycloak does before
# it can send. RCPT acceptance is intentionally excluded: `mailer@` is a SASL
# sender service account, not a verified-deliverable mailbox, and Stalwart has
# a documented negative-RCPT cache — probing RCPT risks a gate that fail-closes
# forever and blocks every deploy, strictly worse than the flake it guards.
#
# This is the cold-start gap #19 gate. mt_wait_for_stalwart (above) only probes
# the REST API and is warning-only; it does NOT prove the path Keycloak uses to
# send invitation / magic-link / "execute actions" emails. On every on-demand-dev
# cold-start (and around any Stalwart restart) the submission listener can be
# bound while SASL still 5xxs (OIDC directory not warmed) or the connect is
# refused/timed-out — which deterministically fails the shard-6 onboarding
# e2e tests and, on a main-merge, silently blocks deploy-prod.
#
# Fidelity: the probe runs from an ephemeral pod in NS_AUTH (Keycloak's own
# namespace) and connects to the *same* external FQDN Keycloak uses
# (SMTP_RELAY_HOST). In-cluster, CoreDNS rewrites that FQDN to the Stalwart
# ClusterIP and the `allow-mail-ingress` NetworkPolicy gates :588 from
# infra-auth — so this exercises the identical DNS-rewrite + NetworkPolicy +
# listener + SASL path as a real Keycloak invitation send. A probe from the CI
# box would take the internet→NodeBalancer path and false-green.
#
# FATAL on timeout (unlike mt_wait_for_stalwart) — per the project's
# "Fail Fast — Never Silently Skip" rule. Fails closed: anything other than an
# explicit success sentinel + exit 0 is treated as failure.
#
# Required env: SMTP_RELAY_HOST, SMTP_RELAY_USERNAME, SMTP_RELAY_PASSWORD
#               (export via scripts/lib/smtp-credentials.sh :: mt_export_smtp_relay_env),
#               KUBECONFIG, NS_AUTH.
# Optional env: SMTP_RELAY_PORT (default 588), MT_SMTP_GATE_DEADLINE (default 420s).
mt_wait_for_stalwart_submission() {
    : "${KUBECONFIG:?mt_wait_for_stalwart_submission: KUBECONFIG must be set}"
    : "${NS_AUTH:?mt_wait_for_stalwart_submission: NS_AUTH must be set}"
    : "${SMTP_RELAY_HOST:?mt_wait_for_stalwart_submission: SMTP_RELAY_HOST must be set (run mt_export_smtp_relay_env first)}"
    : "${SMTP_RELAY_USERNAME:?mt_wait_for_stalwart_submission: SMTP_RELAY_USERNAME must be set}"
    : "${SMTP_RELAY_PASSWORD:?mt_wait_for_stalwart_submission: SMTP_RELAY_PASSWORD must be set}"
    local port="${SMTP_RELAY_PORT:-588}"
    local deadline="${MT_SMTP_GATE_DEADLINE:-420}"

    print_status "Cold-start gate #19: verifying Stalwart SMTP submission connect+STARTTLS+AUTH"
    print_status "  from NS_AUTH=${NS_AUTH} → ${SMTP_RELAY_HOST}:${port} (SASL as ${SMTP_RELAY_USERNAME}), deadline ${deadline}s"

    # Single long-lived probe pod; the Python script retries internally until
    # it succeeds or its own deadline expires. Password is fed via stdin so it
    # never lands in the Pod spec, argv, or CI logs. Host/port/user are
    # non-secret and passed as env.
    local py
    py='
import os,sys,ssl,time,smtplib
host=os.environ["PHOST"]; port=int(os.environ["PPORT"])
user=os.environ["PUSER"]
deadline=time.time()+float(os.environ["PDEADLINE"])
pw=sys.stdin.readline().rstrip("\n")
# Unverified TLS context: mirror Keycloak'\''s lenient STARTTLS (it does not
# enforce server-cert identity by default). Cert validity is a separate gap
# with its own gate — do not couple this probe to cert-manager readiness.
ctx=ssl._create_unverified_context()
attempt=0; last="(no attempt)"
while time.time()<deadline:
    attempt+=1
    try:
        s=smtplib.SMTP(host,port,timeout=15)
        s.ehlo(); s.starttls(context=ctx); s.ehlo()
        s.login(user,pw)
        c,m=s.noop()
        s.quit()
        if c!=250:
            raise RuntimeError("NOOP after AUTH returned %s %r"%(c,m))
        print("STALWART_SMTP_PROBE_OK attempt=%d %s:%d AUTH=%s"%(attempt,host,port,user))
        sys.exit(0)
    except Exception as e:
        last=type(e).__name__+": "+str(e)
        print("  attempt %d connect/auth not ready yet: %s"%(attempt,last),flush=True)
        time.sleep(10)
print("STALWART_SMTP_PROBE_FAIL last_error: %s"%last)
sys.exit(1)
'
    local pod="smtp-submission-probe-$$-${RANDOM}"
    local out
    out=$(mktemp)
    # shellcheck disable=SC2064
    trap "kubectl --kubeconfig='$KUBECONFIG' -n '$NS_AUTH' delete pod '$pod' --ignore-not-found --force --grace-period=0 >/dev/null 2>&1; rm -f '$out'" RETURN

    local rc=0
    printf '%s' "$SMTP_RELAY_PASSWORD" | kubectl --kubeconfig="$KUBECONFIG" \
        run "$pod" -i --rm --restart=Never \
        --image=python:3.13-alpine \
        -n "$NS_AUTH" \
        --env "PHOST=${SMTP_RELAY_HOST}" \
        --env "PPORT=${port}" \
        --env "PUSER=${SMTP_RELAY_USERNAME}" \
        --env "PDEADLINE=${deadline}" \
        --command -- python3 -c "$py" >"$out" 2>&1 || rc=$?

    # Surface the probe's progress in CI logs (contains no secrets).
    sed 's/^/    [smtp-probe] /' "$out" || true

    # Fail closed: require BOTH a clean exit AND the explicit success sentinel.
    if [ "$rc" -eq 0 ] && grep -q 'STALWART_SMTP_PROBE_OK' "$out"; then
        print_success "Stalwart SMTP submission connect+AUTH OK (cold-start gate #19 passed)"
        return 0
    fi

    print_error "Stalwart SMTP submission connect/AUTH never succeeded (gate #19, rc=$rc)"
    print_error "  Keycloak invitation / magic-link emails would fail — failing the deploy loudly"
    return 1
}

# Wait for admin-portal's /version endpoint to return 200.
# Lightest sanity check that the full ingress + portal + version-injection
# chain is up. Use as a final "everything's up" assertion.
#
# Usage: mt_wait_for_admin_portal [admin_host]
# Required env: ADMIN_HOST (or pass admin_host as $1)
mt_wait_for_admin_portal() {
    local admin_host="${1:-${ADMIN_HOST:-}}"
    if [ -z "$admin_host" ]; then
        print_warning "mt_wait_for_admin_portal: ADMIN_HOST not set, skipping"
        return 0
    fi
    local url="https://${admin_host}/version"
    print_status "Waiting for admin-portal /version: $url"
    if curl -sf -m 5 --retry 30 --retry-delay 5 --retry-all-errors \
        "$url" >/dev/null 2>&1; then
        print_success "admin-portal /version returned 200"
        return 0
    fi
    print_error "admin-portal /version never returned 200 at $url"
    return 1
}

# Returns 0 if $1 currently resolves in DNS, 1 if it does not (e.g. NXDOMAIN).
# If no resolver tool is available, returns 0 (assume resolvable) so callers
# never skip a real check merely because resolution could not be tested.
# Usage: mt_host_resolves <hostname>
mt_host_resolves() {
    local host="$1"
    [ -z "$host" ] && return 1
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$host" >/dev/null 2>&1
    elif command -v host >/dev/null 2>&1; then
        host "$host" >/dev/null 2>&1
    else
        return 0
    fi
}

# Wait for Nextcloud's occ status to report installed=true.
# This is the "Gate 4" readiness check after the install Job + helmfile sync:
# pod-Ready is necessary but not sufficient (the seed-identity init container
# may finish while config.php is still being seeded, and `occ status` is the
# canonical signal that Nextcloud will actually serve requests).
#
# Usage: mt_wait_for_nextcloud_installed <namespace>
mt_wait_for_nextcloud_installed() {
    local namespace="$1"
    if [ -z "$namespace" ]; then
        print_error "mt_wait_for_nextcloud_installed: namespace required"
        return 1
    fi
    print_status "Waiting for Nextcloud occ status installed=true in $namespace"
    for i in $(seq 1 30); do
        local pod
        pod=$(kubectl -n "$namespace" get pod \
                -l app.kubernetes.io/instance=nextcloud \
                -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
              | awk '{print $1}')
        if [ -n "$pod" ]; then
            local installed
            installed=$(kubectl -n "$namespace" exec "$pod" -c nextcloud -- \
                bash -c "php /var/www/html/occ status --output=json 2>/dev/null | grep -o '\"installed\":true'" \
                2>/dev/null || true)
            if [ -n "$installed" ]; then
                print_success "Nextcloud installed=true after $((i*10))s"
                return 0
            fi
        fi
        sleep 10
    done
    print_error "Nextcloud never reported installed=true in $namespace"
    return 1
}
