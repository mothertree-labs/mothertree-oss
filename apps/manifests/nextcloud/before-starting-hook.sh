#!/bin/sh
# Nextcloud before-starting hook
# Runs on every pod start AFTER Nextcloud initialization but BEFORE Apache launches.
#
# Because /var/www/html is an emptyDir, every pod restart triggers a fresh
# Nextcloud install from the image. The user_oidc app re-initializes with its
# default allow_multiple_user_backends=1, which shows the native login form
# instead of auto-redirecting to Keycloak. This hook enforces OIDC-only login.

set -e

# Guard: skip if Nextcloud isn't fully installed yet (first boot race condition).
# The entrypoint generates config.php from env vars, but the app may not be
# fully bootstrapped when this hook runs on a fresh emptyDir pod.
if ! php /var/www/html/occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
    echo "[before-starting] Nextcloud not yet installed, skipping hook (will run on next restart)"
    exit 0
fi

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

# Set overwrite.cli.url and regenerate .htaccess for pretty URLs.
# Without this, Apache returns 404 for /apps/calendar and any rewrite-dependent path.
# Must run on every pod start because /var/www/html is an emptyDir.
# NEXTCLOUD_INIT_HTACCESS is disabled in the entrypoint (fails before bootstrap completes),
# so we do it here where the app is already installed.
FILES_HOST=$(echo "${NEXTCLOUD_TRUSTED_DOMAINS:-}" | awk '{print $1}')
if [ -n "$FILES_HOST" ]; then
    echo "[before-starting] Configuring pretty URLs (overwrite.cli.url=https://$FILES_HOST)..."
    php /var/www/html/occ config:system:set overwrite.cli.url --value="https://$FILES_HOST" 2>/dev/null && \
    php /var/www/html/occ maintenance:update:htaccess 2>/dev/null && \
    echo "[before-starting] .htaccess updated for pretty URLs" || \
    echo "[before-starting] Warning: failed to update .htaccess (non-critical)"
else
    echo "[before-starting] Warning: NEXTCLOUD_TRUSTED_DOMAINS not set, skipping .htaccess update"
fi

echo "[before-starting] Enforcing OIDC-only login (allow_multiple_user_backends=0)..."
php /var/www/html/occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends 2>/dev/null || {
    echo "[before-starting] Warning: could not set allow_multiple_user_backends (user_oidc may not be installed yet)"
}

# Enable guest_bridge + sharebymail together. sharebymail provides the TYPE_EMAIL share
# provider; guest_bridge suppresses sharebymail's notification emails (no unauthenticated
# links sent). guest_bridge MUST be enabled first to avoid a window where sharebymail
# sends unauthenticated link emails without suppression.
echo "[before-starting] Enabling guest_bridge + sharebymail (email shares with guest provisioning)..."
php /var/www/html/occ app:enable guest_bridge 2>/dev/null || {
    echo "[before-starting] Warning: could not enable guest_bridge"
}
php /var/www/html/occ app:enable sharebymail 2>/dev/null || {
    echo "[before-starting] Warning: could not enable sharebymail"
}

# Configure guest_bridge API settings from env vars (injected from K8s secret).
# occ config:system:set writes to per-pod config.php, so this MUST run on every pod.
if [ -n "${GUEST_BRIDGE_API_URL:-}" ] && [ -n "${GUEST_BRIDGE_API_KEY:-}" ]; then
    echo "[before-starting] Configuring guest_bridge API settings..."
    php /var/www/html/occ config:system:set guest_bridge.api_url --value="$GUEST_BRIDGE_API_URL" 2>/dev/null || {
        echo "[before-starting] Warning: could not set guest_bridge.api_url"
    }
    php /var/www/html/occ config:system:set guest_bridge.api_key --value="$GUEST_BRIDGE_API_KEY" >/dev/null 2>/dev/null || {
        echo "[before-starting] Warning: could not set guest_bridge.api_key"
    }
    echo "[before-starting] guest_bridge API configured"
else
    echo "[before-starting] Warning: GUEST_BRIDGE_API_URL or GUEST_BRIDGE_API_KEY not set, guest provisioning disabled"
fi

echo "[before-starting] Configuring share security policies..."
# shareapi_allow_links must be 'yes' — Nextcloud's TYPE_EMAIL shares (sharebymail)
# are internally link-based and fail with 404 when links are disabled.
# Security is handled by guest_bridge (intercepts shares, provisions guests via passkeys).
php /var/www/html/occ config:app:set core shareapi_allow_links --value='yes' 2>/dev/null || true
# No password enforcement needed (email shares use passkeys via guest_bridge)
php /var/www/html/occ config:app:set core shareapi_enforce_links_password --value='no' 2>/dev/null || true
# Suggest 30-day expiry by default but don't enforce it
php /var/www/html/occ config:app:set core shareapi_default_expire_date --value='yes' 2>/dev/null || true
php /var/www/html/occ config:app:set core shareapi_expire_after_n_days --value='30' 2>/dev/null || true
php /var/www/html/occ config:app:set core shareapi_enforce_expire_date --value='no' 2>/dev/null || true
php /var/www/html/occ config:app:set core shareapi_default_permissions --value='1' 2>/dev/null || true

# Disable server-to-server (federated) sharing. federatedfilesharing is an always-enabled
# core app that cannot be disabled via app:disable. When federation is enabled (the default),
# the sharing UI offers BOTH "Email" (TYPE_EMAIL=4) and "Federated" (TYPE_REMOTE=6) options
# for user@domain inputs. If the user picks federated (or the UI defaults to it for certain
# inputs), the share bypasses guest_bridge entirely and fails with "could not find user@domain".
# This was the root cause of repeated sharing failures (PRs #155, #157, #159, #163).
# Setting these to 'no' removes federated options from the UI so all external sharing goes
# through the email/guest_bridge pipeline.
php /var/www/html/occ config:app:set files_sharing outgoing_server2server_share_enabled --value='no' 2>/dev/null || true
php /var/www/html/occ config:app:set files_sharing incoming_server2server_share_enabled --value='no' 2>/dev/null || true
php /var/www/html/occ config:app:set files_sharing outgoing_server2server_group_share_enabled --value='no' 2>/dev/null || true
php /var/www/html/occ config:app:set files_sharing incoming_server2server_group_share_enabled --value='no' 2>/dev/null || true

# Patch user_oidc Safari workaround for Login Flow v2 compatibility.
# user_oidc PR #358 added a meta-refresh redirect for Safari to preserve PHP sessions.
# But iOS Nextcloud app's Login Flow v2 uses ASWebAuthenticationSession which doesn't
# process <meta http-equiv="refresh">. The redirect to Keycloak never happens, and
# the user sees "Forbidden". Skip the workaround for Login Flow v2 requests (identified
# by redirectUrl containing /login/v2/) — they use token-based auth, not cookies.
LOGIN_CONTROLLER="/var/www/html/custom_apps/user_oidc/lib/Controller/LoginController.php"
if [ -f "$LOGIN_CONTROLLER" ]; then
    if grep -q "isUserAgent.*Safari.*DataDisplayResponse.*meta http-equiv" "$LOGIN_CONTROLLER" 2>/dev/null; then
        echo "[before-starting] Patching user_oidc Safari workaround for Login Flow v2..."
        sed -i 's|if ($this->request->isUserAgent(\['"'"'/Safari/'"'"'\]) \&\& !$this->request->isUserAgent(\['"'"'/Chrome/'"'"'\])) {|$isLoginFlowV2 = $redirectUrl !== null \&\& str_contains($redirectUrl, '"'"'/login/v2/'"'"');\n\t\tif (!$isLoginFlowV2 \&\& $this->request->isUserAgent(['"'"'/Safari/'"'"']) \&\& !$this->request->isUserAgent(['"'"'/Chrome/'"'"'])) {|' "$LOGIN_CONTROLLER"
        echo "[before-starting] user_oidc Login Flow v2 patch applied"
    else
        echo "[before-starting] user_oidc Safari workaround already patched or not found, skipping"
    fi
else
    echo "[before-starting] user_oidc not installed yet, skipping Login Flow v2 patch"
fi

# Install OIDC health check script (exec readiness probe uses this via CLI)
cp /docker-entrypoint-hooks.d/before-starting/oidc-health.php /var/www/html/oidc-health.php 2>/dev/null || true

echo "[before-starting] Done"
