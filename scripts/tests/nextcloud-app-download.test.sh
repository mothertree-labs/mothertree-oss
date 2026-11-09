#!/usr/bin/env bash
# Unit test for download_app() in apps/manifests/nextcloud/identity-init-configmap.yaml.
# Runs the real function (extracted from the ConfigMap) against a fake curl and
# a no-op sleep: success, retry-then-success, give up after 6 attempts, and an
# archive that does not contain the app. Also checks that a failed download
# stops the init script instead of letting the pod start without the app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CM="$REPO_ROOT/apps/manifests/nextcloud/identity-init-configmap.yaml"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail=0
check() { local name="$1"; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi; }

# Extract the function (4-space indented inside the ConfigMap) and point it at
# a temp custom_apps dir.
APPS="$TEST_TMP/custom_apps"; mkdir -p "$APPS" "$TEST_TMP/bin"
awk '/^    download_app\(\) \{/{f=1} f{print} f&&/^    \}$/{exit}' "$CM" \
  | sed -e 's/^    //' -e "s#/mnt/custom_apps#$APPS#g" > "$TEST_TMP/fn.sh"
check "download_app found in the ConfigMap" grep -q '^download_app()' "$TEST_TMP/fn.sh"

# A real app archive: richdocuments/appinfo/info.xml
mkdir -p "$TEST_TMP/src/richdocuments/appinfo" "$TEST_TMP/src/other"
echo '<info><version>9.9.9</version></info>' > "$TEST_TMP/src/richdocuments/appinfo/info.xml"
tar czf "$TEST_TMP/good.tar.gz" -C "$TEST_TMP/src" richdocuments
tar czf "$TEST_TMP/wrong.tar.gz" -C "$TEST_TMP/src" other

# Fake curl: fails the first $FAIL_FIRST calls, then writes $ARCHIVE to -o.
cat > "$TEST_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$CALLS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CALLS"
[ "$n" -le "$FAIL_FIRST" ] && exit 22
printf '%s\n' "$*" > "$ARGS"
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { cp "$ARCHIVE" "$2"; exit 0; }; shift; done
exit 2
EOF
printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/bin/sleep"
chmod +x "$TEST_TMP/bin/curl" "$TEST_TMP/bin/sleep"

sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
GOOD_SHA=$(sha_of "$TEST_TMP/good.tar.gz")
WRONG_SHA=$(sha_of "$TEST_TMP/wrong.tar.gz")
# The init image (Debian) has sha256sum; provide one where the host lacks it.
if ! command -v sha256sum >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$TEST_TMP/bin/sha256sum"; chmod +x "$TEST_TMP/bin/sha256sum"
fi

run() {  # run <fail_first> <archive> [sha256]; sets RC, CALLS_N and ERR
  rm -rf "${APPS:?}/richdocuments"; export CALLS="$TEST_TMP/calls" ARGS="$TEST_TMP/args" FAIL_FIRST="$1" ARCHIVE="$2"; rm -f "$CALLS" "$ARGS"
  local sha="${3-$GOOD_SHA}"
  RC=0; PATH="$TEST_TMP/bin:$PATH" sh -c ". '$TEST_TMP/fn.sh'; download_app richdocuments https://example.invalid/r.tar.gz '$sha'" >/dev/null 2>"$TEST_TMP/err" || RC=$?
  CALLS_N=$(cat "$CALLS" 2>/dev/null || echo 0); ERR=$(cat "$TEST_TMP/err")
}

run 0 "$TEST_TMP/good.tar.gz"
check "first-try success returns 0" test "$RC" = 0
check "first-try success installs the app" test -f "$APPS/richdocuments/appinfo/info.xml"
check "first-try success makes 1 call" test "$CALLS_N" = 1

run 2 "$TEST_TMP/good.tar.gz"
check "retry then success returns 0" test "$RC" = 0
check "retry then success installs the app" test -f "$APPS/richdocuments/appinfo/info.xml"
check "retry then success makes 3 calls" test "$CALLS_N" = 3

run 99 "$TEST_TMP/good.tar.gz"
check "persistent failure returns non-zero" test "$RC" != 0
check "persistent failure gives up after 6 attempts" test "$CALLS_N" = 6
check "persistent failure leaves no app dir" test ! -e "$APPS/richdocuments"

run 0 "$TEST_TMP/wrong.tar.gz" "$WRONG_SHA"
check "archive without the app returns non-zero" test "$RC" != 0

# --- #654: sha256 pin ---------------------------------------------------------
run 0 "$TEST_TMP/good.tar.gz"
check "curl is limited to https" grep -q -- "--proto =https" "$TEST_TMP/args"
check "redirects are limited to https" grep -q -- "--proto-redir =https" "$TEST_TMP/args"

run 0 "$TEST_TMP/wrong.tar.gz"
check "sha256 mismatch returns non-zero" test "$RC" != 0
check "sha256 mismatch is not retried (1 call)" test "$CALLS_N" = 1
check "sha256 mismatch installs nothing" test ! -e "$APPS/richdocuments"
check "sha256 mismatch says so" bash -c "grep -q 'sha256 mismatch' '$TEST_TMP/err'"

run 0 "$TEST_TMP/good.tar.gz" ""
check "missing sha256 pin returns non-zero" test "$RC" != 0
check "missing sha256 pin never downloads" test "$CALLS_N" = 0

run 0 "$TEST_TMP/good.tar.gz" "${GOOD_SHA}0"
check "over-long sha256 pin rejected" test "$RC" != 0
run 0 "$TEST_TMP/good.tar.gz" "$(printf '%s' "$GOOD_SHA" | tr 'a-f' 'A-F')"
check "uppercase sha256 pin rejected" test "$RC" != 0
run 0 "$TEST_TMP/good.tar.gz" "$(printf 'g%.0s' $(seq 64))"
check "non-hex sha256 pin rejected" test "$RC" != 0

check "no staging dir left after success" bash -c "! ls -A '$APPS' | grep -q '^\.staging'"
run 0 "$TEST_TMP/wrong.tar.gz" "$WRONG_SHA"
check "no staging dir left after a bad archive" bash -c "! ls -A '$APPS' | grep -q '^\.staging'"
check "extraction drops archive owner/modes" grep -q -- '--no-same-owner --no-same-permissions' "$CM"
check "skip check requires info.xml, not just a dir" \
  grep -q 'if \[ -f "/mnt/custom_apps/\$APP_ID/appinfo/info.xml" \]' "$CM"
check "the caller passes the third (sha256) field" \
  bash -c "grep -q 'read -r APP_ID APP_URL APP_SHA256' '$CM' && grep -q 'download_app \"\$APP_ID\" \"\$APP_URL\" \"\${APP_SHA256:-}\"' '$CM'"

# The caller must stop the init script, not log and continue.
check "no 'non-critical' soft-fail left" bash -c "! grep -q 'non-critical' '$CM'"
check "failed download exits the init script" \
  bash -c "grep -A4 'if download_app' '$CM' | grep -q 'exit 1'"

exit "$fail"
