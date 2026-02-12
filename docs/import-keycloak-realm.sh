#!/bin/bash

# Script to import Keycloak realm configuration with Google OAuth credentials
# This script retrieves credentials from Kubernetes secrets and applies the realm configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Require MT_ENV and set kubeconfig statelessly
REPO_ROOT="${REPO_ROOT:-/workspace}"
if [ -z "${MT_ENV:-}" ]; then
  print_error "MT_ENV is not set. Usage: MT_ENV=dev ./docs/import-keycloak-realm.sh"
  exit 1
fi
export KUBECONFIG="$REPO_ROOT/kubeconfig.$MT_ENV.yaml"

# Use namespace variables from environment, with defaults
NS_AUTH="${NS_AUTH:-infra-auth}"
NS_DOCS="${NS_DOCS:-tn-${TENANT_NAME:-example}-docs}"

print_status "Importing Keycloak realm configuration with Google OAuth..."
print_status "Keycloak namespace: $NS_AUTH, Docs namespace: $NS_DOCS"

# Validate required environment variables (set by create_env from tenant config)
# EMAIL_DOMAIN includes env prefix (e.g., dev.example.com for dev) - used for user email addresses
required_vars=("DOCS_HOST" "MATRIX_HOST" "AUTH_HOST" "JITSI_HOST" "FILES_HOST" "MAIL_HOST" "TENANT_DOMAIN" "TENANT_DISPLAY_NAME" "TENANT_KEYCLOAK_REALM" "EMAIL_DOMAIN")
# WEBMAIL_HOST and ADMIN_HOST are optional (only needed if webmail_enabled/admin_portal_enabled)
missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    print_error "Required environment variables not set: ${missing_vars[*]}"
    print_error "This script should be called from create_env which sets these from tenant config."
    exit 1
fi
print_status "Using environment: AUTH_HOST=$AUTH_HOST, DOCS_HOST=$DOCS_HOST"

# Set SMTP_DOMAIN from TENANT_DOMAIN if not set
export SMTP_DOMAIN="${SMTP_DOMAIN:-$TENANT_DOMAIN}"

# Wait for Keycloak pod to be ready (relies on readiness probe)
# Use StatefulSet selector - Keycloak chart uses app.kubernetes.io/name=keycloakx
print_status "Waiting for Keycloak pod to be ready (Kubernetes readiness probe)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloakx -n "$NS_AUTH" --timeout=300s || {
    print_error "Keycloak pod is not ready after 5 minutes"
    exit 1
}
print_success "Keycloak pod is ready (readiness probe passed)"

# Access Keycloak via service using port-forward (simplest way to access from outside cluster)
print_status "Setting up port-forward to Keycloak service..."
kubectl -n "$NS_AUTH" port-forward svc/keycloak-keycloakx-http 8080:80 > /tmp/keycloak-pf.log 2>&1 &
PF_PID=$!
sleep 3

# Use localhost for API calls via port-forward
KEYCLOAK_URL="http://localhost:8080"
KEYCLOAK_SKIP_SSL_VERIFY=""

# Cleanup function
cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Get Google OAuth credentials from tenant secrets (required - no fallback)
print_status "Retrieving Google OAuth credentials from tenant secrets..."
export GOOGLE_CLIENT_ID=$(yq '.google.client_id' "$TENANT_SECRETS" 2>/dev/null)
export GOOGLE_CLIENT_SECRET=$(yq '.google.client_secret' "$TENANT_SECRETS" 2>/dev/null)

if [ -z "$GOOGLE_CLIENT_ID" ] || [ "$GOOGLE_CLIENT_ID" = "null" ]; then
    print_error "Missing required 'google.client_id' in tenant secrets: $TENANT_SECRETS"
    print_error "Each tenant must have their own Google OAuth credentials configured"
    exit 1
fi

if [ -z "$GOOGLE_CLIENT_SECRET" ] || [ "$GOOGLE_CLIENT_SECRET" = "null" ]; then
    print_error "Missing required 'google.client_secret' in tenant secrets: $TENANT_SECRETS"
    print_error "Each tenant must have their own Google OAuth credentials configured"
    exit 1
fi
print_success "Google OAuth credentials retrieved from tenant secrets"

# Get OIDC client secret for docs-app (required - env var is source of truth)
print_status "Retrieving OIDC client secret for docs-app..."
if [ -z "${TF_VAR_oidc_rp_client_secret_docs:-}" ]; then
    print_error "TF_VAR_oidc_rp_client_secret_docs is not set."
    print_error "This must be set from tenant secrets (oidc.docs_client_secret in tenants/<tenant>/${MT_ENV}.secrets.yaml)"
    exit 1
fi
export OIDC_RP_CLIENT_SECRET="$TF_VAR_oidc_rp_client_secret_docs"
print_success "OIDC client secret for docs-app retrieved from environment"

# Get Nextcloud OIDC client secret (required - env var is source of truth)
if [ -z "${TF_VAR_nextcloud_oidc_client_secret:-}" ]; then
    print_error "TF_VAR_nextcloud_oidc_client_secret is not set."
    print_error "This must be set from tenant secrets (oidc.nextcloud_client_secret in tenants/<tenant>/${MT_ENV}.secrets.yaml)"
    exit 1
fi
export NEXTCLOUD_OIDC_CLIENT_SECRET="$TF_VAR_nextcloud_oidc_client_secret"
print_success "Nextcloud OIDC client secret retrieved from environment"

# Get Stalwart OIDC client secret (optional - only needed if mail_enabled)
STALWART_OIDC_SECRET_VALUE=$(yq '.oidc.stalwart_client_secret // ""' "$TENANT_SECRETS" 2>/dev/null)
if [ -n "$STALWART_OIDC_SECRET_VALUE" ] && [ "$STALWART_OIDC_SECRET_VALUE" != "null" ] && [[ "$STALWART_OIDC_SECRET_VALUE" != *"PLACEHOLDER"* ]]; then
    export STALWART_OIDC_SECRET="$STALWART_OIDC_SECRET_VALUE"
    print_success "Stalwart OIDC client secret retrieved from tenant secrets"
else
    export STALWART_OIDC_SECRET=""
    print_status "Stalwart OIDC client secret not set (mail may not be enabled)"
fi

# Get Roundcube OIDC client secret (optional - only needed if webmail_enabled)
ROUNDCUBE_OIDC_SECRET_VALUE=$(yq '.oidc.roundcube_client_secret // ""' "$TENANT_SECRETS" 2>/dev/null)
if [ -n "$ROUNDCUBE_OIDC_SECRET_VALUE" ] && [ "$ROUNDCUBE_OIDC_SECRET_VALUE" != "null" ] && [[ "$ROUNDCUBE_OIDC_SECRET_VALUE" != *"PLACEHOLDER"* ]]; then
    export ROUNDCUBE_OIDC_SECRET="$ROUNDCUBE_OIDC_SECRET_VALUE"
    print_success "Roundcube OIDC client secret retrieved from tenant secrets"
else
    export ROUNDCUBE_OIDC_SECRET=""
    print_status "Roundcube OIDC client secret not set (webmail may not be enabled)"
fi

# Get Keycloak admin credentials
ADMIN_USER="admin"
if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
    print_error "KEYCLOAK_ADMIN_PASSWORD is required but not set"
    print_error "Set it in tenants/<tenant>/<env>.secrets.yaml under keycloak.admin_password"
    exit 1
fi
ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD"

# Get access token with retries (Keycloak may need time to be fully ready)
print_status "Getting Keycloak admin access token..."
MAX_TOKEN_RETRIES=3
TOKEN_RETRY_DELAY=5
ACCESS_TOKEN=""

for attempt in $(seq 1 $MAX_TOKEN_RETRIES); do
    ACCESS_TOKEN=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -X POST \
      "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
      --data-urlencode "username=$ADMIN_USER" \
      --data-urlencode "password=$ADMIN_PASSWORD" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=admin-cli" | \
      jq -r '.access_token')
    
    if [ "$ACCESS_TOKEN" != "null" ] && [ -n "$ACCESS_TOKEN" ]; then
        break
    fi
    
    if [ $attempt -lt $MAX_TOKEN_RETRIES ]; then
        print_warning "Failed to get access token (attempt $attempt/$MAX_TOKEN_RETRIES), retrying in ${TOKEN_RETRY_DELAY}s..."
        sleep $TOKEN_RETRY_DELAY
    fi
done

if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    print_error "Failed to get access token after $MAX_TOKEN_RETRIES attempts. Check Keycloak admin credentials."
    exit 1
fi
print_success "Access token obtained successfully"

# Helper: refresh the admin token (Keycloak admin-cli tokens expire after ~60s)
refresh_token() {
    ACCESS_TOKEN=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -X POST \
      "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
      --data-urlencode "username=$ADMIN_USER" \
      --data-urlencode "password=$ADMIN_PASSWORD" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=admin-cli" | \
      jq -r '.access_token')
    if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
        print_error "Failed to refresh access token"
        exit 1
    fi
}

# Create temporary realm config with environment-specific variables
print_status "Preparing realm configuration with environment-specific variables..."
TEMP_CONFIG=$(mktemp)

# Render template with environment variables (GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, and all host vars already available)
envsubst < "$REPO_ROOT/docs/keycloak-realm-config.json.tpl" > "$TEMP_CONFIG"

# Import/update the realm configuration
print_status "Importing realm configuration to Keycloak..."
REALM_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/keycloak_response.json -X POST \
  "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$TEMP_CONFIG")

if [ "$REALM_RESPONSE" = "201" ]; then
    print_success "Realm '$TENANT_KEYCLOAK_REALM' created successfully"
elif [ "$REALM_RESPONSE" = "409" ]; then
    print_warning "Realm '$TENANT_KEYCLOAK_REALM' already exists, updating configuration..."
    
    # Update the realm using partial import
    UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/keycloak_update_response.json -X PUT \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d @"$TEMP_CONFIG")
    
    if [ "$UPDATE_RESPONSE" = "204" ]; then
        print_success "Realm '$TENANT_KEYCLOAK_REALM' updated successfully"
    else
        print_error "Failed to update realm '$TENANT_KEYCLOAK_REALM' (HTTP $UPDATE_RESPONSE)"
        if [ -f /tmp/keycloak_update_response.json ]; then
            print_error "Error details: $(cat /tmp/keycloak_update_response.json)"
        fi
        exit 1
    fi
else
    print_error "Failed to import realm configuration (HTTP $REALM_RESPONSE)"
    if [ -f /tmp/keycloak_response.json ]; then
        print_error "Error details: $(cat /tmp/keycloak_response.json)"
    fi
    exit 1
fi

# Update realm frontendUrl to use tenant's auth domain (multi-domain support)
# This ensures the realm uses the correct domain for redirects and links
print_status "Setting realm frontendUrl to https://${AUTH_HOST}..."
FRONTEND_URL_UPDATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/frontend_url_update.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"attributes\": {\"frontendUrl\": \"https://${AUTH_HOST}\"}}")

if [ "$FRONTEND_URL_UPDATE" = "204" ]; then
    print_success "Realm frontendUrl set to https://${AUTH_HOST}"
else
    print_warning "Failed to update frontendUrl (HTTP $FRONTEND_URL_UPDATE), continuing..."
    if [ -f /tmp/frontend_url_update.json ]; then
        print_warning "Details: $(cat /tmp/frontend_url_update.json)"
    fi
fi

# Update SMTP server configuration (realm PUT doesn't always update smtpServer)
print_status "Updating SMTP server configuration..."
SMTP_CONFIG='{
  "host": "postfix-internal.infra-mail.svc.cluster.local",
  "port": "587",
  "from": "noreply@'"${SMTP_DOMAIN}"'",
  "fromDisplayName": "'"${TENANT_DISPLAY_NAME}"' Team",
  "replyTo": "noreply@'"${SMTP_DOMAIN}"'",
  "replyToDisplayName": "'"${TENANT_DISPLAY_NAME}"' Team",
  "ssl": "false",
  "starttls": "false",
  "auth": "false"
}'
SMTP_UPDATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/smtp_update.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"smtpServer\": $SMTP_CONFIG}")

if [ "$SMTP_UPDATE" = "204" ]; then
    print_success "SMTP server configuration updated (host: postfix-internal.infra-mail.svc.cluster.local:587, from: noreply@${SMTP_DOMAIN})"
else
    print_warning "Failed to update SMTP configuration (HTTP $SMTP_UPDATE), continuing..."
    if [ -f /tmp/smtp_update.json ]; then
        print_warning "Details: $(cat /tmp/smtp_update.json)"
    fi
fi

# Update Google identity provider with credentials (realm import doesn't update existing IdPs)
print_status "Updating Google identity provider with OAuth credentials..."
GOOGLE_IDP_UPDATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/google_idp_update.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/identity-provider/instances/google" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"alias\": \"google\",
    \"displayName\": \"Google\",
    \"providerId\": \"google\",
    \"enabled\": true,
    \"updateProfileFirstLoginMode\": \"on\",
    \"trustEmail\": true,
    \"storeToken\": false,
    \"addReadTokenRoleOnCreate\": false,
    \"authenticateByDefault\": false,
    \"linkOnly\": false,
    \"hideOnLogin\": false,
    \"firstBrokerLoginFlowAlias\": \"first broker login\",
    \"config\": {
      \"clientId\": \"$GOOGLE_CLIENT_ID\",
      \"clientSecret\": \"$GOOGLE_CLIENT_SECRET\",
      \"defaultScope\": \"openid email profile\",
      \"hostedDomain\": \"\",
      \"useJwksUrl\": \"true\",
      \"syncMode\": \"IMPORT\",
      \"hideOnLoginPage\": \"false\"
    }
  }")

if [ "$GOOGLE_IDP_UPDATE" = "204" ]; then
    print_success "Google identity provider updated with OAuth credentials"
else
    print_error "Failed to update Google identity provider (HTTP $GOOGLE_IDP_UPDATE)"
    if [ -f /tmp/google_idp_update.json ]; then
        print_error "Error details: $(cat /tmp/google_idp_update.json)"
    fi
    exit 1
fi

# Verify Google identity provider configuration
print_status "Verifying Google identity provider configuration..."
GOOGLE_PROVIDER_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/google_idp_check.json \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/identity-provider/instances/google" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

if [ "$GOOGLE_PROVIDER_RESPONSE" = "200" ]; then
    CHECKED_CLIENT_ID=$(cat /tmp/google_idp_check.json | jq -r '.config.clientId // "null"')
    if [ "$CHECKED_CLIENT_ID" != "null" ] && [ -n "$CHECKED_CLIENT_ID" ]; then
        print_success "Google identity provider is configured correctly with clientId: $CHECKED_CLIENT_ID"
    else
        print_warning "Google identity provider exists but clientId is missing or null"
    fi
else
    print_warning "Google identity provider verification failed (HTTP $GOOGLE_PROVIDER_RESPONSE)"
fi

# Update docs-app client secret to match backend (realm import doesn't always update existing client secrets)
print_status "Updating docs-app client secret to match backend configuration..."
DOCS_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=docs-app" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

if [ -z "$DOCS_CLIENT_ID" ] || [ "$DOCS_CLIENT_ID" = "null" ]; then
    print_error "docs-app client not found in Keycloak realm"
    exit 1
fi

# Get current client configuration
DOCS_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$DOCS_CLIENT_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

# Update client with new secret (update the full client object)
DOCS_CLIENT_UPDATE=$(echo "$DOCS_CLIENT_CONFIG" | jq ". + {secret: \"$OIDC_RP_CLIENT_SECRET\"}")
DOCS_CLIENT_SECRET_UPDATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/docs_client_secret_update.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$DOCS_CLIENT_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$DOCS_CLIENT_UPDATE")

if [ "$DOCS_CLIENT_SECRET_UPDATE" = "204" ]; then
    print_success "docs-app client secret updated to match backend"
else
    print_error "Failed to update docs-app client secret (HTTP $DOCS_CLIENT_SECRET_UPDATE)"
    if [ -f /tmp/docs_client_secret_update.json ]; then
        print_error "Error details: $(cat /tmp/docs_client_secret_update.json)"
    fi
    exit 1
fi

# Update docs-app client redirect URIs to match environment (realm import doesn't always update existing clients)
print_status "Updating docs-app client redirect URIs for environment..."
# Get current client configuration again (we already have DOCS_CLIENT_ID and DOCS_CLIENT_CONFIG above)
DOCS_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$DOCS_CLIENT_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

# Update client with correct redirect URIs and web origins
# Include both the wildcard pattern and the specific callback path
DOCS_CLIENT_UPDATE=$(echo "$DOCS_CLIENT_CONFIG" | jq ". + {
  redirectUris: [\"https://${DOCS_HOST}/*\", \"https://${DOCS_HOST}/api/v1.0/callback/\"],
  webOrigins: [\"https://${DOCS_HOST}\"]
}")
DOCS_CLIENT_REDIRECT_UPDATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/docs_client_redirect_update.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$DOCS_CLIENT_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$DOCS_CLIENT_UPDATE")

if [ "$DOCS_CLIENT_REDIRECT_UPDATE" = "204" ]; then
    print_success "docs-app client redirect URIs updated to https://${DOCS_HOST}/api/v1.0/callback/"
else
    print_error "Failed to update docs-app client redirect URIs (HTTP $DOCS_CLIENT_REDIRECT_UPDATE)"
    if [ -f /tmp/docs_client_redirect_update.json ]; then
        print_error "Error details: $(cat /tmp/docs_client_redirect_update.json)"
    fi
    exit 1
fi

# Update matrix-synapse client redirect URIs to match environment (realm import doesn't always update existing clients)
print_status "Updating matrix-synapse client redirect URIs for environment..."
refresh_token
MATRIX_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=matrix-synapse" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

if [ -z "$MATRIX_CLIENT_ID" ] || [ "$MATRIX_CLIENT_ID" = "null" ]; then
    print_error "matrix-synapse client not found in Keycloak realm '$TENANT_KEYCLOAK_REALM'. The realm template should have created it."
    exit 1
else
    # Get current client configuration
    MATRIX_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$MATRIX_CLIENT_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    # Update client with correct secret, redirect URIs and web origins
    # Include secret from SYNAPSE_OIDC_CLIENT_SECRET env var if set
    if [ -n "${SYNAPSE_OIDC_CLIENT_SECRET:-}" ]; then
        MATRIX_CLIENT_UPDATE=$(echo "$MATRIX_CLIENT_CONFIG" | jq ". + {
          secret: \"${SYNAPSE_OIDC_CLIENT_SECRET}\",
          redirectUris: [\"https://${MATRIX_HOST}/_synapse/client/oidc/callback\"],
          webOrigins: [\"https://${MATRIX_HOST}\"]
        }")
    else
        MATRIX_CLIENT_UPDATE=$(echo "$MATRIX_CLIENT_CONFIG" | jq ". + {
          redirectUris: [\"https://${MATRIX_HOST}/_synapse/client/oidc/callback\"],
          webOrigins: [\"https://${MATRIX_HOST}\"]
        }")
    fi
    MATRIX_CLIENT_UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/matrix_client_update.json -X PUT \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$MATRIX_CLIENT_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$MATRIX_CLIENT_UPDATE")

    if [ "$MATRIX_CLIENT_UPDATE_RESPONSE" = "204" ]; then
        print_success "matrix-synapse client redirect URIs updated to https://${MATRIX_HOST}/_synapse/client/oidc/callback"
    else
        print_error "Failed to update matrix-synapse client redirect URIs (HTTP $MATRIX_CLIENT_UPDATE_RESPONSE)"
        if [ -f /tmp/matrix_client_update.json ]; then
            print_error "Error details: $(cat /tmp/matrix_client_update.json)"
        fi
        exit 1
    fi
fi

# Update or create nextcloud-app client for environment
refresh_token
print_status "Configuring nextcloud-app client for environment..."
NEXTCLOUD_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=nextcloud-app" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

if [ -z "$NEXTCLOUD_CLIENT_ID" ] || [ "$NEXTCLOUD_CLIENT_ID" = "null" ]; then
    print_status "nextcloud-app client not found, creating it..."
    # Create the client - include CALENDAR_HOST if set
    if [ -n "${CALENDAR_HOST:-}" ]; then
      NEXTCLOUD_CLIENT_CREATE=$(cat <<EOF
{
  "clientId": "nextcloud-app",
  "name": "Nextcloud Application",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "$NEXTCLOUD_OIDC_CLIENT_SECRET",
  "redirectUris": ["https://${FILES_HOST}/*", "https://${FILES_HOST}/apps/user_oidc/code", "https://${CALENDAR_HOST}/*", "https://${CALENDAR_HOST}/apps/user_oidc/code"],
  "webOrigins": ["https://${FILES_HOST}", "https://${CALENDAR_HOST}"],
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true,
  "defaultClientScopes": ["web-origins", "role_list", "profile", "roles", "email", "offline_access"],
  "optionalClientScopes": ["address", "phone", "microprofile-jwt"]
}
EOF
)
    else
      NEXTCLOUD_CLIENT_CREATE=$(cat <<EOF
{
  "clientId": "nextcloud-app",
  "name": "Nextcloud Application",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "$NEXTCLOUD_OIDC_CLIENT_SECRET",
  "redirectUris": ["https://${FILES_HOST}/*", "https://${FILES_HOST}/apps/user_oidc/code"],
  "webOrigins": ["https://${FILES_HOST}"],
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true,
  "defaultClientScopes": ["web-origins", "role_list", "profile", "roles", "email", "offline_access"],
  "optionalClientScopes": ["address", "phone", "microprofile-jwt"]
}
EOF
)
    fi
    NEXTCLOUD_CLIENT_CREATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/nextcloud_client_create.json -X POST \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$NEXTCLOUD_CLIENT_CREATE")

    if [ "$NEXTCLOUD_CLIENT_CREATE_RESPONSE" = "201" ]; then
        print_success "nextcloud-app client created for https://${FILES_HOST}"
    else
        print_error "Failed to create nextcloud-app client (HTTP $NEXTCLOUD_CLIENT_CREATE_RESPONSE)"
        if [ -f /tmp/nextcloud_client_create.json ]; then
            print_error "Error details: $(cat /tmp/nextcloud_client_create.json)"
        fi
        exit 1
    fi
else
    # Get current client configuration
    print_status "nextcloud-app client found, updating it..."
    NEXTCLOUD_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$NEXTCLOUD_CLIENT_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    # Update client with correct redirect URIs, web origins, and secret
    # Note: Nextcloud user_oidc app uses /apps/user_oidc/code as the callback path
    # Include CALENDAR_HOST for calendar subdomain access (if set)
    if [ -n "${CALENDAR_HOST:-}" ]; then
      NEXTCLOUD_CLIENT_UPDATE=$(echo "$NEXTCLOUD_CLIENT_CONFIG" | jq ". + {
        secret: \"$NEXTCLOUD_OIDC_CLIENT_SECRET\",
        redirectUris: [\"https://${FILES_HOST}/*\", \"https://${FILES_HOST}/apps/user_oidc/code\", \"https://${CALENDAR_HOST}/*\", \"https://${CALENDAR_HOST}/apps/user_oidc/code\"],
        webOrigins: [\"https://${FILES_HOST}\", \"https://${CALENDAR_HOST}\"]
      }")
    else
      NEXTCLOUD_CLIENT_UPDATE=$(echo "$NEXTCLOUD_CLIENT_CONFIG" | jq ". + {
        secret: \"$NEXTCLOUD_OIDC_CLIENT_SECRET\",
        redirectUris: [\"https://${FILES_HOST}/*\", \"https://${FILES_HOST}/apps/user_oidc/code\"],
        webOrigins: [\"https://${FILES_HOST}\"]
      }")
    fi
    NEXTCLOUD_CLIENT_UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/nextcloud_client_update.json -X PUT \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$NEXTCLOUD_CLIENT_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$NEXTCLOUD_CLIENT_UPDATE")

    if [ "$NEXTCLOUD_CLIENT_UPDATE_RESPONSE" = "204" ]; then
        print_success "nextcloud-app client updated with secret and redirect URIs for https://${FILES_HOST}"
    else
        print_error "Failed to update nextcloud-app client (HTTP $NEXTCLOUD_CLIENT_UPDATE_RESPONSE)"
        if [ -f /tmp/nextcloud_client_update.json ]; then
            print_error "Error details: $(cat /tmp/nextcloud_client_update.json)"
        fi
        exit 1
    fi
fi

# Update or create jitsi client for environment (public client for Keycloak adapter)
refresh_token
print_status "Configuring jitsi client for environment..."
JITSI_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=jitsi" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

if [ -z "$JITSI_CLIENT_ID" ] || [ "$JITSI_CLIENT_ID" = "null" ]; then
    print_status "jitsi client not found, creating it..."
    # Create the client (public client, no secret needed)
    JITSI_CLIENT_CREATE=$(cat <<EOF
{
  "clientId": "jitsi",
  "name": "Jitsi Meet",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": true,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true,
  "redirectUris": ["https://${JITSI_HOST}/*"],
  "webOrigins": ["https://${JITSI_HOST}"],
  "defaultClientScopes": ["web-origins", "profile", "roles", "email"],
  "optionalClientScopes": ["address", "phone", "offline_access"]
}
EOF
)
    JITSI_CLIENT_CREATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/jitsi_client_create.json -X POST \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$JITSI_CLIENT_CREATE")

    if [ "$JITSI_CLIENT_CREATE_RESPONSE" = "201" ]; then
        print_success "jitsi client created for https://${JITSI_HOST}"
    else
        print_error "Failed to create jitsi client (HTTP $JITSI_CLIENT_CREATE_RESPONSE)"
        if [ -f /tmp/jitsi_client_create.json ]; then
            print_error "Error details: $(cat /tmp/jitsi_client_create.json)"
        fi
        exit 1
    fi
else
    # Get current client configuration
    print_status "jitsi client found, updating it..."
    JITSI_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$JITSI_CLIENT_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    # Update client with correct redirect URIs and web origins
    JITSI_CLIENT_UPDATE=$(echo "$JITSI_CLIENT_CONFIG" | jq ". + {
      publicClient: true,
      redirectUris: [\"https://${JITSI_HOST}/*\"],
      webOrigins: [\"https://${JITSI_HOST}\"]
    }")
    JITSI_CLIENT_UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/jitsi_client_update.json -X PUT \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$JITSI_CLIENT_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$JITSI_CLIENT_UPDATE")

    if [ "$JITSI_CLIENT_UPDATE_RESPONSE" = "204" ]; then
        print_success "jitsi client updated with redirect URIs for https://${JITSI_HOST}"
    else
        print_error "Failed to update jitsi client (HTTP $JITSI_CLIENT_UPDATE_RESPONSE)"
        if [ -f /tmp/jitsi_client_update.json ]; then
            print_error "Error details: $(cat /tmp/jitsi_client_update.json)"
        fi
        exit 1
    fi
fi

# Update or create stalwart client for mail (only if OIDC secret is configured)
refresh_token
if [ -n "$STALWART_OIDC_SECRET" ]; then
    print_status "Configuring stalwart client for mail authentication..."
    STALWART_KC_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=stalwart" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

    if [ -z "$STALWART_KC_CLIENT_ID" ] || [ "$STALWART_KC_CLIENT_ID" = "null" ]; then
        print_status "stalwart client not found, creating it..."
        # Create the client
        STALWART_CLIENT_CREATE=$(cat <<EOF
{
  "clientId": "stalwart",
  "name": "Stalwart Mail Server",
  "description": "OIDC client for Stalwart mail server authentication",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "$STALWART_OIDC_SECRET",
  "redirectUris": ["https://${MAIL_HOST}/*"],
  "webOrigins": ["https://${MAIL_HOST}"],
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true,
  "defaultClientScopes": ["web-origins", "role_list", "profile", "roles", "email"],
  "optionalClientScopes": ["address", "phone", "offline_access", "microprofile-jwt"]
}
EOF
)
        STALWART_CLIENT_CREATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/stalwart_client_create.json -X POST \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$STALWART_CLIENT_CREATE")

        if [ "$STALWART_CLIENT_CREATE_RESPONSE" = "201" ]; then
            print_success "stalwart client created for https://${MAIL_HOST}"
        else
            print_warning "Failed to create stalwart client (HTTP $STALWART_CLIENT_CREATE_RESPONSE) - mail may not be configured"
            if [ -f /tmp/stalwart_client_create.json ]; then
                print_warning "Details: $(cat /tmp/stalwart_client_create.json)"
            fi
        fi
    else
        # Get current client configuration
        print_status "stalwart client found, updating it..."
        STALWART_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$STALWART_KC_CLIENT_ID" \
          -H "Authorization: Bearer $ACCESS_TOKEN")

        # Update client with correct secret, redirect URIs and web origins
        STALWART_CLIENT_UPDATE=$(echo "$STALWART_CLIENT_CONFIG" | jq ". + {
          secret: \"$STALWART_OIDC_SECRET\",
          directAccessGrantsEnabled: true,
          redirectUris: [\"https://${MAIL_HOST}/*\"],
          webOrigins: [\"https://${MAIL_HOST}\"]
        }")
        STALWART_CLIENT_UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/stalwart_client_update.json -X PUT \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$STALWART_KC_CLIENT_ID" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$STALWART_CLIENT_UPDATE")

        if [ "$STALWART_CLIENT_UPDATE_RESPONSE" = "204" ]; then
            print_success "stalwart client updated with secret and redirect URIs for https://${MAIL_HOST}"
        else
            print_warning "Failed to update stalwart client (HTTP $STALWART_CLIENT_UPDATE_RESPONSE)"
            if [ -f /tmp/stalwart_client_update.json ]; then
                print_warning "Details: $(cat /tmp/stalwart_client_update.json)"
            fi
        fi
    fi
else
    print_status "Skipping stalwart client configuration (OIDC secret not configured)"
fi

# Update or create roundcube client for webmail (only if OIDC secret is configured)
refresh_token
if [ -n "$ROUNDCUBE_OIDC_SECRET" ]; then
    print_status "Configuring roundcube client for webmail authentication..."
    ROUNDCUBE_KC_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=roundcube" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

    if [ -z "$ROUNDCUBE_KC_CLIENT_ID" ] || [ "$ROUNDCUBE_KC_CLIENT_ID" = "null" ]; then
        print_status "roundcube client not found, creating it..."
        # Create the client
        ROUNDCUBE_CLIENT_CREATE=$(cat <<EOF
{
  "clientId": "roundcube",
  "name": "Roundcube Webmail",
  "description": "OIDC client for Roundcube webmail OAuth authentication",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "$ROUNDCUBE_OIDC_SECRET",
  "redirectUris": ["https://${WEBMAIL_HOST}/index.php/login/oauth"],
  "webOrigins": ["https://${WEBMAIL_HOST}"],
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true,
  "defaultClientScopes": ["web-origins", "role_list", "profile", "roles", "email", "offline_access"],
  "optionalClientScopes": ["address", "phone", "microprofile-jwt"]
}
EOF
)
        ROUNDCUBE_CLIENT_CREATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/roundcube_client_create.json -X POST \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$ROUNDCUBE_CLIENT_CREATE")

        if [ "$ROUNDCUBE_CLIENT_CREATE_RESPONSE" = "201" ]; then
            print_success "roundcube client created for https://${WEBMAIL_HOST}"
        else
            print_warning "Failed to create roundcube client (HTTP $ROUNDCUBE_CLIENT_CREATE_RESPONSE) - webmail may not be configured"
            if [ -f /tmp/roundcube_client_create.json ]; then
                print_warning "Details: $(cat /tmp/roundcube_client_create.json)"
            fi
        fi
    else
        # Get current client configuration
        print_status "roundcube client found, updating it..."
        ROUNDCUBE_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ROUNDCUBE_KC_CLIENT_ID" \
          -H "Authorization: Bearer $ACCESS_TOKEN")

        # Update client with correct secret, redirect URIs and web origins
        ROUNDCUBE_CLIENT_UPDATE=$(echo "$ROUNDCUBE_CLIENT_CONFIG" | jq ". + {
          secret: \"$ROUNDCUBE_OIDC_SECRET\",
          directAccessGrantsEnabled: true,
          redirectUris: [\"https://${WEBMAIL_HOST}/index.php/login/oauth\"],
          webOrigins: [\"https://${WEBMAIL_HOST}\"]
        }")
        ROUNDCUBE_CLIENT_UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/roundcube_client_update.json -X PUT \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ROUNDCUBE_KC_CLIENT_ID" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$ROUNDCUBE_CLIENT_UPDATE")

        if [ "$ROUNDCUBE_CLIENT_UPDATE_RESPONSE" = "204" ]; then
            print_success "roundcube client updated with secret and redirect URIs for https://${WEBMAIL_HOST}"
        else
            print_warning "Failed to update roundcube client (HTTP $ROUNDCUBE_CLIENT_UPDATE_RESPONSE)"
            if [ -f /tmp/roundcube_client_update.json ]; then
                print_warning "Details: $(cat /tmp/roundcube_client_update.json)"
            fi
        fi
    fi

    # Add audience mapper to include nextcloud-app in Roundcube tokens (for CalDAV SSO)
    # This allows Roundcube's OAuth token to be used for Nextcloud CalDAV requests
    # First, get the roundcube client ID if we don't have it yet
    if [ -z "$ROUNDCUBE_KC_CLIENT_ID" ] || [ "$ROUNDCUBE_KC_CLIENT_ID" = "null" ]; then
        ROUNDCUBE_KC_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=roundcube" \
          -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')
    fi

    if [ -n "$ROUNDCUBE_KC_CLIENT_ID" ] && [ "$ROUNDCUBE_KC_CLIENT_ID" != "null" ]; then
        print_status "Adding nextcloud-app audience mapper to roundcube client for CalDAV SSO..."
        
        # Check if mapper already exists
        EXISTING_MAPPER=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ROUNDCUBE_KC_CLIENT_ID/protocol-mappers/models" \
          -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[] | select(.name == "nextcloud-audience") | .id // empty')

        if [ -z "$EXISTING_MAPPER" ]; then
            # Create the audience mapper
            AUDIENCE_MAPPER=$(cat <<EOF
{
  "name": "nextcloud-audience",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "config": {
    "included.client.audience": "nextcloud-app",
    "id.token.claim": "true",
    "access.token.claim": "true"
  }
}
EOF
)
            MAPPER_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/roundcube_mapper.json -X POST \
              "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ROUNDCUBE_KC_CLIENT_ID/protocol-mappers/models" \
              -H "Authorization: Bearer $ACCESS_TOKEN" \
              -H "Content-Type: application/json" \
              -d "$AUDIENCE_MAPPER")

            if [ "$MAPPER_RESPONSE" = "201" ]; then
                print_success "Added nextcloud-audience mapper to roundcube client (enables CalDAV SSO)"
            else
                print_warning "Failed to add audience mapper (HTTP $MAPPER_RESPONSE)"
                if [ -f /tmp/roundcube_mapper.json ]; then
                    print_warning "Details: $(cat /tmp/roundcube_mapper.json)"
                fi
            fi
        else
            print_status "nextcloud-audience mapper already exists on roundcube client"
        fi

        # Add stalwart audience mapper so XOAUTH2 tokens are accepted by Stalwart
        # When storage.directory = "internal", Stalwart validates JWT audience against its client-id
        print_status "Adding stalwart audience mapper to roundcube client for mail auth..."

        EXISTING_STALWART_MAPPER=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ROUNDCUBE_KC_CLIENT_ID/protocol-mappers/models" \
          -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[] | select(.name == "stalwart-audience") | .id // empty')

        if [ -z "$EXISTING_STALWART_MAPPER" ]; then
            STALWART_AUDIENCE_MAPPER=$(cat <<EOF
{
  "name": "stalwart-audience",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "config": {
    "included.client.audience": "stalwart",
    "id.token.claim": "true",
    "access.token.claim": "true"
  }
}
EOF
)
            STALWART_MAPPER_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/roundcube_stalwart_mapper.json -X POST \
              "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ROUNDCUBE_KC_CLIENT_ID/protocol-mappers/models" \
              -H "Authorization: Bearer $ACCESS_TOKEN" \
              -H "Content-Type: application/json" \
              -d "$STALWART_AUDIENCE_MAPPER")

            if [ "$STALWART_MAPPER_RESPONSE" = "201" ]; then
                print_success "Added stalwart-audience mapper to roundcube client (enables XOAUTH2 mail auth)"
            else
                print_warning "Failed to add stalwart audience mapper (HTTP $STALWART_MAPPER_RESPONSE)"
                if [ -f /tmp/roundcube_stalwart_mapper.json ]; then
                    print_warning "Details: $(cat /tmp/roundcube_stalwart_mapper.json)"
                fi
            fi
        else
            print_status "stalwart-audience mapper already exists on roundcube client"
        fi
    fi
else
    print_status "Skipping roundcube client configuration (OIDC secret not configured)"
fi

# Get Admin Portal OIDC client secret (optional - only needed if admin_portal_enabled)
ADMIN_PORTAL_OIDC_SECRET_VALUE=$(yq '.oidc.admin_portal_client_secret // ""' "$TENANT_SECRETS" 2>/dev/null)
if [ -n "$ADMIN_PORTAL_OIDC_SECRET_VALUE" ] && [ "$ADMIN_PORTAL_OIDC_SECRET_VALUE" != "null" ] && [[ "$ADMIN_PORTAL_OIDC_SECRET_VALUE" != *"PLACEHOLDER"* ]]; then
    export ADMIN_PORTAL_OIDC_SECRET="$ADMIN_PORTAL_OIDC_SECRET_VALUE"
    print_success "Admin Portal OIDC client secret retrieved from tenant secrets"
else
    export ADMIN_PORTAL_OIDC_SECRET=""
    print_status "Admin Portal OIDC client secret not set (admin portal may not be enabled)"
fi

# Update or create admin-portal client (only if OIDC secret is configured)
if [ -n "$ADMIN_PORTAL_OIDC_SECRET" ]; then
    print_status "Configuring admin-portal client for tenant administration..."
    ADMIN_PORTAL_KC_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=admin-portal" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

    if [ -z "$ADMIN_PORTAL_KC_CLIENT_ID" ] || [ "$ADMIN_PORTAL_KC_CLIENT_ID" = "null" ]; then
        print_status "admin-portal client not found, creating it..."
        # Create the client with service account enabled for Admin API access
        ADMIN_PORTAL_CLIENT_CREATE=$(cat <<EOF
{
  "clientId": "admin-portal",
  "name": "Tenant Admin Portal",
  "description": "Admin portal for tenant user management and onboarding",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "$ADMIN_PORTAL_OIDC_SECRET",
  "redirectUris": ["https://${ADMIN_HOST}/*"],
  "webOrigins": ["https://${ADMIN_HOST}"],
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true,
  "defaultClientScopes": ["web-origins", "role_list", "profile", "roles", "email"],
  "optionalClientScopes": ["address", "phone", "offline_access", "microprofile-jwt"]
}
EOF
)
        ADMIN_PORTAL_CLIENT_CREATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/admin_portal_client_create.json -X POST \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$ADMIN_PORTAL_CLIENT_CREATE")

        if [ "$ADMIN_PORTAL_CLIENT_CREATE_RESPONSE" = "201" ]; then
            print_success "admin-portal client created for https://${ADMIN_HOST}"
            # Get the newly created client ID for role assignment
            ADMIN_PORTAL_KC_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=admin-portal" \
              -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')
        else
            print_warning "Failed to create admin-portal client (HTTP $ADMIN_PORTAL_CLIENT_CREATE_RESPONSE) - admin portal may not be configured"
            if [ -f /tmp/admin_portal_client_create.json ]; then
                print_warning "Details: $(cat /tmp/admin_portal_client_create.json)"
            fi
        fi
    else
        # Get current client configuration
        print_status "admin-portal client found, updating it..."
        ADMIN_PORTAL_CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ADMIN_PORTAL_KC_CLIENT_ID" \
          -H "Authorization: Bearer $ACCESS_TOKEN")

        # Update client with correct secret, redirect URIs and web origins
        ADMIN_PORTAL_CLIENT_UPDATE=$(echo "$ADMIN_PORTAL_CLIENT_CONFIG" | jq ". + {
          secret: \"$ADMIN_PORTAL_OIDC_SECRET\",
          serviceAccountsEnabled: true,
          redirectUris: [\"https://${ADMIN_HOST}/*\"],
          webOrigins: [\"https://${ADMIN_HOST}\"]
        }")
        ADMIN_PORTAL_CLIENT_UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/admin_portal_client_update.json -X PUT \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ADMIN_PORTAL_KC_CLIENT_ID" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$ADMIN_PORTAL_CLIENT_UPDATE")

        if [ "$ADMIN_PORTAL_CLIENT_UPDATE_RESPONSE" = "204" ]; then
            print_success "admin-portal client updated with secret and redirect URIs for https://${ADMIN_HOST}"
        else
            print_warning "Failed to update admin-portal client (HTTP $ADMIN_PORTAL_CLIENT_UPDATE_RESPONSE)"
            if [ -f /tmp/admin_portal_client_update.json ]; then
                print_warning "Details: $(cat /tmp/admin_portal_client_update.json)"
            fi
        fi
    fi

    # Assign realm-management roles to admin-portal service account for user management
    if [ -n "$ADMIN_PORTAL_KC_CLIENT_ID" ] && [ "$ADMIN_PORTAL_KC_CLIENT_ID" != "null" ]; then
        print_status "Configuring admin-portal service account roles for user management..."
        
        # Get the service account user ID
        SERVICE_ACCOUNT_USER_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$ADMIN_PORTAL_KC_CLIENT_ID/service-account-user" \
          -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.id // empty')
        
        if [ -n "$SERVICE_ACCOUNT_USER_ID" ] && [ "$SERVICE_ACCOUNT_USER_ID" != "null" ]; then
            # Get the realm-management client ID
            REALM_MGMT_CLIENT_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
              "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=realm-management" \
              -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')
            
            if [ -n "$REALM_MGMT_CLIENT_ID" ] && [ "$REALM_MGMT_CLIENT_ID" != "null" ]; then
                # Get role IDs for manage-users, view-users, query-users
                MANAGE_USERS_ROLE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
                  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$REALM_MGMT_CLIENT_ID/roles/manage-users" \
                  -H "Authorization: Bearer $ACCESS_TOKEN")
                VIEW_USERS_ROLE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
                  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$REALM_MGMT_CLIENT_ID/roles/view-users" \
                  -H "Authorization: Bearer $ACCESS_TOKEN")
                QUERY_USERS_ROLE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
                  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$REALM_MGMT_CLIENT_ID/roles/query-users" \
                  -H "Authorization: Bearer $ACCESS_TOKEN")
                
                # Assign roles to service account
                ROLES_TO_ASSIGN="[$MANAGE_USERS_ROLE, $VIEW_USERS_ROLE, $QUERY_USERS_ROLE]"
                ROLE_ASSIGN_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/role_assign.json -X POST \
                  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/users/$SERVICE_ACCOUNT_USER_ID/role-mappings/clients/$REALM_MGMT_CLIENT_ID" \
                  -H "Authorization: Bearer $ACCESS_TOKEN" \
                  -H "Content-Type: application/json" \
                  -d "$ROLES_TO_ASSIGN")
                
                if [ "$ROLE_ASSIGN_RESPONSE" = "204" ]; then
                    print_success "admin-portal service account granted user management roles"
                else
                    print_warning "Failed to assign roles to admin-portal service account (HTTP $ROLE_ASSIGN_RESPONSE)"
                fi
            else
                print_warning "realm-management client not found, skipping role assignment"
            fi
        else
            print_warning "Service account user not found for admin-portal client"
        fi
    fi
else
    print_status "Skipping admin-portal client configuration (OIDC secret not configured)"
fi

# Move offline_access from optional to default client scope for long-lived session apps
# Offline tokens survive SSO session expiry (30-day lifetime vs 10h SSO session max)
# Uses client object PUT (GET+modify+PUT) because the dedicated scope assignment endpoint
# (PUT .../default-client-scopes/{scopeId}) is unreliable in Keycloak 26 — returns 204
# but doesn't always persist. Updating defaultClientScopes in the client object is reliable.
print_status "Configuring offline_access as default scope for long-lived session clients..."

# Clients that need offline tokens for long-lived sessions
for CLIENT_NAME in nextcloud-app docs-app roundcube; do
    CLIENT_UUID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=$CLIENT_NAME" \
      -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id // empty')

    if [ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" = "null" ]; then
        print_status "Client $CLIENT_NAME not found, skipping offline_access scope update"
        continue
    fi

    # Get current client config, add offline_access to default scopes, remove from optional
    CLIENT_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    # Check if already in default scopes
    HAS_OFFLINE=$(echo "$CLIENT_CONFIG" | jq -r '.defaultClientScopes | index("offline_access") // empty')
    if [ -n "$HAS_OFFLINE" ]; then
        print_success "$CLIENT_NAME: offline_access already in default scopes"
        continue
    fi

    # Add to default, remove from optional via client object PUT
    # IMPORTANT: delete the secret field — GET returns a hashed/placeholder value,
    # and PUTting it back would overwrite the real secret with the hash
    UPDATED_CONFIG=$(echo "$CLIENT_CONFIG" | jq 'del(.secret) | .defaultClientScopes += ["offline_access"] | .optionalClientScopes -= ["offline_access"]')
    SCOPE_UPDATE_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /dev/null -X PUT \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$UPDATED_CONFIG")

    if [ "$SCOPE_UPDATE_RESPONSE" = "204" ]; then
        # Verify it actually persisted (Keycloak can return 204 without persisting)
        VERIFY=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID/default-client-scopes" \
          -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '[.[].name] | index("offline_access") // empty')
        if [ -n "$VERIFY" ]; then
            print_success "$CLIENT_NAME: offline_access set as default scope (verified)"
        else
            print_warning "$CLIENT_NAME: PUT returned 204 but offline_access not found in default scopes — retrying via scope endpoint"
            # Fallback: use the dedicated scope endpoint
            OFFLINE_ACCESS_SCOPE_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
              "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/client-scopes" \
              -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[] | select(.name == "offline_access") | .id // empty')
            if [ -n "$OFFLINE_ACCESS_SCOPE_ID" ]; then
                curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -o /dev/null -X PUT \
                  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID/default-client-scopes/$OFFLINE_ACCESS_SCOPE_ID" \
                  -H "Authorization: Bearer $ACCESS_TOKEN"
                curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -o /dev/null -X DELETE \
                  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID/optional-client-scopes/$OFFLINE_ACCESS_SCOPE_ID" \
                  -H "Authorization: Bearer $ACCESS_TOKEN"
                print_status "$CLIENT_NAME: retried via scope endpoint"
            fi
        fi
    else
        print_warning "$CLIENT_NAME: failed to update client (HTTP $SCOPE_UPDATE_RESPONSE)"
    fi
done

# Configure WebAuthn Passwordless authentication
print_status "Configuring WebAuthn Passwordless authentication..."

# Enable WebAuthn Passwordless required action
print_status "Enabling WebAuthn Passwordless required action..."
WEBAUTHN_RA_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/webauthn_ra.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/required-actions/webauthn-register-passwordless" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "alias": "webauthn-register-passwordless",
    "name": "Webauthn Register Passwordless",
    "providerId": "webauthn-register-passwordless",
    "enabled": true,
    "defaultAction": false,
    "priority": 70,
    "config": {}
  }')

if [ "$WEBAUTHN_RA_RESPONSE" = "204" ]; then
    print_success "WebAuthn Passwordless required action enabled"
else
    print_warning "Failed to enable WebAuthn Passwordless required action (HTTP $WEBAUTHN_RA_RESPONSE)"
    if [ -f /tmp/webauthn_ra.json ]; then
        print_warning "Details: $(cat /tmp/webauthn_ra.json)"
    fi
fi

# Update realm WebAuthn Passwordless policy
# SAFEGUARD: Check if RP ID would change - this would invalidate all existing passkeys!
print_status "Checking current WebAuthn RP ID..."
CURRENT_REALM_CONFIG=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN")
CURRENT_RP_ID=$(echo "$CURRENT_REALM_CONFIG" | jq -r '.webAuthnPolicyPasswordlessRpId // ""')

if [ -n "$CURRENT_RP_ID" ] && [ "$CURRENT_RP_ID" != "${EMAIL_DOMAIN}" ]; then
    print_error "==================================================================="
    print_error "CRITICAL: WebAuthn RP ID change detected!"
    print_error "==================================================================="
    print_error "Current RP ID: '$CURRENT_RP_ID'"
    print_error "New RP ID:     '${EMAIL_DOMAIN}'"
    print_error ""
    print_error "Changing the WebAuthn RP ID will PERMANENTLY INVALIDATE all"
    print_error "existing passkeys. Users will need to re-register their passkeys."
    print_error ""
    print_error "If you are CERTAIN you want to proceed, set:"
    print_error "  export FORCE_RPID_CHANGE=true"
    print_error "==================================================================="
    if [ "$FORCE_RPID_CHANGE" != "true" ]; then
        exit 1
    fi
    print_warning "FORCE_RPID_CHANGE=true is set, proceeding with RP ID change..."
elif [ -z "$CURRENT_RP_ID" ]; then
    print_status "No existing RP ID found (empty or not set), safe to set new value"
else
    print_status "RP ID unchanged: ${EMAIL_DOMAIN}"
fi

print_status "Updating WebAuthn Passwordless policy..."
print_status "Setting WebAuthn RP ID to: ${EMAIL_DOMAIN}"
WEBAUTHN_POLICY_UPDATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/webauthn_policy.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"webAuthnPolicyPasswordlessRpEntityName\": \"${TENANT_DISPLAY_NAME}\",
    \"webAuthnPolicyPasswordlessSignatureAlgorithms\": [\"ES256\", \"RS256\"],
    \"webAuthnPolicyPasswordlessRpId\": \"${EMAIL_DOMAIN}\",
    \"webAuthnPolicyPasswordlessAttestationConveyancePreference\": \"not specified\",
    \"webAuthnPolicyPasswordlessAuthenticatorAttachment\": \"not specified\",
    \"webAuthnPolicyPasswordlessRequireResidentKey\": \"Yes\",
    \"webAuthnPolicyPasswordlessUserVerificationRequirement\": \"required\",
    \"webAuthnPolicyPasswordlessCreateTimeout\": 0,
    \"webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister\": false
  }")

if [ "$WEBAUTHN_POLICY_UPDATE" = "204" ]; then
    print_success "WebAuthn Passwordless policy updated: RP ID = ${EMAIL_DOMAIN}"
else
    print_warning "Failed to update WebAuthn Passwordless policy (HTTP $WEBAUTHN_POLICY_UPDATE)"
    print_warning "Attempted RP ID: ${EMAIL_DOMAIN}"
    if [ -f /tmp/webauthn_policy.json ]; then
        print_warning "Details: $(cat /tmp/webauthn_policy.json)"
    fi
fi

# Create passkey-enabled browser flow
# This flow supports both passkey (WebAuthn Passwordless) and traditional password login for bootstrap
print_status "Configuring passkey-enabled browser flow..."

# Check if our custom flow already exists
PASSKEY_FLOW_EXISTS=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[] | select(.alias == "passkey browser") | .id // empty')

if [ -z "$PASSKEY_FLOW_EXISTS" ]; then
    print_status "Creating passkey browser flow..."
    
    # Copy the browser flow as a base
    COPY_FLOW_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/copy_flow.json -X POST \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows/browser/copy" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"newName": "passkey browser"}')
    
    if [ "$COPY_FLOW_RESPONSE" = "201" ]; then
        print_success "Created passkey browser flow from browser template"
        
        # Get the new flow ID
        PASSKEY_FLOW_ID=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows" \
          -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[] | select(.alias == "passkey browser") | .id')
        
        if [ -n "$PASSKEY_FLOW_ID" ]; then
            # Get the flow executions
            FLOW_EXECUTIONS=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
              "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows/passkey%20browser/executions" \
              -H "Authorization: Bearer $ACCESS_TOKEN")
            
            # Find the "passkey browser forms" subflow
            FORMS_SUBFLOW_ID=$(echo "$FLOW_EXECUTIONS" | jq -r '.[] | select(.displayName == "passkey browser forms") | .id // empty')
            
            if [ -n "$FORMS_SUBFLOW_ID" ]; then
                # Add WebAuthn Passwordless authenticator to the forms subflow
                print_status "Adding WebAuthn Passwordless authenticator to the flow..."
                
                ADD_WEBAUTHN_RESPONSE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/add_webauthn.json -X POST \
                  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows/passkey%20browser%20forms/executions/execution" \
                  -H "Authorization: Bearer $ACCESS_TOKEN" \
                  -H "Content-Type: application/json" \
                  -d '{"provider": "webauthn-authenticator-passwordless"}')
                
                if [ "$ADD_WEBAUTHN_RESPONSE" = "201" ]; then
                    print_success "Added WebAuthn Passwordless authenticator"
                    
                    # Get updated executions to find the new WebAuthn execution
                    UPDATED_EXECUTIONS=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} \
                      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows/passkey%20browser/executions" \
                      -H "Authorization: Bearer $ACCESS_TOKEN")
                    
                    # Find and set WebAuthn Passwordless as ALTERNATIVE
                    WEBAUTHN_EXEC_ID=$(echo "$UPDATED_EXECUTIONS" | jq -r '.[] | select(.providerId == "webauthn-authenticator-passwordless") | .id // empty')
                    
                    if [ -n "$WEBAUTHN_EXEC_ID" ]; then
                        curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -X PUT \
                          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows/passkey%20browser/executions" \
                          -H "Authorization: Bearer $ACCESS_TOKEN" \
                          -H "Content-Type: application/json" \
                          -d "{\"id\": \"$WEBAUTHN_EXEC_ID\", \"requirement\": \"ALTERNATIVE\"}" > /dev/null 2>&1
                        print_success "Set WebAuthn Passwordless as ALTERNATIVE authenticator"
                    fi
                    
                    # Also set the Username Password Form as ALTERNATIVE (for bootstrap)
                    USERNAME_PWD_EXEC_ID=$(echo "$UPDATED_EXECUTIONS" | jq -r '.[] | select(.providerId == "auth-username-password-form") | .id // empty')
                    
                    if [ -n "$USERNAME_PWD_EXEC_ID" ]; then
                        curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -X PUT \
                          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/authentication/flows/passkey%20browser/executions" \
                          -H "Authorization: Bearer $ACCESS_TOKEN" \
                          -H "Content-Type: application/json" \
                          -d "{\"id\": \"$USERNAME_PWD_EXEC_ID\", \"requirement\": \"ALTERNATIVE\"}" > /dev/null 2>&1
                        print_success "Set Username Password Form as ALTERNATIVE (for bootstrap)"
                    fi
                else
                    print_warning "Failed to add WebAuthn Passwordless authenticator (HTTP $ADD_WEBAUTHN_RESPONSE)"
                fi
            else
                print_warning "Could not find 'passkey browser forms' subflow"
            fi
            
            # Set the passkey browser flow as the realm's browser flow
            print_status "Setting passkey browser flow as realm default..."
            SET_BROWSER_FLOW=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/set_browser_flow.json -X PUT \
              "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
              -H "Authorization: Bearer $ACCESS_TOKEN" \
              -H "Content-Type: application/json" \
              -d '{"browserFlow": "passkey browser"}')
            
            if [ "$SET_BROWSER_FLOW" = "204" ]; then
                print_success "Set 'passkey browser' as realm default browser flow"
            else
                print_warning "Failed to set passkey browser flow as default (HTTP $SET_BROWSER_FLOW)"
            fi
        fi
    else
        print_warning "Failed to copy browser flow (HTTP $COPY_FLOW_RESPONSE)"
        if [ -f /tmp/copy_flow.json ]; then
            print_warning "Details: $(cat /tmp/copy_flow.json)"
        fi
    fi
else
    print_success "Passkey browser flow already exists"
    
    # Ensure it's set as the default browser flow
    print_status "Ensuring passkey browser flow is set as default..."
    SET_BROWSER_FLOW=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/set_browser_flow.json -X PUT \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"browserFlow": "passkey browser"}')
    
    if [ "$SET_BROWSER_FLOW" = "204" ]; then
        print_success "Confirmed 'passkey browser' as realm default browser flow"
    else
        print_warning "Failed to set passkey browser flow as default (HTTP $SET_BROWSER_FLOW)"
    fi
fi

# Set login and email themes to platform
print_status "Setting login and email themes to platform..."
THEME_UPDATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/theme_update.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"loginTheme": "platform", "emailTheme": "platform"}')

if [ "$THEME_UPDATE" = "204" ]; then
    print_success "Realm themes set to platform"
else
    print_warning "Failed to set realm themes (HTTP $THEME_UPDATE)"
    if [ -f /tmp/theme_update.json ]; then
        print_warning "Details: $(cat /tmp/theme_update.json)"
    fi
fi

# Create tenant-admin role if it doesn't exist
print_status "Ensuring tenant-admin role exists..."
TENANT_ADMIN_ROLE_CHECK=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/tenant_admin_role.json \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/roles/tenant-admin" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

if [ "$TENANT_ADMIN_ROLE_CHECK" = "404" ]; then
    print_status "Creating tenant-admin role..."
    TENANT_ADMIN_ROLE_CREATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/tenant_admin_role_create.json -X POST \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/roles" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "tenant-admin",
        "description": "Tenant administrator - can invite and manage users",
        "composite": false,
        "clientRole": false
      }')
    
    if [ "$TENANT_ADMIN_ROLE_CREATE" = "201" ]; then
        print_success "tenant-admin role created"
    else
        print_warning "Failed to create tenant-admin role (HTTP $TENANT_ADMIN_ROLE_CREATE)"
    fi
else
    print_success "tenant-admin role already exists"
fi

# Create guest-user role if it doesn't exist
print_status "Ensuring guest-user role exists..."
GUEST_USER_ROLE_CHECK=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/guest_user_role.json \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/roles/guest-user" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

if [ "$GUEST_USER_ROLE_CHECK" = "404" ]; then
    print_status "Creating guest-user role..."
    GUEST_USER_ROLE_CREATE=$(curl -s ${KEYCLOAK_SKIP_SSL_VERIFY} -w "%{http_code}" -o /tmp/guest_user_role_create.json -X POST \
      "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/roles" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "guest-user",
        "description": "External guest collaborator - limited access to shared resources only",
        "composite": false,
        "clientRole": false
      }')

    if [ "$GUEST_USER_ROLE_CREATE" = "201" ]; then
        print_success "guest-user role created"
    else
        print_warning "Failed to create guest-user role (HTTP $GUEST_USER_ROLE_CREATE)"
    fi
else
    print_success "guest-user role already exists"
fi

# Clean up temporary file
rm -f "$TEMP_CONFIG" "$TEMP_CONFIG.bak"

print_success "Keycloak realm configuration imported successfully!"
echo ""
echo "Next steps:"
echo "1. Visit https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/account"
echo "2. Verify 'Google' login option appears"
echo "3. Test Google OAuth flow by clicking 'Sign in with Google'"
echo "4. Verify user can authenticate and is redirected back to Keycloak"
echo ""
echo "Google OAuth Configuration:"
echo "  Client ID: $GOOGLE_CLIENT_ID"
echo "  Redirect URI: https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/broker/google/endpoint"
