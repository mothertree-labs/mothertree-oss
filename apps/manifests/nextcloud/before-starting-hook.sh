#!/bin/sh
# Nextcloud before-starting hook
# Runs on every pod start AFTER Nextcloud initialization but BEFORE Apache launches.
#
# Because /var/www/html is an emptyDir, every pod restart triggers a fresh
# Nextcloud install from the image. The user_oidc app re-initializes with its
# default allow_multiple_user_backends=1, which shows the native login form
# instead of auto-redirecting to Keycloak. This hook enforces OIDC-only login.

set -e

# Only run occ upgrade when the database actually needs it. Running upgrade
# unconditionally sets maintenance=true in the shared DB, which causes all
# other pods to return 503 during HPA scale-up (even when no upgrade is needed).
needs_upgrade=$(php /var/www/html/occ status --output=json 2>/dev/null \
  | grep -o '"needsDbUpgrade":true' || true)
if [ -n "$needs_upgrade" ]; then
    echo "[before-starting] DB upgrade needed — running occ upgrade..."
    php /var/www/html/occ upgrade --no-interaction 2>/dev/null || {
        echo "[before-starting] Warning: occ upgrade returned non-zero (may be first install)"
    }
else
    echo "[before-starting] No DB upgrade needed, skipping occ upgrade"
fi

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

# Install OIDC health check script (exec readiness probe uses this via CLI)
cp /docker-entrypoint-hooks.d/before-starting/oidc-health.php /var/www/html/oidc-health.php 2>/dev/null || true

echo "[before-starting] Done"
