#!/usr/bin/env bash
# Unit tests for vcli_del_if — the atomic compare-and-delete behind every CI
# lock release and stale-holder reclaim (issue #647).
#
# The bug it fixes: `GET` then `DEL` is check-then-act. Two waiters that observe
# the SAME dead holder both issue the DEL, and the second erases the lock the
# first has just won — so both print "Acquired ...". On 2026-09-09 pipelines
# #2131 and #2132 did exactly that and ran concurrent `terraform apply` against
# phase1-dev/terraform.tfstate.
#
# Two layers:
#   * argument contract — always runs, so CI has a real assertion even where no
#     server binary exists (the Woodpecker step image is bare `bash`);
#   * functional — runs against a real redis/valkey when the binary is present,
#     exercising the actual Lua, including a replay of the #647 race.
#
# Run: scripts/tests/test-ci-lock-atomicity.sh   (CI: ci/scripts/shell-unit-tests.sh)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   - $1"; else FAIL=$((FAIL + 1)); echo "  FAIL - $1 (expected [$2] got [$3])"; fi
}

# ── Layer 1: argument contract ────────────────────────────────────────────────
# Catches the realistic coding errors: wrong numkeys, or KEYS/ARGV swapped so the
# comparison silently never matches (which would make every release a no-op and
# leave locks stranded until TTL).
export CI_VALKEY_PASSWORD="unused-in-contract-mode"
# shellcheck source=../../ci/scripts/ci-lib.sh
source "${REPO_ROOT}/ci/scripts/ci-lib.sh"

# Capture as an ARRAY: the Lua body contains spaces, so positional word
# splitting would misread every field after it.
CAPTURED_ARGS=()
vcli() { CAPTURED_ARGS=("$@"); }   # shadow the real wrapper

vcli_del_if "my-lock" "2131#pull_request"
check "invokes EVAL"              "EVAL"               "${CAPTURED_ARGS[0]}"
check "declares exactly one key"  "1"                  "${CAPTURED_ARGS[2]}"
check "key is passed as KEYS[1]"  "my-lock"            "${CAPTURED_ARGS[3]}"
check "expected value is ARGV[1]" "2131#pull_request"  "${CAPTURED_ARGS[4]}"
check "passes exactly 5 arguments" "5"                 "${#CAPTURED_ARGS[@]}"
LUA="${CAPTURED_ARGS[1]}"
case "$LUA" in
  *"redis.call('get', KEYS[1]) == ARGV[1]"*) PASS=$((PASS+1)); echo "  ok   - compares KEYS[1] against ARGV[1]";;
  *) FAIL=$((FAIL+1)); echo "  FAIL - comparison is not KEYS[1] vs ARGV[1]: $LUA";;
esac
case "$LUA" in
  *"redis.call('del', KEYS[1])"*) PASS=$((PASS+1)); echo "  ok   - deletes the same key it compared";;
  *) FAIL=$((FAIL+1)); echo "  FAIL - does not delete KEYS[1]";;
esac

# Restore the real wrapper. `unset -f vcli` would remove the LIBRARY function
# too — there is only one name — leaving the functional layer with no client.
# shellcheck source=../../ci/scripts/ci-lib.sh
source "${REPO_ROOT}/ci/scripts/ci-lib.sh"

# ── Bad arguments must RETURN, never abort the caller ─────────────────────────
# These helpers run inside ci-deploy.sh's EXIT trap. A `${n:?}` guard is a
# parameter-expansion failure: it exits the shell outright and `|| true` does NOT
# catch it, so the rest of the trap — including the scrub of the decrypted deploy
# vault and tenant *.secrets.yaml — would silently never run.
#
# NOTE the shape of this test. `$(vcli_del_if lock "")` would pass even with the
# bug present, because command substitution runs in a subshell and the abort dies
# there. Only a DIRECT call in this shell detects it.
_survived=""
vcli() { return 0; }                       # stub: never reach a real server
vcli_del_if lock "" >/dev/null 2>&1 || true
_survived="yes"
check "empty expected value returns, does not abort the shell" "yes" "$_survived"

_survived=""
vcli_del_if "" "val" >/dev/null 2>&1 || true
_survived="yes"
check "empty key returns, does not abort the shell" "yes" "$_survived"

_survived=""
vcli_renew_if lock "val" "" >/dev/null 2>&1 || true
_survived="yes"
check "renew with empty ttl returns, does not abort" "yes" "$_survived"

vcli_del_if lock "" >/dev/null 2>&1; check "  and signals the error (rc 2)" "2" "$?"
unset -f vcli
# shellcheck source=../../ci/scripts/ci-lib.sh
source "${REPO_ROOT}/ci/scripts/ci-lib.sh"

# ── Layer 2: functional, against a real server ────────────────────────────────
SERVER=$(command -v valkey-server 2>/dev/null || command -v redis-server 2>/dev/null || true)
CLIENT=$(command -v valkey-cli 2>/dev/null || command -v redis-cli 2>/dev/null || true)

if [ -z "$SERVER" ] || [ -z "$CLIENT" ]; then
    # Loud on purpose. The CI host runs Valkey only as a Docker container, so
    # there is no host binary and this layer does NOT execute in CI today —
    # meaning the Lua CAS and the #2131/#2132 race replay are covered locally
    # only. A quiet skip here would be exactly the vacuous green this PR's
    # sibling change to version-bump.md warns about.
    echo "  SKIP - functional layer NOT run: no valkey/redis binary on PATH."
    echo "         The Lua compare-and-delete is unverified in this environment;"
    echo "         only the argument contract above was checked."
else
    # An ephemeral port, not a fixed 6399: this runs on a shared CI host
    # (WOODPECKER_BACKEND=local), where two concurrent pipelines on a fixed port
    # would collide — the loser's bind fails, its ping fails, and it reports a
    # green "skip" having tested nothing.
    PORT=$(( 20000 + (RANDOM % 20000) ))
    # Strong throwaway secret. `test-$$` was the shell PID: a 2-6 digit integer
    # guarding a server that allows EVAL and CONFIG SET, i.e. arbitrary file
    # write.
    PW=$( (openssl rand -hex 24 2>/dev/null) || date +%s%N | shasum -a 256 | cut -c1-48 )
    DATADIR=$(mktemp -d)
    # --bind loopback ONLY. Without it redis binds every interface, and
    # protected-mode does not save you once a password is set — the server is
    # then reachable from the LAN, and on the CI VM from any Tailscale peer.
    "$SERVER" --port "$PORT" --bind '127.0.0.1 -::1' --requirepass "$PW" \
              --save '' --appendonly no \
              --dir "$DATADIR" --daemonize yes --pidfile "$DATADIR/pid" >/dev/null 2>&1
    cleanup() {
        "$CLIENT" -h 127.0.0.1 -p "$PORT" -a "$PW" --no-auth-warning shutdown nosave >/dev/null 2>&1
        # Fallback: a SIGKILL of this script would skip the graceful shutdown and
        # orphan a listening daemon with nobody left to stop it.
        [ -f "$DATADIR/pid" ] && kill "$(cat "$DATADIR/pid")" 2>/dev/null
        rm -rf "$DATADIR"
    }
    trap cleanup EXIT

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        "$CLIENT" -h 127.0.0.1 -p "$PORT" -a "$PW" --no-auth-warning ping >/dev/null 2>&1 && break
        sleep 0.3
    done

    # Point the library's wrapper at our throwaway server. $_CI_VCLI is expanded
    # unquoted inside vcli(), so the extra -p flag rides along.
    _CI_VCLI="$CLIENT -p $PORT"   # vcli() adds -h 127.0.0.1
    export CI_VALKEY_PASSWORD="$PW"

    if ! vcli ping >/dev/null 2>&1; then
        # Loud, for the same reason as the no-binary skip above: a bind
        # collision or a slow start would otherwise leave PASS/FAIL untouched
        # and exit 0, testing nothing.
        echo "  SKIP - functional layer NOT run: server did not come up on port ${PORT}."
        echo "         The Lua compare-and-delete is unverified in this run."
    else
        vcli SET lock "A" >/dev/null
        check "deletes when the value matches"        "1" "$(vcli_del_if lock A)"
        check "  key is gone"                         ""  "$(vcli GET lock)"

        vcli SET lock "A" >/dev/null
        check "refuses when the value differs"        "0" "$(vcli_del_if lock B)"
        check "  key survives untouched"              "A" "$(vcli GET lock)"
        vcli DEL lock >/dev/null

        check "absent key is a no-op"                 "0" "$(vcli_del_if lock anything)"

        # ── Replay of the #647 race ──────────────────────────────────────────
        # Dead holder 2126. Waiters 2131 and 2132 both read it and both try to
        # reclaim. Exactly one must end up holding the lock.
        vcli SET lock "2126#pull_request" >/dev/null
        OBSERVED=$(vcli GET lock)          # both waiters read the same value

        vcli_del_if lock "$OBSERVED" >/dev/null          # 2131 reclaims
        A_WON=$(vcli SET lock "2131" NX EX 60)           # 2131 acquires
        vcli_del_if lock "$OBSERVED" >/dev/null          # 2132 reclaims the SAME observed value
        B_WON=$(vcli SET lock "2132" NX EX 60)           # 2132 tries to acquire

        check "first waiter acquires"                 "OK" "$A_WON"
        check "second waiter is refused (the #647 fix)" ""   "$B_WON"
        check "  lock still belongs to the first"     "2131" "$(vcli GET lock)"

        # ── vcli_renew_if: the guarded TTL refresh ───────────────────────────
        # Replaces an unchecked `SET … XX` on the PROD deploy lock that announced
        # success even when the key had expired — deploying production while
        # holding nothing.
        vcli SET dlock "2200" EX 60 >/dev/null
        check "renews when still ours"                "1" "$(vcli_renew_if dlock 2200 120)"
        TTL=$(vcli TTL dlock)
        check "  TTL actually extended"               "yes" "$([ "$TTL" -gt 60 ] && echo yes || echo no)"
        check "refuses to renew someone else's lock"  "0" "$(vcli_renew_if dlock 2201 120)"
        check "  and did not overwrite the holder"    "2200" "$(vcli GET dlock)"
        vcli DEL dlock >/dev/null
        check "renew on an expired/absent key -> 0"   "0" "$(vcli_renew_if dlock 2200 120)"

        # Contrast: the old unconditional DEL lets the second waiter steal it.
        vcli SET lock "2126#pull_request" >/dev/null
        vcli DEL lock >/dev/null; vcli SET lock "2131" NX EX 60 >/dev/null
        vcli DEL lock >/dev/null; OLD_B=$(vcli SET lock "2132" NX EX 60)
        check "old behaviour DID let the second in (regression guard)" "OK" "$OLD_B"
        vcli DEL lock >/dev/null
    fi
fi

echo ""
echo "ci-lock-atomicity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
