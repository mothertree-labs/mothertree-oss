#!/bin/sh
# Nextcloud before-starting hook
# Runs on every pod start AFTER Nextcloud initialization but BEFORE Apache launches.
#
# Because /var/www/html is an emptyDir, every pod restart triggers a fresh
# Nextcloud install from the image. The user_oidc app re-initializes with its
# default allow_multiple_user_backends=1, which shows the native login form
# instead of auto-redirecting to Keycloak. This hook enforces OIDC-only login.

set -e

echo "[before-starting] Enforcing OIDC-only login (allow_multiple_user_backends=0)..."
php /var/www/html/occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends 2>/dev/null || {
    echo "[before-starting] Warning: could not set allow_multiple_user_backends (user_oidc may not be installed yet)"
}

echo "[before-starting] Done"
