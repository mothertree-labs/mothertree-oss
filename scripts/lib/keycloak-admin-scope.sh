#!/usr/bin/env bash
# Keycloak admin-API audience scope (CVE-2026-19688, Keycloak 26.8.2+).
#
# From 26.8.2 on, the Admin REST API only accepts bearer tokens whose audience
# names the realm's admin API. A client_credentials token carries that
# audience only when its client has the built-in `kc-admin-api` client scope
# as a default scope. The 26.8.2 migration creates that scope in every realm,
# but attaches it to no client and leaves it out of the realm's default
# scopes, so after the upgrade every service-account call from the portals
# (admin-portal, account-portal) and the CI user scripts gets HTTP 401
# ("Expected audience not available in the token" in Keycloak's debug log).
#
# This library attaches the scope to the named clients and reads it back.
# It is transport-agnostic: the caller defines three functions before calling
# mt_kc_ensure_admin_api_scope:
#
#   mt_kc_get <realm> <path>   print the JSON of GET /admin/realms/<realm>/<path>;
#                              non-zero on any error
#   mt_kc_put <realm> <path>   PUT /admin/realms/<realm>/<path> with no body;
#                              non-zero on any error
#   mt_kc_version              print the server version (e.g. 26.8.2)
#
# deploy_infra uses kcadm.sh inside the Keycloak pod; setup-admin-portal-client
# uses curl against the public auth host. Unit tests:
# scripts/lib/tests/keycloak-admin-scope.test.sh.

MT_KC_ADMIN_API_SCOPE="kc-admin-api"
# First Keycloak release that enforces the admin-API audience.
MT_KC_ADMIN_API_SCOPE_SINCE="26.8.2"

# _mt_kc_version_ge <a> <b>: true when version a >= version b. Numeric
# major.minor.patch; anything after the patch number (e.g. -SNAPSHOT) is ignored.
_mt_kc_version_ge() {
    local a="$1" b="$2" i x y
    local -a av bv
    IFS=. read -r -a av <<< "${a%%-*}"
    IFS=. read -r -a bv <<< "${b%%-*}"
    for i in 0 1 2; do
        x="${av[$i]:-0}"; y="${bv[$i]:-0}"
        if ! [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
            return 2
        fi
        if [ "$x" -gt "$y" ]; then return 0; fi
        if [ "$x" -lt "$y" ]; then return 1; fi
    done
    return 0
}

# mt_kc_ensure_admin_api_scope [--if-present] <realm> <clientId>...
#
# Attaches kc-admin-api as a default client scope of every named client, then
# verifies it is attached. Idempotent.
#
# Without --if-present every named client must exist in the realm (the caller
# has just created them). With --if-present, clients absent from the realm are
# skipped: deploy_infra sweeps every realm on the server and the clients that
# exist are exactly the ones that make admin-API calls.
#
# If the realm has no kc-admin-api scope, that is only acceptable on a
# Keycloak older than 26.8.2 (nothing to do); on 26.8.2+ it is an error.
mt_kc_ensure_admin_api_scope() {
    local if_present=false
    if [ "${1:-}" = "--if-present" ]; then if_present=true; shift; fi
    local realm="${1:?mt_kc_ensure_admin_api_scope: realm required}"; shift
    if [ $# -eq 0 ]; then
        print_error "mt_kc_ensure_admin_api_scope: at least one clientId required"
        return 1
    fi

    local scopes scope_id
    scopes=$(mt_kc_get "$realm" "client-scopes") || {
        print_error "Could not list client scopes in realm ${realm}"
        return 1
    }
    scope_id=$(jq -r --arg n "$MT_KC_ADMIN_API_SCOPE" \
        '[.[] | select(.name == $n)][0].id // ""' <<< "$scopes") || {
        print_error "Unparseable client-scope list from realm ${realm}"
        return 1
    }

    if [ -z "$scope_id" ]; then
        local version rc
        version=$(mt_kc_version) || {
            print_error "Realm ${realm} has no ${MT_KC_ADMIN_API_SCOPE} scope and the Keycloak version could not be read"
            return 1
        }
        _mt_kc_version_ge "$version" "$MT_KC_ADMIN_API_SCOPE_SINCE"; rc=$?
        case "$rc" in
            1)
                print_status "Keycloak ${version} predates the admin-API audience check; ${MT_KC_ADMIN_API_SCOPE} not needed in realm ${realm}"
                return 0 ;;
            0)
                print_error "Keycloak ${version} enforces the admin-API audience but realm ${realm} has no ${MT_KC_ADMIN_API_SCOPE} client scope"
                return 1 ;;
            *)
                print_error "Unrecognised Keycloak version '${version}'"
                return 1 ;;
        esac
    fi

    local client clients client_id defaults
    for client in "$@"; do
        clients=$(mt_kc_get "$realm" "clients?clientId=${client}") || {
            print_error "Could not look up client ${client} in realm ${realm}"
            return 1
        }
        # Match the clientId exactly: never trust .[0] to be the client asked
        # for (a dropped query string would return every client in the realm).
        client_id=$(jq -r --arg c "$client" \
            '[.[] | select(.clientId == $c)][0].id // ""' <<< "$clients") || {
            print_error "Unparseable client lookup for ${client} in realm ${realm}"
            return 1
        }
        if [ -z "$client_id" ]; then
            if [ "$if_present" = true ]; then
                continue
            fi
            print_error "Client ${client} not found in realm ${realm}"
            return 1
        fi

        defaults=$(mt_kc_get "$realm" "clients/${client_id}/default-client-scopes") || {
            print_error "Could not read default scopes of ${client} in realm ${realm}"
            return 1
        }
        if jq -e --arg n "$MT_KC_ADMIN_API_SCOPE" 'any(.[]; .name == $n)' <<< "$defaults" > /dev/null; then
            print_status "${client} (${realm}) already has ${MT_KC_ADMIN_API_SCOPE}"
            continue
        fi

        mt_kc_put "$realm" "clients/${client_id}/default-client-scopes/${scope_id}" || {
            print_error "Could not attach ${MT_KC_ADMIN_API_SCOPE} to ${client} in realm ${realm}"
            return 1
        }
        defaults=$(mt_kc_get "$realm" "clients/${client_id}/default-client-scopes") || {
            print_error "Could not re-read default scopes of ${client} in realm ${realm}"
            return 1
        }
        if ! jq -e --arg n "$MT_KC_ADMIN_API_SCOPE" 'any(.[]; .name == $n)' <<< "$defaults" > /dev/null; then
            print_error "${MT_KC_ADMIN_API_SCOPE} still missing from ${client} in realm ${realm} after attaching it"
            return 1
        fi
        print_success "Attached ${MT_KC_ADMIN_API_SCOPE} to ${client} (${realm})"
    done
}
