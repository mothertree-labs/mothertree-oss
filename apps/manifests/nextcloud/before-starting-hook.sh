#!/bin/sh
# Nextcloud before-starting hook
# Runs on every pod start AFTER Nextcloud initialization but BEFORE Apache launches.
#
# Because /var/www/html is an emptyDir, every pod restart triggers a fresh
# Nextcloud install from the image. The user_oidc app re-initializes with its
# default allow_multiple_user_backends=1, which shows the native login form
# instead of auto-redirecting to Keycloak. This hook enforces OIDC-only login.

set -e

# Run occ upgrade to reconcile app version mismatches between the filesystem
# and database. This is critical for HPA scale-up: the custom-apps ConfigMap
# may contain an older app version than what was auto-updated on the first pod.
# Without this, Nextcloud returns 503 ("Update needed") because needUpgrade()
# detects the mismatch. Safe to run when nothing needs upgrading (no-op).
echo "[before-starting] Running occ upgrade (reconcile app versions)..."
php /var/www/html/occ upgrade --no-interaction 2>/dev/null || {
    echo "[before-starting] Warning: occ upgrade returned non-zero (may be first install)"
}

echo "[before-starting] Enforcing OIDC-only login (allow_multiple_user_backends=0)..."
php /var/www/html/occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends 2>/dev/null || {
    echo "[before-starting] Warning: could not set allow_multiple_user_backends (user_oidc may not be installed yet)"
}

# Disable sharebymail to prevent unauthenticated public links via email shares (Issue #119).
# The Bitnami image ships with sharebymail enabled by default, so pod restarts re-enable it.
echo "[before-starting] Disabling sharebymail (prevents unauthenticated email share links)..."
php /var/www/html/occ app:disable sharebymail 2>/dev/null || {
    echo "[before-starting] Warning: could not disable sharebymail"
}

# Defense-in-depth: enforce share security policies on public link shares
echo "[before-starting] Enforcing share security policies..."
php /var/www/html/occ config:app:set core shareapi_enforce_links_password --value='yes' 2>/dev/null || true
php /var/www/html/occ config:app:set core shareapi_default_expire_date --value='yes' 2>/dev/null || true
php /var/www/html/occ config:app:set core shareapi_expire_after_n_days --value='30' 2>/dev/null || true
php /var/www/html/occ config:app:set core shareapi_enforce_expire_date --value='yes' 2>/dev/null || true
php /var/www/html/occ config:app:set core shareapi_default_permissions --value='1' 2>/dev/null || true

echo "[before-starting] Done"
