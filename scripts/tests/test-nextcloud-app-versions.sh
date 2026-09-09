#!/usr/bin/env bash
# Unit tests for scripts/lib/nextcloud-app-versions.py — the release selector
# behind scripts/check-nextcloud-app-versions.sh. Pure fixtures, no network.
#
# Regression under test: the app store lists newest-first including release
# candidates, and both the report and the --update writeback took releases[0].
# That is how `calendar 6.6.0-rc.2` was proposed for the manifest.
#
# Run: scripts/tests/test-nextcloud-app-versions.sh   (CI: ci/scripts/shell-unit-tests.sh)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELECTOR="${REPO_ROOT}/scripts/lib/nextcloud-app-versions.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   - $1"; else FAIL=$((FAIL + 1)); echo "  FAIL - $1 (expected [$2] got [$3])"; fi
}
contains() {  # contains <description> <needle> <haystack>
    case "$3" in *"$2"*) PASS=$((PASS + 1)); echo "  ok   - $1";; *) FAIL=$((FAIL + 1)); echo "  FAIL - $1 (no [$2] in: $3)";; esac
}

write_manifest() {  # write_manifest <path> <app>=<version>...
    local path="$1"; shift
    { echo '{"platform_version": "32.0.5", "apps": {'
      local first=1
      for pair in "$@"; do
          [ $first -eq 1 ] || echo ','
          first=0
          # Must be an allow-listed https host: the selector re-validates every
          # pinned URL on each run, not only newly proposed ones.
          printf '"%s": {"version": "%s", "url": "https://github.com/x/%s.tar.gz"}' \
              "${pair%%=*}" "${pair#*=}" "${pair%%=*}"
      done
      echo '}}'
    } > "$path"
}

# App store fixture: newest-first, RCs at the top — the real API's shape.
cat > "$TMPDIR_TEST/api.json" <<'JSON'
[
  {"id": "calendar", "releases": [
    {"version": "6.6.0-rc.2", "isNightly": false, "download": "https://github.com/x/calendar-6.6.0-rc.2.tar.gz"},
    {"version": "6.6.0-rc.1", "isNightly": false, "download": "https://github.com/x/calendar-6.6.0-rc.1.tar.gz"},
    {"version": "6.5.4",      "isNightly": false, "download": "https://github.com/x/calendar-6.5.4.tar.gz"},
    {"version": "6.4.2",      "isNightly": false, "download": "https://github.com/x/calendar-6.4.2.tar.gz"}
  ]},
  {"id": "richdocuments", "releases": [
    {"version": "9.2.1", "isNightly": false, "download": "https://github.com/x/richdocuments-9.2.1.tar.gz"},
    {"version": "9.1.0", "isNightly": false, "download": "https://github.com/x/richdocuments-9.1.0.tar.gz"}
  ]},
  {"id": "unsorted", "releases": [
    {"version": "1.2.0",  "isNightly": false, "download": "https://github.com/x/unsorted-1.2.0.tar.gz"},
    {"version": "1.10.0", "isNightly": false, "download": "https://github.com/x/unsorted-1.10.0.tar.gz"},
    {"version": "1.9.0",  "isNightly": false, "download": "https://github.com/x/unsorted-1.9.0.tar.gz"}
  ]},
  {"id": "nightly_only", "releases": [
    {"version": "2.0.0", "isNightly": true, "download": "https://github.com/x/nightly_only-2.0.0.tar.gz"}
  ]},
  {"id": "dotted_rc", "releases": [
    {"version": "6.6.0.rc2", "isNightly": false, "download": "https://evil.example/dotted_rc-6.6.0.rc2.tar.gz"},
    {"version": "6.5.4",     "isNightly": false, "download": "https://github.com/x/dotted_rc-6.5.4.tar.gz"}
  ]},
  {"id": "offhost", "releases": [
    {"version": "2.0.0", "isNightly": false, "download": "https://evil.example/offhost-2.0.0.tar.gz"}
  ]},
  {"id": "plaintext", "releases": [
    {"version": "2.0.0", "isNightly": false, "download": "http://github.com/x/plaintext-2.0.0.tar.gz"}
  ]},
  {"id": "smuggled", "releases": [
    {"version": "2.0.0", "isNightly": false, "download": "https://github.com/x/ok.tar.gz\nevil_app|https://evil.example/backdoor.tar.gz"}
  ]},
  {"id": "buildmeta", "releases": [
    {"version": "2.0.0+evil -> fabricated", "isNightly": false, "download": "https://github.com/x/buildmeta-2.0.0.tar.gz"}
  ]},
  {"id": "retagged", "releases": [
    {"version": "v8.11.0", "isNightly": false, "download": "https://github.com/x/retagged-8.11.0.tar.gz"},
    {"version": "8.9.0",   "isNightly": false, "download": "https://github.com/x/retagged-8.9.0.tar.gz"}
  ]}
]
JSON
API="$TMPDIR_TEST/api.json"

# --- the regression: an RC must never be proposed -----------------------------
write_manifest "$TMPDIR_TEST/m1.json" calendar=6.4.2
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m1.json" "$API" 2>&1); RC=$?
check    "updates available -> exit 2" 2 "$RC"
contains "proposes the newest STABLE, not the RC" "calendar: 6.4.2 -> 6.5.4" "$OUT"
case "$OUT" in *rc.2*) FAIL=$((FAIL+1)); echo "  FAIL - RC leaked into the report";; *) PASS=$((PASS+1)); echo "  ok   - RC absent from the report";; esac

# --- --update writes the same choice the report made --------------------------
write_manifest "$TMPDIR_TEST/m2.json" calendar=6.4.2
python3 "$SELECTOR" "$TMPDIR_TEST/m2.json" "$API" --update >/dev/null 2>&1
WROTE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apps"]["calendar"]["version"])' "$TMPDIR_TEST/m2.json")
check "--update writes the stable version" "6.5.4" "$WROTE"
WROTE_URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apps"]["calendar"]["url"])' "$TMPDIR_TEST/m2.json")
contains "--update writes the matching download URL" "calendar-6.5.4.tar.gz" "$WROTE_URL"

# --- opt-in prereleases -------------------------------------------------------
write_manifest "$TMPDIR_TEST/m3.json" calendar=6.4.2
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m3.json" "$API" --allow-prerelease 2>&1)
contains "--allow-prerelease opts back in" "calendar: 6.4.2 -> 6.6.0-rc.2" "$OUT"

# --- semver order beats array order -------------------------------------------
write_manifest "$TMPDIR_TEST/m4.json" unsorted=1.2.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m4.json" "$API" 2>&1)
contains "1.10.0 > 1.9.0 > 1.2.0 (numeric, not lexical)" "unsorted: 1.2.0 -> 1.10.0" "$OUT"

# --- never propose a downgrade ------------------------------------------------
write_manifest "$TMPDIR_TEST/m5.json" richdocuments=9.9.9
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m5.json" "$API" 2>&1); RC=$?
check    "pin ahead of the store -> exit 0, no update" 0 "$RC"
contains "explains the pin is ahead" "ahead of the store" "$OUT"

# --- a hand-pinned RC fails closed -------------------------------------------
# It used to exit 0 "up to date": an RC's core version is ahead of the newest
# stable, so it looked like a pin ahead of the store and no update was ever
# proposed for that app again.
write_manifest "$TMPDIR_TEST/m6.json" calendar=6.6.0-rc.2
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m6.json" "$API" 2>&1); RC=$?
check    "prerelease pin -> exit 1, not a clean report" 1 "$RC"
contains "says how to resolve it" "pin a stable release" "$OUT"
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m6.json" "$API" --allow-prerelease 2>&1); RC=$?
check    "--allow-prerelease accepts a prerelease pin" 0 "$RC"

# --- up to date ---------------------------------------------------------------
write_manifest "$TMPDIR_TEST/m7.json" calendar=6.5.4 richdocuments=9.2.1
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m7.json" "$API" 2>&1); RC=$?
check    "all current -> exit 0" 0 "$RC"
contains "says so" "All apps are up to date" "$OUT"

# --- fail fast: pinned app missing from the store -----------------------------
write_manifest "$TMPDIR_TEST/m8.json" calendar=6.5.4 vanished=1.0.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m8.json" "$API" 2>&1); RC=$?
check    "missing app -> exit 1, not a silent skip" 1 "$RC"
contains "names the missing app" "vanished" "$OUT"

# --- fail fast: app with only nightly releases --------------------------------
write_manifest "$TMPDIR_TEST/m9.json" nightly_only=1.0.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m9.json" "$API" 2>&1); RC=$?
check    "nightly-only app -> exit 1" 1 "$RC"
contains "explains why" "no installable release" "$OUT"

# --- a failed run must not rewrite the manifest -------------------------------
write_manifest "$TMPDIR_TEST/m10.json" calendar=6.4.2 vanished=1.0.0
BEFORE=$(cat "$TMPDIR_TEST/m10.json")
python3 "$SELECTOR" "$TMPDIR_TEST/m10.json" "$API" --update >/dev/null 2>&1
check "error run leaves the manifest untouched" "$BEFORE" "$(cat "$TMPDIR_TEST/m10.json")"

# --- non-hyphen prerelease must not bypass the filter -------------------------
# Regression: `int(part) if part.isdigit() else 0` parsed 6.6.0.rc2 as (6,6,0,0)
# — ahead of stable 6.5.4 and never matching the `-` prerelease test — so the
# writeback pinned an RC from an unexpected host. The old suite only ever
# exercised the hyphen form, so it passed while this shipped.
# It is NOT enough to skip it and quietly take 6.5.4: we cannot tell an RC we
# failed to parse from a newer stable release we failed to parse, so an
# unreadable entry stops the run for a human to look at.
write_manifest "$TMPDIR_TEST/m11.json" dotted_rc=6.4.2
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m11.json" "$API" 2>&1); RC=$?
check    "6.6.0.rc2 is refused rather than parsed -> exit 1" 1 "$RC"
contains "names the unreadable version" "6.6.0.rc2" "$OUT"
contains "explains the risk" "may be hidden behind them" "$OUT"

write_manifest "$TMPDIR_TEST/m12.json" dotted_rc=6.4.2
python3 "$SELECTOR" "$TMPDIR_TEST/m12.json" "$API" --update >/dev/null 2>&1
WROTE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apps"]["dotted_rc"]["version"])' "$TMPDIR_TEST/m12.json")
check "--update leaves the pin alone; the RC is never written" "6.4.2" "$WROTE"
WROTE_URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apps"]["dotted_rc"]["url"])' "$TMPDIR_TEST/m12.json")
case "$WROTE_URL" in *evil.example*) FAIL=$((FAIL+1)); echo "  FAIL - the off-host RC URL reached the manifest";; *) PASS=$((PASS+1)); echo "  ok   - the off-host RC URL never reached the manifest";; esac

# --- unparseable pin is an error, not a coerced guess -------------------------
write_manifest "$TMPDIR_TEST/m13.json" calendar=not-a-version
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m13.json" "$API" 2>&1); RC=$?
check    "unparseable pin -> exit 1" 1 "$RC"
contains "names the bad pin" "not a version we can parse" "$OUT"

# --- download host allow-list -------------------------------------------------
write_manifest "$TMPDIR_TEST/m14.json" offhost=1.0.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m14.json" "$API" 2>&1); RC=$?
check    "off-allowlist download host -> exit 1" 1 "$RC"
contains "names the rejected host" "evil.example" "$OUT"

OUT=$(MT_NC_ALLOWED_DOWNLOAD_HOSTS=github.com,evil.example python3 "$SELECTOR" "$TMPDIR_TEST/m14.json" "$API" 2>&1); RC=$?
check "host allow-list is overridable for a legitimate move" 2 "$RC"

# --- parse_version unit checks ------------------------------------------------
pv() { python3 -c '
import sys; sys.path.insert(0, "'"${REPO_ROOT}"'/scripts/lib")
import importlib.util
spec = importlib.util.spec_from_file_location("nav", "'"${REPO_ROOT}"'/scripts/lib/nextcloud-app-versions.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    key, pre = m.parse_version(sys.argv[1]); print("pre" if pre else "stable")
except m.UnparseableVersion:
    print("unparseable")
' "$1"; }
check "1.4.0 is stable"            stable      "$(pv 1.4.0)"
check "1.4.0-rc.2 is prerelease"   pre         "$(pv 1.4.0-rc.2)"
check "6.6.0.rc2 is unparseable"   unparseable "$(pv 6.6.0.rc2)"
check "empty prerelease rejected"  unparseable "$(pv 1.0.0-)"
check "5 components rejected"      unparseable "$(pv 1.2.3.4.5)"
check "build metadata ignored"     stable      "$(pv 1.4.0+build7)"

# --- scheme must be https, not just an allow-listed host ----------------------
write_manifest "$TMPDIR_TEST/m15.json" plaintext=1.0.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m15.json" "$API" 2>&1); RC=$?
check    "http:// on an allow-listed host -> exit 1" 1 "$RC"
contains "says why" "not https" "$OUT"

# --- an unreadable NEWEST release must not silently fall back -----------------
# Upstream re-tagging as "v8.11.0" above a readable 8.9.0 would otherwise report
# "up to date" forever behind a green scheduled run — the same silent stall this
# script exists to remove.
write_manifest "$TMPDIR_TEST/m16.json" retagged=8.9.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m16.json" "$API" 2>&1); RC=$?
check    "unparseable release hides a newer one -> exit 1" 1 "$RC"
contains "names the unreadable version" "v8.11.0" "$OUT"
case "$OUT" in *"up to date"*) FAIL=$((FAIL+1)); echo "  FAIL - still claimed up to date";; *) PASS=$((PASS+1)); echo "  ok   - does not claim up to date";; esac

# --- an already-pinned bad URL is re-checked every run ------------------------
# The host check used to sit inside the "newer release" branch, so a pin equal
# to or ahead of the store was never examined again.
cat > "$TMPDIR_TEST/m17.json" <<'JSON'
{"platform_version": "32.0.5", "apps": {
  "calendar": {"version": "99.0.0", "url": "https://evil.example/backdoor.tar.gz"}
}}
JSON
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m17.json" "$API" 2>&1); RC=$?
check    "pin ahead of store with a bad URL -> exit 1, not clean" 1 "$RC"
contains "flags the pinned URL" "pinned download URL" "$OUT"

cat > "$TMPDIR_TEST/m18.json" <<'JSON'
{"platform_version": "32.0.5", "apps": {
  "calendar": {"version": "6.5.4", "url": "https://evil.example/backdoor.tar.gz"}
}}
JSON
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m18.json" "$API" 2>&1); RC=$?
check "up-to-date pin with a bad URL -> exit 1" 1 "$RC"

# --- unknown flags are rejected ----------------------------------------------
write_manifest "$TMPDIR_TEST/m19.json" calendar=6.4.2
BEFORE=$(cat "$TMPDIR_TEST/m19.json")
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m19.json" "$API" --updates 2>&1); RC=$?
check    "typo'd --updates -> exit 1, not a silent no-op" 1 "$RC"
check    "  and writes nothing" "$BEFORE" "$(cat "$TMPDIR_TEST/m19.json")"

# --- charset: isdigit() is not an ASCII test ---------------------------------
check "Arabic-Indic digits are not a stable version" unparseable "$(pv $'\u0663.0.0')"
check "superscript does not crash the parser"        unparseable "$(pv $'1.2.\u00b2')"
# shellcheck disable=SC2016  # the literal $(id) is the point: it must NOT expand
check "non-semver prerelease charset rejected"       unparseable "$(pv '1.0.0-rc$(id)')"
check "legal prerelease charset accepted"            pre         "$(pv '1.0.0-rc-2.beta')"

# --- newline smuggling must not pass the host check ---------------------------
# urlsplit() strips \t \r \n BEFORE parsing, so this URL reports hostname
# github.com while the raw string still carries a second line. deploy-nextcloud.sh
# renders the manifest into "<app_id>|<url>" lines that the init container reads
# one per line, so a smuggled newline installs an unpinned app from any host.
write_manifest "$TMPDIR_TEST/m20.json" smuggled=1.0.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m20.json" "$API" 2>&1); RC=$?
check    "newline-smuggled download URL -> exit 1" 1 "$RC"
contains "says why" "whitespace or control characters" "$OUT"

write_manifest "$TMPDIR_TEST/m21.json" smuggled=1.0.0
python3 "$SELECTOR" "$TMPDIR_TEST/m21.json" "$API" --update >/dev/null 2>&1
case "$(cat "$TMPDIR_TEST/m21.json")" in
  *evil.example*) FAIL=$((FAIL+1)); echo "  FAIL - smuggled second URL reached the manifest";;
  *)              PASS=$((PASS+1)); echo "  ok   - smuggled second URL never reached the manifest";;
esac

# --- build metadata is kept in the raw string, so validate its charset --------
# "+evil -> fabricated" survives the workflow`s `grep " -> "` filter and would
# fabricate change lines in the PR body a human reviews.
write_manifest "$TMPDIR_TEST/m22.json" buildmeta=1.0.0
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m22.json" "$API" 2>&1); RC=$?
check "injected build metadata -> exit 1" 1 "$RC"
check "legitimate build metadata still parses" stable "$(pv 1.4.0+build7)"
check "dotted build metadata still parses"     stable "$(pv 1.4.0+sha.abc-1)"
check "shell metachars in build metadata rejected" unparseable "$(pv '''1.0.0+;rm -rf /''')"

# --- --update must preserve unknown fields (#654 will add a checksum) ---------
cat > "$TMPDIR_TEST/m23.json" <<'JSON'
{"platform_version": "32.0.5", "apps": {
  "calendar": {"version": "6.4.2", "url": "https://github.com/x/calendar-6.4.2.tar.gz", "sha256": "OLD-TARBALL-DIGEST", "note": "keepme"}
}}
JSON
python3 "$SELECTOR" "$TMPDIR_TEST/m23.json" "$API" --update >/dev/null 2>&1
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apps"]["calendar"].get(sys.argv[2], "GONE"))' "$1" "$2"; }
check "  version still updates" "6.5.4" "$(field "$TMPDIR_TEST/m23.json" version)"
# A checksum is bound to the BYTES of the old release. Carrying it across a
# version bump would either break the install or leave the manifest asserting a
# checksum for a different tarball while the diff shows an UNCHANGED sha256 line
# — no signal for the reviewer. It must be dropped (and, once #654 lands,
# recomputed from the selected release).
check "  content-bound sha256 is dropped, not carried" "GONE" "$(field "$TMPDIR_TEST/m23.json" sha256)"
check "  unrelated fields survive the merge" "keepme" "$(field "$TMPDIR_TEST/m23.json" note)"

# --- malformed URLs return a verdict, not a traceback -------------------------
# urlparse() raises ValueError on an unterminated IPv6 literal and on netlocs
# that fail NFKC normalisation. Uncaught, that aborts the whole per-app loop.
for BAD in 'https://[::1/x.tgz' 'https://exa[mple.com/x.tgz' 'https://github.com\uff0fevil.example/x.tgz'; do
  cat > "$TMPDIR_TEST/m24.json" <<JSON
{"platform_version": "32.0.5", "apps": {
  "calendar": {"version": "6.4.2", "url": "$BAD"}
}}
JSON
  OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m24.json" "$API" 2>&1); RC=$?
  check "malformed URL -> exit 1: $BAD" 1 "$RC"
  case "$OUT" in
    *Traceback*) FAIL=$((FAIL+1)); echo "  FAIL - traceback instead of a verdict";;
    *ERROR:*)    PASS=$((PASS+1)); echo "  ok   -   reported as an ERROR line";;
    *)           FAIL=$((FAIL+1)); echo "  FAIL - no error line (got: $OUT)";;
  esac
done

# One bad app must not stop the others being checked.
cat > "$TMPDIR_TEST/m25.json" <<'JSON'
{"platform_version": "32.0.5", "apps": {
  "calendar": {"version": "6.4.2", "url": "https://[::1/x.tgz"},
  "offhost":  {"version": "1.0.0", "url": "https://evil.example/x.tgz"}
}}
JSON
OUT=$(python3 "$SELECTOR" "$TMPDIR_TEST/m25.json" "$API" 2>&1)
contains "a bad URL does not abort the loop (calendar reported)" "calendar" "$OUT"
contains "  ...and the second app is still checked (offhost reported)" "offhost" "$OUT"

echo ""
echo "nextcloud-app-versions: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
