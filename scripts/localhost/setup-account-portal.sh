#!/bin/bash
# Dev-only utility for setting up local Keycloak and account-portal for development.
#
# Usage:
#   ./scripts/localhost/setup-account-portal.sh [--restart-keycloak|-r]
#   ./scripts/localhost/setup-account-portal.sh [--help|-h]
#
# Options:
#   --restart-keycloak, -r  Restart Keycloak and recreate realm/client
#   --help, -h             Show this help message
#
# Without options: just start the account-portal (assumes Keycloak is running)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "${REPO_ROOT}/scripts/lib/common.sh"

CONTAINER_NAME="keycloak-dev"
KEYCLOAK_URL="http://localhost:8080"
ADMIN_USER="admin"
ADMIN_PASSWORD="admin"
REALM="dev"
CLIENT_ID="account-portal"
TEST_USER="testuser"
TEST_PASSWORD="testpassword"

RESTART_KEYCLOAK=false

mt_usage() {
    cat <<'EOF'
Usage: setup-dev-keycloak.sh [options]

Options:
  --restart-keycloak, -r  Restart Keycloak and recreate realm/client
  --help, -h             Show this help message

Without options: just start the account-portal (assumes Keycloak is running)
EOF
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --restart-keycloak|-r)
            RESTART_KEYCLOAK=true
            ;;
        --help|-h)
            mt_usage
            ;;
        *)
            print_warning "Unknown argument: $arg"
            mt_usage
            ;;
    esac
done

if [[ "$RESTART_KEYCLOAK" == "true" ]]; then
    print_status "=========================================="
    print_status "=== RESTARTING KEYCLOAK (--restart-keycloak) ==="
    print_status "=========================================="

    print_status "Stopping and removing Keycloak container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    print_status "Removing any associated volumes..."
    docker volume rm "$(docker volume ls -q -f name=keycloak 2>/dev/null | tr '\n' ' ')" 2>/dev/null || true

    print_status "Starting fresh Keycloak container..."
    docker run -d --name "$CONTAINER_NAME" -p 8080:8080 -p 9000:9000 \
        -e KEYCLOAK_ADMIN="$ADMIN_USER" \
        -e KEYCLOAK_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        -e KC_HEALTH_ENABLED=true \
        -e KC_BOOTSTRAP_ADMIN_USERNAME="$ADMIN_USER" \
        -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        quay.io/keycloak/keycloak:26.5.1 start-dev

    print_status "Waiting for Keycloak to be ready..."
    until curl -sf "http://localhost:9000/health/ready" 2>/dev/null; do
        print_status "Waiting for Keycloak..."
        sleep 2
    done
    print_success "Keycloak is ready at $KEYCLOAK_URL"

    print_status "Getting admin token..."
    ADMIN_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=$ADMIN_USER" \
        -d "password=$ADMIN_PASSWORD" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r '.access_token')

    print_status "Creating realm '$REALM'..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"realm\": \"$REALM\",
            \"enabled\": true,
            \"displayName\": \"Development\"
        }"

    print_status "Creating test user '$TEST_USER'..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
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

    print_status "Creating client '$CLIENT_ID'..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"clientId\": \"$CLIENT_ID\",
            \"enabled\": true,
            \"protocol\": \"openid-connect\",
            \"publicClient\": false,
            \"bearerOnly\": false,
            \"standardFlowEnabled\": true,
            \"implicitFlowEnabled\": false,
            \"directAccessGrantsEnabled\": true,
            \"serviceAccountsEnabled\": false,
            \"authorizationServicesEnabled\": false,
            \"redirectUris\": [\"http://localhost:3000/\", \"http://localhost:3000/*\", \"http://localhost:3000/auth/callback\", \"http://localhost:3000/registration-callback\"],
            \"webOrigins\": [\"http://localhost:3000\", \"*\"]
        }"

    print_status "Getting client UUID..."
    CLIENT_UUID=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
        -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

    print_status "Resetting client secret..."
    NEW_SECRET=$(curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' | jq -r '.value')

    print_success "Keycloak setup complete: realm=$REALM, client=$CLIENT_ID"

    print_status "Updating account-portal .env with new secret..."
    sed -i "s/KEYCLOAK_CLIENT_SECRET=.*/KEYCLOAK_CLIENT_SECRET=$NEW_SECRET/" "$REPO_ROOT/apps/account-portal/.env"
fi

print_status "Building Tailwind CSS..."
cd "$REPO_ROOT/apps/account-portal"
npm run build:css

print_status "Starting account-portal..."

pkill -f "node server.js" 2>/dev/null || true
sleep 1

cd "$REPO_ROOT/apps/account-portal"
nohup env $(grep -v '^#' .env | xargs) NODE_ENV=development node server.js > /tmp/account-portal.log 2>&1 &
ACCOUNT_PID=$!

sleep 2
print_success "Account portal started (PID: $ACCOUNT_PID)"
echo ""
echo "=========================================="
echo "Keycloak: http://localhost:8080"
echo "  Admin: $ADMIN_USER / $ADMIN_PASSWORD"
echo "  Test User: $TEST_USER / $TEST_PASSWORD"
echo "Account Portal: http://localhost:3000"
echo "=========================================="
echo ""
echo "To stop:"
echo "  kill $ACCOUNT_PID"
echo "  docker rm -f $CONTAINER_NAME"
