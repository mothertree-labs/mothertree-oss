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
#      MIGRATE_V016_SHA256
set -eu
umask 077
status() { printf '%s' "$1" > /dev/termination-log; echo "$1"; }
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

STEP=dump
# Upstream prints progress and warnings to stderr; keep them in /work only.
python3 -I migrate_v016.py dump --url "$SW_URL" --username "$SW_USER" --password "$SW_PASSWORD" \
    > dump.log 2>&1

STEP=convert
python3 -I migrate_v016.py convert > convert.log 2>&1

STEP=patch
for f in config.json export.json; do
    [ -f "$f" ] || { echo "convert produced no $f" >&2; exit 1; }
done
python3 -I /scripts/patch_v016_secrets.py config.json config.patched.json json 2> patch.log
python3 -I /scripts/patch_v016_secrets.py export.json export.patched.ndjson ndjson 2>> patch.log

STEP=summary
principals=$(grep -c '"x:Account"\|"Account"' export.patched.ndjson 2>/dev/null || true)
warnings=$(grep -ci '^warn\|warning' dump.log convert.log 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
status "dump: OK export_lines=$(wc -l < export.patched.ndjson) account_lines=${principals:-0} warnings=${warnings}"
