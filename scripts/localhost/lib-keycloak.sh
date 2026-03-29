#!/bin/bash

if [ "${_MT_KEYCLOAK_LIB_LOADED:-}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_MT_KEYCLOAK_LIB_LOADED=1

mt_keycloak_init() {
    local portal_name="$1"
    local client_id="$2"
    local redirect_uris_json="$3"

    MT_KEYCLOAK_PORTAL_NAME="$portal_name"
    MT_KEYCLOAK_CLIENT_ID="$client_id"
    MT_KEYCLOAK_REDIRECT_URIS_JSON="$redirect_uris_json"

    MT_KEYCLOAK_VERSION=$(grep -E "^  tag:" "$REPO_ROOT/apps/values/keycloak-codecentric.yaml" | awk '{print $2}' | tr -d '"')
    if [ -z "$MT_KEYCLOAK_VERSION" ]; then
        print_error "Could not determine Keycloak version from apps/values/keycloak-codecentric.yaml"
        exit 1
    fi
    print_status "Using Keycloak version: $MT_KEYCLOAK_VERSION"

    CONTAINER_NAME="keycloak-dev"
    KEYCLOAK_URL="http://localhost:8080"
    ADMIN_USER="admin"
    ADMIN_PASSWORD="admin"
    REALM="dev"
    TEST_USER="testuser"
    TEST_PASSWORD="testpassword"

    ENV_FILE=""
    MT_KEYCLOAK_PORT=""
}

mt_keycloak_set_env_file() {
    ENV_FILE="$1"
}

mt_keycloak_set_port() {
    MT_KEYCLOAK_PORT="$1"
}

start_keycloak_container() {
    KEYCLOAK_STARTED=true
    docker run -d --name "$CONTAINER_NAME" -p 8080:8080 -p 9000:9000 \
        -e KEYCLOAK_ADMIN="$ADMIN_USER" \
        -e KEYCLOAK_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        -e KC_HEALTH_ENABLED=true \
        -e KC_BOOTSTRAP_ADMIN_USERNAME="$ADMIN_USER" \
        -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        "quay.io/keycloak/keycloak:${MT_KEYCLOAK_VERSION}" start-dev
}

wait_for_keycloak() {
    print_status "Waiting for Keycloak to be ready..."
    MAX_WAIT=150
    COUNT=0
    until curl -sf "http://localhost:9000/health/ready" 2>/dev/null; do
        if [ $COUNT -ge $MAX_WAIT ]; then
            print_error "Timed out waiting for Keycloak after 5 minutes"
            exit 1
        fi
        print_status "Waiting for Keycloak... ($((COUNT * 2))s)"
        sleep 2
        COUNT=$((COUNT + 1))
    done
    print_success "Keycloak is ready at $KEYCLOAK_URL"
}

get_admin_token() {
    curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=$ADMIN_USER" \
        -d "password=$ADMIN_PASSWORD" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r '.access_token'
}

setup_keycloak_realm() {
    local admin_token="$1"

    print_status "Creating realm '$REALM'..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"realm\": \"$REALM\",
            \"enabled\": true,
            \"displayName\": \"Development\"
        }"

    print_status "Creating test user '$TEST_USER'..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"$TEST_USER\",
            \"enabled\": true,
            \"emailVerified\": true,
            \"email\": \"$TEST_USER@localhost\",
            \"firstName\": \"Test\",
            \"lastName\": \"User\",
            \"credentials\": [{\"type\": \"password\", \"value\": \"$TEST_PASSWORD\", \"temporary\": false}]
        }"

    print_status "Creating tenant-admin role..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/roles" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d '{"name": "tenant-admin", "description": "Tenant administrator role"}' || true

    print_status "Adding tenant-admin role to test user..."
    USER_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$TEST_USER" \
        -H "Authorization: Bearer $admin_token" | jq -r '.[0].id')
    ROLE=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/roles/tenant-admin" \
        -H "Authorization: Bearer $admin_token")
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/role-mappings/realm" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "[$ROLE]"

    _mt_keycloak_create_client "$admin_token"

    _mt_keycloak_update_env "$admin_token"
}

_mt_keycloak_create_client() {
    local admin_token="$1"

    print_status "Creating client '$MT_KEYCLOAK_CLIENT_ID'..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"clientId\": \"$MT_KEYCLOAK_CLIENT_ID\",
            \"enabled\": true,
            \"protocol\": \"openid-connect\",
            \"publicClient\": false,
            \"bearerOnly\": false,
            \"standardFlowEnabled\": true,
            \"implicitFlowEnabled\": false,
            \"directAccessGrantsEnabled\": true,
            \"serviceAccountsEnabled\": false,
            \"authorizationServicesEnabled\": false,
            \"redirectUris\": $MT_KEYCLOAK_REDIRECT_URIS_JSON,
            \"webOrigins\": [\"http://localhost:$MT_KEYCLOAK_PORT\", \"*\"]
        }"

    print_status "Getting client UUID..."
    CLIENT_UUID=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$MT_KEYCLOAK_CLIENT_ID" \
        -H "Authorization: Bearer $admin_token" | jq -r '.[0].id')

    if [ "$MT_KEYCLOAK_PORTAL_NAME" = "admin-portal" ]; then
        print_status "Adding realm roles mapper to client..."
        curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" \
            -H "Authorization: Bearer $admin_token" \
            -H "Content-Type: application/json" \
            -d '{
                "name": "realm roles",
                "protocol": "openid-connect",
                "protocolMapper": "oidc-usermodel-realm-role-mapper",
                "config": {
                    "multivalued": "true",
                    "userinfo.token.claim": "true",
                    "id.token.claim": "true",
                    "access.token.claim": "true",
                    "claim.name": "realm_access.roles",
                    "jsonType.label": "String"
                }
            }'

        print_status "Updating roles scope to include in token..."
        ROLES_SCOPE_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/client-scopes?search=roles" \
            -H "Authorization: Bearer $admin_token" | jq -r '.[0].id')
        if [ -n "$ROLES_SCOPE_ID" ] && [ "$ROLES_SCOPE_ID" != "null" ]; then
            curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/client-scopes/$ROLES_SCOPE_ID" \
                -H "Authorization: Bearer $admin_token" \
                -H "Content-Type: application/json" \
                -d '{
                    "name": "roles",
                    "description": "OpenID Connect scope for add user roles to the access token",
                    "protocol": "openid-connect",
                    "attributes": {
                        "include.in.token.scope": "true",
                        "consent.screen.text": "${rolesScopeConsentText}",
                        "display.on.consent.screen": "true"
                    }
                }' || true
        fi
    fi

    print_status "Resetting client secret..."
    NEW_SECRET=$(curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d '{}' | jq -r '.value')

    print_success "Keycloak setup complete: realm=$REALM, client=$MT_KEYCLOAK_CLIENT_ID"
}

_mt_keycloak_update_env() {
    local admin_token="$1"

    print_status "Updating $MT_KEYCLOAK_PORTAL_NAME .env with new secret..."
    mt_set_env KEYCLOAK_CLIENT_SECRET "$NEW_SECRET" "$ENV_FILE"
    mt_set_env KEYCLOAK_ISSUER "$KEYCLOAK_URL/realms/$REALM" "$ENV_FILE"
    mt_set_env KEYCLOAK_URL "$KEYCLOAK_URL" "$ENV_FILE"
    mt_set_env KEYCLOAK_REALM "$REALM" "$ENV_FILE"
    mt_set_env NEXTAUTH_URL "http://localhost:$MT_KEYCLOAK_PORT" "$ENV_FILE"
    mt_set_env TENANT_DOMAIN "localhost" "$ENV_FILE"
    mt_set_env EMAIL_DOMAIN "localhost" "$ENV_FILE"
    mt_set_env SMTP_FROM "noreply@localhost" "$ENV_FILE"
}

ensure_client_exists() {
    local admin_token="$1"

    CLIENT_UUID=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$MT_KEYCLOAK_CLIENT_ID" \
        -H "Authorization: Bearer $admin_token" | jq -r '.[0].id')

    if [ "$CLIENT_UUID" = "null" ] || [ -z "$CLIENT_UUID" ]; then
        print_status "Client '$MT_KEYCLOAK_CLIENT_ID' not found, creating..."
        setup_keycloak_realm "$admin_token"
    else
        CURRENT_SECRET=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret" \
            -H "Authorization: Bearer $admin_token" | jq -r '.value')
        mt_set_env KEYCLOAK_CLIENT_SECRET "$CURRENT_SECRET" "$ENV_FILE"
        mt_set_env KEYCLOAK_ISSUER "$KEYCLOAK_URL/realms/$REALM" "$ENV_FILE"
        mt_set_env KEYCLOAK_URL "$KEYCLOAK_URL" "$ENV_FILE"
        mt_set_env KEYCLOAK_REALM "$REALM" "$ENV_FILE"
        mt_set_env NEXTAUTH_URL "http://localhost:$MT_KEYCLOAK_PORT" "$ENV_FILE"
        mt_set_env TENANT_DOMAIN "localhost" "$ENV_FILE"
        mt_set_env EMAIL_DOMAIN "localhost" "$ENV_FILE"
        mt_set_env SMTP_FROM "noreply@localhost" "$ENV_FILE"
        print_success "Updated .env with local Keycloak settings"
    fi
}

mt_keycloak_restart() {
    print_status "================================================"
    print_status "=== RESTARTING KEYCLOAK (--restart-keycloak) ==="
    print_status "================================================"

    print_status "Stopping and removing Keycloak container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    print_status "Removing any associated volumes..."
    docker volume rm "$(docker volume ls -q -f name=keycloak 2>/dev/null | tr '\n' ' ')" 2>/dev/null || true

    print_status "Starting fresh Keycloak container..."
    start_keycloak_container

    wait_for_keycloak

    ADMIN_TOKEN=$(get_admin_token)
    setup_keycloak_realm "$ADMIN_TOKEN"
}

mt_keycloak_start_if_needed() {
    if docker ps -q -f name="$CONTAINER_NAME" | grep -q .; then
        print_status "Keycloak is already running"
        ADMIN_TOKEN=$(get_admin_token)
        ensure_client_exists "$ADMIN_TOKEN"
    elif docker ps -aq -f name="$CONTAINER_NAME" | grep -q .; then
        print_status "Starting existing Keycloak container..."
        KEYCLOAK_STARTED=true
        docker start "$CONTAINER_NAME"
        wait_for_keycloak
        print_status "Keycloak started"
        ADMIN_TOKEN=$(get_admin_token)
        ensure_client_exists "$ADMIN_TOKEN"
    else
        print_status "================================================"
        print_status "=== STARTING KEYCLOAK (not running) ==="
        print_status "================================================"

        print_status "Starting Keycloak container..."
        start_keycloak_container

        wait_for_keycloak

        ADMIN_TOKEN=$(get_admin_token)

        if ! curl -sf "$KEYCLOAK_URL/admin/realms/$REALM" -H "Authorization: Bearer $ADMIN_TOKEN" >/dev/null 2>&1; then
            setup_keycloak_realm "$ADMIN_TOKEN"
        else
            print_status "Realm '$REALM' already exists, ensuring client..."
            ensure_client_exists "$ADMIN_TOKEN"
        fi
    fi
}
