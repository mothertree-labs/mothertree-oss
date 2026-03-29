#!/bin/bash
# Dev-only utility for setting up local Keycloak and admin-portal for development.
#
# Usage:
#   ./scripts/localhost/setup-admin-portal.sh [--restart-keycloak|-r]
#   ./scripts/localhost/setup-admin-portal.sh [--help|-h]
#
# Options:
#   --restart-keycloak, -r  Restart Keycloak and recreate realm/client
#   --help, -h             Show this help message
#
# Without options: start admin-portal (starts Keycloak if not running)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/localhost/lib-keycloak.sh"

RESTART_KEYCLOAK=false

mt_usage() {
    cat <<'EOF'
Usage: setup-admin-portal.sh [options]

Options:
  --restart-keycloak, -r  Restart Keycloak and recreate realm/client
  --help, -h             Show this help message

Without options: start admin-portal (starts Keycloak if not running)
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

mt_keycloak_init "admin-portal" "admin-portal" '["http://localhost:3001/", "http://localhost:3001/*", "http://localhost:3001/auth/callback"]'
mt_keycloak_set_port "3001"

ENV_FILE="$REPO_ROOT/apps/admin-portal/.env"
mt_keycloak_set_env_file "$ENV_FILE"

if [ ! -f "$ENV_FILE" ]; then
    print_status "No .env file found, creating from .env.example..."
    cp "$REPO_ROOT/apps/admin-portal/.env.example" "$ENV_FILE"
    print_success "Created $ENV_FILE from .env.example"
fi

if ! grep -q "^SESSION_SECRET=" "$ENV_FILE" || grep -q "^SESSION_SECRET=$" "$ENV_FILE" 2>/dev/null; then
    SESSION_SECRET=$(openssl rand -base64 32)
    echo "SESSION_SECRET=$SESSION_SECRET" >> "$ENV_FILE"
    print_success "Added SESSION_SECRET to .env"
fi

if ! grep -q "^BASE_URL=" "$ENV_FILE" || grep -q "^BASE_URL=$" "$ENV_FILE" 2>/dev/null; then
    echo "BASE_URL=http://localhost:3001" >> "$ENV_FILE"
    print_success "Added BASE_URL to .env"
fi

ADMIN_PID=""
KEYCLOAK_STARTED=false
cleanup() {
    print_status "Cleaning up..."
    if [ -n "$ADMIN_PID" ] && kill -0 "$ADMIN_PID" 2>/dev/null; then
        kill "$ADMIN_PID" 2>/dev/null || true
        print_status "Stopped admin-portal (PID: $ADMIN_PID)"
    fi
    if [ "$KEYCLOAK_STARTED" = true ]; then
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        print_status "Stopped Keycloak container"
    fi
    print_status "Cleanup complete"
}
trap cleanup EXIT INT TERM

if [[ "$RESTART_KEYCLOAK" == "true" ]]; then
    mt_keycloak_restart
else
    mt_keycloak_start_if_needed
fi

print_status "Installing dependencies..."
cd "$REPO_ROOT/apps/admin-portal"
npm install

print_status "Building Tailwind CSS..."
npm run build:css

print_status "Starting admin-portal..."

pkill -f "node server.js" 2>/dev/null || true
sleep 1

cd "$REPO_ROOT/apps/admin-portal"
nohup env $(grep -v '^#' .env | xargs) NODE_ENV=development PORT=3001 node server.js > /tmp/admin-portal.log 2>&1 &
ADMIN_PID=$!

sleep 2

if ! pgrep -f "node server.js" > /dev/null; then
    print_error "Failed to start admin-portal"
    cat /tmp/admin-portal.log
    exit 1
fi

print_success "Admin portal started"
echo ""
echo "=========================================="
echo "Keycloak: http://localhost:8080"
echo "  Admin: $ADMIN_USER / $ADMIN_PASSWORD"
echo "  Test User: $TEST_USER / $TEST_PASSWORD"
echo "Admin Portal: http://localhost:3001"
echo "=========================================="
echo ""
echo "Admin portal is running in the background."
echo "Press Ctrl+C to stop."

while pgrep -f "node server.js" > /dev/null 2>&1; do
    sleep 1
done
