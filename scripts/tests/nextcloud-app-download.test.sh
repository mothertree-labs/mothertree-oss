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
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { cp "$ARCHIVE" "$2"; exit 0; }; shift; done
exit 2
EOF
printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/bin/sleep"
chmod +x "$TEST_TMP/bin/curl" "$TEST_TMP/bin/sleep"

run() {  # run <fail_first> <archive>; sets RC and CALLS_N
  rm -rf "${APPS:?}/richdocuments"; export CALLS="$TEST_TMP/calls" FAIL_FIRST="$1" ARCHIVE="$2"; rm -f "$CALLS"
  RC=0; PATH="$TEST_TMP/bin:$PATH" sh -c ". '$TEST_TMP/fn.sh'; download_app richdocuments https://example.invalid/r.tar.gz" >/dev/null 2>&1 || RC=$?
  CALLS_N=$(cat "$CALLS")
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

run 0 "$TEST_TMP/wrong.tar.gz"
check "archive without the app returns non-zero" test "$RC" != 0

# The caller must stop the init script, not log and continue.
check "no 'non-critical' soft-fail left" bash -c "! grep -q 'non-critical' '$CM'"
check "failed download exits the init script" \
  bash -c "grep -A4 'if download_app' '$CM' | grep -q 'exit 1'"

exit "$fail"
