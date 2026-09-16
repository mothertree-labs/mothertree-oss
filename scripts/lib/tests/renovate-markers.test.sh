#!/usr/bin/env bash
# Assert that every `# renovate: ...` marker under apps/values/ is actually
# matched by the customManager that exists to consume it.
#
# Why this test exists (#711). The Nextcloud runtime image is pinned as a bare
# `tag:` with no sibling `repository:`, so no Renovate manager had a datasource
# to attach and every bump silently skipped it -- the install job moved ahead of
# the runtime image and the pod entered the app-version 503 crash-loop. The fix
# is a marker comment plus a manager that binds it to the line below.
#
# That fix has the same failure mode as the bug: the marker is positional and
# format-exact, so a maintainer who inserts a line, reorders the two fields,
# adds a third (`versioning=`), doubles a space, or writes `#renovate:` without
# the space disables the pin with NO error anywhere. A review of the fix found
# five such spellings that silently skip.
#
# So: count the markers, count the matches, require equality. That single
# assertion catches insertion, reordering, extra fields and spacing -- turning a
# silent skip into a failed pipeline, per the repo's fail-fast rule.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
cd "$REPO"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"
    fi
}

# The pattern is read OUT OF renovate.json5 rather than duplicated here. A copy
# would drift from the config and assert nothing.
PATTERN=$(python3 - <<'PY'
import io, json, sys
s = io.open("renovate.json5", encoding="utf-8").read()
cands = [l.strip().rstrip(",").strip() for l in s.split("\n")
         if "# renovate: datasource=" in l and "matchStrings" not in l
         and l.strip().startswith('"')]
if len(cands) != 1:
    sys.exit("expected exactly 1 marker matchString in renovate.json5, found %d" % len(cands))
sys.stdout.write(json.loads(cands[0]))
PY
) || { echo "FAIL: could not extract the marker pattern from renovate.json5"; exit 1; }

[ -n "$PATTERN" ] || { echo "FAIL: extracted marker pattern is empty"; exit 1; }

# How many markers a human has written under apps/values/ ...
MARKERS=$(grep -rc '# renovate: ' apps/values/ 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')

# ... and how many of them the manager actually binds. Counted on the `tag:`
# side, because that is the line the manager rewrites: one match == one managed
# pin. Done in python3 rather than grep: the pattern spans a newline, and no
# POSIX grep matches across lines. python3 is already required by check-health,
# so this adds no new CI dependency.
MATCHES=$(python3 - "$PATTERN" <<'PY'
import io, os, re, sys
# Renovate/RE2 spell named groups `(?<name>...)`; Python's re wants `(?P<name>...)`.
# Translate rather than rewrite, so what we compile is still the config's pattern.
src = re.sub(r'\(\?<(?![=!])', '(?P<', sys.argv[1])
pat = re.compile(src, re.MULTILINE)
n = 0
for root, _dirs, files in os.walk("apps/values"):
    for f in files:
        if not re.search(r"\.ya?ml(\.gotmpl)?$", f):
            continue
        n += len(pat.findall(io.open(os.path.join(root, f), encoding="utf-8").read()))
sys.stdout.write(str(n))
PY
)

# Boundary: this asserts the marker BINDS, not that its captured values are
# meaningful. `datasource=dokcer` satisfies the character class, counts as
# bound, and would still skip inside Renovate. Catching that needs a datasource
# allowlist or a live dry-run, both out of proportion to the risk here.
check "every marker under apps/values/ is bound by the manager" "$MARKERS" "$MATCHES"

# A zero/zero pass would be vacuous: if the marker were deleted from the values
# file, MARKERS and MATCHES would both be 0 and the equality above would still
# hold. Require that the Nextcloud pin specifically is still managed.
check "the Nextcloud runtime tag is still marked" "1" \
    "$(grep -c '# renovate: datasource=docker depName=nextcloud' apps/values/nextcloud.yaml.gotmpl 2>/dev/null)"
check "at least one marker is bound" "yes" "$([ "${MATCHES:-0}" -ge 1 ] && echo yes || echo no)"

# And the three Nextcloud version sites must agree -- the invariant the values
# And the three Nextcloud version sites must agree -- the invariant the values
# file's own comment states, and the one whose breach caused #711.
#
# The quote class matches the manager pattern's own `["']?`: a quoted tag is a
# legitimate, Renovate-compatible spelling, and a grep stricter than the
# manager would red the build with a message pointing nowhere near the cause.
NC_PAT="nextcloud:[0-9]+\\.[0-9]+\\.[0-9]+-apache|tag: ['\"]?[0-9]+\\.[0-9]+\\.[0-9]+-apache"
NC_FILES="apps/values/nextcloud.yaml.gotmpl apps/manifests/nextcloud/install-job.yaml.tpl"
# shellcheck disable=SC2086  # NC_FILES is a deliberate word-split list
NC_RAW=$(grep -rhoE "$NC_PAT" $NC_FILES 2>/dev/null)
NC_VERSIONS=$(printf '%s\n' "$NC_RAW" | sed -E "s/.*[: ]['\"]?([0-9]+\\.[0-9]+\\.[0-9]+-apache)/\\1/" | sort -u)
check "all Nextcloud version sites agree" "1" "$(printf '%s\n' "$NC_VERSIONS" | grep -c .)"
check "there are 3 Nextcloud version sites" "3" "$(printf '%s\n' "$NC_RAW" | grep -c .)"

echo "renovate-markers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
