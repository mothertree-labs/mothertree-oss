#!/usr/bin/env bash
# Assert that the Renovate custom managers can actually REWRITE what they match.
#
# Why this test exists. The pandoc manager matched the version in three places
# across two lines and rebuilt them from an `autoReplaceStringTemplate` that
# carried a `(?<between>...)` capture. Renovate's regex manager keeps only the
# capture groups in its `validMatchFields` and discards every other one, and
# autoReplaceStringTemplate is compiled against the *upgrade* object rather than
# the capture groups -- so `{{{between}}}` rendered as an empty string, the
# replacement collapsed the `wget ... | tar xz ...` pipe onto one mangled line,
# the post-replace re-extract found nothing, and Renovate threw `update-failure`.
#
# That error abandons the whole branch. Under per-package branches it lost one
# PR silently; once #722 batched every non-major bump into one branch it meant
# NO dependency PR opened at all -- security patches included -- and the only
# symptom was one WARN line on the dependency dashboard.
#
# Extraction still worked throughout, so `renovate-config-validator` was green
# and the marker test was green. Nothing in CI could see it. Hence these three
# assertions, in the same spirit as renovate-markers.test.sh (#711/#714):
# turn a silent skip into a failed pipeline.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
cd "$REPO" || exit 1

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"
    fi
}

# 1. The general guard: no autoReplaceStringTemplate may interpolate a capture
#    group Renovate does not keep. This is the defect itself, stated once for
#    every manager present and any manager added later.
BAD=$(python3 - <<'PY'
import io, json, re, sys
# validMatchFields, from Renovate's lib/modules/manager/custom/utils.ts. Plus the
# fields the branch worker itself puts on the upgrade object, which templates may
# legitimately use.
VALID = {"depName", "packageName", "currentValue", "currentDigest", "datasource",
         "versioning", "extractVersion", "registryUrl", "depType", "indentation",
         "newValue", "newVersion", "newDigest", "newName", "currentVersion",
         "packageFile", "packageFileDir", "newMajor", "newMinor", "newPatch"}
src = io.open("renovate.json5", encoding="utf-8").read()
# Strip // comments so a commented-out template cannot red the build.
src = re.sub(r"^\s*//.*$", "", src, flags=re.MULTILINE)
bad = []
for line in src.split("\n"):
    if "autoReplaceStringTemplate" not in line:
        continue
    for name in re.findall(r"\{\{\{?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}?\}\}", line):
        if name not in VALID:
            bad.append(name)
sys.stdout.write(",".join(sorted(set(bad))))
PY
) || { echo "FAIL: could not scan renovate.json5 for autoReplaceStringTemplate groups"; exit 1; }
check "no autoReplaceStringTemplate uses a discarded capture group" "" "$BAD"

# 2. The pandoc pin specifically is still bound. Without this, deleting the
#    manager would leave assertion 1 vacuously true.
PANDOC_MATCHES=$(python3 - <<'PY'
import io, json, re, sys
src = io.open("renovate.json5", encoding="utf-8").read()
cands = [l.strip().rstrip(",").strip() for l in src.split("\n")
         if "PANDOC_VERSION=" in l and '"matchStrings"' in l]
if len(cands) != 1:
    sys.exit("expected exactly 1 PANDOC_VERSION matchStrings line, found %d" % len(cands))
pat = json.loads(cands[0].split(":", 1)[1].strip().lstrip("[").rstrip("]").strip())
# Renovate/RE2 spell named groups `(?<name>...)`; Python's re wants `(?P<name>...)`.
pat = re.sub(r"\(\?<(?![=!])", "(?P<", pat)
body = io.open("apps/values/nextcloud.yaml.gotmpl", encoding="utf-8").read()
sys.stdout.write(str(len(re.compile(pat, re.MULTILINE).findall(body))))
PY
) || { echo "FAIL: could not bind the pandoc matchString"; exit 1; }
check "the pandoc pin is bound exactly once" "1" "$PANDOC_MATCHES"

# 3. And the fetch still CONSUMES the pin. The manager no longer matches inside
#    the URL, so re-inlining a literal version there would leave Renovate
#    bumping a variable nothing reads -- invisible drift, the same failure class
#    this file exists to prevent.
# shellcheck disable=SC2016  # the literal ${PANDOC_VERSION} IS the thing asserted
PANDOC_LINES=$(grep -c 'pandoc-${PANDOC_VERSION}\|download/${PANDOC_VERSION}' \
    apps/values/nextcloud.yaml.gotmpl 2>/dev/null)
check "the pandoc URL and tar path expand the pin" "2" "$PANDOC_LINES"
check "no literal pandoc version remains beside the pin" "0" \
    "$(grep -cE 'pandoc-[0-9]+(\.[0-9]+)*(-linux|/bin)' apps/values/nextcloud.yaml.gotmpl 2>/dev/null)"

echo "renovate-pandoc-pin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
