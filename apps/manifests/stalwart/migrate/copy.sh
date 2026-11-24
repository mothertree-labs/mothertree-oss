#!/bin/bash
# Stalwart 0.15 → v1 migration, Job 2 step 1 (#715): copy the (stopped) 0.15
# database into a scratch database for hop 1. 0.16.27 recovery mode rewrites
# its tables in place, so it must never touch the live 0.15 database: that
# one stays byte-identical, and rolling back before cutover is just scaling
# 0.15 up again.
#
# Also checks the v1 target is empty (stalwart-migrate needs an empty store).
# With RESET_V1=yes (dev only, decided by deploy-stalwart.sh) a non-empty v1
# database is dropped and recreated first.
#
# Runs in postgres:18 as the postgres superuser via PgBouncer.
# Env: PGHOST PGPORT PGUSER PGPASSWORD SRC_DB SCRATCH_DB V1_DB DB_OWNER RESET_V1
set -euo pipefail
status() { { printf '%s' "$1" > /dev/termination-log; } 2>/dev/null || true; echo "$1"; }
trap 'rc=$?; [ $rc -eq 0 ] || status "copy: FAILED at step ${STEP:-?} (exit $rc)"' EXIT

for v in SRC_DB SCRATCH_DB V1_DB DB_OWNER; do
    [ -n "${!v:-}" ] || { echo "$v is not set" >&2; exit 1; }
done
STEP=names
for v in SRC_DB SCRATCH_DB V1_DB DB_OWNER; do
    [[ "${!v}" =~ ^[a-z0-9_]+$ ]] || { echo "$v is not a plain identifier" >&2; exit 1; }
done
# This step DROPs databases as superuser: only ever the two derived names.
[ "$SCRATCH_DB" = "${SRC_DB}_v016" ] && [ "$V1_DB" = "${SRC_DB}_v1" ] \
    || { echo "scratch/v1 database names must be <live>_v016 / <live>_v1" >&2; exit 1; }

q() { psql -v ON_ERROR_STOP=1 -Atq "$@"; }

# Same isolation as db-init-job.yaml.tpl: owned by the tenant role, no
# PUBLIC connect, PgBouncer may connect for auth_query.
create_db() {
    local db="$1"
    q -c "CREATE DATABASE \"$db\" OWNER \"$DB_OWNER\""
    q -c "REVOKE CONNECT ON DATABASE \"$db\" FROM PUBLIC"
    q -c "GRANT CONNECT ON DATABASE \"$db\" TO \"$DB_OWNER\""
    q -c "GRANT CONNECT ON DATABASE \"$db\" TO \"pgbouncer\""
    q -d "$db" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC"
    q -d "$db" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$DB_OWNER\""
    q -d "$db" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm"
}
drop_db() {
    local owner
    owner=$(q -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$1'")
    if [ -n "$owner" ] && [ "$owner" != "$DB_OWNER" ]; then
        echo "refusing to drop $1: owned by $owner, not $DB_OWNER" >&2
        exit 1
    fi
    q -c "DROP DATABASE IF EXISTS \"$1\" WITH (FORCE)"
}

STEP=v1-empty
v1_tables=$(q -d "$V1_DB" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
if [ "$v1_tables" != "0" ]; then
    if [ "${RESET_V1:-}" = "yes" ]; then
        drop_db "$V1_DB"
        create_db "$V1_DB"
    else
        echo "$V1_DB is not empty ($v1_tables tables); refusing (an earlier migration?)" >&2
        exit 1
    fi
fi

STEP=scratch
drop_db "$SCRATCH_DB"
create_db "$SCRATCH_DB"

STEP=copy
src_tables=$(q -d "$SRC_DB" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
# --no-owner/--role: objects end up owned by the tenant role, as Stalwart made them.
# stderr (COPY errors quote table rows) stays on the migration volume, in a
# directory of this step's own (it runs as a different uid than dump.sh,
# whose hop1/ is 0700).
umask 077
mkdir -p /work/copy
pg_dump -Fc --no-owner -d "$SRC_DB" -f /work/copy/live.dump 2> /work/copy/pg_dump.err
# Extensions (pg_trgm, created by db-init) belong to the superuser: create_db
# already made them, and restoring them or their COMMENT as the tenant role
# is refused. Restore everything else.
pg_restore -l /work/copy/live.dump | grep -v -E ' EXTENSION |COMMENT - EXTENSION' > /work/copy/restore.list
if ! pg_restore --no-owner --role="$DB_OWNER" --exit-on-error -L /work/copy/restore.list \
        -d "$SCRATCH_DB" /work/copy/live.dump 2> /work/copy/pg_restore.err; then
    # The ERROR line is the failed statement's message; DETAIL/CONTEXT lines
    # (which can quote row data) are not reported.
    err=$(grep -m1 -o 'ERROR: .*' /work/copy/pg_restore.err | cut -c1-200 || true)
    STEP="copy (${err:-pg_restore failed})"
    exit 1
fi
rm -f /work/copy/live.dump
dst_tables=$(q -d "$SCRATCH_DB" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
[ "$src_tables" = "$dst_tables" ] || { echo "table count mismatch: $src_tables vs $dst_tables" >&2; exit 1; }
size=$(q -c "SELECT pg_size_pretty(pg_database_size('$SCRATCH_DB'))")

status "copy: OK tables=$dst_tables size=$size v1_reset=${RESET_V1:-no}"
