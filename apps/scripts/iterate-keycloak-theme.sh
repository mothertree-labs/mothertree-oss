#!/bin/bash

# Convenience script for rapid Keycloak theme iteration
# Syncs theme changes and provides quick access to test the login page
#
# Usage: ./apps/scripts/iterate-keycloak-theme.sh [dev|prod]
#        Defaults to 'dev' if not specified

set -euo pipefail

ENVIRONMENT="${1:-dev}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    echo "Error: Environment must be 'dev' or 'prod'" >&2
    echo "Usage: $0 [dev|prod]" >&2
    exit 1
fi

REPO_ROOT="${REPO_ROOT:-/workspace}"
SCRIPT_DIR="$REPO_ROOT/apps/scripts"

echo "🔄 Iterating on Keycloak theme (env=$ENVIRONMENT)"
echo ""

# Run the sync script
MT_ENV="$ENVIRONMENT" "$SCRIPT_DIR/sync-keycloak-theme.sh"

echo ""
echo "✅ Theme sync complete!"
echo ""
echo "To test the login page:"
echo "  https://${AUTH_HOST:-auth.\$TENANT_DOMAIN}/realms/${TENANT_KEYCLOAK_REALM:-docs}/account"
echo ""
echo "To make changes:"
echo "  1. Edit files in: $REPO_ROOT/apps/themes/platform/"
echo "  2. Run this script again: $0 $ENVIRONMENT"
echo ""
