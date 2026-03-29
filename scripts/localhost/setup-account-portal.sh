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
# Without options: start account-portal (starts Keycloak if not running)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/localhost/lib-keycloak.sh"

RESTART_KEYCLOAK=false

mt_usage() {
    cat <<'EOF'
Usage: setup-dev-keycloak.sh [options]

Options:
  --restart-keycloak, -r  Restart Keycloak and recreate realm/client
  --help, -h             Show this help message

Without options: start account-portal (starts Keycloak if not running)
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

mt_keycloak_init "account-portal" "account-portal" '["http://localhost:3000/", "http://localhost:3000/*", "http://localhost:3000/auth/callback", "http://localhost:3000/registration-callback"]'
mt_keycloak_set_port "3000"

ENV_FILE="$REPO_ROOT/apps/account-portal/.env"
mt_keycloak_set_env_file "$ENV_FILE"

if [ ! -f "$ENV_FILE" ]; then
    print_status "No .env file found, creating from .env.example..."
    cp "$REPO_ROOT/apps/account-portal/.env.example" "$ENV_FILE"
    print_success "Created $ENV_FILE from .env.example"
fi

ACCOUNT_PID=""
KEYCLOAK_STARTED=false
cleanup() {
    print_status "Cleaning up..."
    if [ -n "$ACCOUNT_PID" ] && kill -0 "$ACCOUNT_PID" 2>/dev/null; then
        kill "$ACCOUNT_PID" 2>/dev/null || true
        print_status "Stopped account-portal (PID: $ACCOUNT_PID)"
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

if ! pgrep -f "node server.js" > /dev/null; then
    print_error "Failed to start account-portal"
    cat /tmp/account-portal.log
    exit 1
fi

print_success "Account portal started"
echo ""
echo "=========================================="
echo "Keycloak: http://localhost:8080"
echo "  Admin: $ADMIN_USER / $ADMIN_PASSWORD"
echo "  Test User: $TEST_USER / $TEST_PASSWORD"
echo "Account Portal: http://localhost:3000"
echo "=========================================="
echo ""
echo "Account portal is running in the background."
echo "Press Ctrl+C to stop."

while pgrep -f "node server.js" > /dev/null 2>&1; do
    sleep 1
done
