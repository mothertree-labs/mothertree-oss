#!/usr/bin/env bash
# One-time bootstrap of a FRESH devhome PostgreSQL (after ansible/playbook.yml's
# postgres play has installed and configured it). Creates what no deploy step
# creates on a cold database, in the order deploy_infra needs it:
#   - the postgres superuser password      (PgBouncer + db-init Jobs log in as postgres)
#   - the pgbouncer auth_user              (auth_query reads pg_shadow)
#   - the keycloak role + database         (deploy_infra deploys Keycloak BEFORE
#                                           create_env's docs db-init would create it)
# Idempotent. Passwords come from the infra tenant's <env>.secrets.yaml; the SQL
# itself lives in scripts/lib/pg-bootstrap-sql.sh (shared with scripts/devbox).
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

# shellcheck source=scripts/lib/pg-bootstrap-sql.sh source-path=SCRIPTDIR/../..
source "$REPO_ROOT/scripts/lib/pg-bootstrap-sql.sh"
# Build the SQL first so a missing password fails here, before ssh runs.
SQL=$(mt_pg_bootstrap_sql "$SECRETS")
printf '%s\n' "$SQL" | ssh "$@" "$TARGET" 'sudo -u postgres psql -q -d postgres'
echo "PostgreSQL bootstrap complete for env=$ENV ($TARGET)"
