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
