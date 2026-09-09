#!/bin/bash
# scripts/lib/nextcloud-db.sh — schema-level probes and the cold-start orphan
# guard for a tenant's nextcloud_<tenant> database (issue #548).
#
# Background. Nextcloud keeps its install identity (instanceid, passwordsalt,
# secret) in the in-cluster `nextcloud-identity` Secret; the database lives on
# the always-up PostgreSQL VM. deploy-nextcloud.sh runs `occ maintenance:install`
# only when that Secret is ABSENT (cold start). On the on-demand dev cluster the
# Secret dies with every cluster rebuild while the DB survives, so the install
# runs against a fully populated DB and aborts with "The Login is already being
# used" — eight times between 2026-08-26 and 2026-09-08, and since main pushes
# run the full dev deploy, a poisoned dev also blocks prod deploys.
#
# Two earlier guards swept ALL nextcloud_* DBs from outside the tenant deploy
# (dev-bringup.sh at cluster bring-up, destroy-dev-cluster.sh at teardown) by
# listing the catalog through a `kubectl run -i` pod. Both read a LOST attach
# result (exit 0, empty stdout) as "no databases", so they silently did nothing
# and the poison stayed. A cluster-wide sweep also cannot know which tenant the
# current pipeline leased, so it could stomp a concurrent pipeline's install.
#
# This library moves the decision INTO the per-tenant deploy, where it is scoped
# to exactly the tenant being deployed, and answers with an explicit verdict
# (issue #623): every probe runs as a Job whose logs carry MT_PROBE_VERDICT
# sentinel lines; no sentinel means UNKNOWN and the caller fails CLOSED without
# touching anything. A drop is only reported as done after a fresh probe proves
# the database is gone from the catalog.
#
# Requires scripts/lib/common.sh (print_*, mt_kubectl_probe, mt_probe_job) and
# NS_DB (namespace holding the postgres-credentials Secret and the pgbouncer
# Service).

# The postgres image every probe Job runs. Kept as a literal for Renovate.
MT_NC_PROBE_IMAGE="postgres:17-alpine"

# Tenant DB names are operator-controlled and always nextcloud_<tenant>
# (lowercase + digits + underscore/hyphen). Refuse anything else before it can
# reach a SQL identifier or a Job manifest.
mt_nc_db_name_ok() {
    [[ "${1:-}" =~ ^nextcloud_[a-z0-9][a-z0-9_-]*$ ]]
}

# Does a namespaced K8s object exist? Three answers, never two: a kube-API
# error (timeout, konnectivity blip, RBAC) is NOT "absent" — a plain
# `kubectl get ... || true` would read it as a cold start and, on dev, feed a
# DROP. Returns 0 = present, 1 = absent (a definitive NotFound for the object
# OR its namespace), 2 = could not tell (error text in MT_NC_K8S_ERROR).
# Usage: mt_nc_k8s_state <namespace> <kind> <name>
# shellcheck disable=SC2034  # MT_NC_K8S_ERROR is read by callers
mt_nc_k8s_state() {
    local ns="${1:?mt_nc_k8s_state: namespace}" kind="${2:?mt_nc_k8s_state: kind}" name="${3:?mt_nc_k8s_state: name}"
    local out rc=0
    MT_NC_K8S_ERROR=""
    out=$(kubectl get "$kind" "$name" -n "$ns" -o name 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        # `-o name` prints exactly "<kind>/<name>"; anything else is not an answer.
        case "$out" in
            */"$name") return 0 ;;
            *) MT_NC_K8S_ERROR="unexpected output from kubectl get: $out"; return 2 ;;
        esac
    fi
    if grep -qiE '\(NotFound\)|not found' <<< "$out"; then
        return 1
    fi
    MT_NC_K8S_ERROR="$out"
    return 2
}

# Schema probe script (runs inside the Job; $NC_DB from the Job env). Prints
#   MT_PROBE_DETAIL=db=<0|1> schema=<0|1>
#   MT_PROBE_VERDICT=OK       -> DB present WITH a Nextcloud schema
#   MT_PROBE_VERDICT=MISSING  -> DB absent, or present but empty
# and nothing at all (-> UNKNOWN) when a query cannot run. Always exits 0: the
# verdict travels in the sentinel, never in the exit code.
# shellcheck disable=SC2016  # expanded inside the Job, not here
read -r -d '' MT_NC_SCHEMA_PROBE_SCRIPT <<'PROBE' || true
present=$(psql -h pgbouncer -U postgres -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$NC_DB'") || { echo "nc-schema-probe: catalog query failed"; exit 0; }
case "$present" in
    0) echo "MT_PROBE_DETAIL=db=0 schema=0"; echo "MT_PROBE_VERDICT=MISSING"; exit 0 ;;
    1) ;;
    *) echo "nc-schema-probe: unexpected catalog answer '$present'"; exit 0 ;;
esac
schema=$(psql -h pgbouncer -U postgres -d "$NC_DB" -tAc "SELECT (to_regclass('public.oc_appconfig') IS NOT NULL)::int") || { echo "nc-schema-probe: tenant DB query failed"; exit 0; }
case "$schema" in
    1) echo "MT_PROBE_DETAIL=db=1 schema=1"; echo "MT_PROBE_VERDICT=OK" ;;
    0) echo "MT_PROBE_DETAIL=db=1 schema=0"; echo "MT_PROBE_VERDICT=MISSING" ;;
    *) echo "nc-schema-probe: unexpected schema answer '$schema'" ;;
esac
exit 0
PROBE

# Drop script (runs inside the Job). DROP DATABASE cannot run in a transaction
# block, so a single -c statement. WITH (FORCE) terminates PgBouncer's pooled
# server connections to the tenant DB; the (db, app-user) pool may then cache a
# "database does not exist" login error until db-init recreates the DB — the
# mt_pgbouncer_verify_db gate after db-init heals exactly that.
# shellcheck disable=SC2016
read -r -d '' MT_NC_DROP_SCRIPT <<'DROP' || true
if psql -h pgbouncer -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$NC_DB\" WITH (FORCE);"; then
    echo "MT_PROBE_VERDICT=OK"
else
    echo "nc-drop: DROP DATABASE failed"
    echo "MT_PROBE_VERDICT=FAIL"
fi
exit 0
DROP

# Run one probe-Job script against the tenant DB.
# Usage: _mt_nc_run_job <label> <attempts> <job-prefix> <script> <db>
_mt_nc_run_job() {
    local label="$1" attempts="$2" prefix="$3" script="$4" db="$5"
    mt_kubectl_probe "$label" "$attempts" \
        mt_probe_job "${NS_DB:?NS_DB required}" "$prefix" "$MT_NC_PROBE_IMAGE" \
            --env-from-secret "PGPASSWORD=postgres-credentials/postgres-password" \
            --env "PGCONNECT_TIMEOUT=5" --env "NC_DB=$db" --timeout 180 \
            -- sh -c "$script"
}

# Does <db> exist AND carry a Nextcloud schema (public.oc_appconfig)?
# Returns 0 = present, 1 = absent (no DB, or DB without schema), 2 = UNKNOWN
# (no verdict after 3 attempts). MT_PROBE_DETAIL / MT_PROBE_OUTPUT are left set.
mt_nc_schema_probe() {
    local db="${1:?mt_nc_schema_probe: db}"
    if ! mt_nc_db_name_ok "$db"; then
        print_error "mt_nc_schema_probe: refusing suspicious DB name '$db'"
        return 2
    fi
    local rc=0
    _mt_nc_run_job "nextcloud schema $db" 3 "nc-schema-probe" "$MT_NC_SCHEMA_PROBE_SCRIPT" "$db" || rc=$?
    case "$rc" in
        0|1) return "$rc" ;;
        *)   return 2 ;;
    esac
}

# Drop <db> and PROVE it is gone. Returns 0 only when a fresh catalog probe
# reports db=0 afterwards; anything else (drop failed, no verdict, DB still in
# the catalog) returns 1 with the evidence printed.
mt_nc_drop_db_verified() {
    local db="${1:?mt_nc_drop_db_verified: db}"
    if ! mt_nc_db_name_ok "$db"; then
        print_error "mt_nc_drop_db_verified: refusing suspicious DB name '$db'"
        return 1
    fi
    local rc=0
    _mt_nc_run_job "drop $db" 2 "nc-drop" "$MT_NC_DROP_SCRIPT" "$db" || rc=$?
    if [ "$rc" -ne 0 ]; then
        print_error "DROP DATABASE $db did not succeed (probe verdict: ${MT_PROBE_VERDICT:-UNKNOWN})"
        printf '%s\n' "${MT_PROBE_OUTPUT:-}" | grep -v '^[[:space:]]*$' | tail -5 | sed 's/^/    /'
        return 1
    fi
    # The DROP reported success; do not take its word for it.
    rc=0
    mt_nc_schema_probe "$db" || rc=$?
    if [ "$rc" -eq 1 ] && [ "${MT_PROBE_DETAIL:-}" = "db=0 schema=0" ]; then
        print_success "Verified: $db is no longer in the catalog"
        return 0
    fi
    print_error "DROP DATABASE $db reported success but the follow-up probe did not confirm it (rc=$rc detail='${MT_PROBE_DETAIL:-}')"
    return 1
}

# Cold-start orphan guard. Call ONLY when the tenant's nextcloud-identity Secret
# is absent (the caller establishes that). Decides whether the install Job may
# run against <db>:
#   DB absent / empty      -> clean cold start, proceed         (returns 0)
#   DB with schema, dev    -> orphan of a previous cluster: drop it, verified,
#                             then proceed to a fresh install   (returns 0)
#   DB with schema, other  -> refuse: the identity is lost but the data is not;
#                             an install would fail ("The Login is already being
#                             used") and a drop would destroy tenant data
#                                                                (returns 1)
#   UNKNOWN                -> fail closed, nothing touched       (returns 1)
# Sets MT_NC_COLD_START_ACTION to clean|dropped|refused|unknown (read by callers).
# The dev drop additionally requires <db> to be THIS tenant's DB by convention
# (nextcloud_<tenant>): the orphan verdict comes from this tenant's identity
# Secret, so a tenant config pointing at another tenant's DB must never turn
# into a drop of that other tenant's live data.
# Usage: mt_nc_cold_start_guard <db> <env> <tenant>
# shellcheck disable=SC2034
mt_nc_cold_start_guard() {
    local db="${1:?mt_nc_cold_start_guard: db}" env="${2:?mt_nc_cold_start_guard: env}" tenant="${3:?mt_nc_cold_start_guard: tenant}"
    MT_NC_COLD_START_ACTION="unknown"
    print_status "Cold start: checking whether $db already holds a Nextcloud schema (orphan guard, #548)"
    local rc=0
    mt_nc_schema_probe "$db" || rc=$?
    case "$rc" in
        1)
            MT_NC_COLD_START_ACTION="clean"
            print_success "$db has no Nextcloud schema (${MT_PROBE_DETAIL:-}); clean cold start"
            return 0 ;;
        0)
            if [ "$env" = "dev" ] && [ "$db" != "nextcloud_${tenant}" ]; then
                MT_NC_COLD_START_ACTION="refused"
                print_error "$db is fully installed but is not this tenant's database by convention (expected nextcloud_${tenant}); refusing to drop a DB that may belong to another tenant. Fix database.nextcloud_db in the tenant config or reset the DB by hand. Aborting WITHOUT touching it."
                return 1
            fi
            if [ "$env" = "dev" ]; then
                print_warning "ORPHAN: $db is fully installed (${MT_PROBE_DETAIL:-}) but this cluster has no nextcloud-identity Secret — a previous dev cluster left it behind"
                print_warning "dev pool tenant: dropping $db so the install Job can start from a fresh database (dev data loss acceptable)"
                if mt_nc_drop_db_verified "$db"; then
                    MT_NC_COLD_START_ACTION="dropped"
                    return 0
                fi
                print_error "Could not drop the orphaned $db — aborting before the install Job (it would fail with 'The Login is already being used')"
                return 1
            fi
            MT_NC_COLD_START_ACTION="refused"
            print_error "$db is fully installed (${MT_PROBE_DETAIL:-}) but the nextcloud-identity Secret is missing on $env."
            print_error "The install Job would fail ('The Login is already being used') and dropping the DB would destroy tenant data."
            print_error "Restore the nextcloud-identity Secret (instanceid/passwordsalt/secret from backup) or reinstall deliberately by hand. Aborting WITHOUT touching the tenant."
            return 1 ;;
        *)
            print_error "Could not determine whether $db has a Nextcloud schema (no probe verdict after 3 attempts) — aborting WITHOUT touching the tenant (#623: a lost kubectl result is not an answer)"
            printf '%s\n' "${MT_PROBE_OUTPUT:-}" | grep -v '^[[:space:]]*$' | tail -5 | sed 's/^/    /'
            return 1 ;;
    esac
}
