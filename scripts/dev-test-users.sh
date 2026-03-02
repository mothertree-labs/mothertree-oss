#!/bin/bash
# Dev-only utility for managing test users with password authentication in Keycloak.
#
# Usage:
#   ./scripts/dev-test-users.sh -e dev -t <tenant> create <username> [--password <pw>] [--admin]
#   ./scripts/dev-test-users.sh -e dev -t <tenant> list
#   ./scripts/dev-test-users.sh -e dev -t <tenant> delete <username>
#   ./scripts/dev-test-users.sh -e dev -t <tenant> reset-password <username> [--password <pw>]
#
# SAFETY: This script will ONLY run when MT_ENV=dev. It exits immediately otherwise.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  cat <<'EOF'
Usage: dev-test-users.sh -e dev -t <tenant> <command> [options]

Commands:
  create <username> [--password <pw>] [--admin]   Create a test user with password
  list                                             List users in the dev realm
  delete <username>                                Delete a test user
  reset-password <username> [--password <pw>]      Reset a user's password

Options:
  -e <env>        Environment (must be 'dev')
  -t <tenant>     Tenant name
  --password <pw> Password to set (default: testpass123)
  --admin         Also assign tenant-admin role (create only)

This script is for dev/testing only and will refuse to run in non-dev environments.
EOF
  exit 1
}

# ============================================================================
# Pre-filter args: extract subcommand + username before mt_parse_args
# mt_parse_args treats bare positional args as env/tenant, so we need to
# separate our subcommand/username from the flags it understands.
# ============================================================================
COMMAND=""
USERNAME=""
PASSWORD="testpass123"
ADMIN_FLAG=false
MT_ARGS=()

# Split args into: MT_ARGS (for mt_parse_args) vs our subcommand/flags.
# -e/-t and their values go to MT_ARGS. Bare words become command/username.
# --password/--admin are ours. Everything else passes through.
_NEXT_FOR=""
for arg in "$@"; do
    if [ "$_NEXT_FOR" = "mt" ]; then
        MT_ARGS+=("$arg")
        _NEXT_FOR=""
        continue
    elif [ "$_NEXT_FOR" = "password" ]; then
        PASSWORD="$arg"
        _NEXT_FOR=""
        continue
    fi
    case "$arg" in
        -e|-t)
            MT_ARGS+=("$arg")
            _NEXT_FOR="mt"
            ;;
        -h|--help)
            MT_ARGS+=("$arg")
            ;;
        --password)
            _NEXT_FOR="password"
            ;;
        --password=*)
            PASSWORD="${arg#*=}"
            ;;
        --admin)
            ADMIN_FLAG=true
            ;;
        --*)
            MT_ARGS+=("$arg")
            ;;
        -*)
            MT_ARGS+=("$arg")
            ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$arg"
            elif [ -z "$USERNAME" ]; then
                USERNAME="$arg"
            else
                MT_ARGS+=("$arg")
            fi
            ;;
    esac
done
unset _NEXT_FOR

mt_parse_args "${MT_ARGS[@]+"${MT_ARGS[@]}"}"
mt_require_env
mt_require_tenant

source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config

# ============================================================================
# HARD GATE: dev only
# ============================================================================
if [ "$MT_ENV" != "dev" ]; then
    print_error "FATAL: dev-test-users.sh can ONLY run in dev environment"
    print_error "Current MT_ENV=$MT_ENV — refusing to continue"
    exit 1
fi

if [ -z "$COMMAND" ]; then
    print_error "No command specified"
    mt_usage
fi

# ============================================================================
# Keycloak admin API setup (same pattern as import-keycloak-realm.sh)
# ============================================================================
print_status "Setting up port-forward to Keycloak service..."
kubectl -n "$NS_AUTH" port-forward svc/keycloak-keycloakx-http 8080:80 > /tmp/keycloak-pf.log 2>&1 &
PF_PID=$!
sleep 3

KEYCLOAK_URL="http://localhost:8080"
REALM="$TENANT_KEYCLOAK_REALM"

cleanup() {
    kill $PF_PID 2>/dev/null || true
    kill $STALWART_PF_PID 2>/dev/null || true
}
STALWART_PF_PID=""
trap cleanup EXIT

# Get admin credentials
if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
    print_error "KEYCLOAK_ADMIN_PASSWORD is not set (loaded from tenant secrets)"
    exit 1
fi

# Get access token
get_token() {
    ACCESS_TOKEN=$(curl -s -X POST \
      "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
      --data-urlencode "username=admin" \
      --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=admin-cli" | \
      jq -r '.access_token')

    if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
        print_error "Failed to get Keycloak admin access token"
        exit 1
    fi
}

get_token

# ============================================================================
# Helper: assign a realm role to a user
# ============================================================================
assign_role() {
    local user_id="$1"
    local role_name="$2"

    ROLE_JSON=$(curl -s \
      "$KEYCLOAK_URL/admin/realms/$REALM/roles/$role_name" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    ROLE_ID=$(echo "$ROLE_JSON" | jq -r '.id // empty')
    if [ -z "$ROLE_ID" ]; then
        print_warning "Role '$role_name' not found — skipping"
        return 0
    fi

    ASSIGN_RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/assign_role.json -X POST \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$user_id/role-mappings/realm" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "[{\"id\": \"$ROLE_ID\", \"name\": \"$role_name\"}]")

    if [ "$ASSIGN_RESPONSE" = "204" ]; then
        print_success "Assigned role '$role_name'"
    else
        print_warning "Failed to assign role '$role_name' (HTTP $ASSIGN_RESPONSE)"
    fi
}

# ============================================================================
# Helper: ensure Stalwart mail principal exists for a user
# Uses /api/principal/deploy (works with OIDC directory mode).
# ============================================================================
ensure_stalwart_principal() {
    local email="$1"
    local display_name="${2:-$email}"

    if [ -z "${STALWART_ADMIN_PASSWORD:-}" ]; then
        print_warning "STALWART_ADMIN_PASSWORD not set — skipping Stalwart principal creation"
        return 0
    fi

    # Start port-forward to Stalwart if not already running
    if [ -z "$STALWART_PF_PID" ] || ! kill -0 "$STALWART_PF_PID" 2>/dev/null; then
        print_status "Setting up port-forward to Stalwart service..."
        kubectl -n "$NS_STALWART" port-forward svc/stalwart 8090:8080 > /tmp/stalwart-pf.log 2>&1 &
        STALWART_PF_PID=$!
        sleep 3
    fi

    local stalwart_url="http://localhost:8090"
    local admin_auth
    admin_auth="Basic $(printf 'admin:%s' "$STALWART_ADMIN_PASSWORD" | base64)"

    # Use username (without domain) as the principal name to match what Stalwart's
    # OIDC auto-provisioner creates (uses preferred_username from the token).
    local principal_name="${email%%@*}"

    # Check if principal already exists (by username, not full email)
    local check_body
    check_body=$(curl -s "$stalwart_url/api/principal/$principal_name" \
      -H "Authorization: $admin_auth")

    if echo "$check_body" | jq -e '.error' > /dev/null 2>&1; then
        # Principal doesn't exist (error = "notFound") or other error — try to create
        :
    else
        print_status "Stalwart principal already exists for $principal_name"
        return 0
    fi

    # Create principal via /api/principal/deploy
    local deploy_body
    deploy_body=$(jq -n \
      --arg name "$principal_name" \
      --arg email "$email" \
      --arg desc "$display_name" \
      '{type: "individual", name: $name, emails: [$email], description: $desc, roles: ["user"], secrets: []}')

    local response
    response=$(curl -s -X POST "$stalwart_url/api/principal/deploy" \
      -H "Authorization: $admin_auth" \
      -H "Content-Type: application/json" \
      -d "$deploy_body")

    local error
    error=$(echo "$response" | jq -r '.error // empty')
    if [ -n "$error" ]; then
        if [ "$error" = "fieldAlreadyExists" ]; then
            print_status "Stalwart principal already exists for $email"
            return 0
        fi
        print_warning "Stalwart principal creation returned: $error"
        return 0
    fi

    # Reload config so RCPT TO picks up the new principal immediately
    curl -s -X GET "$stalwart_url/api/reload" \
      -H "Authorization: $admin_auth" > /dev/null 2>&1

    print_success "Created Stalwart mail principal for $email"
}

# ============================================================================
# Commands
# ============================================================================

cmd_create() {
    if [ -z "$USERNAME" ]; then
        print_error "Usage: dev-test-users.sh -e dev -t <tenant> create <username> [--password <pw>] [--admin]"
        exit 1
    fi

    local email="${USERNAME}@${EMAIL_DOMAIN}"

    print_status "Creating test user: $USERNAME (email: $email)"

    # Check if user already exists
    EXISTING=$(curl -s \
      "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$USERNAME&exact=true" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

    if [ -n "$EXISTING" ]; then
        print_warning "User '$USERNAME' already exists (ID: $EXISTING)"
        print_status "Use 'reset-password' to change their password"
        # Still ensure Stalwart principal exists (may be missing for pre-existing users)
        ensure_stalwart_principal "$email" "$USERNAME Test"
        return 0
    fi

    # Create user
    CREATE_RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/create_user.json -X POST \
      "$KEYCLOAK_URL/admin/realms/$REALM/users" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(cat <<USERJSON
{
    "username": "$USERNAME",
    "email": "$email",
    "emailVerified": true,
    "enabled": true,
    "firstName": "$USERNAME",
    "lastName": "Test",
    "attributes": {
        "userType": ["member"],
        "recoveryEmail": ["$email"],
        "tenantEmail": ["$email"]
    },
    "requiredActions": []
}
USERJSON
)")

    if [ "$CREATE_RESPONSE" = "201" ]; then
        print_success "Created user '$USERNAME'"
    else
        print_error "Failed to create user (HTTP $CREATE_RESPONSE)"
        [ -f /tmp/create_user.json ] && cat /tmp/create_user.json
        exit 1
    fi

    # Get the new user's ID
    get_token
    USER_ID=$(curl -s \
      "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$USERNAME&exact=true" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

    if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
        print_error "Could not retrieve user ID after creation"
        exit 1
    fi

    # Set password
    SET_PW_RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/set_password.json -X PUT \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"type\": \"password\", \"value\": \"$PASSWORD\", \"temporary\": false}")

    if [ "$SET_PW_RESPONSE" = "204" ]; then
        print_success "Password set for '$USERNAME'"
    else
        print_warning "Failed to set password (HTTP $SET_PW_RESPONSE)"
    fi

    # Assign docs-user role
    assign_role "$USER_ID" "docs-user"

    # Optionally assign tenant-admin role
    if $ADMIN_FLAG; then
        assign_role "$USER_ID" "tenant-admin"
    fi

    # Create Stalwart mail principal so the user can receive email immediately
    ensure_stalwart_principal "$email" "$USERNAME Test"

    echo ""
    print_success "Test user ready!"
    print_status "  Username: $USERNAME"
    print_status "  Password: $PASSWORD"
    print_status "  Email:    $email"
    print_status "  Roles:    docs-user$(if $ADMIN_FLAG; then echo ", tenant-admin"; fi)"
}

cmd_list() {
    print_status "Users in realm '$REALM':"
    echo ""

    USERS=$(curl -s \
      "$KEYCLOAK_URL/admin/realms/$REALM/users?max=100" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    echo "$USERS" | jq -r '.[] | "  \(.username)\t\(.email // "-")\t\(.enabled)\tid:\(.id)"' | column -t -s $'\t'

    local count
    count=$(echo "$USERS" | jq 'length')
    echo ""
    print_status "Total: $count user(s)"
}

cmd_delete() {
    if [ -z "$USERNAME" ]; then
        print_error "Usage: dev-test-users.sh -e dev -t <tenant> delete <username>"
        exit 1
    fi

    USER_ID=$(curl -s \
      "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$USERNAME&exact=true" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

    if [ -z "$USER_ID" ]; then
        print_error "User '$USERNAME' not found"
        exit 1
    fi

    DELETE_RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/delete_user.json -X DELETE \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    if [ "$DELETE_RESPONSE" = "204" ]; then
        print_success "Deleted user '$USERNAME' (ID: $USER_ID)"
    else
        print_error "Failed to delete user (HTTP $DELETE_RESPONSE)"
        [ -f /tmp/delete_user.json ] && cat /tmp/delete_user.json
        exit 1
    fi
}

cmd_reset_password() {
    if [ -z "$USERNAME" ]; then
        print_error "Usage: dev-test-users.sh -e dev -t <tenant> reset-password <username> [--password <pw>]"
        exit 1
    fi

    USER_ID=$(curl -s \
      "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$USERNAME&exact=true" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

    if [ -z "$USER_ID" ]; then
        print_error "User '$USERNAME' not found"
        exit 1
    fi

    SET_PW_RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/set_password.json -X PUT \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"type\": \"password\", \"value\": \"$PASSWORD\", \"temporary\": false}")

    if [ "$SET_PW_RESPONSE" = "204" ]; then
        print_success "Password reset for '$USERNAME'"
    else
        print_error "Failed to reset password (HTTP $SET_PW_RESPONSE)"
        [ -f /tmp/set_password.json ] && cat /tmp/set_password.json
        exit 1
    fi
}

# ============================================================================
# Dispatch
# ============================================================================
case "$COMMAND" in
    create)         cmd_create ;;
    list)           cmd_list ;;
    delete)         cmd_delete ;;
    reset-password) cmd_reset_password ;;
    *)
        print_error "Unknown command: $COMMAND"
        mt_usage
        ;;
esac
