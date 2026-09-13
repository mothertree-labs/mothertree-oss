#!/bin/bash

# Deploy Open WebUI for a tenant (per-tenant LLM chat UI with Keycloak OIDC)
# Uses shared Ollama inference engine in infra-llm namespace.
#
# Usage:
#   ./apps/deploy-llm-webui.sh -e <env> -t <tenant>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Open WebUI for a tenant (Keycloak OIDC auth, shared Ollama)."
    echo ""
    echo "Options:"
    echo "  -e <env>       Environment (e.g., dev, prod)"
    echo "  -t <tenant>    Tenant name (e.g., example)"
    echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env
mt_require_tenant

source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-llm-webui"

mt_require_commands kubectl yq envsubst curl jq

print_status "Deploying Open WebUI for $MT_TENANT ($MT_ENV)"
print_status "  Namespace: $NS_LLM"
print_status "  Host:      $LLM_HOST"
print_status "  Auth:      $AUTH_HOST/realm/$TENANT_KEYCLOAK_REALM"

# Validate required variables and secrets
if [ "${LLM_ENABLED:-false}" != "true" ]; then
    print_warning "LLM is not enabled for $MT_TENANT (features.llm_enabled != true) — skipping"
    exit 0
fi

if [ -z "${LLM_OIDC_CLIENT_SECRET:-}" ] || [ "$LLM_OIDC_CLIENT_SECRET" = "null" ]; then
    print_error "LLM_OIDC_CLIENT_SECRET not set. Add oidc.open_webui_client_secret to tenant secrets."
    exit 1
fi

# Load Keycloak admin password (needed to create/update the OIDC client)
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    KEYCLOAK_ADMIN_PASSWORD=$(yq '.keycloak.admin_password // ""' "$TENANT_SECRETS" 2>/dev/null)
fi
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ] || [ "$KEYCLOAK_ADMIN_PASSWORD" = "null" ]; then
    print_error "KEYCLOAK_ADMIN_PASSWORD is required. Set keycloak.admin_password in tenant secrets."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Ensure namespace exists
# ---------------------------------------------------------------------------
mt_reset_change_tracker
print_status "Ensuring $NS_LLM namespace exists..."
kubectl create namespace "$NS_LLM" --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 2. Setup Open WebUI OIDC client in Keycloak
# ---------------------------------------------------------------------------
print_status "Setting up Open WebUI OIDC client in Keycloak realm $TENANT_KEYCLOAK_REALM..."

# Access Keycloak through kubectl port-forward (avoids ingress TLS issues).
LOCAL_PORT=$((RANDOM + 10000))
print_status "Setting up port-forward to Keycloak on port ${LOCAL_PORT}..."
kubectl -n "$NS_AUTH" port-forward svc/keycloak-keycloakx-http ${LOCAL_PORT}:80 > /tmp/keycloak-pf.log 2>&1 &
PF_PID=$!
# One EXIT trap only — a second `trap ... EXIT` replaces rather than appends,
# which would silently drop the port-forward kill. gate_log is set much later;
# ${gate_log:-} keeps this valid under `set -u` before then.
trap 'kill $PF_PID 2>/dev/null || true; rm -f "${gate_log:-}"' EXIT
sleep 3

KEYCLOAK_URL="http://localhost:${LOCAL_PORT}"

# Get admin token
TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" | jq -r '.access_token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
    print_error "Failed to get Keycloak admin token"
    exit 1
fi

# Check if client exists
EXISTING_CLIENT=$(curl -s "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=open-webui" \
    -H "Authorization: Bearer $TOKEN")
CLIENT_COUNT=$(echo "$EXISTING_CLIENT" | jq 'length')

CLIENT_CONFIG=$(jq -cn \
    --arg client_secret "$LLM_OIDC_CLIENT_SECRET" \
    --arg redirect_uri "https://$LLM_HOST/*" \
    --arg web_origin "https://$LLM_HOST" \
    '{
        clientId: "open-webui",
        name: "Open WebUI",
        enabled: true,
        protocol: "openid-connect",
        publicClient: false,
        secret: $client_secret,
        standardFlowEnabled: true,
        directAccessGrantsEnabled: false,
        serviceAccountsEnabled: false,
        redirectUris: [$redirect_uri],
        webOrigins: [$web_origin],
        attributes: {
            "pkce.code.challenge.method": "S256"
        }
    }')

if [ "$CLIENT_COUNT" -gt 0 ]; then
    print_status "Updating existing open-webui client..."
    CLIENT_UUID=$(echo "$EXISTING_CLIENT" | jq -r '.[0].id')
    curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_CONFIG" > /dev/null
else
    print_status "Creating new open-webui client..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_CONFIG" > /dev/null
fi
print_success "Open WebUI OIDC client configured"

# Kill the port-forward — no longer needed
kill $PF_PID 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Ensure Keycloak auth ingress (external) for this tenant
#
# The OIDC flow redirects the browser to $AUTH_HOST (Keycloak). The external
# ingress must exist so the public NodeBalancer routes the request to Keycloak
# with the proper wildcard TLS cert. The template is also used by
# deploy-matrix.sh — we apply it here so deploy-llm-webui.sh is self-sufficient.
# Note: The open-webui-oidc Secret is defined in the template applied in step 6.
# =============================================================================
print_status "Ensuring external Keycloak ingress for $AUTH_HOST..."
envsubst '${AUTH_HOST} ${TENANT} ${NS_AUTH} ${TENANT_DOMAIN} ${TENANT_NAME}' \
    < "$REPO_ROOT/apps/manifests/keycloak/tenant-auth-ingress.yaml.tpl" \
    | kubectl apply -f -
print_success "External Keycloak ingress configured for $AUTH_HOST"

# ---------------------------------------------------------------------------
# 4. Ensure Keycloak internal ingress for this tenant
#
# Open WebUI's backend fetches OIDC metadata from $AUTH_HOST server-side.
# The CoreDNS rewrite below routes these requests to the internal ingress
# controller. That controller needs a matching ingress with the wildcard TLS
# cert — otherwise it serves its default (fake) cert and the Python HTTPX
# client rejects the connection.
# =============================================================================
print_status "Ensuring internal Keycloak ingress for $AUTH_HOST..."
if ! kubectl -n "$NS_AUTH" get ingress "keycloak-internal-${MT_TENANT}" >/dev/null 2>&1; then
    kubectl apply -f - <<INGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
  labels:
    app: keycloak
    purpose: internal-oidc
    tenant: ${MT_TENANT}
  name: keycloak-internal-${MT_TENANT}
  namespace: ${NS_AUTH}
spec:
  ingressClassName: nginx-internal
  rules:
  - host: ${AUTH_HOST}
    http:
      paths:
      - backend:
          service:
            name: keycloak-keycloakx-http
            port:
              name: http
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - ${AUTH_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
INGRESS
    print_success "Internal Keycloak ingress created for $AUTH_HOST"
else
    print_status "Internal Keycloak ingress already exists for $AUTH_HOST"
fi

# ---------------------------------------------------------------------------
# 5. CoreDNS rewrite for AUTH_HOST → internal ingress
#
# The CoreDNS rewrite makes $AUTH_HOST resolve to the internal ingress
# controller IP, keeping server-side OIDC metadata requests in-cluster and
# avoiding hairpin connections through the public NodeBalancer.
#
# Follows the same pattern as deploy-stalwart.sh's mail rewrite.
# =============================================================================
print_status "Ensuring CoreDNS rewrite for $AUTH_HOST → internal ingress"
if ! kubectl -n kube-system get configmap coredns-custom >/dev/null 2>&1; then
    kubectl -n kube-system create configmap coredns-custom
fi
_coredns_key="auth-${MT_TENANT}.include"
_coredns_target="ingress-nginx-internal-controller.infra-ingress-internal.svc.cluster.local"
_coredns_body="rewrite name ${AUTH_HOST} ${_coredns_target}"$'\n'

_coredns_existing=$(kubectl -n kube-system get configmap coredns-custom \
    -o "jsonpath={.data.${_coredns_key}}" 2>/dev/null || true)
if [ "$_coredns_existing" = "$_coredns_body" ]; then
    print_status "CoreDNS rewrite already in place — skipping patch + rollout"
    _coredns_changed=false
else
    _coredns_patch=$(jq -cn \
        --arg key "$_coredns_key" \
        --arg body "$_coredns_body" \
        '{data: {($key): $body}}')
    kubectl -n kube-system patch configmap coredns-custom --type=merge -p "$_coredns_patch"
    print_success "CoreDNS rewrite applied"
    _coredns_changed=true
fi

if [ "$_coredns_changed" = "true" ]; then
    _coredns_deploy=$(kubectl -n kube-system get deploy -l k8s-app=kube-dns -o name | head -n1)
    if [ -z "$_coredns_deploy" ]; then
        print_error "No CoreDNS deployment found in kube-system (label k8s-app=kube-dns)"
        exit 1
    fi
    print_status "Restarting $_coredns_deploy to propagate rewrite to all replicas"
    kubectl -n kube-system rollout restart "$_coredns_deploy"
    kubectl -n kube-system rollout status "$_coredns_deploy" --timeout=180s

    if kubectl -n kube-system get ds node-local-dns >/dev/null 2>&1; then
        print_status "Restarting node-local-dns DaemonSet to flush per-node caches"
        kubectl -n kube-system rollout restart ds/node-local-dns
        kubectl -n kube-system rollout status ds/node-local-dns --timeout=180s
    fi
fi

# Verify the rewrite propagated to all CoreDNS replicas
print_status "Verifying CoreDNS rewrite propagated to ALL replicas"
_auth_cluster_ip=$(kubectl -n infra-ingress-internal get svc ingress-nginx-internal-controller \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -z "$_auth_cluster_ip" ]; then
    print_warning "Could not read internal ingress ClusterIP — skipping per-replica verification"
    print_warning "  (the rewrite rule is applied; CoreDNS reloaded; DNS will converge)"
else
    # Explicit-verdict probe via a Job + post-completion logs (issue #623): the
    # old `kubectl run --rm -i` read a lost attach as "did not propagate" and
    # failed healthy deploys (pipeline 2077). mt_coredns_rewrite_require aborts
    # on 1 (definitely not converged) but WARNS and proceeds on 2 (no verdict):
    # that flake stranded two merged PRs short of prod on 2026-09-11 (#662).
    if ! mt_coredns_rewrite_require "$NS_LLM" "$AUTH_HOST" "$_auth_cluster_ip"; then
        print_error "Check kube-system/coredns-custom ConfigMap and CoreDNS pod logs:"
        print_error "  kubectl -n kube-system get configmap coredns-custom -o yaml"
        print_error "  kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 6. Apply Open WebUI manifests
# ---------------------------------------------------------------------------
print_status "Applying Open WebUI manifests..."
# Resolve infra config path to read LLM_MODEL
_mt_resolve_infra_config "$MT_ENV" 2>/dev/null || true
if [ -n "$MT_INFRA_CONFIG" ] && [ -f "$MT_INFRA_CONFIG" ]; then
  LLM_MODEL=$(yq '.llm.model // "llama3.2:1b"' "$MT_INFRA_CONFIG")
else
  LLM_MODEL="llama3.2:1b"
fi
export LLM_MODEL

# Choose volume type based on environment.
# Dev: emptyDir is fine (ephemeral, matches Linode block-storage cap).
# Prod: PVC survives restarts and avoids conversation data loss.
if [ "$MT_ENV" = "prod" ]; then
    LLM_WEBUI_STORAGE_VALUE="persistentVolumeClaim:
            claimName: llm-data-${MT_TENANT}"
    print_status "Creating PVC for Open WebUI data (${LLM_STORAGE_SIZE})..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: llm-data-${MT_TENANT}
  namespace: ${NS_LLM}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${LLM_STORAGE_SIZE}
EOF
else
    LLM_WEBUI_STORAGE_VALUE="emptyDir: {}"
fi
export LLM_WEBUI_STORAGE_VALUE

mt_apply kubectl apply -f <(envsubst < "${REPO_ROOT}/apps/manifests/llm/open-webui-tenant.yaml.tpl")

# ---------------------------------------------------------------------------
# 7. Deploy HPA for Open WebUI auto-scaling (only if min != max replicas)
# ---------------------------------------------------------------------------
if [ "$LLM_MIN_REPLICAS" != "$LLM_MAX_REPLICAS" ]; then
    print_status "Deploying HPA for Open WebUI..."
    envsubst < "$REPO_ROOT/apps/manifests/llm/open-webui-hpa.yaml.tpl" | kubectl apply -f -
    print_success "Open WebUI HPA deployed (CPU 80% threshold)"
else
    kubectl delete hpa open-webui-hpa -n "$NS_LLM" --ignore-not-found >/dev/null 2>&1
    print_status "Open WebUI: fixed replicas ($LLM_MIN_REPLICAS), HPA removed"
fi

# ---------------------------------------------------------------------------
# 8. Wait for rollout
# ---------------------------------------------------------------------------
print_status "Waiting for Open WebUI deployment to roll out..."
kubectl rollout status deployment/open-webui -n "$NS_LLM" --timeout=120s || {
    print_warning "Open WebUI rollout not ready within timeout — dumping pod diagnostics"
    dump_pod_diagnostics "$NS_LLM" "app=open-webui"
}

# ---------------------------------------------------------------------------
# 9. Verification
# ---------------------------------------------------------------------------
print_status "Verifying Open WebUI pod..."
kubectl get pods -n "$NS_LLM"

# Check that the OIDC discovery endpoint resolves
print_status "Verifying OpenID Connect discovery..."
kubectl run -n "$NS_LLM" --rm -i --restart=Never llm-oidc-check \
    --image=curlimages/curl:8.12.1 \
    -- curl -sf "https://$AUTH_HOST/realms/$TENANT_KEYCLOAK_REALM/.well-known/openid-configuration" \
    > /dev/null 2>&1 && \
    print_success "OIDC discovery endpoint reachable" || \
    print_warning "OIDC discovery not reachable from inside cluster (expected if Keycloak ingress uses auth.dev.*)"

# Restart if changes were detected
mt_restart_if_changed deployment/open-webui -n "$NS_LLM"

# ---------------------------------------------------------------------------
# 10. Ensure legacy function calling (web search wiring)
#
# Open WebUI 0.11 defaults to native function calling, which routes web
# search through the injected search_web tool — unreliable for the pinned
# small model (see the DEFAULT_MODEL_PARAMS comment in
# apps/manifests/llm/open-webui-tenant.yaml.tpl). Force the legacy path so
# the BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL forced-RAG handler runs.
#
# The DEFAULT_MODEL_PARAMS env in the template only seeds a FRESH webui.db.
# On PVC-backed databases the row already exists (e.g. seeded as "{}" on an
# earlier version) and shadows the env, so upsert it here idempotently.
# ---------------------------------------------------------------------------
print_status "Ensuring legacy function calling for web search in Open WebUI..."
if kubectl get deployment open-webui -n "$NS_LLM" >/dev/null 2>&1; then
    kubectl exec -i -n "$NS_LLM" deploy/open-webui -- sh -c 'python3 -' <<'PYEOF'
import sqlite3, time, json
db = sqlite3.connect("/app/backend/data/webui.db")
cur = db.execute("SELECT value FROM config WHERE key = 'models.default_params'")
row = cur.fetchone()
current = json.loads(row[0]) if row and row[0] else {}
if current.get("function_calling") != "legacy":
    current["function_calling"] = "legacy"
    db.execute(
        "INSERT OR REPLACE INTO config (key, value, updated_at) VALUES (?, ?, ?)",
        ("models.default_params", json.dumps(current), int(time.time() * 1000)),
    )
    db.commit()
    print("models.default_params upserted:", json.dumps(current))
else:
    print("models.default_params already legacy — no change")
PYEOF
    print_success "Legacy function calling enabled (models.default_params.function_calling=legacy)"
else
    print_warning "open-webui Deployment not found in $NS_LLM — skipped config upsert (run deploy-llm-webui.sh after the app exists)"
fi

# ---------------------------------------------------------------------------
# 11. Web-search functional gate
#
# Image upgrades can break web search without breaking the deployment: the
# pod comes up healthy, OIDC works, the model list renders, but search
# silently never runs (e.g. Open WebUI 0.11 changed the function-calling
# default so the forced-RAG search handler was skipped — see
# docs/plans/llm/web-search.md). This gate exercises the real path as a
# role=user account: SearXNG canary, then a chat completion with
# features.web_search=true asserting the response cites sources.
#
# ADVISORY BY DEFAULT. The gate reports one of three outcomes and this script
# decides what is fatal:
#
#   0  passed
#   2  could not run — upstream search engines refused this cluster's egress
#      IP (CAPTCHA / rate limit), Ollama down, model or key missing. Warn and
#      continue: "cannot run the test" is not "the test failed", and blocking
#      on it took the whole PR queue down on 2026-09-10 (#658/#657/#625/#639
#      all failed this step on a freshly rebuilt dev cluster whose new egress
#      IP was CAPTCHA'd by duckduckgo and startpage from the first query).
#   3  regression — the canary proved upstream search works and our chat path
#      still cited no sources. This is the real signal. Warned about loudly,
#      FATAL on prod/prod-eu, advisory on dev -- see the case statement below.
#      WEBSEARCH_GATE_ENFORCE in the environment overrides either way.
# This script exits 20 when an enforced gate fails, which create_env treats as
# fatal; any other non-zero stays non-fatal there (see #446). Gate result codes
# from the gate script itself are separate and listed below.
#
#   *  anything else, 1 included — the harness broke, not the deployment.
#      kubectl reports its own failures (no such pod, API unreachable, exec
#      denied) as exit 1, which is why the gate's regression verdict is 3:
#      a connection problem must never be announced as "web search is broken".
#      90 is synthesised here for "exited 0 but never printed a verdict".
#
# Exit 0 is NOT taken at face value: it must be corroborated by the gate's own
# GATE PASS line, or an empty stdin to `python3 -` would read EOF, exit 0, and
# be reported as a pass that tested nothing.
#
# A non-pass also downgrades the closing "deployed" line from green to a
# warning, so a log that no longer goes red cannot end looking clean.
# ---------------------------------------------------------------------------
print_status "Waiting for Open WebUI rollout before web-search gate..."
# 300s: under concurrent CI deploys the pod can take >180s to become Ready
# (image churn + node CPU contention) — observed live in pipeline 1894.
kubectl rollout status deployment/open-webui -n "$NS_LLM" --timeout=300s

# Enforcement is per-environment, not global. Prod and prod-eu have stable egress
# IPs and passed the gate cleanly on 2026-09-10/11 (canary returning 29-31
# results), so a regression there is real and should block. Dev is rebuilt on
# demand and lands on fresh Linode IPs that duckduckgo and startpage CAPTCHA from
# the first query (#661), which is what made a hard gate able to take the whole
# PR queue down -- so dev stays advisory.
#
# Derived from MT_ENV rather than set in .woodpecker/ so that a standalone
# `./apps/deploy-llm-webui.sh -e prod -t <tenant>` gets the same treatment as the
# pipeline; an explicit WEBSEARCH_GATE_ENFORCE in the environment still wins.
case "${MT_ENV:-}" in
    prod|prod-eu) _gate_enforce="${WEBSEARCH_GATE_ENFORCE:-1}" ;;
    *)            # Unknown env stays ADVISORY on purpose: auto-arming a gate that is
                  # known to fail on fresh egress IPs (#661) for any future env name
                  # would reintroduce the 2026-09-10 queue-wide outage. But silence
                  # is the real risk here, so say so.
                  _gate_enforce="${WEBSEARCH_GATE_ENFORCE:-0}"
                  [ -n "${WEBSEARCH_GATE_ENFORCE:-}" ] || \
                    print_warning "MT_ENV=${MT_ENV:-unset} is not in the gate-enforcement allowlist (prod, prod-eu) — web-search gate is ADVISORY." ;;
esac

print_status "Running web-search functional gate (SearXNG + chat completion sources)..."
# GATE_MODEL is passed via env(1), not spliced into the sh -c string, so a
# quote in the config value cannot break out into the remote shell.
# The gate script must exist and be readable BEFORE we try to deliver it. A
# failed input redirect is reported by bash as exit 1, which now merely warns —
# so without this check a moved file or a mis-resolved REPO_ROOT would turn the
# gate into a permanent silent no-op. That is a repo-integrity bug, not a
# "legitimate reason the test cannot run", so it stays fatal.
# -s as well as -r: `-r` alone passes on a zero-byte or truncated file, and
# `python3 - < empty` then exits 0 having run nothing — which the GATE PASS
# corroboration below turns into 90 (advisory), i.e. the exact repo-integrity
# class this check declares fatal would have slipped through as a warning.
GATE_SCRIPT="$REPO_ROOT/apps/websearch-gate/websearch-gate.py"
if [ ! -r "$GATE_SCRIPT" ] || [ ! -s "$GATE_SCRIPT" ]; then
    print_error "Web-search gate script missing, unreadable or empty: $GATE_SCRIPT"
    exit 1
fi

# Captured to a file rather than piped: assigning gate_rc inside a pipeline runs
# it in a subshell and loses the value (the same trap CLAUDE.md documents for
# mt_apply). `|| gate_rc=$?` keeps `set -e` from aborting before we classify —
# the exit code IS the result here, not an error to propagate.
gate_log="$(mktemp)"
gate_rc=0
kubectl exec -i -n "$NS_LLM" deploy/open-webui -- env "GATE_MODEL=$LLM_MODEL" sh -c \
    'export WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY:-$(cat /app/backend/.webui_secret_key 2>/dev/null)}"; python3 -' \
    < "$GATE_SCRIPT" > "$gate_log" 2>&1 || gate_rc=$?
cat "$gate_log"

# Exit 0 alone is not proof the gate ran. `kubectl exec -i` delivering empty or
# truncated stdin leaves `python3 -` with nothing to execute: it reads EOF and
# exits 0, and the deploy would report a pass having tested nothing. Same class
# as the Roundcube schema-verify false negative (an empty result from
# `kubectl run -i` is not an answer). The gate prints an unambiguous positive
# token when it really passed, so require it and fail closed to "no verdict".
if [ "$gate_rc" -eq 0 ] && ! grep -q "GATE PASS:" "$gate_log"; then
    print_warning "Web-search gate exited 0 without printing a GATE PASS verdict —"
    print_warning "  treating as NO VERDICT, not a pass (likely empty/truncated stdin to python3 -)."
    gate_rc=90
fi
rm -f "$gate_log"

case "$gate_rc" in
    0)
        print_success "Web-search gate passed"
        ;;
    2)
        print_warning "Web-search gate COULD NOT RUN for $MT_TENANT — the test was not performed."
        print_warning "  Web search is NOT known to be broken and is NOT known to be working."
        print_warning "  Usual cause: upstream engines refusing this cluster's egress IP."
        print_warning "  Check:  kubectl logs -n infra-llm deploy/searxng --tail=50"
        ;;
    3)
        # Canary proved upstream search works and our chat path still cited no
        # sources — the exact silent breakage this gate was built for.
        print_warning "*** Web-search gate FAILED for $MT_TENANT — web search is BROKEN on this deployment. ***"
        print_warning "  This is OURS, not upstream: either the container env contradicts the"
        print_warning "  deploy (ENABLE_WEB_SEARCH / SEARXNG_QUERY_URL — checked before the"
        print_warning "  canary), or the canary proved upstream search works and our chat path"
        print_warning "  still cited no sources. The gate's own output above says which."
        print_warning "  See docs/plans/llm/web-search.md."
        print_warning "  Debug: kubectl logs -n $NS_LLM deploy/open-webui --tail=100"
        if [ "$_gate_enforce" = "1" ]; then
            print_error "Web-search gate enforced on ${MT_ENV:-this env} — failing the deploy."
            # Exit 20, not 1. This script has two callers and they disagree:
            # ci/scripts/ci-deploy-app.sh calls it bare under `set -e` (any
            # non-zero is fatal), while create_env deliberately treats a generic
            # non-zero as non-fatal ("had issues, continuing") because of #446,
            # where a stuck Ollama init made deploys flaky. A bare exit 1 would
            # therefore be honoured on one path and swallowed on the other, so
            # deploy-prod could go green with web search broken. 20 is the
            # distinct "an enforced gate failed" signal that create_env
            # propagates explicitly; ci-deploy-app.sh already propagates it.
            exit 20
        fi
        print_warning "  Continuing anyway (gate is advisory on ${MT_ENV:-this env}; WEBSEARCH_GATE_ENFORCE=1 blocks)."
        ;;
    *)
        # Not a verdict about the deployment: the gate never got to report one.
        print_warning "Web-search gate did not report a verdict for $MT_TENANT (exit $gate_rc)."
        print_warning "  90 = exited 0 but printed no GATE PASS, so nothing was actually tested."
        print_warning "  Otherwise the harness broke: the gate itself only ever exits 0/2/3, so"
        print_warning "  any other code is kubectl exec failing (no such pod, API unreachable,"
        print_warning "  exec denied) or the script erroring before it could judge."
        print_warning "  Either way web search is UNTESTED, not known-broken."
        print_warning "  Debug: kubectl logs -n $NS_LLM deploy/open-webui --tail=100"
        ;;
esac

if [ "$gate_rc" -eq 0 ]; then
    print_success "Open WebUI deployed for $MT_TENANT!"
else
    # Do not let the last line of a non-blocking failure be unqualified green.
    print_warning "Open WebUI deployed for $MT_TENANT — but the web-search gate did NOT pass (exit $gate_rc, see above)."
fi
print_success "  URL:  https://${LLM_HOST}"
print_success "  Auth: Keycloak realm $TENANT_KEYCLOAK_REALM via $AUTH_HOST"
