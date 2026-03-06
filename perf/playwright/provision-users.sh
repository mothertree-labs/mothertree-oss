#!/bin/bash
# Provision or delete load test users (load-01 through load-20).
#
# Usage:
#   ./perf/playwright/provision-users.sh -e dev -t <tenant> create
#   ./perf/playwright/provision-users.sh -e dev -t <tenant> delete
#   ./perf/playwright/provision-users.sh -e dev -t <tenant> create --count 10
#
# Wraps scripts/dev-test-users.sh — requires kubectl port-forward to Keycloak.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV_USERS_SCRIPT="${REPO_ROOT}/scripts/dev-test-users.sh"

PASSWORD="load-testpass"
COUNT=20

# ── Parse args ─────────────────────────────────────────────────────────

ACTION=""
MT_ARGS=()
_NEXT_FOR=""

for arg in "$@"; do
    if [ "$_NEXT_FOR" = "mt" ]; then
        MT_ARGS+=("$arg")
        _NEXT_FOR=""
        continue
    elif [ "$_NEXT_FOR" = "count" ]; then
        COUNT="$arg"
        _NEXT_FOR=""
        continue
    fi
    case "$arg" in
        -e|-t)
            MT_ARGS+=("$arg")
            _NEXT_FOR="mt"
            ;;
        --count)
            _NEXT_FOR="count"
            ;;
        --count=*)
            COUNT="${arg#*=}"
            ;;
        create|delete)
            ACTION="$arg"
            ;;
        *)
            MT_ARGS+=("$arg")
            ;;
    esac
done
unset _NEXT_FOR

if [ -z "$ACTION" ]; then
    echo "Usage: $0 -e dev -t <tenant> <create|delete> [--count N]"
    echo ""
    echo "  create    Create load-01 through load-N users (default: 20)"
    echo "  delete    Delete load-01 through load-N users"
    echo "  --count N Number of users (default: 20)"
    exit 1
fi

# ── Execute ────────────────────────────────────────────────────────────

for i in $(seq 1 "$COUNT"); do
    padded=$(printf "%02d" "$i")
    username="load-${padded}"

    case "$ACTION" in
        create)
            echo "=== Creating user $username ($i/$COUNT) ==="
            "$DEV_USERS_SCRIPT" "${MT_ARGS[@]}" create "$username" --password "$PASSWORD" || true
            echo ""
            ;;
        delete)
            echo "=== Deleting user $username ($i/$COUNT) ==="
            "$DEV_USERS_SCRIPT" "${MT_ARGS[@]}" delete "$username" || true
            echo ""
            ;;
    esac
done

echo "Done. $ACTION $COUNT load test users (load-01 through load-$(printf "%02d" "$COUNT"))."
echo "Password for all users: $PASSWORD"
