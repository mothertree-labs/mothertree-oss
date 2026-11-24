#!/bin/sh
# Stalwart 0.15 → v1 migration, Job 2 main container (#715): copy the
# hop-1 v0.16.27 store into the empty v1 database with upstream's
# stalwart-migrate, then verify every account.
#
# The source is the scratch copy (config.v016.json), the target is
# STALWART_V1_DB_NAME; the live 0.15 database is opened by neither.
# answers.toml is static: hop 1 creates no OIDC directory, so prepare only
# asks the global questions (blob store, categories, changed defaults).
#
# Runs in stalwartlabs/stalwart-migrate. Env: PG_HOST V1_DB DB_OWNER
# STALWART_DB_PASSWORD (both configs reference it) and the S3 keys.
set -eu
umask 077
status() { { printf '%s' "$1" > /dev/termination-log; } 2>/dev/null || true; echo "$1"; }
trap 'rc=$?; [ $rc -eq 0 ] || status "migrate: FAILED at step ${STEP:-?} (exit $rc)"' EXIT

W=/work/hop2
rm -rf "$W" && mkdir -p "$W/state"
cp /scripts/answers.toml "$W/state/answers.toml"
printf '{"@type":"PostgreSql","host":"%s","port":5432,"database":"%s","authUsername":"%s","authSecret":{"@type":"EnvironmentVariable","variableName":"STALWART_DB_PASSWORD"},"useTls":false,"poolMaxConnections":10}' \
    "$PG_HOST" "$V1_DB" "$DB_OWNER" > "$W/config.v1.json"

M="stalwart-migrate --log-format json"
SRC=/work/hop1/config.v016.json

STEP=prepare
$M prepare --non-interactive --source "$SRC" --state "$W/state" > "$W/prepare.log" 2>&1

STEP=run-final
# --concurrency caps parallel writers (each one is a PgBouncer session and a
# PostgreSQL connection, against a tight max_connections budget).
$M run --final --yes --concurrency 4 --source "$SRC" --target "$W/config.v1.json" \
    --state "$W/state" > "$W/run-final.log" 2>&1

STEP=verify
$M verify --full --source "$SRC" --target "$W/config.v1.json" --state "$W/state" \
    > "$W/verify.log" 2>&1

STEP=summary
# Only counters leave the pod; the logs stay on the migration volume.
max() { grep -oE "\"$1\":[0-9]+" "$2" | cut -d: -f2 | sort -n | tail -1; }
accounts=$(max accounts_full "$W/run-final.log")
failed=$(max accounts_failed "$W/run-final.log")
emails=$(max emails_written "$W/run-final.log")
mismatches=$(max mismatches "$W/verify.log")
if [ "${failed:-0}" != "0" ] || [ "${mismatches:-x}" != "0" ]; then
    STEP="verify (accounts_failed=${failed:-?} mismatches=${mismatches:-?})"
    exit 1
fi
# The converted export and logs hold the OAuth signing key and DKIM keys;
# the volume is deleted too, this is belt and braces.
rm -rf /work/hop1 /work/hop2 /work/copy 2>/dev/null || true
status "migrate: OK accounts=${accounts:-?} emails=${emails:-?} accounts_failed=0 mismatches=0"
