#!/usr/bin/env bash
# One-time bootstrap of a FRESH devhome PostgreSQL (after ansible/playbook.yml's
# postgres play has installed and configured it). Creates what no deploy step
# creates on a cold database, in the order deploy_infra needs it:
#   - the postgres superuser password      (PgBouncer + db-init Jobs log in as postgres)
#   - the pgbouncer auth_user              (auth_query reads pg_shadow)
#   - the keycloak role + database         (deploy_infra deploys Keycloak BEFORE
#                                           create_env's docs db-init would create it)
# Idempotent. Passwords come from the infra tenant's <env>.secrets.yaml.
#
# Usage: devhome/scripts/pg-bootstrap.sh -e <env> -t <infra-tenant> <ssh-target> [ssh options...]
#   e.g. devhome/scripts/pg-bootstrap.sh -e devhome -t <infra-tenant> root@172.30.0.10 -o ProxyJump=root@<box>
set -euo pipefail

usage() { echo "Usage: $0 -e <env> -t <infra-tenant> <ssh-target> [ssh options...]" >&2; exit 2; }
[ "${1:-}" = "-e" ] && [ "${3:-}" = "-t" ] || usage
ENV="${2:?env required}"; TENANT="${4:?infra tenant required}"; TARGET="${5:?ssh target required}"; shift 5
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/paths.sh source-path=SCRIPTDIR/../..
source "$REPO_ROOT/scripts/lib/paths.sh"
_mt_resolve_tenants_dir
SECRETS="$MT_TENANTS_DIR/$TENANT/${ENV}.secrets.yaml"
[ -f "$SECRETS" ] || { echo "ERROR: $SECRETS not found" >&2; exit 1; }

PG_PW=$(yq '.database.postgres_password // ""' "$SECRETS")
BOUNCER_PW=$(yq '.pgbouncer.auth_password // ""' "$SECRETS")
KC_PW=$(yq '.keycloak.db_password // ""' "$SECRETS")
for v in PG_PW BOUNCER_PW KC_PW; do
  [ -n "${!v}" ] && [ "${!v}" != "null" ] || { echo "ERROR: $v is empty in $SECRETS" >&2; exit 1; }
done

# Passwords travel on stdin (never argv) and are quoted as SQL literals there.
sql_lit() { printf "'%s'" "${1//\'/\'\'}"; }
{
  echo "\\set ON_ERROR_STOP on"
  echo "ALTER ROLE postgres WITH PASSWORD $(sql_lit "$PG_PW");"
  echo "SELECT 'CREATE ROLE pgbouncer LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='pgbouncer') \\gexec"
  echo "ALTER ROLE pgbouncer WITH LOGIN PASSWORD $(sql_lit "$BOUNCER_PW");"
  echo "GRANT SELECT ON pg_catalog.pg_shadow TO pgbouncer;"
  echo "SELECT 'CREATE ROLE keycloak LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='keycloak') \\gexec"
  echo "ALTER ROLE keycloak WITH LOGIN PASSWORD $(sql_lit "$KC_PW");"
  echo "SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='keycloak') \\gexec"
  echo "REVOKE CONNECT ON DATABASE keycloak FROM PUBLIC;"
  echo "GRANT CONNECT ON DATABASE keycloak TO keycloak;"
  # pgbouncer needs nothing beyond pg_shadow: auth_query runs in auth_dbname=postgres.
  echo "REVOKE pg_read_all_data FROM pgbouncer;"
} | ssh "$@" "$TARGET" 'sudo -u postgres psql -q -d postgres'
echo "PostgreSQL bootstrap complete for env=$ENV ($TARGET)"
