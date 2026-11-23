#!/bin/bash

# Deploy the Matrix Authentication Service (MAS) for a tenant.
#
# MAS provides native OAuth 2.0 login for Matrix clients (Element X requires it,
# and QR-code login needs it). Keycloak stays the identity provider: MAS uses
# the tenant realm as its only upstream and has local passwords disabled.
#
# Synapse delegates authentication to MAS (#824): deploy-matrix.sh runs this
# BEFORE syncing the Synapse chart, which reads the shared secret from the
# mas-config Secret written here.
#
# Steps:
#   1. Resolve MAS secrets (tenant secrets YAML → live K8s Secret → generate)
#   2. Apply the `mas-config` Secret (config.yaml + secret files)
#   3. Create the MAS database + role on the shared PostgreSQL VM (via PgBouncer)
#   4. Create/update the `matrix-mas` confidential client in the tenant realm
#   5. One-time Synapse → MAS migration (syn2mas) when Synapse has users
#   6. Apply the Service, Deployment, MAS Ingress and the compat-layer Ingress
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
: "${SYNAPSE_DB_NAME:?SYNAPSE_DB_NAME not set (database.synapse_db in tenant config)}"
: "${SYNAPSE_DB_USER:?SYNAPSE_DB_USER not set}"

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
envsubst '${NS_MATRIX} ${MAS_DB_NAME} ${MAS_DB_USER} ${PG_HOST} ${SYNAPSE_DB_NAME}' \
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
probe=$(kubectl logs -n "$NS_MATRIX" job/mas-db-init 2>/dev/null | grep -E '^MAS_PROBE ' | tail -1 || true)
if ! [[ "$probe" =~ ^MAS_PROBE\ synapse_users=([0-9]+)\ mas_rows=([0-9]+)$ ]]; then
    print_error "MAS db-init did not report the migration probe (got: '${probe}')"
    kubectl logs -n "$NS_MATRIX" job/mas-db-init --tail=30 || true
    exit 1
fi
MAS_PROBE_SYNAPSE_USERS="${BASH_REMATCH[1]}"
MAS_PROBE_MAS_ROWS="${BASH_REMATCH[2]}"
print_success "MAS database ready (Synapse users: $MAS_PROBE_SYNAPSE_USERS, MAS user/session rows: $MAS_PROBE_MAS_ROWS)"

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
# The temporary syn2mas Secret (Synapse DB password) is removed on every exit.
trap '_mas_rc=$?; kill $PF_PID 2>/dev/null || true; rm -f "$PF_LOG" "$KC_RESP"; [ -n "${SYN2MAS_SECRET_CREATED:-}" ] && kubectl delete secret mas-syn2mas-synapse -n "$NS_MATRIX" --ignore-not-found >/dev/null 2>&1; (exit $_mas_rc); _mt_deploy_exit_handler' EXIT
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
# 5. One-time Synapse → MAS migration (syn2mas)
# =============================================================================
# Synapse delegates auth to MAS from this deploy on, so existing Synapse users,
# devices, access tokens and Keycloak links must be in MAS before Synapse
# restarts delegated. A `mas-migration` ConfigMap records that this happened.
#
#   marker present                           → nothing to do
#   Synapse has no users (new tenant)        → nothing to migrate; set marker
#   Synapse has users, MAS DB empty          → migrate (below); set marker
#   Synapse has users, MAS DB not empty      → refuse: MAS was used before the
#                                              migration; recreate its DB
#
# Prod needs MAS_MIGRATE_CONFIRM=yes (it means a short Matrix outage and should
# follow a fresh Synapse DB backup — see the #824 runbook).

_run_syn2mas() {
    # _run_syn2mas <job-name> <allowed exit codes, space separated> <args...>
    local job="$1" allowed="$2" rc="" args=""
    shift 2
    local a
    for a in "$@"; do args+="${args:+, }\"$a\""; done
    kubectl delete job "$job" -n "$NS_MATRIX" --ignore-not-found --wait=true >/dev/null
    SYN2MAS_JOB_NAME="$job" SYN2MAS_ARGS="$args" \
        envsubst '${NS_MATRIX} ${SYN2MAS_JOB_NAME} ${SYN2MAS_ARGS}' \
        < "$REPO_ROOT/apps/manifests/mas/syn2mas-job.yaml.tpl" | kubectl create -f - >/dev/null
    print_status "syn2mas $*: running (job $job)..."
    for _ in $(seq 1 300); do
        rc=$(kubectl get pods -n "$NS_MATRIX" -l "job-name=$job" \
            -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
        [ -n "$rc" ] && break
        sleep 2
    done
    kubectl logs -n "$NS_MATRIX" "job/$job" --tail=200 2>&1 | sed 's/^/  [syn2mas] /' || true
    if [ -z "$rc" ]; then
        print_error "syn2mas $* did not finish within 10 minutes"
        exit 1
    fi
    if [[ " $allowed " != *" $rc "* ]]; then
        print_error "syn2mas $* failed (exit $rc)"
        exit 1
    fi
    print_success "syn2mas $*: ok (exit $rc)"
}

_mas_mark_migrated() {
    kubectl create configmap mas-migration -n "$NS_MATRIX" \
        --from-literal=status=done \
        --from-literal=reason="$1" \
        --from-literal=at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

if [ "$(kubectl get configmap mas-migration -n "$NS_MATRIX" -o jsonpath='{.data.status}' 2>/dev/null || true)" = "done" ]; then
    print_status "Synapse → MAS migration already done (configmap mas-migration)"
else
    # Counts come from the db-init Job above (Job logs are reliable; an empty
    # answer from `kubectl run --rm -i` is not a zero).
    SYNAPSE_USERS="${MAS_PROBE_SYNAPSE_USERS:?db-init probe missing}"
    if [ "$SYNAPSE_USERS" = "0" ]; then
        print_status "Synapse has no users yet — nothing to migrate to MAS"
        _mas_mark_migrated "no synapse users"
    else
        MAS_ROWS="${MAS_PROBE_MAS_ROWS:?db-init probe missing}"
        if [ "$MAS_ROWS" != "0" ]; then
            print_error "Synapse has $SYNAPSE_USERS users to migrate, but the MAS database $MAS_DB_NAME is not empty ($MAS_ROWS user/session rows)."
            print_error "MAS was used before the migration. Drop and recreate $MAS_DB_NAME, then deploy again (#824 runbook)."
            exit 1
        fi
        if [ "$MT_ENV" = "prod" ] && [ "${MAS_MIGRATE_CONFIRM:-}" != "yes" ]; then
            print_error "Synapse → MAS migration needed on prod ($SYNAPSE_USERS Synapse users). It stops Matrix for a few minutes."
            print_error "Back up $SYNAPSE_DB_NAME, then re-run with MAS_MIGRATE_CONFIRM=yes (#824 runbook)."
            exit 1
        fi
        : "${SYNAPSE_DB_PASSWORD:?SYNAPSE_DB_PASSWORD not set (matrix.synapse_password in tenant secrets)}"
        export SYNAPSE_DB_NAME SYNAPSE_DB_USER SYNAPSE_DB_PASSWORD
        print_status "Migrating $SYNAPSE_USERS Synapse users to MAS (syn2mas)..."
        if [ -n "$(kubectl get pods -n "$NS_MATRIX" -l app.kubernetes.io/component=syn2mas \
                --field-selector=status.phase=Running -o name 2>/dev/null)" ]; then
            print_error "A syn2mas Job from an earlier run is still running in $NS_MATRIX; wait for it (kubectl get jobs -n $NS_MATRIX)"
            exit 1
        fi
        # Values go in through yq strenv(), so no password character can break the YAML.
        SYN2MAS_SECRET_CREATED=1
        kubectl create secret generic mas-syn2mas-synapse -n "$NS_MATRIX" \
            --from-file=homeserver.yaml=<(yq '
                .server_name = strenv(MATRIX_HOST) |
                .database.args.user = strenv(SYNAPSE_DB_USER) |
                .database.args.password = strenv(SYNAPSE_DB_PASSWORD) |
                .database.args.dbname = strenv(SYNAPSE_DB_NAME) |
                .database.args.host = strenv(PG_HOST) |
                .oidc_providers[0].issuer = "https://" + strenv(AUTH_HOST) + "/realms/" + strenv(TENANT_KEYCLOAK_REALM)
              ' "$REPO_ROOT/apps/manifests/mas/syn2mas-synapse.yaml.tpl") \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null

        # MAS must not run during the dry run or the migration.
        if kubectl get deployment mas -n "$NS_MATRIX" >/dev/null 2>&1; then
            kubectl scale deployment mas -n "$NS_MATRIX" --replicas=0 >/dev/null
            kubectl wait pod -n "$NS_MATRIX" -l app.kubernetes.io/name=mas,app.kubernetes.io/component=server \
                --for=delete --timeout=120s >/dev/null 2>&1 || true
        fi

        # Exit 11 = warnings only (e.g. non-email threepids). Synapse keeps running.
        _run_syn2mas mas-syn2mas-check "0 11" check
        _run_syn2mas mas-syn2mas-dry-run "0" migrate --dry-run

        # The real run locks Synapse's tables: Synapse must be stopped. It comes
        # back delegated when deploy-matrix.sh syncs the chart right after this.
        # If anything below fails, Synapse is scaled back up on its current,
        # NOT yet delegated config (the chart sync has not run), so Matrix
        # keeps working with the old Keycloak SSO.
        SYNAPSE_REPLICAS=$(kubectl get deployment matrix-synapse -n "$NS_MATRIX" -o jsonpath='{.spec.replicas}')
        _restore_synapse() {
            print_warning "Scaling Synapse back to ${SYNAPSE_REPLICAS} replica(s) on its previous (non-delegated) config"
            kubectl scale deployment matrix-synapse -n "$NS_MATRIX" --replicas="${SYNAPSE_REPLICAS:-1}" >/dev/null || true
        }
        print_status "Stopping Synapse for the migration..."
        kubectl scale deployment matrix-synapse -n "$NS_MATRIX" --replicas=0 >/dev/null
        if ! kubectl wait pod -n "$NS_MATRIX" \
                -l app.kubernetes.io/name=matrix-synapse,app.kubernetes.io/component=synapse \
                --for=delete --timeout=180s >/dev/null 2>&1; then
            print_error "Synapse pods did not stop; not migrating"
            _restore_synapse
            exit 1
        fi
        # Subshell: _run_syn2mas exits on failure, and Synapse must come back.
        if ! ( _run_syn2mas mas-syn2mas-migrate "0" migrate ); then
            _restore_synapse
            print_error "syn2mas migrate failed. Synapse is back on its old config (Keycloak SSO), MAS holds partial data."
            print_error "To retry: drop and recreate the $MAS_DB_NAME database (nothing else is lost), then deploy again."
            exit 1
        fi

        _mas_mark_migrated "syn2mas: ${SYNAPSE_USERS} users"
        print_success "Synapse → MAS migration complete; Synapse stays stopped until the chart sync"
    fi
fi

# =============================================================================
# 6. Service, Deployment, Ingresses (MAS host + compat routes on the homeserver)
# =============================================================================
print_status "Applying MAS Service, Deployment and Ingresses..."
mt_apply kubectl apply -f <(envsubst '${NS_MATRIX} ${TENANT_NAME} ${MAS_HOST} ${MATRIX_HOST}' < "$REPO_ROOT/apps/manifests/mas/mas.yaml.tpl")
mt_restart_if_changed deployment/mas -n "$NS_MATRIX"

if ! kubectl -n "$NS_MATRIX" rollout status deployment/mas --timeout=300s; then
    print_error "MAS did not become ready"
    dump_pod_diagnostics "$NS_MATRIX" "app.kubernetes.io/name=mas,app.kubernetes.io/component=server"
    kubectl -n "$NS_MATRIX" logs deployment/mas --tail=80 || true
    exit 1
fi

print_success "Matrix Authentication Service deployed: https://$MAS_HOST"
