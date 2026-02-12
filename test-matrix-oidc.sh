#!/bin/bash

# Test script to verify Matrix OIDC integration
# This script tests the OIDC authentication flow
#
# Usage: MATRIX_HOST=matrix.example.org AUTH_HOST=auth.example.org ./test-matrix-oidc.sh
# Or source create_env first which sets these variables

set -e

# Use environment variables or defaults
MATRIX_HOST="${MATRIX_HOST:-matrix.${TENANT_DOMAIN:-example.org}}"
AUTH_HOST="${AUTH_HOST:-auth.${TENANT_DOMAIN:-example.org}}"
KEYCLOAK_REALM="${TENANT_KEYCLOAK_REALM:-docs}"

echo "Testing Matrix OIDC Integration..."
echo "=================================="
echo "Matrix: https://$MATRIX_HOST"
echo "Auth:   https://$AUTH_HOST/realms/$KEYCLOAK_REALM"
echo ""

# Test 1: Check if Matrix server is accessible
echo "1. Testing Matrix server accessibility..."
MATRIX_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "https://$MATRIX_HOST/_matrix/client/versions")
if [ "$MATRIX_RESPONSE" = "200" ]; then
    echo "✅ Matrix server is accessible"
else
    echo "❌ Matrix server is not accessible (HTTP $MATRIX_RESPONSE)"
    exit 1
fi

# Test 2: Check if OIDC endpoint is configured
echo "2. Testing OIDC endpoint configuration..."
OIDC_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "https://$MATRIX_HOST/_synapse/client/oidc")
if [ "$OIDC_RESPONSE" = "405" ]; then
    echo "✅ OIDC endpoint is configured (405 Method Not Allowed is expected for GET)"
else
    echo "❌ OIDC endpoint not properly configured (HTTP $OIDC_RESPONSE)"
    exit 1
fi

# Test 3: Check if Keycloak is accessible
echo "3. Testing Keycloak accessibility..."
KEYCLOAK_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "https://$AUTH_HOST/realms/$KEYCLOAK_REALM")
if [ "$KEYCLOAK_RESPONSE" = "200" ]; then
    echo "✅ Keycloak is accessible"
else
    echo "❌ Keycloak is not accessible (HTTP $KEYCLOAK_RESPONSE)"
    exit 1
fi

# Test 4: Check if Matrix client exists in Keycloak
echo "4. Testing Matrix client in Keycloak..."
KEYCLOAK_CLIENT_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "https://$AUTH_HOST/realms/$KEYCLOAK_REALM/protocol/openid-connect/auth?client_id=matrix-synapse&response_type=code&redirect_uri=https://$MATRIX_HOST/_synapse/client/oidc/callback&scope=openid%20profile%20email")
if [ "$KEYCLOAK_CLIENT_RESPONSE" = "200" ]; then
    echo "✅ Matrix client is configured in Keycloak"
else
    echo "❌ Matrix client not found in Keycloak (HTTP $KEYCLOAK_CLIENT_RESPONSE)"
    exit 1
fi

echo ""
echo "🎉 All tests passed! Matrix OIDC integration is working."
echo ""
echo "Next steps:"
echo "1. Open Element Web at: https://$MATRIX_HOST"
echo "2. Click 'Sign in with SSO' or 'Sign in with Google'"
echo "3. You should be redirected to Keycloak for Google authentication"
echo "4. After Google authentication, you'll be redirected back to Matrix"
echo ""
echo "Authentication flow:"
echo "Matrix → Keycloak → Google → Keycloak → Matrix"
