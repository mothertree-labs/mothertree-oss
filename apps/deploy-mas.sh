#!/bin/bash

# Deploy the Matrix Authentication Service (MAS) for a tenant.
#
# MAS provides native OAuth 2.0 login for Matrix clients (Element X requires it,
# and QR-code login needs it). Keycloak stays the identity provider: MAS uses
# the tenant realm as its only upstream and has local passwords disabled.
#
# This script deploys MAS INERT (issue #824, PR 1): `matrix.kind:
# synapse_read_only` and Synapse does not delegate auth to it yet. The cutover
# (Synapse `matrix_authentication_service`, compat-path routing, syn2mas)
# is a separate change.
#
# Steps:
#   1. Resolve MAS secrets (tenant secrets YAML → live K8s Secret → generate)
#   2. Create the MAS database + role on the shared PostgreSQL VM (via PgBouncer)
#   3. Create/update the `matrix-mas` confidential client in the tenant realm
#   4. Apply the `mas-config` Secret, Service, Deployment and Ingress
#
# Called from apps/deploy-matrix.sh; also runnable on its own:
#   ./apps/deploy-mas.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy the Matrix Authentication Service (MAS) for a tenant."
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
mt_deploy_start "deploy-mas"

mt_require_commands kubectl envsubst curl jq yq openssl

if [ "${MATRIX_ENABLED:-true}" != "true" ]; then
    print_status "Matrix is not enabled for $MT_TENANT (features.matrix_enabled=false) — skipping MAS"
    exit 0
fi

: "${NS_MATRIX:?NS_MATRIX not set}"
: "${MAS_HOST:?MAS_HOST not set}"
: "${MATRIX_HOST:?MATRIX_HOST not set}"
: "${AUTH_HOST:?AUTH_HOST not set}"
: "${TENANT_KEYCLOAK_REALM:?TENANT_KEYCLOAK_REALM not set}"
: "${KEYCLOAK_INTERNAL_URL:?KEYCLOAK_INTERNAL_URL not set}"
: "${PG_HOST:?PG_HOST not set — run deploy_infra first}"
: "${MAS_DB_NAME:?MAS_DB_NAME not set (database.mas_db in tenant config)}"
: "${MAS_DB_USER:?MAS_DB_USER not set}"

# Upstream provider ID (a ULID). It is part of the Keycloak redirect URI
# (/upstream/callback/<id>) and the key MAS stores user links under, so it is
# a fixed constant — NEVER change it once a tenant has MAS users.
export MAS_UPSTREAM_PROVIDER_ID="01M83CMKJR82BAG4TJ27EE2SFB"
MAS_KC_CLIENT_ID="matrix-mas"

print_status "Deploying Matrix Authentication Service for $MT_TENANT ($MT_ENV)"
print_status "  Namespace: $NS_MATRIX"
print_status "  Host:      https://$MAS_HOST"
print_status "  Database:  $MAS_DB_NAME (user: $MAS_DB_USER) via $PG_HOST"
print_status "  Upstream:  https://$AUTH_HOST/realms/$TENANT_KEYCLOAK_REALM (client $MAS_KC_CLIENT_ID)"

mt_reset_change_tracker

kubectl create namespace "$NS_MATRIX" --dry-run=client -o yaml | kubectl apply -f -

# =============================================================================
# 1. Secrets
# =============================================================================
# Priority: 1) tenant secrets YAML (loaded by config.sh), 2) the live
# mas-config Secret, 3) generate. Same precedence as the portal secrets: the
# values survive redeploys because step 4 writes them back into mas-config.
_mas_resolve() {
    # _mas_resolve <VAR> <secret-key> <generator command...>
    local var="$1" key="$2"
    shift 2
    local val="${!var:-}"
    if [ -n "$val" ] && [ "$val" != "null" ] && [[ "$val" != *PLACEHOLDER* ]]; then
        print_status "MAS $key: from tenant secrets"
    else
        val=$(read_k8s_secret "$NS_MATRIX" "mas-config" "$key")
        if [ -n "$val" ]; then
            print_status "MAS $key: reusing existing value from cluster"
        else
            print_warning "MAS $key: not configured, generating one"
            val=$("$@")
            if [ -z "$val" ]; then
                print_error "MAS $key: generator produced no value"
                exit 1
            fi
        fi
    fi
    printf -v "$var" '%s' "$val"
}

_gen_rsa_key() { openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null; }
_gen_ec_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null; }

# Signing keys (multi-line PEM) can be pinned in tenant secrets too.
MAS_SIGNING_KEY_RSA=$(yq '.mas.signing_key_rsa // ""' "$TENANT_SECRETS")
MAS_SIGNING_KEY_EC=$(yq '.mas.signing_key_ec // ""' "$TENANT_SECRETS")

_mas_resolve MAS_DB_PASSWORD           db-password             openssl rand -hex 24
_mas_resolve MAS_OIDC_CLIENT_SECRET    keycloak-client-secret  openssl rand -hex 32
# 32-byte hex. Changing it later loses every encrypted field in the MAS DB.
_mas_resolve MAS_ENCRYPTION_KEY        encryption-key          openssl rand -hex 32
_mas_resolve MAS_SYNAPSE_SHARED_SECRET synapse-shared-secret   openssl rand -hex 32
_mas_resolve MAS_SIGNING_KEY_RSA       signing-key-rsa                _gen_rsa_key
_mas_resolve MAS_SIGNING_KEY_EC        signing-key-ec                _gen_ec_key

if ! [[ "$MAS_ENCRYPTION_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
    print_error "mas.encryption_key must be 32 bytes, hex-encoded (64 hex characters)"
    exit 1
fi
export MAS_DB_PASSWORD

# =============================================================================
# 2. mas-config Secret (config.yaml + the secret files it references)
# =============================================================================
# Applied before the DB init Job, which reads db-password from it.
MAS_CONFIG_VARS='${MAS_HOST} ${PG_HOST} ${MAS_DB_USER} ${MAS_DB_PASSWORD} ${MAS_DB_NAME} ${MATRIX_HOST} ${NS_MATRIX} ${MAS_UPSTREAM_PROVIDER_ID} ${AUTH_HOST} ${TENANT_KEYCLOAK_REALM} ${KEYCLOAK_INTERNAL_URL}'

_render_mas_config_secret() {
    kubectl create secret generic mas-config \
        --namespace="$NS_MATRIX" \
        --from-file=config.yaml=<(envsubst "$MAS_CONFIG_VARS" < "$REPO_ROOT/apps/manifests/mas/config.yaml.tpl") \
        --from-file=db-password=<(printf '%s' "$MAS_DB_PASSWORD") \
        --from-file=keycloak-client-secret=<(printf '%s' "$MAS_OIDC_CLIENT_SECRET") \
        --from-file=encryption-key=<(printf '%s' "$MAS_ENCRYPTION_KEY") \
        --from-file=synapse-shared-secret=<(printf '%s' "$MAS_SYNAPSE_SHARED_SECRET") \
        --from-file=signing-key-rsa=<(printf '%s\n' "$MAS_SIGNING_KEY_RSA") \
        --from-file=signing-key-ec=<(printf '%s\n' "$MAS_SIGNING_KEY_EC") \
        --dry-run=client -o yaml
}

print_status "Applying mas-config Secret..."
mt_apply kubectl apply -f <(_render_mas_config_secret)

# =============================================================================
# 3. Database on the shared PostgreSQL VM
# =============================================================================
print_status "Initializing MAS database $MAS_DB_NAME..."
PG_PASSWORD=$(mt_pg_password)
if [ -z "$PG_PASSWORD" ]; then
    print_error "Could not read the postgres-credentials Secret from ${NS_DB:-infra-db}"
    exit 1
fi
kubectl create secret generic postgres-credentials \
    --namespace="$NS_MATRIX" \
    --from-literal=postgres-password="$PG_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if kubectl get job mas-db-init -n "$NS_MATRIX" >/dev/null 2>&1; then
    kubectl delete job mas-db-init -n "$NS_MATRIX" --wait=true --timeout=60s >/dev/null
fi
envsubst '${NS_MATRIX} ${MAS_DB_NAME} ${MAS_DB_USER} ${PG_HOST}' \
    < "$REPO_ROOT/apps/manifests/mas/db-init-job.yaml.tpl" | kubectl create -f -

# Wait for either outcome; a timeout is a failure too (never start MAS on a
# database we could not confirm).
db_init_ok=false
for _ in $(seq 1 60); do
    if [ "$(kubectl get job mas-db-init -n "$NS_MATRIX" -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
        db_init_ok=true
        break
    fi
    if [ "$(kubectl get job mas-db-init -n "$NS_MATRIX" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)" = "True" ]; then
        break
    fi
    sleep 2
done
if [ "$db_init_ok" != "true" ]; then
    print_error "MAS database initialization did not succeed"
    kubectl logs -n "$NS_MATRIX" job/mas-db-init --tail=50 || true
    exit 1
fi
print_success "MAS database ready"

# =============================================================================
# 4. Keycloak client `matrix-mas`
# =============================================================================
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    KEYCLOAK_ADMIN_PASSWORD=$(yq '.keycloak.admin_password // ""' "$TENANT_SECRETS")
fi
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ] || [ "$KEYCLOAK_ADMIN_PASSWORD" = "null" ]; then
    print_error "keycloak.admin_password is required in tenant secrets (to manage the $MAS_KC_CLIENT_ID client)"
    exit 1
fi

print_status "Configuring Keycloak client $MAS_KC_CLIENT_ID in realm $TENANT_KEYCLOAK_REALM..."
LOCAL_PORT=$((RANDOM + 10000))
PF_LOG=$(mktemp)
kubectl -n "${NS_AUTH:-infra-auth}" port-forward svc/keycloak-keycloakx-http "${LOCAL_PORT}:80" >"$PF_LOG" 2>&1 &
PF_PID=$!
KC_RESP=$(mktemp)
# mt_deploy_start owns the EXIT trap (deploy notification); a second trap
# would replace it, so chain: clean up, restore the exit code, then notify.
trap '_mas_rc=$?; kill $PF_PID 2>/dev/null || true; rm -f "$PF_LOG" "$KC_RESP"; (exit $_mas_rc); _mt_deploy_exit_handler' EXIT
KEYCLOAK_URL="http://localhost:${LOCAL_PORT}"
for _ in $(seq 1 30); do
    curl -s -o /dev/null "$KEYCLOAK_URL/realms/master" && break
    sleep 1
done

KC_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" | jq -r '.access_token // empty')
if [ -z "$KC_TOKEN" ]; then
    print_error "Failed to get a Keycloak admin token (port-forward log: $(cat "$PF_LOG"))"
    exit 1
fi

KC_CLIENT_JSON=$(jq -cn \
    --arg client_id "$MAS_KC_CLIENT_ID" \
    --arg secret "$MAS_OIDC_CLIENT_SECRET" \
    --arg redirect "https://${MAS_HOST}/upstream/callback/${MAS_UPSTREAM_PROVIDER_ID}" \
    --arg origin "https://${MAS_HOST}" \
    '{
        clientId: $client_id,
        name: "Matrix Authentication Service",
        enabled: true,
        protocol: "openid-connect",
        publicClient: false,
        clientAuthenticatorType: "client-secret",
        secret: $secret,
        standardFlowEnabled: true,
        implicitFlowEnabled: false,
        directAccessGrantsEnabled: false,
        serviceAccountsEnabled: false,
        # MAS only needs openid/email/profile; do not put realm roles in its tokens.
        fullScopeAllowed: false,
        redirectUris: [$redirect],
        webOrigins: [$origin],
        attributes: { "pkce.code.challenge.method": "S256" }
    }')

KC_CLIENT_UUID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=$MAS_KC_CLIENT_ID" \
    -H "Authorization: Bearer $KC_TOKEN" | jq -r '.[0].id // empty') || {
    print_error "Failed to query Keycloak clients in realm $TENANT_KEYCLOAK_REALM"
    exit 1
}

if [ -n "$KC_CLIENT_UUID" ]; then
    code=$(curl -s -o "$KC_RESP" -w '%{http_code}' -X PUT \
        "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$KC_CLIENT_UUID" \
        -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
        -d "$KC_CLIENT_JSON")
    expected=204
else
    code=$(curl -s -o "$KC_RESP" -w '%{http_code}' -X POST \
        "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
        -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
        -d "$KC_CLIENT_JSON")
    expected=201
fi
if [ "$code" != "$expected" ]; then
    print_error "Keycloak rejected the $MAS_KC_CLIENT_ID client (HTTP $code): $(cat "$KC_RESP")"
    exit 1
fi
kill $PF_PID 2>/dev/null || true
print_success "Keycloak client $MAS_KC_CLIENT_ID configured (redirect https://${MAS_HOST}/upstream/callback/${MAS_UPSTREAM_PROVIDER_ID})"

# =============================================================================
# 5. Service, Deployment, Ingress
# =============================================================================
print_status "Applying MAS Service, Deployment and Ingress..."
mt_apply kubectl apply -f <(envsubst '${NS_MATRIX} ${TENANT_NAME} ${MAS_HOST}' < "$REPO_ROOT/apps/manifests/mas/mas.yaml.tpl")
mt_restart_if_changed deployment/mas -n "$NS_MATRIX"

if ! kubectl -n "$NS_MATRIX" rollout status deployment/mas --timeout=300s; then
    print_error "MAS did not become ready"
    dump_pod_diagnostics "$NS_MATRIX" "app.kubernetes.io/name=mas,app.kubernetes.io/component=server"
    kubectl -n "$NS_MATRIX" logs deployment/mas --tail=80 || true
    exit 1
fi

print_success "Matrix Authentication Service deployed: https://$MAS_HOST (inert until the Synapse cutover, #824)"
