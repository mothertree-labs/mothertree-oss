#!/bin/bash

# Mint per-user Nextcloud CalDAV app-passwords into the
# `calendar-automation-caldav-tokens` Secret.
#
# Nextcloud CalDAV is user-scoped — the admin account cannot read or write
# another user's calendar. calendar-automation therefore authenticates as each
# user via a per-user app-password. This module enumerates users (Nextcloud
# local + Keycloak OIDC), provisions any Keycloak users missing from Nextcloud,
# generates app-passwords in bulk, and stores them as a K8s Secret.
#
# This is the single source of truth for token minting. It is sourced by:
#   - apps/deploy-calendar-automation.sh  (normal deploy path — tolerant)
#   - ci/scripts/ci-deploy-app.sh         (CI re-mint after create-test-users)
#
# The function is behaviour-preserving relative to the original inline block in
# deploy-calendar-automation.sh: it warns (does not fail) when the Nextcloud pod
# is absent, when the Keycloak admin token can't be obtained, or when zero
# tokens are produced. Callers that require a hard guarantee (e.g. CI, where a
# specific user's token MUST be present) layer their own assertion on top.
#
# Required environment (set by the caller via mt_load_tenant_config + the
# deploy script preamble):
#   NS_FILES                  Nextcloud namespace (tn-<tenant>-files)
#   NS_MAIL                   calendar-automation namespace (tn-<tenant>-mail)
#   NEXTCLOUD_ADMIN_PASSWORD  Nextcloud admin password (from K8s secret)
#   KEYCLOAK_ADMIN_PASSWORD   Keycloak admin password (from tenant secrets)
#   AUTH_HOST                 Keycloak hostname (auth.<domain>)
#   TENANT_KEYCLOAK_REALM     Tenant realm name
#
# Requires: kubectl, jq (caller must have run mt_require_commands).

# mt_mint_caldav_tokens — enumerate users, provision into Nextcloud, mint
# per-user CalDAV app-passwords, and store them in the
# calendar-automation-caldav-tokens Secret in $NS_MAIL.
#
# Behaviour-preserving extraction of the original inline block from
# deploy-calendar-automation.sh. Returns 0 in all non-fatal cases (including
# "no Nextcloud pod" and "zero tokens"); only hard infra errors propagate.
mt_mint_caldav_tokens() {
    : "${NS_FILES:?mt_mint_caldav_tokens: NS_FILES required}"
    : "${NS_MAIL:?mt_mint_caldav_tokens: NS_MAIL required}"
    # NEXTCLOUD_ADMIN_PASSWORD is only used for the optional admin-password
    # drift-correction below (occ user:resetpassword, wrapped in `|| true`).
    # The actual token mint does NOT authenticate as admin (occ user:add runs
    # as root in-container; create-caldav-tokens.php runs as www-data). The
    # normal deploy path (deploy-calendar-automation.sh) still fails fast on
    # this secret upstream before calling us; the CI re-mint path may legitly
    # lack it (the drift-correction already ran at calendar deploy time), so
    # it is soft-guarded rather than required here.
    NEXTCLOUD_ADMIN_PASSWORD="${NEXTCLOUD_ADMIN_PASSWORD:-}"

    print_status "Creating per-user CalDAV app passwords..."

    mt_require_commands jq

    local NEXTCLOUD_POD
    NEXTCLOUD_POD=$(kubectl get pods -n "$NS_FILES" -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$NEXTCLOUD_POD" ]; then
        print_warning "Nextcloud pod not found in $NS_FILES, skipping CalDAV token creation"
        return 0
    fi

    # Ensure admin password matches K8s secret (may drift after Helm upgrades).
    # Optional: only attempt when we actually have the password. The token mint
    # below does not authenticate as admin, so skipping this is harmless (and on
    # the CI re-mint path the calendar deploy already did this minutes earlier).
    if [ -n "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
            env "OC_PASS=${NEXTCLOUD_ADMIN_PASSWORD}" php occ user:resetpassword --password-from-env admin 2>/dev/null || true
    else
        print_warning "NEXTCLOUD_ADMIN_PASSWORD not set — skipping admin password drift-correction (not required for token mint)"
    fi

    # -------------------------------------------------------------------------
    # Provision Keycloak users into Nextcloud
    # -------------------------------------------------------------------------
    # Nextcloud only creates user principals on first OIDC web login. Users that
    # exist in Keycloak but have never logged into Nextcloud (e.g. CI mail users)
    # won't have CalDAV principals, so calendar-automation can't create calendars
    # for them. Pre-provision them here so CalDAV tokens can be created below.
    local KC_TOKEN=""
    local KEYCLOAK_URL=""
    local KC_EMAILS=""
    if [ -n "${KEYCLOAK_ADMIN_PASSWORD:-}" ] && [ -n "${AUTH_HOST:-}" ] && [ -n "${TENANT_KEYCLOAK_REALM:-}" ]; then
        KEYCLOAK_URL="https://${AUTH_HOST}"
        KC_TOKEN=$(curl -sf --connect-timeout 10 --max-time 15 -X POST \
          "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
          --data-urlencode "username=admin" \
          --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
          --data-urlencode "grant_type=password" \
          --data-urlencode "client_id=admin-cli" | \
          jq -r '.access_token // empty' 2>/dev/null) || true
    fi

    if [ -n "$KC_TOKEN" ]; then
        KC_EMAILS=$(curl -sf --connect-timeout 10 --max-time 15 \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/users?max=500" \
          -H "Authorization: Bearer $KC_TOKEN" | \
          jq -r '.[] | select(.email != null) | .email' 2>/dev/null || echo "")

        local NC_EXISTING
        NC_EXISTING=$(kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
            php occ user:list --output=json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")

        local PROVISIONED=0
        local kc_email RAND_PASS
        while IFS= read -r kc_email; do
            [ -z "$kc_email" ] && continue
            # Validate email format (defense-in-depth against injection via crafted Keycloak data)
            if ! [[ "$kc_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$ ]]; then
                print_warning "Skipping invalid email from Keycloak: $kc_email"
                continue
            fi
            # Skip if already in Nextcloud
            if echo "$NC_EXISTING" | grep -qxF "$kc_email"; then
                continue
            fi
            # Provision with a random password (OIDC handles real auth)
            RAND_PASS=$(openssl rand -base64 32)
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
                env "OC_PASS=$RAND_PASS" \
                php occ user:add --password-from-env --display-name "$kc_email" -- "$kc_email" 2>/dev/null && \
                PROVISIONED=$((PROVISIONED + 1)) || \
                print_warning "Failed to provision Nextcloud user: $kc_email"
        done <<< "$KC_EMAILS"

        if [ "$PROVISIONED" -gt 0 ]; then
            print_success "Provisioned $PROVISIONED Keycloak user(s) into Nextcloud"
        fi
    else
        print_warning "Could not get Keycloak admin token — skipping user provisioning into Nextcloud"
    fi

    # Build combined user list: occ user:list (local users) + Keycloak emails (OIDC users).
    # occ user:list doesn't enumerate OIDC-backend users, so we merge both sources
    # to ensure CalDAV tokens are created for all users regardless of backend.
    local NC_USER_JSON NC_EMAILS USER_EMAILS_JSON
    NC_USER_JSON=$(kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
        php occ user:list --output=json 2>/dev/null || echo "{}")
    NC_EMAILS=$(echo "$NC_USER_JSON" | jq -r 'keys[] | select(. != "admin")' 2>/dev/null || echo "")
    USER_EMAILS_JSON=$(printf '%s\n%s' "$NC_EMAILS" "${KC_EMAILS:-}" | sort -u | grep -v '^$' | jq -R . | jq -s . || echo "[]")

    # Create app passwords in bulk via create-caldav-tokens.php.
    # This uses Nextcloud's ITokenProvider::generateToken() directly, bypassing
    # occ user:auth-tokens:add which requires allow_multiple_user_backends=1.
    # Single PHP process, single kubectl exec, ~30s for 550 users instead of ~6min.
    # Critically: allow_multiple_user_backends is never toggled, so the readiness
    # probe (oidc-health.php) is never poisoned and no NextcloudDown alert fires.
    local CALDAV_TOKENS TOKEN_COUNT
    CALDAV_TOKENS=$(echo "$USER_EMAILS_JSON" | kubectl exec -i -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
        su -s /bin/sh www-data -c 'php /docker-entrypoint-hooks.d/before-starting/create-caldav-tokens.php calendar-automation' 2>/dev/null || echo "{}")
    TOKEN_COUNT=$(echo "$CALDAV_TOKENS" | jq 'length' 2>/dev/null || echo "0")

    if [ "$TOKEN_COUNT" -eq 0 ]; then
        print_warning "No CalDAV tokens were created — calendar-automation will not be able to access user calendars"
    fi

    # Store tokens as a Secret (mounted read-only in the calendar-automation pod)
    kubectl create secret generic calendar-automation-caldav-tokens \
        --namespace="$NS_MAIL" \
        --from-literal=caldav-tokens.json="$CALDAV_TOKENS" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "CalDAV app passwords created for $TOKEN_COUNT user(s)"

    # Export for callers that want to layer assertions / restarts on top.
    MT_CALDAV_TOKEN_COUNT="$TOKEN_COUNT"
    export MT_CALDAV_TOKEN_COUNT
}
