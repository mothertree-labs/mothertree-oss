#!/bin/sh
# Stalwart 0.15 → v1 migration, Job 1 of 2 (#715): export the LIVE 0.15
# server's settings and principals with upstream's migrate_v016.py, convert
# them to the v0.16 import format and fix the secrets it leaves unexpanded.
#
# Runs in python:3.13-slim with /work (the migration PVC) and the tenant's TLS
# Secret at /opt/stalwart/tls (convert inlines the certificate it references).
#
# Output files contain the server's OAuth signing key and may inline DKIM/TLS
# private keys: nothing from /work is ever printed. Only a one-line status is
# written to the termination message.
#
# Env: SW_URL (0.15 management URL), SW_USER, SW_PASSWORD, MIGRATE_V016_URL,
#      MIGRATE_V016_SHA256, SRC_DB (the live 0.15 database), SCRATCH_DB (the
#      hop-1 copy that 0.16.27 recovery mode is allowed to rewrite)
set -eu
umask 077
status() { { printf '%s' "$1" > /dev/termination-log; } 2>/dev/null || true; echo "$1"; }
trap 'rc=$?; [ $rc -eq 0 ] || status "dump: FAILED at step ${STEP:-?} (exit $rc)"' EXIT

cd /work
rm -rf hop1 && mkdir hop1 && cd hop1

STEP=download
python3 - "$MIGRATE_V016_URL" "$MIGRATE_V016_SHA256" <<'EOF'
import hashlib, sys, urllib.request
url, want = sys.argv[1], sys.argv[2]
data = urllib.request.urlopen(url, timeout=60).read()
got = hashlib.sha256(data).hexdigest()
if got != want:
    sys.exit(f"migrate_v016.py sha256 mismatch: got {got}")
open("migrate_v016.py", "wb").write(data)
EOF

STEP=deps
# migrate_v016.py imports requests (+ urllib3). Every package and wheel hash
# is pinned in requirements.txt; installed into the scratch dir only.
python3 -m pip install --quiet --disable-pip-version-check --no-cache-dir \
    --require-hashes --no-deps --only-binary=:all: \
    --target /work/hop1/pydeps -r /scripts/requirements.txt > pip.log 2>&1
export PYTHONPATH=/work/hop1/pydeps

STEP=dump
# Upstream prints progress and warnings to stderr; keep them in /work only.
python3 -s migrate_v016.py dump --url "$SW_URL" --username "$SW_USER" --password "$SW_PASSWORD" \
    > dump.log 2>&1

STEP=convert
python3 -s migrate_v016.py convert > convert.log 2>&1

STEP=patch
for f in config.json export.json; do
    [ -f "$f" ] || { echo "convert produced no $f" >&2; exit 1; }
done
python3 -I /scripts/patch_v016_secrets.py config.json config.patched.json json 2> patch.log
python3 -I /scripts/patch_v016_secrets.py export.json export.patched.ndjson ndjson 2>> patch.log

STEP=retarget
# convert's config.json names the live database (from the 0.15 TOML). Hop 1
# must only ever open the scratch copy: rewrite it, and fail if any field
# selecting a database still names the live one.
python3 -I - config.patched.json config.v016.json "$SRC_DB" "$SCRATCH_DB" <<'EOF'
import json, sys
src, dst, live, scratch = sys.argv[1:5]
c = json.load(open(src))
if c.get("@type") != "PostgreSql":
    sys.exit(f"unexpected data store type {c.get('@type')!r}")
if c.get("database") != live:
    sys.exit("converted config does not name the expected live database")
c["database"] = scratch
c["poolMaxConnections"] = 10
# The tenant role is named like the live database (stalwart_<tenant>), so
# only the fields that select a database are checked.
for k in ("database", "url", "dbName"):
    if c.get(k) == live:
        sys.exit(f"{k} still names the live database after retargeting")
open(dst, "w").write(json.dumps(c))
EOF

STEP=export-check
# The import runs against the scratch copy; nothing in it may point a store
# back at the live database. Only a count is reported.
python3 -I - export.patched.ndjson "$SRC_DB" <<'EOF'
import json, sys
path, live = sys.argv[1:3]
hits = 0
def walk(o):
    global hits
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ("database", "dbName", "url") and v == live:
                hits += 1
            walk(v)
    elif isinstance(o, list):
        for x in o:
            walk(x)
for line in open(path):
    if line.strip():
        walk(json.loads(line))
if hits:
    sys.exit(f"export names the live database in {hits} field(s)")
EOF

STEP=summary
principals=$(grep -c '"x:Account"\|"Account"' export.patched.ndjson 2>/dev/null || true)
warnings=$(grep -ci '^warn\|warning' dump.log convert.log 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
status "dump: OK export_lines=$(wc -l < export.patched.ndjson) account_lines=${principals:-0} warnings=${warnings}"
