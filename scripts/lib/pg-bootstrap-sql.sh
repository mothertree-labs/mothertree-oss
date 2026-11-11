#!/bin/bash
# SQL that bootstraps a FRESH PostgreSQL for the Mothertree deploy scripts —
# one source of truth for devhome (devhome/scripts/pg-bootstrap.sh, over SSH)
# and the developer box (scripts/devbox, through `docker exec`). Creates what
# no deploy step creates on a cold database, in the order deploy_infra needs it:
#   - the postgres superuser password      (PgBouncer + db-init Jobs log in as postgres)
#   - the pgbouncer auth_user              (auth_query reads pg_shadow)
#   - the keycloak role + database         (deploy_infra deploys Keycloak BEFORE
#                                           create_env's docs db-init would create it)
# Idempotent. The production PG VM gets the same objects from Ansible.
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/pg-bootstrap-sql.sh"
#   mt_pg_bootstrap_sql <infra-tenant secrets.yaml> | <psql -d postgres as a superuser>
#
# Passwords travel on stdout -> the psql stdin (never argv) and are quoted as
# SQL literals.

mt_pg_bootstrap_sql() {
  local secrets="${1:?Usage: mt_pg_bootstrap_sql <secrets.yaml>}"
  [ -f "$secrets" ] || { echo "ERROR: $secrets not found" >&2; return 1; }
  local PG_PW BOUNCER_PW KC_PW v
  PG_PW=$(yq '.database.postgres_password // ""' "$secrets")
  BOUNCER_PW=$(yq '.pgbouncer.auth_password // ""' "$secrets")
  KC_PW=$(yq '.keycloak.db_password // ""' "$secrets")
  for v in PG_PW BOUNCER_PW KC_PW; do
    [ -n "${!v}" ] && [ "${!v}" != "null" ] || { echo "ERROR: $v is empty in $secrets" >&2; return 1; }
  done

  _mt_sql_lit() { printf "'%s'" "${1//\'/\'\'}"; }
  echo "\\set ON_ERROR_STOP on"
  echo "ALTER ROLE postgres WITH PASSWORD $(_mt_sql_lit "$PG_PW");"
  echo "SELECT 'CREATE ROLE pgbouncer LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='pgbouncer') \\gexec"
  echo "ALTER ROLE pgbouncer WITH LOGIN PASSWORD $(_mt_sql_lit "$BOUNCER_PW");"
  echo "GRANT SELECT ON pg_catalog.pg_shadow TO pgbouncer;"
  echo "SELECT 'CREATE ROLE keycloak LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='keycloak') \\gexec"
  echo "ALTER ROLE keycloak WITH LOGIN PASSWORD $(_mt_sql_lit "$KC_PW");"
  echo "SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='keycloak') \\gexec"
  echo "REVOKE CONNECT ON DATABASE keycloak FROM PUBLIC;"
  echo "GRANT CONNECT ON DATABASE keycloak TO keycloak;"
  # pgbouncer needs nothing beyond pg_shadow: auth_query runs in auth_dbname=postgres.
  echo "REVOKE pg_read_all_data FROM pgbouncer;"
}
