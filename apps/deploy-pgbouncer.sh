#!/bin/bash

# Deploy PgBouncer with Tailscale Sidecar
# Purpose: Deploy PgBouncer connection pooler with Tailscale sidecar to infra-db namespace.
#          PgBouncer provides connection pooling for all tenant databases.
#          The Tailscale sidecar connects to the external PostgreSQL VM over the Headscale mesh.
#
# Creates:
#   - ServiceAccount + RBAC (for Tailscale state Secret management)
#   - ConfigMap (pgbouncer.ini)
#   - Secrets (userlist.txt, Tailscale auth key)
#   - Deployment (PgBouncer + Tailscale sidecar, 2 replicas, anti-affinity)
#   - Service (ClusterIP port 5432)
#
# Called by: deploy_infra (after PostgreSQL section, when PGBOUNCER_ENABLED=true)
# Can also be run standalone.
#
# Usage:
#   ./apps/deploy-pgbouncer.sh -e <env>
#
# Examples:
#   ./apps/deploy-pgbouncer.sh -e dev
#   ./apps/deploy-pgbouncer.sh -e prod

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy PgBouncer with Tailscale sidecar to infra-db namespace."
  echo ""
  echo "Options:"
  echo "  -e <env>       Environment (e.g., dev, prod)"
  echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env

# Load infrastructure configuration
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

mt_require_commands kubectl envsubst shasum

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/pgbouncer"

# =============================================================================
# Load PgBouncer-specific config from infra config
# =============================================================================

# Required: PG VM Tailscale IP (set in infra config or terraform outputs)
: "${PG_VM_TAILSCALE_IP:?PG_VM_TAILSCALE_IP not set. Add pgbouncer.pg_vm_tailscale_ip to infra config.}"
export PG_VM_TAILSCALE_IP

# Required: Headscale URL
: "${HEADSCALE_URL:?HEADSCALE_URL not set. Add headscale.url to infra config.}"
export HEADSCALE_URL

# Required: Tailscale pre-auth key — prefer tagged key for ACL enforcement
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY_PGBOUNCER:-${TAILSCALE_AUTHKEY:?TAILSCALE_AUTHKEY not set. Add tailscale.authkey to infra secrets.}}"

# Required: PgBouncer auth password (for auth_query bootstrap)
: "${PGBOUNCER_AUTH_PASSWORD:?PGBOUNCER_AUTH_PASSWORD not set. Add pgbouncer.auth_password to infra secrets.}"

# Required: PostgreSQL superuser password (from infra secrets, same as on the PG VM)
: "${TF_VAR_postgres_password:?TF_VAR_postgres_password not set. Add database.postgres_password to infra secrets.}"
export PG_SUPERUSER_PASSWORD="$TF_VAR_postgres_password"

# Pool sizing (defaults can be overridden in infra config)
export PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-400}"
export PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-50}"

print_status "Deploying PgBouncer to $NS_DB (env: $MT_ENV)"
print_status "  PG VM Tailscale IP: $PG_VM_TAILSCALE_IP"
print_status "  Headscale URL: $HEADSCALE_URL"
print_status "  Max client connections: $PGBOUNCER_MAX_CLIENT_CONN"
print_status "  Default pool size: $PGBOUNCER_DEFAULT_POOL_SIZE"

# =============================================================================
# Process config template
# =============================================================================

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

envsubst '${PG_VM_TAILSCALE_IP} ${PGBOUNCER_MAX_CLIENT_CONN} ${PGBOUNCER_DEFAULT_POOL_SIZE}' \
  < "$MANIFESTS_DIR/pgbouncer.ini.tpl" > "$WORK_DIR/pgbouncer.ini"

# =============================================================================
# Compute config checksums for deployment annotations
# =============================================================================

CHECKSUM_PGBOUNCER_CONFIG=$(shasum -a 256 "$WORK_DIR/pgbouncer.ini" | cut -d' ' -f1)
CHECKSUM_PGBOUNCER_USERLIST=$(echo -n "${PGBOUNCER_AUTH_PASSWORD}${PG_SUPERUSER_PASSWORD}" | shasum -a 256 | cut -d' ' -f1)

export CHECKSUM_PGBOUNCER_CONFIG CHECKSUM_PGBOUNCER_USERLIST

# =============================================================================
# Apply RBAC (ServiceAccount, Role, RoleBinding)
# =============================================================================

print_status "Applying PgBouncer RBAC..."
mt_reset_change_tracker
envsubst '${NS_DB}' < "$MANIFESTS_DIR/pgbouncer-rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Create/update ConfigMap
# =============================================================================

print_status "Applying PgBouncer ConfigMap..."
kubectl create configmap pgbouncer-config -n "$NS_DB" \
  --from-file=pgbouncer.ini="$WORK_DIR/pgbouncer.ini" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# =============================================================================
# Apply Secrets
# =============================================================================

print_status "Applying PgBouncer Secrets..."
envsubst '${NS_DB} ${PGBOUNCER_AUTH_PASSWORD} ${PG_SUPERUSER_PASSWORD} ${TAILSCALE_AUTHKEY}' \
  < "$MANIFESTS_DIR/pgbouncer-secret.yaml.tpl" | mt_apply kubectl apply -f -

# Create postgres-credentials Secret for deploy scripts (mt_psql / mt_pg_password helpers).
# This replaces the Bitnami-generated docs-postgresql secret that scripts previously read.
print_status "Applying postgres-credentials Secret..."
kubectl create secret generic postgres-credentials -n "$NS_DB" \
  --from-literal=postgres-password="$PG_SUPERUSER_PASSWORD" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# =============================================================================
# Apply Deployment
# =============================================================================

print_status "Applying PgBouncer Deployment..."
envsubst '${NS_DB} ${PG_VM_TAILSCALE_IP} ${HEADSCALE_URL} ${CHECKSUM_PGBOUNCER_CONFIG} ${CHECKSUM_PGBOUNCER_USERLIST}' \
  < "$MANIFESTS_DIR/pgbouncer-deployment.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Service
# =============================================================================

print_status "Applying PgBouncer Service..."
envsubst '${NS_DB}' < "$MANIFESTS_DIR/pgbouncer-service.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Conditional restart (only if config/secrets changed)
# =============================================================================

mt_restart_if_changed deployment/pgbouncer -n "$NS_DB"

# =============================================================================
# Wait for rollout
# =============================================================================

print_status "Waiting for PgBouncer deployment rollout..."
kubectl rollout status deployment/pgbouncer -n "$NS_DB" --timeout=120s

print_success "PgBouncer deployed to $NS_DB"
