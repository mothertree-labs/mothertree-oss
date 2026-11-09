#!/usr/bin/env bash
# Unit tests for scripts/lib/keycloak-admin-scope.sh (CVE-2026-19688: Keycloak
# 26.8.2's admin-API audience check). The Keycloak transport (mt_kc_get /
# mt_kc_put / mt_kc_version) is a fake backed by files, because the library
# calls it inside $(...) subshells. Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "$HERE/../common.sh"
# shellcheck source=../keycloak-admin-scope.sh
source "$HERE/../keycloak-admin-scope.sh"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# State: $TMP/<realm>/scopes.json, $TMP/<realm>/client-<clientId> (holds the
# uuid), $TMP/<realm>/defaults-<uuid>.json; $TMP/version; $TMP/puts (log);
# $TMP/put-noop (PUT succeeds but changes nothing); $TMP/get-fail-<path-glob>.
reset() {
    rm -rf "${TMP:?}"/*
    echo "26.8.2" > "$TMP/version"
    : > "$TMP/puts"
}
add_realm() {  # add_realm <realm> <with-scope:true|false>
    mkdir -p "$TMP/$1"
    if [ "$2" = true ]; then
        echo '[{"id":"s-basic","name":"basic"},{"id":"s-admin","name":"kc-admin-api"}]' > "$TMP/$1/scopes.json"
    else
        echo '[{"id":"s-basic","name":"basic"}]' > "$TMP/$1/scopes.json"
    fi
}
add_client() {  # add_client <realm> <clientId> <has-scope:true|false>
    local uuid="u-$2"
    echo "$uuid" > "$TMP/$1/client-$2"
    if [ "$3" = true ]; then
        echo '[{"id":"s-basic","name":"basic"},{"id":"s-admin","name":"kc-admin-api"}]' > "$TMP/$1/defaults-$uuid.json"
    else
        echo '[{"id":"s-basic","name":"basic"}]' > "$TMP/$1/defaults-$uuid.json"
    fi
}
mt_kc_get() {
    local realm="$1" path="$2"
    [ -d "$TMP/$realm" ] || return 1
    [ -e "$TMP/get-fail" ] && [ "$(cat "$TMP/get-fail")" = "$path" ] && return 1
    case "$path" in
        client-scopes) cat "$TMP/$realm/scopes.json" ;;
        clients\?clientId=*)
            local c="${path#clients?clientId=}"
            if [ -e "$TMP/query-ignored" ]; then
                # Server ignored the query: every client, the wanted one not first.
                printf '[{"id":"u-broker","clientId":"broker"}'
                for f in "$TMP/$realm"/client-*; do
                    [ -f "$f" ] && printf ',{"id":"%s","clientId":"%s"}' "$(cat "$f")" "${f##*/client-}"
                done
                echo ']'
            elif [ -f "$TMP/$realm/client-$c" ]; then
                printf '[{"id":"%s","clientId":"%s"}]\n' "$(cat "$TMP/$realm/client-$c")" "$c"
            else
                echo '[]'
            fi ;;
        clients/*/default-client-scopes)
            local uuid="${path#clients/}"; uuid="${uuid%/default-client-scopes}"
            cat "$TMP/$realm/defaults-$uuid.json" ;;
        *) return 1 ;;
    esac
}
mt_kc_put() {
    local realm="$1" path="$2"
    echo "$realm $path" >> "$TMP/puts"
    [ -e "$TMP/put-fail" ] && return 1
    [ -e "$TMP/put-noop" ] && return 0
    local uuid="${path#clients/}"; uuid="${uuid%%/*}"
    local sid="${path##*/}"
    local f="$TMP/$realm/defaults-$uuid.json"
    jq --arg id "$sid" '. + [{"id":$id,"name":"kc-admin-api"}]' "$f" > "$f.new" && mv "$f.new" "$f"
}
mt_kc_version() { [ -e "$TMP/version-fail" ] && return 1; cat "$TMP/version"; }

has_scope() { jq -r 'any(.[]; .name == "kc-admin-api")' "$TMP/$1/defaults-u-$2.json"; }
puts() { wc -l < "$TMP/puts" | tr -d ' '; }

# --- version compare --------------------------------------------------------
_mt_kc_version_ge 26.8.2 26.8.2; check "ge equal" 0 $?
_mt_kc_version_ge 26.8.10 26.8.2; check "ge numeric not lexical" 0 $?
_mt_kc_version_ge 26.9.0 26.8.2; check "ge minor" 0 $?
_mt_kc_version_ge 27.0.0 26.8.2; check "ge major" 0 $?
_mt_kc_version_ge 26.8.1 26.8.2; check "lt patch" 1 $?
_mt_kc_version_ge 26.7.4 26.8.2; check "lt minor" 1 $?
_mt_kc_version_ge 26.8.2-SNAPSHOT 26.8.2; check "suffix ignored" 0 $?
_mt_kc_version_ge 26 26.8.2; check "short version" 1 $?
_mt_kc_version_ge garbage 26.8.2; check "garbage" 2 $?

# --- attaches to both clients and verifies ----------------------------------
reset; add_realm t true; add_client t admin-portal false; add_client t account-portal false
mt_kc_ensure_admin_api_scope t admin-portal account-portal > /dev/null 2>&1; check "attach rc" 0 $?
check "admin-portal attached" true "$(has_scope t admin-portal)"
check "account-portal attached" true "$(has_scope t account-portal)"
check "two PUTs" 2 "$(puts)"
check "PUT path" "t clients/u-admin-portal/default-client-scopes/s-admin" "$(head -1 "$TMP/puts")"

# --- idempotent: already attached → no PUT ----------------------------------
mt_kc_ensure_admin_api_scope t admin-portal account-portal > /dev/null 2>&1; check "rerun rc" 0 $?
check "rerun no new PUTs" 2 "$(puts)"

# --- PUT reported success but readback lacks the scope → fail ---------------
reset; add_realm t true; add_client t admin-portal false; touch "$TMP/put-noop"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "readback mismatch fails" 1 $?

# --- PUT fails → fail --------------------------------------------------------
reset; add_realm t true; add_client t admin-portal false; touch "$TMP/put-fail"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "PUT failure fails" 1 $?

# --- strict mode: missing client fails; --if-present skips it ---------------
reset; add_realm t true; add_client t admin-portal false
mt_kc_ensure_admin_api_scope t admin-portal account-portal > /dev/null 2>&1; check "strict missing client fails" 1 $?
reset; add_realm t true; add_client t admin-portal false
mt_kc_ensure_admin_api_scope --if-present t admin-portal account-portal > /dev/null 2>&1; check "if-present rc" 0 $?
check "if-present attached existing client" true "$(has_scope t admin-portal)"
check "if-present one PUT" 1 "$(puts)"
reset; add_realm master true
mt_kc_ensure_admin_api_scope --if-present master admin-portal account-portal > /dev/null 2>&1; check "if-present realm without clients" 0 $?
check "if-present no PUTs" 0 "$(puts)"

# --- scope absent: fine before 26.8.2, error from 26.8.2 --------------------
reset; add_realm t false; add_client t admin-portal false; echo "26.8.1" > "$TMP/version"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "no scope on 26.8.1 ok" 0 $?
check "no scope on 26.8.1 no PUT" 0 "$(puts)"
reset; add_realm t false; add_client t admin-portal false
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "no scope on 26.8.2 fails" 1 $?
reset; add_realm t false; add_client t admin-portal false; touch "$TMP/version-fail"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "no scope + unknown version fails" 1 $?
reset; add_realm t false; add_client t admin-portal false; echo "nightly" > "$TMP/version"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "no scope + garbage version fails" 1 $?

# --- lookup returns several clients: only the exact clientId is touched -----
reset; add_realm t true; add_client t account-portal false; add_client t admin-portal false; touch "$TMP/query-ignored"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "multi-result rc" 0 $?
check "multi-result PUT hits admin-portal" "t clients/u-admin-portal/default-client-scopes/s-admin" "$(head -1 "$TMP/puts")"
check "multi-result leaves account-portal alone" false "$(has_scope t account-portal)"
reset; add_realm t true; add_client t account-portal false; touch "$TMP/query-ignored"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "multi-result without match fails strict" 1 $?
check "multi-result without match no PUT" 0 "$(puts)"

# --- transport errors fail ---------------------------------------------------
reset
mt_kc_ensure_admin_api_scope nosuch admin-portal > /dev/null 2>&1; check "scope list error fails" 1 $?
reset; add_realm t true; add_client t admin-portal false; echo "clients?clientId=admin-portal" > "$TMP/get-fail"
mt_kc_ensure_admin_api_scope --if-present t admin-portal > /dev/null 2>&1; check "client lookup error fails even if-present" 1 $?
reset; add_realm t true; add_client t admin-portal false; echo "clients/u-admin-portal/default-client-scopes" > "$TMP/get-fail"
mt_kc_ensure_admin_api_scope t admin-portal > /dev/null 2>&1; check "defaults read error fails" 1 $?
reset; add_realm t true
mt_kc_ensure_admin_api_scope t > /dev/null 2>&1; check "no clients arg fails" 1 $?

echo "keycloak-admin-scope: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
