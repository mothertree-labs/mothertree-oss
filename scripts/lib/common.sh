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
#   mt_resolve_ipv4_verdict / mt_host_resolves_to / mt_partition_hosts_by_target
#                       — fail-closed public DNS checks (does a host point at
#                         our ingress?)
#   mt_kubectl_probe    — in-cluster probe with an explicit OK/MISSING/UNKNOWN
#                         verdict (issue #623); transports mt_probe_exec /
#                         mt_probe_job; mt_kubectl_logs = retried log fetch

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
            mt_kubectl_logs -- -n "$namespace" "job/$job_name" --tail=50 || true
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
    mt_kubectl_logs -- -n "$namespace" "job/$job_name" --tail=50 || true
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
#   mt_apply kubectl apply -f - <<EOF  # works with a heredoc on stdin
#   mt_restart_if_changed deployment/foo -n "$NS"     # replaces kubectl rollout restart
#
# Change detection is a server-side `kubectl diff` of the same manifest
# (exit 0 = live object identical, 1 = differs / absent), NOT the
# "configured"/"unchanged" word in kubectl's output. Client-side apply prints
# "configured" whenever it SENDS a patch, even one the API server turns into
# a no-op: every Secret rendered by `kubectl create --dry-run=client -o yaml`
# (carries `creationTimestamp: null`), every `stringData` Secret (stored as
# `data`), and any manifest whose quantities the server normalises
# (`cpu: 2000m` → `2`). Grepping that word made mt_restart_if_changed fire on
# EVERY deploy for Ollama (1.3 GB model re-pull from S3 each time), Jitsi
# Prosody, Roundcube, both portals and Open WebUI — verified on the prod
# deploy log of pipeline 2122 (2026-09-09).
#
# The manifest named by -f (a file, `-` for stdin, or a <(...) process
# substitution, which can only be read once) is slurped into memory and fed
# to both diff and apply. Diff output is discarded on purpose — it would
# print Secret data into deploy logs. If diff itself cannot run (rc > 1:
# RBAC, unknown kind, no `diff` binary) the old output-grep is used so a real
# change is never silently missed; that path only ever over-restarts.
#
# Caveats:
#   - Never pipe INTO or OUT OF mt_apply (`gen | mt_apply kubectl apply -f -`,
#     `mt_apply ... | tee`): bash runs pipeline members in subshells, so the
#     flag is set in a throwaway shell and the caller never sees it. Use
#     `-f <(gen)` / `-f - <<EOF` / `> file` instead. (Pre-existing: ~30
#     infra-tier call sites still pipe in — tracked separately.)
#   - Only pass flags that BOTH `kubectl diff` and `kubectl apply` accept
#     (`-n` is fine). An apply-only flag makes diff exit 1 or 2 depending on
#     the kubectl version; either way that call site degrades to
#     restart-every-deploy (silently on 1, with a warning on 2).
#   - Detection is stateless (live vs manifest). If a deploy applies a
#     changed Secret and dies before its mt_restart_if_changed runs, the next
#     deploy sees no difference and will not restart the consumer — run
#     `kubectl rollout restart` by hand in that case.
#   - Do not run deploy scripts under `bash -x`: the in-memory manifest
#     (Secret data included) would be echoed to stderr.
_mt_deploy_changed=false

mt_reset_change_tracker() {
    _mt_deploy_changed=false
}

mt_apply() {
    local -a pre=() post=()
    local src="" have_f=false arg manifest output rc=0 diff_rc diff_err
    # Split "$@" into <before -f> / <manifest source> / <after -f>
    while [ $# -gt 0 ]; do
        arg=$1
        if [ "$have_f" = false ]; then
            case "$arg" in
                -f|--filename)
                    [ $# -ge 2 ] || { print_error "mt_apply: $arg needs an argument"; return 2; }
                    src=$2; have_f=true; shift 2; continue ;;
                -f=*|--filename=*) src=${arg#*=}; have_f=true; shift; continue ;;
            esac
            pre+=("$arg")
        else
            post+=("$arg")
        fi
        shift
    done

    if [ "$have_f" = false ]; then
        # No manifest to diff — legacy behaviour (output grep).
        output=$("${pre[@]}" 2>&1) || rc=$?
        printf '%s\n' "$output"
        if printf '%s\n' "$output" | grep -qE ' (configured|created)$'; then
            _mt_deploy_changed=true
        fi
        return $rc
    fi

    if [ "$src" = "-" ]; then
        manifest=$(cat)
    else
        manifest=$(cat -- "$src") || { print_error "mt_apply: cannot read manifest '$src'"; return 2; }
    fi

    # Server-side diff first: 0 = no change, 1 = change, >1 = diff unavailable.
    local -a diffcmd=("${pre[@]}")
    local i
    for i in "${!diffcmd[@]}"; do
        if [ "${diffcmd[$i]}" = "apply" ]; then diffcmd[$i]="diff"; break; fi
    done
    # KUBECTL_EXTERNAL_DIFF is unset so an inherited env var can never route
    # the LIVE/MERGED objects (Secret data included) through an arbitrary program.
    diff_rc=0
    diff_err=$(printf '%s\n' "$manifest" | env -u KUBECTL_EXTERNAL_DIFF "${diffcmd[@]}" -f - "${post[@]}" 2>&1 >/dev/null) || diff_rc=$?

    output=$(printf '%s\n' "$manifest" | "${pre[@]}" -f - "${post[@]}" 2>&1) || rc=$?
    printf '%s\n' "$output"

    case "$diff_rc" in
        0) ;;
        1) _mt_deploy_changed=true ;;
        *)
            print_warning "mt_apply: kubectl diff unavailable (rc=$diff_rc: ${diff_err%%$'\n'*}) — falling back to apply-output grep"
            if printf '%s\n' "$output" | grep -qE ' (configured|created)$'; then
                _mt_deploy_changed=true
            fi ;;
    esac
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

# Verify a tenant database is reachable AS THE APP USER through EVERY PgBouncer
# pod — and, as a side effect, force PgBouncer to heal a poisoned login cache
# for that pool.
#
# Why this exists (CI pipeline #1746): PgBouncer pools are keyed on
# (database, user). While a database is dropped (dev drop/recreate windows:
# destroy-side DB sweep, dev-bringup orphan guard, split-brain recovery), any
# pool that attempts a server login records the failure and serves clients a
# cached error — "server login has been failing, cached error: database ...
# does not exist (server_login_retry)". The cache only clears on the next
# SUCCESSFUL server login for that exact pool. On top of that there are two
# PgBouncer replicas behind one ClusterIP: kube-proxy picks a backend per
# connection, so a single probe through the Service can hit the healthy pod
# while the app keeps landing on the poisoned one (in #1746 nextcloud-install
# failed with the cached error for 2.5 minutes, seconds AFTER db-init succeeded
# through the very same Service). Hence: probe each pod IP, as the app user.
#
# Every attempt that lands outside PgBouncer's server_login_retry window
# triggers a real server login; once the DB exists that login succeeds and the
# pool is healed for all subsequent clients (app pods, install Jobs, readiness
# probes). So this gate both VERIFIES and REPAIRS. If a pod still cannot serve
# the pool within the deadline, we fail loudly here — naming the pod — instead
# of letting an install Job or readiness probe fail three steps later with a
# mystery SQLSTATE.
#
# Usage: mt_pgbouncer_verify_db <pod_ns> <db> <user> <password> [deadline_secs]
#   pod_ns        namespace to run the throwaway psql pod in (the app's ns)
#   deadline_secs per-pod deadline before declaring the pod poisoned (default 90)
mt_pgbouncer_verify_db() {
    local pod_ns="$1" db="$2" db_user="$3" db_password="$4" deadline="${5:-90}"
    local ns="${NS_DB:-infra-db}"
    : "${pod_ns:?mt_pgbouncer_verify_db: pod_ns required}"
    : "${db:?mt_pgbouncer_verify_db: db required}"
    : "${db_user:?mt_pgbouncer_verify_db: db_user required}"
    : "${db_password:?mt_pgbouncer_verify_db: db_password required}"

    local pod_ips
    pod_ips=$(kubectl get pods -n "$ns" -l app=pgbouncer \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}' 2>/dev/null | xargs echo -n || true)
    if [ -z "$pod_ips" ]; then
        print_error "mt_pgbouncer_verify_db: no Running PgBouncer pods found in $ns"
        return 1
    fi

    print_status "Verifying ${db} is reachable as ${db_user} via every PgBouncer pod (${pod_ips})..."
    # Single throwaway pod loops over all PgBouncer pod IPs so we pay pod
    # startup once. Attempts are spaced >server_login_retry (3s) apart so each
    # one can trigger a fresh real server login rather than the cached error.
    local out rc=0
    out=$(kubectl run "pgb-verify-$$-${RANDOM}" --rm -i --restart=Never \
        --image=postgres:15-alpine --quiet -n "$pod_ns" --pod-running-timeout=240s \
        --env "PGPASSWORD=$db_password" \
        --env "PGCONNECT_TIMEOUT=5" \
        --env "PGB_IPS=$pod_ips" \
        --env "PGB_DB=$db" \
        --env "PGB_USER=$db_user" \
        --env "PGB_DEADLINE=$deadline" \
        -- sh -c '
            rc=0
            for ip in $PGB_IPS; do
                start=$(date +%s); ok=""
                while : ; do
                    if psql -h "$ip" -U "$PGB_USER" -d "$PGB_DB" -tAc "SELECT 1" >/dev/null 2>&1; then
                        ok=1; break
                    fi
                    now=$(date +%s)
                    [ $((now - start)) -ge "$PGB_DEADLINE" ] && break
                    sleep 4
                done
                if [ -n "$ok" ]; then
                    echo "PGB_VERIFY_OK ${ip} ($(( $(date +%s) - start ))s)"
                else
                    echo "PGB_VERIFY_FAIL ${ip} (deadline ${PGB_DEADLINE}s)"
                    rc=1
                fi
            done
            exit $rc
        ' 2>&1) || rc=1
    printf '%s\n' "$out" | sed 's/^/    /'
    if [ "$rc" -ne 0 ]; then
        print_error "PgBouncer pool for (${db}, ${db_user}) is not serving on at least one pod."
        print_error "That pod is likely stuck on a cached login failure from a drop/recreate window."
        print_error "Inspect: kubectl logs -n $ns -l app=pgbouncer | grep '$db' — or bounce it:"
        print_error "  kubectl rollout restart deployment/pgbouncer -n $ns"
        return 1
    fi
    print_success "All PgBouncer pods serve (${db}, ${db_user})"
    return 0
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

# (mt_host_resolves — a yes/no getent check — was removed: it read a resolver
# timeout as "does not resolve". Use mt_resolve_ipv4_verdict, below.)

# ---------------------------------------------------------------------------
# DNS helpers: "does this public host point at OUR ingress?"
# ---------------------------------------------------------------------------
# Used by create_env for external-DNS tenants (dns_external=true). An HTTP-01
# multi-SAN certificate is all-or-nothing, so a host may only be included once
# its CNAME chain actually ends at our ingress LB. "Resolves" is not enough —
# a name that resolves somewhere else fails the challenge for every SAN.
#
# FAIL CLOSED. Every lookup has a tri-state verdict:
#   RESOLVED  IPv4 answer(s)
#   NEGATIVE  a definite "no": NXDOMAIN, or NOERROR with no A record (NODATA)
#   ERROR     the resolver could not answer (timeout, SERVFAIL/REFUSED, tool
#             error, unparsable output) — UNKNOWN, never "does not exist"
# Only dig can produce NEGATIVE (it exposes the response status); a non-answer
# from the getent/host/nslookup fallbacks is ERROR because they cannot tell a
# timeout from NXDOMAIN. ERROR is retried with backoff, and with dig the retries
# also ask explicit public resolvers, because a wedged local stub resolver has
# been seen to time out on our own LB alias. A host that is still ERROR after
# that is UNRESOLVABLE and the caller must abort: treating it as "not ours"
# would drop a LIVE host from spec.dnsNames, re-issue a smaller certificate,
# flip that host to the ingress fake cert until the next deploy, and burn a
# Let's Encrypt order (duplicate-certificate limit: 5 per week).
# Kept bash-3.2 friendly (space-separated strings, no arrays): create_env is
# also run from macOS /bin/bash.
#
# Tunables (mainly for tests): MT_RESOLVER_BACKEND=auto|dig|getent|host|nslookup,
# MT_RESOLVE_PUBLIC_RESOLVERS (default "1.1.1.1 8.8.8.8"; dig only),
# MT_RESOLVE_RETRY_BACKOFF (seconds × attempt number, default 2).

_MT_IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'

# Returns 0 if a DNS resolver CLI is available (dig, getent, host, nslookup).
# Usage: mt_have_dns_resolver
mt_have_dns_resolver() {
    [ "$(_mt_resolver_backend)" != "none" ]
}

# Internal: which resolver CLI to use. dig first — it is the only one that
# reports the response status. Note the backends are not byte-identical: dig
# queries the nameserver directly and bypasses /etc/hosts and the resolver
# search list, while getent honours both and host/nslookup honour the search
# list — so a bare label or an /etc/hosts entry can differ between them. All
# hosts we check are fully qualified public names, where they agree.
_mt_resolver_backend() {
    case "${MT_RESOLVER_BACKEND:-auto}" in
        auto)
            if command -v dig >/dev/null 2>&1; then echo dig
            elif command -v getent >/dev/null 2>&1; then echo getent
            elif command -v host >/dev/null 2>&1; then echo host
            elif command -v nslookup >/dev/null 2>&1; then echo nslookup
            else echo none
            fi ;;
        *) echo "${MT_RESOLVER_BACKEND}" ;;
    esac
}

# Internal: ONE lookup of <host>'s A records, optionally via an explicit
# <server> (dig only). Sets MT_RESOLVE_VERDICT (RESOLVED|NEGATIVE|ERROR),
# MT_RESOLVE_IPS (newline-separated IPv4s, RESOLVED only) and
# MT_RESOLVE_REASON (NEGATIVE/ERROR detail). Always returns 0.
_mt_resolve_attempt() {
    local host="$1" server="${2:-}" backend out="" rc=0 ips="" status="" via="" flags="" answer_count="" parsed_a=0 parsed_cname=0
    MT_RESOLVE_VERDICT="ERROR"
    MT_RESOLVE_IPS=""
    MT_RESOLVE_REASON=""
    backend=$(_mt_resolver_backend)
    [ -n "$server" ] && via=" via ${server}"
    case "$backend" in
        dig)
            # +noall +comments +answer: the ->>HEADER<<- status line, the
            # ";; flags: ...; QUERY: 1, ANSWER: N, ..." line and the answer
            # records, nothing else. +ttlid +cl +noshort +nodnssec pin the
            # record layout (name ttl IN type rdata) — command-line options
            # override a ~/.digrc, which could otherwise drop columns and turn
            # a live answer into "no A record". +tries=1 because the retry
            # policy lives in mt_resolve_ipv4_verdict. (No `-r`: dig 9.10 on
            # macOS does not have it.)
            if [ -n "$server" ]; then
                out=$(dig +noall +comments +answer +ttlid +cl +noshort +nodnssec +time=3 +tries=1 A "$host" "@${server}" 2>&1) || rc=$?
            else
                out=$(dig +noall +comments +answer +ttlid +cl +noshort +nodnssec +time=3 +tries=1 A "$host" 2>&1) || rc=$?
            fi
            if [ "$rc" -ne 0 ]; then
                # rc 9 = no servers could be reached (timeout), 8 = usage, 10 = internal
                MT_RESOLVE_REASON="dig exit ${rc}${via}: $(printf '%s\n' "$out" | grep -v '^$' | head -1 | sed 's/^;; //')"
                return 0
            fi
            status=$(printf '%s\n' "$out" | sed -nE 's/^;; ->>HEADER<<-.*status: ([A-Z]+).*/\1/p' | head -1)
            case "$status" in
                NOERROR|NXDOMAIN) ;;
                "")
                    MT_RESOLVE_REASON="unparsable dig output${via}: $(printf '%s\n' "$out" | grep -v '^$' | head -1)"
                    return 0 ;;
                *)
                    MT_RESOLVE_REASON="dig status ${status}${via}"
                    return 0 ;;
            esac
            # Answer-section integrity: the flags line says how many records
            # came back, and every one of them must have been understood (an
            # A row carrying an IPv4, or a CNAME row) before RESOLVED or
            # NEGATIVE is allowed. A record we cannot read — reshaped columns,
            # an RRSIG, a truncated (tc) response — is ERROR: otherwise a live
            # answer would be read as "no A record", the failure this helper
            # exists to prevent.
            flags=$(printf '%s\n' "$out" | sed -nE 's/^;; flags:([^;]*);.*/\1/p' | head -1)
            answer_count=$(printf '%s\n' "$out" | sed -nE 's/^;; flags:.*ANSWER: ([0-9]+).*/\1/p' | head -1)
            if [ -z "$answer_count" ]; then
                MT_RESOLVE_REASON="unparsable dig output${via}: no ANSWER count in the flags line"
                return 0
            fi
            case " $flags " in
                *" tc "*)
                    MT_RESOLVE_REASON="truncated response (tc flag)${via}"
                    return 0 ;;
            esac
            ips=$(printf '%s\n' "$out" | awk '$1 !~ /^;/ && NF >= 5 && $3 == "IN" && $4 == "A" {print $5}' | grep -E "$_MT_IPV4_RE" || true)
            parsed_a=$(printf '%s\n' "$ips" | grep -cE "$_MT_IPV4_RE" || true)
            parsed_cname=$(printf '%s\n' "$out" | awk '$1 !~ /^;/ && NF >= 5 && $3 == "IN" && $4 == "CNAME" {n++} END {print n+0}')
            if [ $((parsed_a + parsed_cname)) -ne "$answer_count" ]; then
                MT_RESOLVE_REASON="unparsable answer section${via} (resolver returned ${answer_count} records, parsed $((parsed_a + parsed_cname)))"
                return 0
            fi
            if [ "$status" = "NXDOMAIN" ]; then
                MT_RESOLVE_VERDICT="NEGATIVE"
                MT_RESOLVE_REASON="NXDOMAIN${via}"
                return 0
            fi
            ips=$(printf '%s\n' "$ips" | grep -E "$_MT_IPV4_RE" | sort -u || true)
            if [ -n "$ips" ]; then
                MT_RESOLVE_VERDICT="RESOLVED"
                MT_RESOLVE_IPS="$ips"
            else
                MT_RESOLVE_VERDICT="NEGATIVE"
                MT_RESOLVE_REASON="no A record (NODATA)${via}"
            fi
            return 0 ;;
        getent)   out=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' || true) ;;
        host)     out=$(host -t A "$host" 2>/dev/null | awk '/has address/ {print $NF}' || true) ;;
        nslookup) out=$(nslookup -type=A "$host" 2>/dev/null | awk '/^Address:/ {print $2}' || true) ;;
        none)
            MT_RESOLVE_REASON="no DNS resolver CLI (dig/getent/host/nslookup)"
            return 0 ;;
        *)
            MT_RESOLVE_REASON="unknown resolver backend '${backend}'"
            return 0 ;;
    esac
    # Fallback backends: an answer is RESOLVED; no answer is ERROR (they do not
    # distinguish a timeout from NXDOMAIN reliably), never NEGATIVE.
    ips=$(printf '%s\n' "$out" | grep -E "$_MT_IPV4_RE" | sort -u || true)
    if [ -n "$ips" ]; then
        MT_RESOLVE_VERDICT="RESOLVED"
        MT_RESOLVE_IPS="$ips"
    else
        MT_RESOLVE_REASON="no answer from ${backend} (cannot tell NXDOMAIN from a resolver failure)"
    fi
    return 0
}

# Resolve <host> to its IPv4 addresses, fail closed. Sets MT_RESOLVE_VERDICT
# (RESOLVED|NEGATIVE|ERROR), MT_RESOLVE_IPS and MT_RESOLVE_REASON.
# Returns 0 RESOLVED, 1 NEGATIVE, 2 ERROR — so under `set -e` call it as
# `rc=0; mt_resolve_ipv4_verdict h || rc=$?`, never bare.
# ERROR is retried up to 3 times with backoff (MT_RESOLVE_RETRY_BACKOFF ×
# attempt seconds): with dig the retries go to the public resolvers in
# MT_RESOLVE_PUBLIC_RESOLVERS first and the system resolver once more last;
# other backends just retry. The first RESOLVED or NEGATIVE answer wins.
# Usage: mt_resolve_ipv4_verdict <hostname>
mt_resolve_ipv4_verdict() {
    local host="$1" server plan="" reasons="" attempt=1 backoff
    MT_RESOLVE_VERDICT="ERROR"
    MT_RESOLVE_IPS=""
    MT_RESOLVE_REASON=""
    if [ -z "$host" ]; then
        MT_RESOLVE_REASON="empty hostname"
        return 2
    fi
    # Attempt plan ("-" = system resolver), always 4 attempts: with dig
    # "- <public resolvers> -" (padded with "-" if fewer than two are
    # configured), otherwise "- - - -".
    plan="-"
    if [ "$(_mt_resolver_backend)" = "dig" ]; then
        for server in ${MT_RESOLVE_PUBLIC_RESOLVERS-1.1.1.1 8.8.8.8}; do
            plan="$plan $server"
        done
        plan="$plan -"
    fi
    # shellcheck disable=SC2086  # counting words of the plan is the point
    set -- $plan
    while [ "$#" -lt 4 ]; do
        plan="$plan -"
        set -- $plan
    done
    for server in $plan; do
        [ "$server" = "-" ] && server=""
        if [ "$attempt" -gt 1 ]; then
            backoff=$(( ${MT_RESOLVE_RETRY_BACKOFF:-2} * (attempt - 1) ))
            if [ "$backoff" -gt 0 ]; then
                sleep "$backoff"
            fi
        fi
        _mt_resolve_attempt "$host" "$server"
        case "$MT_RESOLVE_VERDICT" in
            RESOLVED) return 0 ;;
            NEGATIVE) return 1 ;;
        esac
        reasons="${reasons:+$reasons; }attempt ${attempt}: ${MT_RESOLVE_REASON}"
        attempt=$((attempt + 1))
    done
    MT_RESOLVE_VERDICT="ERROR"
    MT_RESOLVE_REASON="giving up after $((attempt - 1)) attempts — ${reasons}"
    return 2
}

# Print the IPv4 addresses <host> resolves to, one per line (RESOLVED only).
# Returns 0 RESOLVED, 1 NEGATIVE (definitely no address), 2 ERROR (resolver
# failure after retries — unknown, NOT "does not exist").
# Usage: mt_resolve_ipv4 <hostname>
mt_resolve_ipv4() {
    local rc=0
    mt_resolve_ipv4_verdict "$1" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$MT_RESOLVE_IPS"
    fi
    return "$rc"
}

# Internal: returns 0 if any line of <resolved> (newline-separated IPv4s) is in
# <ips> (comma- or space-separated).
_mt_any_ip_in_list() {
    local resolved="$1" ips="$2" ip
    for ip in ${ips//,/ }; do
        if printf '%s\n' "$resolved" | grep -qxF "$ip"; then
            return 0
        fi
    done
    return 1
}

# Does <host> currently resolve to at least one IPv4 in <ips> (comma- or
# space-separated)? Returns 0 yes; 1 definitely not (NXDOMAIN/NODATA, or it
# resolves to other addresses); 2 unknown (resolver error after retries) —
# callers must never read 2 as "not ours".
# Usage: mt_host_resolves_to <hostname> <ip>[,<ip>...]
mt_host_resolves_to() {
    local host="$1" ips="$2" rc=0
    mt_resolve_ipv4_verdict "$host" || rc=$?
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    _mt_any_ip_in_list "$MT_RESOLVE_IPS" "$ips"
}

# Partition <host>... by whether each currently resolves to one of <ips>.
# Sets five globals (strings, so callers work under bash 3.2 + set -u):
#   MT_HOSTS_AT_TARGET             hosts that point at <ips>
#   MT_HOSTS_NOT_AT_TARGET         hosts that definitely do not (NEGATIVE, or
#                                  they resolve to other addresses)
#   MT_HOSTS_NOT_AT_TARGET_DETAIL  one "host: <why>" line each
#   MT_HOSTS_UNRESOLVABLE          hosts whose lookup FAILED after retries
#                                  (verdict unknown — the caller MUST abort,
#                                  see mt_require_hosts_resolvable)
#   MT_HOSTS_UNRESOLVABLE_DETAIL   one "host: <why>" line each
# Each host is resolved once (plus retries on error). Always returns 0.
# Usage: mt_partition_hosts_by_target "<ip>[,<ip>...]" <host>...
mt_partition_hosts_by_target() {
    local ips="$1"
    shift
    MT_HOSTS_AT_TARGET=""
    MT_HOSTS_NOT_AT_TARGET=""
    MT_HOSTS_NOT_AT_TARGET_DETAIL=""
    MT_HOSTS_UNRESOLVABLE=""
    MT_HOSTS_UNRESOLVABLE_DETAIL=""
    local host rc
    for host in "$@"; do
        rc=0
        mt_resolve_ipv4_verdict "$host" || rc=$?
        case "$rc" in
            0)
                if _mt_any_ip_in_list "$MT_RESOLVE_IPS" "$ips"; then
                    MT_HOSTS_AT_TARGET="${MT_HOSTS_AT_TARGET:+$MT_HOSTS_AT_TARGET }$host"
                else
                    MT_HOSTS_NOT_AT_TARGET="${MT_HOSTS_NOT_AT_TARGET:+$MT_HOSTS_NOT_AT_TARGET }$host"
                    MT_HOSTS_NOT_AT_TARGET_DETAIL+="${host}: resolves to $(printf '%s\n' "$MT_RESOLVE_IPS" | tr '\n' ' ' | sed 's/ $//') (not our ingress)"$'\n'
                fi ;;
            1)
                MT_HOSTS_NOT_AT_TARGET="${MT_HOSTS_NOT_AT_TARGET:+$MT_HOSTS_NOT_AT_TARGET }$host"
                MT_HOSTS_NOT_AT_TARGET_DETAIL+="${host}: does not resolve (${MT_RESOLVE_REASON})"$'\n' ;;
            *)
                MT_HOSTS_UNRESOLVABLE="${MT_HOSTS_UNRESOLVABLE:+$MT_HOSTS_UNRESOLVABLE }$host"
                MT_HOSTS_UNRESOLVABLE_DETAIL+="${host}: could not be resolved (${MT_RESOLVE_REASON})"$'\n' ;;
        esac
    done
    return 0
}

# Fail closed after mt_partition_hosts_by_target: if any host could not be
# resolved (resolver ERROR, not a negative answer), print them and return 1 so
# the caller aborts before changing anything. Returns 0 when all verdicts are
# definite.
# Usage: mt_require_hosts_resolvable "<what the hosts are>" || exit 1
mt_require_hosts_resolvable() {
    local what="$1"
    if [ -z "${MT_HOSTS_UNRESOLVABLE:-}" ]; then
        return 0
    fi
    print_error "DNS resolution FAILED for ${what} — refusing to guess which hosts point at us (fail closed; nothing was changed):"
    printf '%s' "$MT_HOSTS_UNRESOLVABLE_DETAIL" | sed 's/^/  - /' >&2
    print_error "This is a resolver problem on this machine/runner (or upstream), not the tenant's DNS state. Fix it and re-run — excluding a live host here would re-issue a smaller certificate and break that host."
    return 1
}

# Print the unique URL hosts of an ENDPOINT_PROBE_TARGETS block (lines shaped
# `        - https://host/path`), space-separated.
# Usage: mt_probe_target_hosts "<targets-block>"
mt_probe_target_hosts() {
    printf '%s\n' "$1" | sed -nE 's#^ *- *https?://([^/]+).*#\1#p' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Keep only the lines of an ENDPOINT_PROBE_TARGETS block whose URL host is in
# the space-separated <hosts> list; prints them in their original order.
# Usage: mt_filter_probe_targets_by_hosts "<targets-block>" "<host> <host> ..."
mt_filter_probe_targets_by_hosts() {
    local block="$1" hosts="$2" line host
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        host=$(printf '%s' "$line" | sed -E 's#^ *- *https?://([^/]+).*#\1#')
        case " $hosts " in
            *" $host "*) printf '%s\n' "$line" ;;
        esac
    done <<< "$block"
}

# Can a pod in this cluster reach a tenant's PUBLIC hosts the way a client does?
# kube-proxy short-circuits pod -> LoadBalancer-IP traffic straight to the
# ingress-nginx pod (the NodeBalancer is not in the path). When the controller
# runs with use-proxy-protocol=true it then rejects the PROXY-header-less
# connection. The path works only if PROXY protocol is off for this env's
# ingress (prod-eu), or the tenant's DNS is Cloudflare-proxied so the request
# leaves the cluster and re-enters through the NodeBalancer (prod). Dev has
# neither. Inputs are the live ingress-nginx ConfigMap value and the tenant's
# Cloudflare-proxy flag — never the environment name.
# Usage: mt_public_hosts_probeable_from_cluster <use-proxy-protocol true|false> <cf-proxied true|false>
mt_public_hosts_probeable_from_cluster() {
    local use_proxy_protocol="$1" cf_proxied="$2"
    [ "$use_proxy_protocol" != "true" ] || [ "$cf_proxied" = "true" ]
}

# Render the CERT_SAN_LINES block of certificate-http01.yaml.tpl (YAML list
# items, 4-space indent) from a space-separated host list.
# Usage: mt_http01_san_lines "<host> <host> ..."
mt_http01_san_lines() {
    local host
    for host in $1; do
        printf '    - "%s"\n' "$host"
    done
}

# Returns 0 when MT_ENV is a production-like environment — every environment
# except dev (prod, prod-eu, any future prod-*). Use this instead of a literal
# `[ "$MT_ENV" = "prod" ]` for behaviour that must also hold on prod-eu: that
# literal silently excluded prod-eu more than once (blackbox probe modules,
# alert delivery). An unset MT_ENV counts as prod-like — the safe direction,
# since prod-like is always the stricter mode.
# Usage: if mt_is_prod_like; then ...; fi
mt_is_prod_like() {
    [ "${MT_ENV:-}" != "dev" ]
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

# ---------------------------------------------------------------------------
# mt_wait_for_daemonset — wait for a DaemonSet rollout to converge; fail fast
# on pods that will never become ready (crash loop, unpullable image, ...).
#
# Converged means desired == current == updated == ready == available and the
# controller has observed the latest generation. `updated == desired` is what
# catches a STALLED rollout: with the default maxUnavailable=1 a broken pod
# template leaves the old pods Ready on every other node, so a ready-only
# check passes while the cluster is silently half-upgraded (issue #612:
# Vector 0.58 rejected a stale config key, 3 of 4 nodes shipped no logs).
#
# Both regular and init containers are inspected — native sidecars
# (initContainers with restartPolicy: Always) crash-loop as init containers.
#
# Pods on NotReady / unreachable nodes are excluded from the comparison (and
# listed): the DaemonSet controller tolerates those taints, so the dead node's
# pod stays in desiredNumberScheduled and would otherwise hold this gate —
# and every prod deploy behind it — for the whole node outage.
#
# On failure the last 30 log lines of the failed container and the pod events
# are printed into the deploy log. Treat everything printed here as public;
# only point this at DaemonSets whose logs are safe to show.
#
# Usage: mt_wait_for_daemonset <namespace> <daemonset> [timeout=420] [interval=5]
# Returns 0 on convergence, 1 on fail-fast or timeout (with diagnostics).
# ---------------------------------------------------------------------------
mt_wait_for_daemonset() {
    local namespace="${1:?mt_wait_for_daemonset: namespace required}"
    local ds="${2:?mt_wait_for_daemonset: daemonset name required}"
    local timeout="${3:-420}"
    local interval="${4:-5}"
    local bad_reasons='CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|InvalidImageName'

    local start=$SECONDS elapsed=0
    while true; do
        local status
        if ! status=$(kubectl get ds "$ds" -n "$namespace" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.status.desiredNumberScheduled}|{.status.currentNumberScheduled}|{.status.updatedNumberScheduled}|{.status.numberReady}|{.status.numberAvailable}' 2>/dev/null); then
            print_error "mt_wait_for_daemonset: cannot read DaemonSet $namespace/$ds"
            return 1
        fi
        local gen obs desired current updated ready available
        IFS='|' read -r gen obs desired current updated ready available <<< "$status"
        gen=${gen:-0}; obs=${obs:-0}; desired=${desired:-0}; current=${current:-0}
        updated=${updated:-0}; ready=${ready:-0}; available=${available:-0}

        if [ "$desired" -eq 0 ]; then
            print_warning "DaemonSet $namespace/$ds has 0 desired pods — nothing to wait for"
            return 0
        fi

        # Pods on NotReady nodes count against desired but can never become
        # ready/updated until the node recovers — exclude them (see header).
        # Credit one per distinct node (a node can briefly carry two pods).
        local excluded_pods excluded excluded_json
        excluded_pods=$(_mt_daemonset_pods_on_notready_nodes "$namespace" "$ds")
        excluded=$(printf '%s\n' "$excluded_pods" | awk 'NF { print $NF }' | sort -u | grep -c . || true)
        excluded_json=$(printf '%s\n' "$excluded_pods" | awk 'NF { print $1 }' | jq -R . | jq -s -c .)

        if [ "$obs" -ge "$gen" ] && [ $((updated + excluded)) -ge "$desired" ] && [ $((current + excluded)) -ge "$desired" ] \
           && [ $((ready + excluded)) -ge "$desired" ] && [ $((available + excluded)) -ge "$desired" ]; then
            if [ "$excluded" -gt 0 ]; then
                print_warning "DaemonSet $namespace/$ds: ignoring $excluded pod(s) on NotReady nodes:"
                echo "$excluded_pods" | sed 's/^/    /'
            fi
            print_success "DaemonSet $namespace/$ds converged: $ready/$desired ready, $updated/$desired updated (${elapsed}s)"
            return 0
        fi

        # Fail fast: a pod owned by this DaemonSet stuck in a crash/pull loop
        # will not recover by waiting. Pods on NotReady nodes are skipped here
        # too — their last reported state is frozen until the node returns.
        # Terminating pods are skipped as well: when a rollout replaces a
        # crash-looping pod, the old pod keeps reporting CrashLoopBackOff
        # until it is gone, and aborting on it would fail the very deploy
        # that fixes it.
        local bad
        bad=$(kubectl get pods -n "$namespace" -o json 2>/dev/null | jq -r --arg ds "$ds" --arg re "$bad_reasons" --argjson skip "$excluded_json" '
            .items[]
            | select((.metadata.ownerReferences // []) | any(.kind == "DaemonSet" and .name == $ds))
            | select(.metadata.deletionTimestamp == null)
            | select(.metadata.name as $n | ($skip | index($n)) == null)
            | . as $p
            | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]
            | select((.state.waiting.reason // "") | test($re))
            | "\($p.metadata.name)|\(.name)|\(.state.waiting.reason)|\(.restartCount)"' 2>/dev/null) || bad=""
        if [ -n "$bad" ]; then
            print_error "DaemonSet $namespace/$ds has pods that will never become ready:"
            echo "$bad" | awk -F'|' '{ printf "    %s (container %s): %s, restarts=%s\n", $1, $2, $3, $4 }'
            _mt_daemonset_diagnostics "$namespace" "$ds" \
                "$(echo "$bad" | head -1 | cut -d'|' -f1)" "$(echo "$bad" | head -1 | cut -d'|' -f2)"
            return 1
        fi

        if [ "$elapsed" -ge "$timeout" ]; then
            print_error "Timeout after ${timeout}s waiting for DaemonSet $namespace/$ds: $ready/$desired ready, $updated/$desired updated, $available/$desired available"
            _mt_daemonset_diagnostics "$namespace" "$ds" "" ""
            return 1
        fi
        echo "  Waiting for DaemonSet $namespace/$ds: $ready/$desired ready, $updated/$desired updated, $available/$desired available (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((SECONDS - start))   # wall-clock, so API round-trips count
    done
}

# Pods of <daemonset> scheduled on nodes whose Ready condition is not True.
# Prints one "pod on NotReady node <node>" line per pod; empty when none.
_mt_daemonset_pods_on_notready_nodes() {
    local namespace="$1" ds="$2" notready
    notready=$(kubectl get nodes -o json 2>/dev/null | jq -r '
        .items[]
        | select((.status.conditions // []) | any(.type == "Ready" and .status != "True"))
        | .metadata.name' 2>/dev/null) || notready=""
    [ -z "$notready" ] && return 0
    kubectl get pods -n "$namespace" -o json 2>/dev/null | jq -r --arg ds "$ds" \
        --argjson nodes "$(printf '%s\n' "$notready" | jq -R . | jq -s .)" '
        .items[]
        | select((.metadata.ownerReferences // []) | any(.kind == "DaemonSet" and .name == $ds))
        | select(.spec.nodeName as $n | $nodes | index($n))
        | "\(.metadata.name) on NotReady node \(.spec.nodeName)"' 2>/dev/null || true
}

# Diagnostics for mt_wait_for_daemonset failures. Best effort, never fails.
_mt_daemonset_diagnostics() {
    local namespace="$1" ds="$2" pod="$3" container="$4"
    kubectl get ds "$ds" -n "$namespace" -o wide 2>/dev/null || true
    kubectl get pods -n "$namespace" -o wide 2>/dev/null | grep -E "^NAME|^${ds}-" || true
    if [ -n "$pod" ]; then
        echo ""
        print_status "Diagnostics: last log lines of $namespace/$pod ($container)"
        kubectl logs -n "$namespace" "$pod" -c "$container" --previous --tail=30 2>/dev/null \
            || kubectl logs -n "$namespace" "$pod" -c "$container" --tail=30 2>/dev/null || true
        echo ""
        kubectl describe pod -n "$namespace" "$pod" 2>/dev/null | sed -n '/^Events:/,$p' | tail -15 || true
    fi
}

# ---------------------------------------------------------------------------
# mt_wait_for_tailscale_sidecar — prove a Tailscale sidecar is on the mesh
# Usage: mt_wait_for_tailscale_sidecar <namespace> <label-selector> <expected-tag> [timeout=180] [remedy-hint]
#
# `kubectl rollout status` is satisfied by the main container's readiness probe
# (socat/pgbouncer listening on their own port), which says nothing about the
# WireGuard tunnel behind it: pg-metrics-bridge reported Ready for months on
# dev while its sidecar was registered without a tag and the ACL dropped every
# packet (#613). This waits until every non-terminating pod matching the
# selector has a `tailscale` sidecar whose `tailscale status --json` reports
# BackendState=Running and <expected-tag> among Self.Tags. Self.Online is
# reported but NOT required: it only means "inside a control-server map poll",
# so a Headscale outage would flip it to false on every healthy sidecar while
# the WireGuard tunnels keep working on the cached netmap — the data plane is
# proven by the positive control the callers run right after this gate.
# Fails fast — no point waiting — when the sidecar log shows an auth failure
# (expired / already-used key, machineAuthorized=false) or the node registered
# without the tag (tags come from the pre-auth key at registration; only a new
# key fixes that: ./scripts/check-tailscale-keys -e <env> --rotate — pass a
# <remedy-hint> for components where that is not the fix, e.g. the router's
# fixed-name state Secret). Dumps diagnostics on failure. Returns 0/1.
# ---------------------------------------------------------------------------
mt_wait_for_tailscale_sidecar() {
    local namespace="${1:?mt_wait_for_tailscale_sidecar: namespace required}"
    local selector="${2:?mt_wait_for_tailscale_sidecar: selector required}"
    local tag="${3:?mt_wait_for_tailscale_sidecar: expected tag required}"
    local timeout="${4:-180}"
    local remedy="${5:-run: ./scripts/check-tailscale-keys -e ${MT_ENV:-<env>} --rotate}"
    local interval=5 start=$SECONDS
    # Same failure signatures as the key library's post-rotation proof — one
    # definition (tailscale-keys.sh must stay standalone for the CronJob).
    local failure_re="${MT_TS_FAILURE_RE:-authkey expired|authkey already used|invalid auth ?key|machineAuthorized=false|tailscale up failed|failed to auth tailscale}"
    # Bound the LocalAPI call: a wedged tailscaled would otherwise hang the deploy.
    local tmo=""; command -v timeout >/dev/null 2>&1 && tmo="timeout 20"; [ -z "$tmo" ] && command -v gtimeout >/dev/null 2>&1 && tmo="gtimeout 20"
    local pods pod status state online tags all_ok pending count online_warned="" xerr last_xerr=""
    # kubectl exec/logs go through the cluster's konnectivity proxy; a transport
    # error there is not a sidecar failure. It is retried like any other
    # transient, but reported at timeout so nobody chases the wrong cause.
    local transport_re='error dialing backend|unable to upgrade connection|proxy error|connection refused|timed out|TLS handshake'

    print_status "Waiting for the Tailscale sidecar(s) of '$selector' in $namespace to join the mesh as $tag..."
    while :; do
        pods=$(kubectl get pods -n "$namespace" -l "$selector" -o json 2>/dev/null \
            | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name') || pods=""
        all_ok=true; pending=""
        for pod in $pods; do
            # Fail fast on an auth failure in the sidecar log
            # grep -c (not -q): -q exits on the first match and the writer then dies
            # of SIGPIPE, which `pipefail` reports as failure — a false "no match".
            if kubectl logs -n "$namespace" "$pod" -c tailscale --tail=200 2>/dev/null | grep -cE "$failure_re" >/dev/null; then
                print_error "Tailscale sidecar of $namespace/$pod failed to authenticate:"
                kubectl logs -n "$namespace" "$pod" -c tailscale --tail=200 2>/dev/null | grep -E "$failure_re" | tail -3 | sed 's/^/    /'
                print_error "The pod's auth Secret holds a dead or untagged pre-auth key — $remedy"
                dump_pod_diagnostics "$namespace" "$selector"
                return 1
            fi
            # shellcheck disable=SC2086  # $tmo is intentionally word-split ("timeout 20" or empty)
            xerr=""
            status=$($tmo kubectl exec -n "$namespace" "$pod" -c tailscale -- tailscale status --json 2>"${TMPDIR:-/tmp}/mt-ts-exec-$$.err") || {
                xerr=$(tail -1 "${TMPDIR:-/tmp}/mt-ts-exec-$$.err" 2>/dev/null); rm -f "${TMPDIR:-/tmp}/mt-ts-exec-$$.err"
                all_ok=false
                if printf '%s' "$xerr" | grep -qE "$transport_re"; then
                    last_xerr="$xerr"; pending="$pod: kubectl exec transport error (cluster proxy), retrying"
                else
                    pending="$pod: sidecar not answering yet"
                fi
                continue
            }
            rm -f "${TMPDIR:-/tmp}/mt-ts-exec-$$.err"
            state=$(printf '%s' "$status" | jq -r '.BackendState // "unknown"')
            online=$(printf '%s' "$status" | jq -r '.Self.Online // false')
            if [ "$state" != "Running" ]; then
                all_ok=false; pending="$pod: BackendState=$state"; continue
            fi
            if [ "$online" != "true" ] && [ -z "$online_warned" ]; then
                print_warning "$namespace/$pod: tailscaled is Running but not inside a Headscale map poll (Self.Online=false) — control plane unreachable? The tunnel keeps working on the cached netmap; the positive control decides."
                online_warned=1
            fi
            tags=$(printf '%s' "$status" | jq -c '.Self.Tags // []')
            if ! printf '%s' "$status" | jq -e --arg t "$tag" '(.Self.Tags // []) | any(. == $t)' >/dev/null; then
                print_error "Tailscale sidecar of $namespace/$pod is on the mesh WITHOUT $tag (tags: $tags) — the ACL will drop its traffic"
                print_error "Tags come from the pre-auth key at registration — $remedy"
                dump_pod_diagnostics "$namespace" "$selector"
                return 1
            fi
        done
        if [ -n "$pods" ] && [ "$all_ok" = true ]; then
            count=$(printf '%s\n' "$pods" | grep -c .)
            print_success "Tailscale sidecar on the mesh as $tag: $count pod(s) of '$selector' in $namespace ($((SECONDS - start))s)"
            return 0
        fi
        if [ $((SECONDS - start)) -ge "$timeout" ]; then
            print_error "Tailscale sidecar(s) of '$selector' in $namespace did not reach the mesh within ${timeout}s (${pending:-no pods found})"
            if [ -n "$last_xerr" ]; then
                print_error "Last kubectl exec transport error (control-plane proxy to the node, NOT the sidecar): $last_xerr"
            fi
            for pod in $pods; do
                echo "    --- $pod (tailscale, last 20 lines) ---"
                kubectl logs -n "$namespace" "$pod" -c tailscale --tail=20 2>&1 | sed 's/^/      /' || true
            done
            dump_pod_diagnostics "$namespace" "$selector"
            return 1
        fi
        echo "  Waiting for Tailscale sidecar... ${pending:-no pods yet} ($((SECONDS - start))s/${timeout}s)"
        sleep "$interval"
    done
}

# ---------------------------------------------------------------------------
# mt_tailscale_sidecar_fetch — positive control through a sidecar: the real target
# Usage: mt_tailscale_sidecar_fetch <namespace> <label-selector> <url> <expect-regex> [timeout=60]
#
# Runs `wget -qO- <url>` inside the first non-terminating pod's `tailscale`
# container (the mesh interface lives in that container's netns, so the fetch
# traverses the tunnel and the ACL exactly like the workload's traffic) and
# requires the body to match <expect-regex>. Retries until the timeout.
# ---------------------------------------------------------------------------
mt_tailscale_sidecar_fetch() {
    local namespace="${1:?}" selector="${2:?}" url="${3:?}" expect="${4:?}" timeout="${5:-60}"
    local start=$SECONDS pod body
    while :; do
        pod=$(kubectl get pods -n "$namespace" -l "$selector" -o json 2>/dev/null \
            | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | .[0].metadata.name // empty') || pod=""
        if [ -n "$pod" ]; then
            body=$(kubectl exec -n "$namespace" "$pod" -c tailscale -- wget -qO- -T 5 "$url" 2>&1) || body="${body:-<no response>}"
            # (stderr is merged on purpose: a kubectl transport error then shows up
            # in the failure excerpt instead of reading as an empty response)
            # grep -c, not -q: a metrics body is ~100 KB and -q would SIGPIPE printf.
            if printf '%s\n' "$body" | grep -cE "$expect" >/dev/null; then
                print_success "Mesh positive control OK: $url reachable from $namespace/$pod ($((SECONDS - start))s)"
                return 0
            fi
        fi
        if [ $((SECONDS - start)) -ge "$timeout" ]; then
            print_error "Mesh positive control FAILED: $url from ${pod:-<no pod>} did not return /$expect/ within ${timeout}s"
            printf '%s\n' "${body:-}" | head -5 | sed 's/^/    /'
            return 1
        fi
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# mt_tailscale_sidecar_tcp_check — positive control for a non-HTTP target
# Usage: mt_tailscale_sidecar_tcp_check <namespace> <label-selector> <host> <port> [timeout=60]
#
# `nc -z` from inside the sidecar's netns: exit 0 means the TCP handshake
# completed through the tunnel AND the Headscale ACL (a port the ACL does not
# open never answers the SYN and times out). Retries until the timeout.
# ---------------------------------------------------------------------------
mt_tailscale_sidecar_tcp_check() {
    local namespace="${1:?}" selector="${2:?}" host="${3:?}" port="${4:?}" timeout="${5:-60}"
    local start=$SECONDS pod
    while :; do
        pod=$(kubectl get pods -n "$namespace" -l "$selector" -o json 2>/dev/null \
            | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | .[0].metadata.name // empty') || pod=""
        local nc_err=""
        if [ -n "$pod" ]; then
            if nc_err=$(kubectl exec -n "$namespace" "$pod" -c tailscale -- nc -z -w 5 "$host" "$port" 2>&1 >/dev/null); then
                print_success "Mesh positive control OK: ${host}:${port} reachable from $namespace/$pod ($((SECONDS - start))s)"
                return 0
            fi
        fi
        if [ $((SECONDS - start)) -ge "$timeout" ]; then
            print_error "Mesh positive control FAILED: ${host}:${port} not reachable from ${pod:-<no pod>} within ${timeout}s (tunnel down, or the ACL does not open this port to the sidecar's tag)"
            [ -n "$nc_err" ] && printf '%s\n' "$nc_err" | tail -1 | sed 's/^/    last error: /'
            return 1
        fi
        sleep 5
    done
}

# ===========================================================================
# In-cluster probes with an EXPLICIT verdict (issue #623)
#
# Background: `kubectl run --rm -i` decides by attaching to a throwaway pod.
# On LKE the attach path (konnectivity) flakes under parallel deploys --
# "couldn't attach to pod ... falling back to streaming logs", "unable to
# upgrade connection", "dial tcp <cp>:8090: connection refused" -- and the
# fallback can lose the output entirely (exit 0, empty stdout). A probe that
# greps for a positive token then reads "no answer" as "no", and a repair
# path keyed on that answer acts on a HEALTHY system (pipeline 2076 dropped
# the public schema of an intact Roundcube DB).
#
# Contract: the probe SCRIPT prints exactly one verdict line
#     MT_PROBE_VERDICT=OK        the thing is there / the check passed
#     MT_PROBE_VERDICT=MISSING   definite negative (what was looked for is absent)
#     MT_PROBE_VERDICT=FAIL      definite negative (a check ran and failed)
# and may print one free-form detail line `MT_PROBE_DETAIL=...`. Anything
# else -- empty output, a transport error, a pod that never ran, a timeout,
# contradictory verdict lines -- is UNKNOWN. UNKNOWN is retried a bounded
# number of times and then reported as UNKNOWN; it is NEVER a negative.
# Callers must fail CLOSED on UNKNOWN: abort without touching anything.
#
# Transports (both print the probe's stdout+stderr and never parse it):
#   mt_probe_exec <namespace> <pod> <container> -- <cmd...>
#       `kubectl exec` into an already-running pod. Nothing to schedule and
#       no attach race; a lost stream yields a kubectl error line and no
#       sentinel -> UNKNOWN.
#   mt_probe_job  <namespace> <name-prefix> <image> [opts...] -- <cmd...>
#       A Job (backoffLimit 0, restartPolicy Never), polled to a terminal
#       condition, then `kubectl logs` AFTER completion (no attach involved;
#       the log fetch itself is retried on transport errors). Cleaned up on
#       return; ttlSecondsAfterFinished is the backstop.
#       opts: --env K=V                        literal env var
#             --env-from-secret VAR=secret/key  env var from a Secret key
#             --timeout N                      seconds to wait for a terminal
#                                              condition (default 180)
#
# Driver:
#   mt_kubectl_probe <label> <attempts> <transport-fn> [args...]
#       Sets MT_PROBE_VERDICT (OK|MISSING|FAIL|UNKNOWN), MT_PROBE_DETAIL and
#       MT_PROBE_OUTPUT (last attempt's raw output).
#       Returns 0 = OK, 1 = MISSING or FAIL, 2 = UNKNOWN after all attempts.
#       Backoff between attempts is attempt*MT_PROBE_BACKOFF_BASE seconds
#       (default 5; tests set 0). mt_probe_job polls every
#       MT_PROBE_POLL_INTERVAL seconds (default 3).
# ===========================================================================

mt_probe_exec() {
    local namespace="${1:?mt_probe_exec: namespace}" pod="${2:?mt_probe_exec: pod}" container="${3:?mt_probe_exec: container}"
    shift 3
    [ "${1:-}" = "--" ] && shift
    # stderr merged on purpose: a transport error must show up in the excerpt
    # instead of reading as an empty answer. The exit code is irrelevant to the
    # verdict (the sentinel decides), so it is deliberately not propagated.
    kubectl exec -n "$namespace" "$pod" -c "$container" -- "$@" 2>&1 || true
}

# Fetch `kubectl logs` with retries on transport errors. Prints the logs on
# success; on failure prints an explicit marker line (so a lost fetch is never
# mistaken for "the pod printed nothing") and returns 1.
# Usage: mt_kubectl_logs [attempts] -- <kubectl logs args...>
mt_kubectl_logs() {
    local attempts=3
    if [ "${1:-}" != "--" ]; then attempts="$1"; shift; fi
    [ "${1:-}" = "--" ] && shift
    local attempt out=""
    for attempt in $(seq 1 "$attempts"); do
        if out=$(kubectl logs "$@" 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        [ "$attempt" -lt "$attempts" ] && sleep $((attempt * ${MT_PROBE_BACKOFF_BASE:-5}))
    done
    printf '[mt_kubectl_logs: fetch FAILED after %s attempts: %s]\n' "$attempts" "$(printf '%s' "$out" | tail -1)"
    return 1
}

mt_probe_job() {
    local namespace="${1:?mt_probe_job: namespace}" prefix="${2:?mt_probe_job: name-prefix}" image="${3:?mt_probe_job: image}"
    shift 3
    local timeout=180 env_json='[]' k v s
    while [ $# -gt 0 ]; do
        case "$1" in
            --env)
                k="${2%%=*}"; v="${2#*=}"
                env_json=$(printf '%s' "$env_json" | jq -c --arg n "$k" --arg v "$v" '. + [{name:$n, value:$v}]')
                shift 2 ;;
            --env-from-secret)
                k="${2%%=*}"; s="${2#*=}"
                env_json=$(printf '%s' "$env_json" | jq -c --arg n "$k" --arg s "${s%%/*}" --arg key "${s#*/}" \
                    '. + [{name:$n, valueFrom:{secretKeyRef:{name:$s, key:$key}}}]')
                shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --) shift; break ;;
            *) echo "mt_probe_job: unknown option $1"; return 2 ;;
        esac
    done
    [ $# -gt 0 ] || { echo "mt_probe_job: no command given"; return 2; }

    local name="${prefix}-$$-${RANDOM}"
    local cmd_json
    cmd_json=$(jq -nc '$ARGS.positional' --args -- "$@")
    local manifest
    manifest=$(jq -nc --arg ns "$namespace" --arg name "$name" --arg image "$image" --arg prefix "$prefix" \
        --argjson cmd "$cmd_json" --argjson env "$env_json" --argjson deadline "$timeout" '{
        apiVersion: "batch/v1", kind: "Job",
        metadata: {name: $name, namespace: $ns,
                   labels: {"app.kubernetes.io/name": "mt-probe", "mothertree.org/probe": $prefix}},
        spec: {backoffLimit: 0, activeDeadlineSeconds: $deadline, ttlSecondsAfterFinished: 900,
               template: {metadata: {labels: {"app.kubernetes.io/name": "mt-probe", "mothertree.org/probe": $prefix}},
                          spec: {restartPolicy: "Never",
                                 automountServiceAccountToken: false,
                                 containers: [{name: "probe", image: $image, command: $cmd, env: $env,
                                               resources: {requests: {cpu: "50m", memory: "64Mi"},
                                                           limits: {cpu: "500m", memory: "256Mi"}}}]}}}}')

    # Create; a transport error here prints and yields no sentinel -> UNKNOWN.
    if ! printf '%s\n' "$manifest" | kubectl apply -f - 2>&1; then
        echo "[mt_probe_job: could not create job/$name in $namespace]"
        return 0
    fi

    # Poll to a terminal condition. Complete OR Failed both mean "the script
    # ran to an exit" and the logs carry the verdict; only no-terminal-condition
    # within the timeout (unschedulable, image pull, deadline) is a non-answer.
    local start=$SECONDS conds terminal=""
    while :; do
        conds=$(kubectl get job "$name" -n "$namespace" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null || true)
        case " $conds " in
            *" Complete "*|*" SuccessCriteriaMet "*) terminal="Complete"; break ;;
            *" Failed "*|*" FailureTarget "*)        terminal="Failed"; break ;;
        esac
        if [ $((SECONDS - start)) -ge "$timeout" ]; then break; fi
        sleep "${MT_PROBE_POLL_INTERVAL:-3}"
    done
    if [ -z "$terminal" ]; then
        echo "[mt_probe_job: job/$name in $namespace reached no terminal condition within ${timeout}s]"
        kubectl get pods -n "$namespace" -l "job-name=$name" -o wide 2>&1 | sed 's/^/    /' || true
    else
        echo "[mt_probe_job: job/$name $terminal after $((SECONDS - start))s]"
        mt_kubectl_logs -- -n "$namespace" "job/$name" --all-containers=true || true
    fi
    kubectl delete job "$name" -n "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    return 0
}

mt_kubectl_probe() {
    local label="${1:?mt_kubectl_probe: label}" attempts="${2:?mt_kubectl_probe: attempts}"
    shift 2
    [ $# -gt 0 ] || { print_error "mt_kubectl_probe: no transport command given"; return 2; }
    local attempt verdicts
    MT_PROBE_VERDICT="UNKNOWN"; MT_PROBE_DETAIL=""; MT_PROBE_OUTPUT=""
    for attempt in $(seq 1 "$attempts"); do
        MT_PROBE_OUTPUT=$("$@" 2>&1) || true
        # Sentinel lines only, exact match, whole line -- stray chatter can never
        # be read as a verdict, and two different verdicts is a probe bug, not an answer.
        verdicts=$(printf '%s\n' "$MT_PROBE_OUTPUT" | grep -E '^MT_PROBE_VERDICT=(OK|MISSING|FAIL)$' | sort -u | sed 's/^MT_PROBE_VERDICT=//' || true)
        # shellcheck disable=SC2034  # read by callers
        MT_PROBE_DETAIL=$(printf '%s\n' "$MT_PROBE_OUTPUT" | grep -E '^MT_PROBE_DETAIL=' | tail -1 | sed 's/^MT_PROBE_DETAIL=//' || true)
        case "$verdicts" in
            OK|MISSING|FAIL)
                MT_PROBE_VERDICT="$verdicts"
                [ "$attempt" -gt 1 ] && print_status "probe [$label]: $MT_PROBE_VERDICT on attempt $attempt"
                [ "$MT_PROBE_VERDICT" = "OK" ] && return 0
                return 1 ;;
            "") ;;
            *)  print_warning "probe [$label]: contradictory verdict lines ($(printf '%s' "$verdicts" | tr '\n' ',')) -- treating as UNKNOWN" ;;
        esac
        print_warning "probe [$label]: no verdict on attempt $attempt/$attempts (transport lost, pod never ran, or timed out)"
        printf '%s\n' "$MT_PROBE_OUTPUT" | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^/    /'
        [ "$attempt" -lt "$attempts" ] && sleep $((attempt * ${MT_PROBE_BACKOFF_BASE:-5}))
    done
    MT_PROBE_VERDICT="UNKNOWN"
    return 2
}

# ---------------------------------------------------------------------------
# mt_coredns_rewrite_verify -- prove a CoreDNS rewrite is live on EVERY replica
# Usage: mt_coredns_rewrite_verify <namespace> <host> <want-ip> [attempts=2]
#
# Runs busybox nslookup against each Running CoreDNS pod IP from a Job in
# <namespace>, polling up to 90s for all replicas to answer <want-ip>.
# Returns 0 (converged), 1 (definitely not converged), 2 (could not determine --
# the probe itself never delivered a verdict). Callers abort on both 1 and 2.
# ---------------------------------------------------------------------------
mt_coredns_rewrite_verify() {
    local namespace="${1:?}" host="${2:?}" want="${3:?}" attempts="${4:-2}"
    local pod_ips
    pod_ips=$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.phase == "Running") | select(.metadata.deletionTimestamp == null) | .status.podIP' \
        | tr '\n' ' ') || pod_ips=""
    if [ -z "${pod_ips// /}" ]; then
        print_error "mt_coredns_rewrite_verify: no Running CoreDNS pods found (label k8s-app=kube-dns in kube-system)"
        return 2
    fi
    print_status "Expecting $host -> $want from CoreDNS pods: $pod_ips"
    # Note: busybox `nslookup` prints the DNS server's own address line first
    # ("Address: <server>#53") and only then the answer addresses after "Name:"
    # -- the awk filter skips lines until "Name:" appears. The script always
    # exits 0: the verdict travels in the sentinel line, never in the exit code.
    local script
    read -r -d '' script <<'PROBE' || true
for i in $(seq 1 18); do
    all_ok=1
    last_state=
    for ip in $PROBE_POD_IPS; do
        got=$(nslookup "$PROBE_HOST" "$ip" 2>/dev/null | awk '/^Name:/{f=1; next} f && /^Address/{print $2; exit}')
        if [ "$got" != "$PROBE_WANT" ]; then
            all_ok=0
            last_state="replica $ip returned '$got'"
        fi
    done
    if [ "$all_ok" = 1 ]; then
        echo "OK: all CoreDNS replicas return $PROBE_WANT for $PROBE_HOST"
        echo "MT_PROBE_VERDICT=OK"
        exit 0
    fi
    echo "  attempt $i: $last_state (want $PROBE_WANT), retrying in 5s"
    sleep 5
done
echo "FAIL: not all CoreDNS replicas converged on $PROBE_WANT for $PROBE_HOST within 90s ($last_state)"
echo "MT_PROBE_VERDICT=FAIL"
exit 0
PROBE
    local rc=0
    mt_kubectl_probe "coredns rewrite $host" "$attempts" \
        mt_probe_job "$namespace" "dns-probe" "busybox:1.36" \
            --env "PROBE_POD_IPS=$pod_ips" --env "PROBE_HOST=$host" --env "PROBE_WANT=$want" --timeout 180 \
            -- sh -c "$script" || rc=$?
    case "$rc" in
        0) print_success "CoreDNS rewrite verified across all replicas: $host -> $want" ;;
        1) print_error "CoreDNS rewrite for $host did not propagate to all replicas within 90s"
           printf '%s\n' "$MT_PROBE_OUTPUT" | grep -E '^(FAIL|  attempt)' | tail -3 | sed 's/^/    /' ;;
        *) print_error "Could not determine whether the CoreDNS rewrite for $host propagated (probe returned no verdict after $attempts attempts)" ;;
    esac
    return "$rc"
}
