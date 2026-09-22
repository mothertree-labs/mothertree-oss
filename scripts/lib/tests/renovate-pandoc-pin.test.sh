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
# and the marker test was green. Nothing in CI could see it. Hence these
# assertions, in the same spirit as renovate-markers.test.sh (#711/#714): turn a
# silent skip into a failed pipeline.
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
BAD=$(python3 - <<'PYEOF'
import io, re, sys

# validMatchFields, from Renovate's lib/modules/manager/custom/utils.ts -- the only
# capture groups the regex manager keeps. Plus the fields the branch worker itself
# puts on the upgrade object, which a template may legitimately interpolate.
VALID = {"depName", "packageName", "currentValue", "currentDigest", "datasource",
         "versioning", "extractVersion", "registryUrl", "depType", "indentation",
         "newValue", "newVersion", "newDigest", "newName", "currentVersion",
         "packageFile", "packageFileDir", "newMajor", "newMinor", "newPatch",
         "newVersionMajor", "currentDigestShort", "newDigestShort", "updateType",
         "compatibility", "sourceUrl"}

# Match the key together with its STRING VALUE, across newlines. Scanning line by
# line was the first version of this check and it passed vacuously: splitting the
# key and the value onto separate lines -- what any JSON5 reformat or a long
# template produces naturally -- hid a `{{{between}}}` from it completely.
KEY = re.compile(r'"autoReplaceStringTemplate"\s*:\s*"((?:[^"\\]|\\.)*)"', re.DOTALL)
HBS = re.compile(r"\{\{\{?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}?\}\}")

def offenders(text):
    # Strip whole-line // comments so commented-out prose cannot red the build. A
    # live key never begins a line with //, and trailing comments are preserved.
    text = re.sub(r"^\s*//.*$", "", text, flags=re.MULTILINE)
    return {n for tpl in KEY.findall(text) for n in HBS.findall(tpl) if n not in VALID}

# Self-test. renovate.json5 currently carries no live autoReplaceStringTemplate at
# all, so without this the assertion below would pass however broken the scanner
# was. The fixture is the historical defect, verbatim in shape.
FIXTURE = ('{ "autoReplaceStringTemplate":\n'
           '    "jgm/pandoc/releases/download/{{{newValue}}}/x{{{between}}}y" }')
if offenders(FIXTURE) != {"between"}:
    sys.exit("self-test failed: the scanner no longer detects a discarded capture group")

sys.stdout.write(",".join(sorted(offenders(io.open("renovate.json5", encoding="utf-8").read()))))
PYEOF
) || { echo "FAIL: could not scan renovate.json5 for autoReplaceStringTemplate groups"; exit 1; }
check "no autoReplaceStringTemplate uses a discarded capture group" "" "$BAD"

# 2. The pandoc pin specifically is still bound. Without this, deleting the
#    manager would leave assertion 1 vacuously true.
PANDOC_MATCHES=$(python3 - <<'PYEOF'
import io, json, re, sys
src = io.open("renovate.json5", encoding="utf-8").read()
cands = [l.strip().rstrip(",").strip() for l in src.split("\n")
         if "PANDOC_VERSION=" in l and '"matchStrings"' in l]
if len(cands) != 1:
    sys.exit("expected exactly 1 single-line PANDOC_VERSION matchStrings entry, "
             "found %d (is the array wrapped across lines?)" % len(cands))
pat = json.loads(cands[0].split(":", 1)[1].strip().lstrip("[").rstrip("]").strip())
# Renovate/RE2 spell named groups `(?<name>...)`; Python's re wants `(?P<name>...)`.
pat = re.sub(r"\(\?<(?![=!])", "(?P<", pat)
body = io.open("apps/values/nextcloud.yaml.gotmpl", encoding="utf-8").read()
sys.stdout.write(str(len(re.compile(pat, re.MULTILINE).findall(body))))
PYEOF
) || { echo "FAIL: could not bind the pandoc matchString"; exit 1; }
check "the pandoc pin is bound exactly once" "1" "$PANDOC_MATCHES"

# 3. And the fetch still CONSUMES the pin. The manager no longer matches inside
#    the URL, so re-inlining a literal version there would leave Renovate
#    bumping a variable nothing reads -- invisible drift, the same failure class
#    this file exists to prevent.
#
#    Counted as occurrences, not lines: `grep -c` would read the two expansions
#    sharing the wget line as one, and would not move at all if a literal version
#    were re-inlined beside them.
# shellcheck disable=SC2016  # the literal ${PANDOC_VERSION} IS the thing asserted
PANDOC_USES=$(grep -o '${PANDOC_VERSION}' apps/values/nextcloud.yaml.gotmpl 2>/dev/null | grep -c .)
check "the pandoc URL and tar path expand the pin 3 times" "3" "$PANDOC_USES"

# The reject pattern must cover the `releases/download/<ver>/` segment too. That
# one carries no `pandoc-` prefix, so a version re-inlined there would slip past a
# `pandoc-[0-9]` pattern while Renovate went on bumping only the variable: URL and
# pin drift apart, the download 404s, and install-pandoc wedges every tenant's pod
# in Init.
check "no literal pandoc version remains beside the pin" "0" \
    "$(grep -cE 'pandoc-[0-9]+(\.[0-9]+)*(-linux|/bin)|releases/download/[0-9]' \
        apps/values/nextcloud.yaml.gotmpl 2>/dev/null)"

echo "renovate-pandoc-pin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
