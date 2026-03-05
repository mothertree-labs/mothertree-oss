#!/bin/bash
# Tenant configuration loader for Mothertree scripts
#
# Source this and call mt_load_tenant_config to load all config and secrets
# for a tenant+environment combination from YAML files.
#
# Prerequisites:
#   - MT_ENV and MT_TENANT must be set (via args.sh or directly)
#   - REPO_ROOT must be set (via args.sh or directly)
#   - yq must be installed
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/config.sh"
#   mt_load_tenant_config
#   # All config vars (TENANT_DOMAIN, NS_MATRIX, MATRIX_HOST, etc.) are now exported
#
# The loader reads:
#   tenants/<tenant>/<env>.config.yaml   — non-secret configuration
#   tenants/<tenant>/<env>.secrets.yaml  — secrets (or $MT_SECRETS_FILE override)
#
# After loading, all variables needed by helmfile, envsubst, and terraform are
# exported as environment variables. This is an internal implementation detail —
# callers should pass -e/-t on the CLI, not set env vars.

# Guard against double-sourcing
if [ "${_MT_TENANT_CONFIG_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# mt_load_tenant_config — main entry point
# ---------------------------------------------------------------------------
mt_load_tenant_config() {
  # Guard against double-calling
  if [ "${_MT_TENANT_CONFIG_LOADED:-}" = "1" ]; then
    return 0
  fi
  _MT_TENANT_CONFIG_LOADED=1

  # Validate prerequisites
  if [ -z "${MT_ENV:-}" ]; then
    echo "[ERROR] MT_ENV is not set. Call mt_parse_args or set MT_ENV before mt_load_tenant_config." >&2
    exit 1
  fi
  if [ -z "${MT_TENANT:-}" ]; then
    echo "[ERROR] MT_TENANT is not set. Call mt_parse_args or set MT_TENANT before mt_load_tenant_config." >&2
    exit 1
  fi
  if [ -z "${REPO_ROOT:-}" ]; then
    echo "[ERROR] REPO_ROOT is not set." >&2
    exit 1
  fi

  # Resolve config paths (supports submodule and legacy layouts)
  source "${REPO_ROOT}/scripts/lib/paths.sh"
  _mt_resolve_tenants_dir

  _mt_validate_paths
  _mt_set_kubeconfig
  _mt_load_tenant_yaml
  _mt_derive_hostnames
  _mt_set_namespaces
  _mt_load_scaling_config
  _mt_detect_pg
  _mt_load_tenant_secrets
  _mt_load_turn_server_ip
  _mt_export_all
}

# ---------------------------------------------------------------------------
# Internal: validate tenant directory and file paths
# ---------------------------------------------------------------------------
_mt_validate_paths() {
  local tenant_dir="$MT_TENANTS_DIR/$MT_TENANT"
  if [ ! -d "$tenant_dir" ]; then
    echo "[ERROR] Tenant directory not found: $tenant_dir" >&2
    echo "" >&2
    echo "Available tenants:" >&2
    ls -1 "$MT_TENANTS_DIR/" 2>/dev/null | grep -v README || echo "  (none found)" >&2
    exit 1
  fi

  export TENANT_CONFIG="$tenant_dir/$MT_ENV.config.yaml"
  if [ ! -f "$TENANT_CONFIG" ]; then
    echo "[ERROR] Tenant config not found: $TENANT_CONFIG" >&2
    echo "Create this file based on the .example directory." >&2
    exit 1
  fi

  # Secrets file: use override if provided, otherwise convention
  if [ -n "${MT_SECRETS_FILE:-}" ]; then
    export TENANT_SECRETS="$MT_SECRETS_FILE"
  else
    export TENANT_SECRETS="$tenant_dir/$MT_ENV.secrets.yaml"
  fi

  if [ ! -f "$TENANT_SECRETS" ]; then
    echo "[ERROR] Tenant secrets not found: $TENANT_SECRETS" >&2
    echo "Create this file based on the .example directory." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Internal: set KUBECONFIG from convention
# ---------------------------------------------------------------------------
_mt_set_kubeconfig() {
  export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"
}

# ---------------------------------------------------------------------------
# Internal: load all config fields from the tenant YAML in a single yq call
# ---------------------------------------------------------------------------
_mt_load_tenant_yaml() {
  # Batch-extract all config fields in one yq invocation for performance
  eval "$(yq '
    "TENANT_DISPLAY_NAME=" + (.tenant.display_name | @sh) + "\n" +
    "TENANT_DOMAIN=" + (.dns.domain | @sh) + "\n" +
    "TENANT_ENV_DNS_LABEL=" + (.dns.env_dns_label // "" | @sh) + "\n" +
    "TENANT_COOKIE_DOMAIN=" + (.dns.cookie_domain // "" | @sh) + "\n" +
    "TENANT_KEYCLOAK_REALM=" + (.keycloak.realm | @sh) + "\n" +
    "S3_CLUSTER=" + (.s3.cluster | @sh) + "\n" +
    "S3_BUCKET_PREFIX=" + (.s3.bucket_prefix // "" | @sh) + "\n" +
    "S3_DOCS_BUCKET=" + (.s3.docs_bucket | @sh) + "\n" +
    "S3_MATRIX_BUCKET=" + (.s3.matrix_bucket | @sh) + "\n" +
    "S3_FILES_BUCKET=" + (.s3.files_bucket | @sh) + "\n" +
    "S3_MAIL_BUCKET=" + (.s3.mail_bucket // "" | @sh) + "\n" +
    "DOCS_DB_NAME=" + (.database.docs_db | @sh) + "\n" +
    "NEXTCLOUD_DB_NAME=" + (.database.nextcloud_db | @sh) + "\n" +
    "SYNAPSE_DB_NAME=" + (.database.synapse_db | @sh) + "\n" +
    "STALWART_DB_NAME=" + (.database.stalwart_db // "" | @sh) + "\n" +
    "ROUNDCUBE_DB_NAME=" + (.database.roundcube_db // "" | @sh) + "\n" +
    "INFRA_DOMAIN=" + (.infra.domain // .dns.domain | @sh) + "\n" +
    "MAIL_SUBDOMAIN=" + (.dns.mail_subdomain // "mail" | @sh) + "\n" +
    "CALENDAR_ENABLED=" + (.features.calendar_enabled // false | tostring | @sh) + "\n" +
    "OFFICE_ENABLED=" + (.features.office_enabled // false | tostring | @sh) + "\n" +
    "MAIL_ENABLED=" + (.features.mail_enabled // false | tostring | @sh) + "\n" +
    "JITSI_ENABLED=" + (.features.jitsi_enabled // true | tostring | @sh) + "\n" +
    "MATRIX_ENABLED=" + (.features.matrix_enabled // true | tostring | @sh) + "\n" +
    "DOCS_ENABLED=" + (.features.docs_enabled // true | tostring | @sh) + "\n" +
    "FILES_ENABLED=" + (.features.files_enabled // true | tostring | @sh) + "\n" +
    "WEBMAIL_ENABLED=" + (.features.webmail_enabled // false | tostring | @sh) + "\n" +
    "ADMIN_PORTAL_ENABLED=" + (.features.admin_portal_enabled // false | tostring | @sh) + "\n" +
    "ACCOUNT_PORTAL_ENABLED=" + (.features.account_portal_enabled // false | tostring | @sh) + "\n" +
    "GOOGLE_IMPORT_ENABLED=" + (.features.google_import_enabled // false | tostring | @sh) + "\n" +
    "EMAIL_PROBE_ENABLED=" + (.features.email_probe_enabled // false | tostring | @sh) + "\n" +
    "EMAIL_PROBE_TARGET_EMAIL=" + (.email_probe.target_address // "" | @sh) + "\n" +
    "DEFAULT_EMAIL_QUOTA_MB=" + (.email.default_quota_mb // 5120 | tostring | @sh) + "\n" +
    "PRIVACY_POLICY_URL=" + (.policies.privacy_policy_url // "" | @sh) + "\n" +
    "TERMS_OF_USE_URL=" + (.policies.terms_of_use_url // "" | @sh) + "\n" +
    "ACCEPTABLE_USE_POLICY_URL=" + (.policies.acceptable_use_policy_url // "" | @sh)
  ' "$TENANT_CONFIG")"

  # Validate required fields
  local missing=()
  [ -z "$TENANT_DOMAIN" ] || [ "$TENANT_DOMAIN" = "null" ] && missing+=("dns.domain")
  [ -z "$DOCS_DB_NAME" ] || [ "$DOCS_DB_NAME" = "null" ] && missing+=("database.docs_db")
  [ -z "$NEXTCLOUD_DB_NAME" ] || [ "$NEXTCLOUD_DB_NAME" = "null" ] && missing+=("database.nextcloud_db")
  [ -z "$SYNAPSE_DB_NAME" ] || [ "$SYNAPSE_DB_NAME" = "null" ] && missing+=("database.synapse_db")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "[ERROR] Required config missing in $TENANT_CONFIG: ${missing[*]}" >&2
    exit 1
  fi

  # Derived identity vars
  export TENANT="$MT_TENANT"
  export TENANT_NAME="$MT_TENANT"
  export TENANT_DB_USER="docs_${MT_TENANT}"
  export SYNAPSE_DB_USER="$SYNAPSE_DB_NAME"
  export STALWART_DB_USER="stalwart_${MT_TENANT}"
  export ROUNDCUBE_DB_USER="roundcube_${MT_TENANT}"

  # Aliases for templates
  export BUCKET_NAME="$S3_DOCS_BUCKET"
  export BASE_DOMAIN="$TENANT_DOMAIN"
  export COOKIE_DOMAIN="${TENANT_COOKIE_DOMAIN:-.${TENANT_DOMAIN}}"
  export KEYCLOAK_REALM="$TENANT_KEYCLOAK_REALM"

  # Email domain (smtp.domain or derived from env_dns_label)
  local smtp_domain_config
  smtp_domain_config=$(yq '.smtp.domain // ""' "$TENANT_CONFIG")
  if [ -n "$smtp_domain_config" ] && [ "$smtp_domain_config" != "null" ]; then
    export EMAIL_DOMAIN="$smtp_domain_config"
  elif [ -n "$TENANT_ENV_DNS_LABEL" ] && [ "$TENANT_ENV_DNS_LABEL" != "null" ]; then
    export EMAIL_DOMAIN="${TENANT_ENV_DNS_LABEL}.${TENANT_DOMAIN}"
  else
    export EMAIL_DOMAIN="${TENANT_DOMAIN}"
  fi
  export SMTP_DOMAIN="${EMAIL_DOMAIN}"
}

# ---------------------------------------------------------------------------
# Internal: compute all hostnames from domain + env_dns_label
# ---------------------------------------------------------------------------
_mt_derive_hostnames() {
  local label="$TENANT_ENV_DNS_LABEL"
  if [ -n "$label" ] && [ "$label" != "null" ]; then
    export MATRIX_HOST="matrix.${label}.${TENANT_DOMAIN}"
    export SYNAPSE_HOST="synapse.${label}.${TENANT_DOMAIN}"
    export SYNAPSE_ADMIN_HOST="synapse-admin.internal.${label}.${TENANT_DOMAIN}"
    export ADMIN_HOST="admin.${label}.${TENANT_DOMAIN}"
    export ACCOUNT_HOST="account.${label}.${TENANT_DOMAIN}"
    export DOCS_HOST="docs.${label}.${TENANT_DOMAIN}"
    export FILES_HOST="files.${label}.${TENANT_DOMAIN}"
    export JITSI_HOST="jitsi.${label}.${TENANT_DOMAIN}"
    export HOME_HOST="home.${label}.${TENANT_DOMAIN}"
    export AUTH_HOST="auth.${label}.${TENANT_DOMAIN}"
    export MAIL_HOST="${MAIL_SUBDOMAIN:-mail}.${label}.${TENANT_DOMAIN}"
    export IMAP_HOST="imap.${label}.${TENANT_DOMAIN}"
    export SMTP_HOST="smtp.${label}.${TENANT_DOMAIN}"
    export WEBMAIL_HOST="webmail.${label}.${TENANT_DOMAIN}"
    export CALENDAR_HOST="calendar.${label}.${TENANT_DOMAIN}"
    export OFFICE_HOST="office.${label}.${TENANT_DOMAIN}"
    export MATRIX_SERVER_NAME="${label}.${TENANT_DOMAIN}"
    export WEBADMIN_HOST="webadmin.internal.${label}.${TENANT_DOMAIN}"
  else
    export MATRIX_HOST="matrix.${TENANT_DOMAIN}"
    export SYNAPSE_HOST="synapse.${TENANT_DOMAIN}"
    export SYNAPSE_ADMIN_HOST="synapse-admin.prod.${TENANT_DOMAIN}"
    export ADMIN_HOST="admin.${TENANT_DOMAIN}"
    export ACCOUNT_HOST="account.${TENANT_DOMAIN}"
    export DOCS_HOST="docs.${TENANT_DOMAIN}"
    export FILES_HOST="files.${TENANT_DOMAIN}"
    export JITSI_HOST="jitsi.${TENANT_DOMAIN}"
    export HOME_HOST="home.${TENANT_DOMAIN}"
    export AUTH_HOST="auth.${TENANT_DOMAIN}"
    export MAIL_HOST="${MAIL_SUBDOMAIN:-mail}.${TENANT_DOMAIN}"
    export IMAP_HOST="imap.${TENANT_DOMAIN}"
    export SMTP_HOST="smtp.${TENANT_DOMAIN}"
    export WEBMAIL_HOST="webmail.${TENANT_DOMAIN}"
    export CALENDAR_HOST="calendar.${TENANT_DOMAIN}"
    export OFFICE_HOST="office.${TENANT_DOMAIN}"
    export MATRIX_SERVER_NAME="${TENANT_DOMAIN}"
    export WEBADMIN_HOST="webadmin.prod.${TENANT_DOMAIN}"
  fi
}

# ---------------------------------------------------------------------------
# Internal: set namespace variables
# ---------------------------------------------------------------------------
_mt_set_namespaces() {
  export TENANT_NS_PREFIX="tn-$MT_TENANT"

  # Tenant-specific namespaces
  export NS_MATRIX="${TENANT_NS_PREFIX}-matrix"
  export NS_DOCS="${TENANT_NS_PREFIX}-docs"
  export NS_FILES="${TENANT_NS_PREFIX}-files"
  export NS_JITSI="${TENANT_NS_PREFIX}-jitsi"
  export NS_STALWART="${TENANT_NS_PREFIX}-mail"
  export NS_WEBMAIL="${TENANT_NS_PREFIX}-webmail"
  export NS_ADMIN="${TENANT_NS_PREFIX}-admin"
  export NS_OFFICE="${TENANT_NS_PREFIX}-office"
  export NS_HOME="${TENANT_NS_PREFIX}-home"

  # Shared infrastructure namespaces
  export NS_DB="infra-db"
  export NS_AUTH="infra-auth"
  export NS_MONITORING="infra-monitoring"
  export NS_INGRESS="infra-ingress"
  export NS_INGRESS_INTERNAL="infra-ingress-internal"
  export NS_CERTMANAGER="infra-cert-manager"
  export NS_MAIL="infra-mail"

  # Backward-compat alias for stalwart scripts
  # (NS_MAIL is overloaded: infra-mail for shared postfix, tn-<tenant>-mail for stalwart)
  # The stalwart deploy script expects NS_MAIL = tn-<tenant>-mail for its namespace.
  # We keep NS_MAIL as infra-mail here (used by create_env for postfix/DKIM) and
  # let stalwart scripts use NS_STALWART instead.
}

# ---------------------------------------------------------------------------
# Internal: load scaling configuration from YAML
# ---------------------------------------------------------------------------
_mt_load_scaling_config() {
  # Batch-extract scaling config in one yq call
  eval "$(yq '
    "DOCS_BACKEND_MIN_REPLICAS=" + (.resources.docs.backend.min_replicas | tostring | @sh) + "\n" +
    "DOCS_BACKEND_MAX_REPLICAS=" + (.resources.docs.backend.max_replicas | tostring | @sh) + "\n" +
    "DOCS_GUNICORN_WORKERS=" + (.resources.docs.backend.gunicorn_workers // 3 | tostring | @sh) + "\n" +
    "DOCS_FRONTEND_MIN_REPLICAS=" + (.resources.docs.frontend.min_replicas | tostring | @sh) + "\n" +
    "DOCS_FRONTEND_MAX_REPLICAS=" + (.resources.docs.frontend.max_replicas | tostring | @sh) + "\n" +
    "YPROVIDER_MIN_REPLICAS=" + (.resources.docs.y_provider.min_replicas | tostring | @sh) + "\n" +
    "YPROVIDER_MAX_REPLICAS=" + (.resources.docs.y_provider.max_replicas | tostring | @sh) + "\n" +
    "ELEMENT_MIN_REPLICAS=" + (.resources.element.min_replicas | tostring | @sh) + "\n" +
    "ELEMENT_MAX_REPLICAS=" + (.resources.element.max_replicas | tostring | @sh) + "\n" +
    "JITSI_WEB_MIN_REPLICAS=" + (.resources.jitsi.web.min_replicas | tostring | @sh) + "\n" +
    "JITSI_WEB_MAX_REPLICAS=" + (.resources.jitsi.web.max_replicas | tostring | @sh) + "\n" +
    "JVB_MIN_REPLICAS=" + (.resources.jitsi.jvb.min_replicas | tostring | @sh) + "\n" +
    "JVB_MAX_REPLICAS=" + (.resources.jitsi.jvb.max_replicas | tostring | @sh) + "\n" +
    "JVB_PORT=" + (.resources.jitsi.jvb_port // 31000 | tostring | @sh) + "\n" +
    "ROUNDCUBE_MIN_REPLICAS=" + (.resources.roundcube.min_replicas | tostring | @sh) + "\n" +
    "ROUNDCUBE_MAX_REPLICAS=" + (.resources.roundcube.max_replicas | tostring | @sh) + "\n" +
    "ADMIN_PORTAL_MIN_REPLICAS=" + (.resources.admin_portal.min_replicas | tostring | @sh) + "\n" +
    "ADMIN_PORTAL_MAX_REPLICAS=" + (.resources.admin_portal.max_replicas | tostring | @sh) + "\n" +
    "ACCOUNT_PORTAL_MIN_REPLICAS=" + (.resources.account_portal.min_replicas // 1 | tostring | @sh) + "\n" +
    "ACCOUNT_PORTAL_MAX_REPLICAS=" + (.resources.account_portal.max_replicas // 3 | tostring | @sh) + "\n" +
    "SYNAPSE_ADMIN_MIN_REPLICAS=" + (.resources.synapse_admin.min_replicas | tostring | @sh) + "\n" +
    "SYNAPSE_ADMIN_MAX_REPLICAS=" + (.resources.synapse_admin.max_replicas | tostring | @sh) + "\n" +
    "STALWART_MIN_REPLICAS=" + (.resources.stalwart.min_replicas | tostring | @sh) + "\n" +
    "STALWART_MAX_REPLICAS=" + (.resources.stalwart.max_replicas | tostring | @sh) + "\n" +
    "STALWART_MEMORY_REQUEST=" + (.resources.stalwart.memory_request // "256Mi" | tostring | @sh) + "\n" +
    "STALWART_MEMORY_LIMIT=" + (.resources.stalwart.memory_limit // "1Gi" | tostring | @sh) + "\n" +
    "STALWART_CPU_REQUEST=" + (.resources.stalwart.cpu_request // "100m" | tostring | @sh) + "\n" +
    "STALWART_STORAGE_SIZE=" + (.resources.stalwart.storage_size // "1Gi" | tostring | @sh) + "\n" +
    "STALWART_SMTPS_PORT=" + (.resources.stalwart.smtps_port // "" | tostring | @sh) + "\n" +
    "STALWART_SUBMISSION_PORT=" + (.resources.stalwart.submission_port // "" | tostring | @sh) + "\n" +
    "STALWART_IMAPS_PORT=" + (.resources.stalwart.imaps_port // "" | tostring | @sh) + "\n" +
    "STALWART_IMAPS_APP_PORT=" + (.resources.stalwart.imaps_app_port // "" | tostring | @sh) + "\n" +
    "STALWART_SUBMISSION_APP_PORT=" + (.resources.stalwart.submission_app_port // "" | tostring | @sh) + "\n" +
    "ROUNDCUBE_MEMORY_REQUEST=" + (.resources.roundcube.memory_request // "128Mi" | tostring | @sh) + "\n" +
    "ROUNDCUBE_MEMORY_LIMIT=" + (.resources.roundcube.memory_limit // "256Mi" | tostring | @sh) + "\n" +
    "ROUNDCUBE_CPU_REQUEST=" + (.resources.roundcube.cpu_request // "100m" | tostring | @sh) + "\n" +
    "KEYCLOAK_REPLICAS=" + (.resources.keycloak.replicas | tostring | @sh) + "\n" +
    "REDIS_REPLICAS=" + (.resources.redis.replicas | tostring | @sh) + "\n" +
    "SYNAPSE_REPLICAS=" + (.resources.synapse.replicas // 1 | tostring | @sh) + "\n" +
    "NEXTCLOUD_MIN_REPLICAS=" + (.resources.nextcloud.min_replicas | tostring | @sh) + "\n" +
    "NEXTCLOUD_MAX_REPLICAS=" + (.resources.nextcloud.max_replicas | tostring | @sh) + "\n" +
    "NEXTCLOUD_CPU_REQUEST=" + (.resources.nextcloud.cpu_request // "500m" | tostring | @sh) + "\n" +
    "NEXTCLOUD_HPA_SCALEDOWN_WINDOW=" + (.resources.nextcloud.hpa_scaledown_window // 300 | tostring | @sh) + "\n" +
    "EMAIL_PROBE_MEMORY_REQUEST=" + (.resources.email_probe.memory_request // "32Mi" | tostring | @sh) + "\n" +
    "EMAIL_PROBE_MEMORY_LIMIT=" + (.resources.email_probe.memory_limit // "64Mi" | tostring | @sh) + "\n" +
    "EMAIL_PROBE_CPU_REQUEST=" + (.resources.email_probe.cpu_request // "50m" | tostring | @sh)
  ' "$TENANT_CONFIG")"

  # Validate required scaling fields — fail fast instead of propagating 'null'
  # to K8s manifests (e.g., minReplicas: null breaks HPAs)
  local _missing=()
  [ "$DOCS_BACKEND_MIN_REPLICAS" = "null" ] || [ -z "$DOCS_BACKEND_MIN_REPLICAS" ] && _missing+=("resources.docs.backend.min_replicas")
  [ "$DOCS_BACKEND_MAX_REPLICAS" = "null" ] || [ -z "$DOCS_BACKEND_MAX_REPLICAS" ] && _missing+=("resources.docs.backend.max_replicas")
  [ "$DOCS_FRONTEND_MIN_REPLICAS" = "null" ] || [ -z "$DOCS_FRONTEND_MIN_REPLICAS" ] && _missing+=("resources.docs.frontend.min_replicas")
  [ "$DOCS_FRONTEND_MAX_REPLICAS" = "null" ] || [ -z "$DOCS_FRONTEND_MAX_REPLICAS" ] && _missing+=("resources.docs.frontend.max_replicas")
  [ "$YPROVIDER_MIN_REPLICAS" = "null" ] || [ -z "$YPROVIDER_MIN_REPLICAS" ] && _missing+=("resources.docs.y_provider.min_replicas")
  [ "$YPROVIDER_MAX_REPLICAS" = "null" ] || [ -z "$YPROVIDER_MAX_REPLICAS" ] && _missing+=("resources.docs.y_provider.max_replicas")
  [ "$ELEMENT_MIN_REPLICAS" = "null" ] || [ -z "$ELEMENT_MIN_REPLICAS" ] && _missing+=("resources.element.min_replicas")
  [ "$ELEMENT_MAX_REPLICAS" = "null" ] || [ -z "$ELEMENT_MAX_REPLICAS" ] && _missing+=("resources.element.max_replicas")
  [ "$JITSI_WEB_MIN_REPLICAS" = "null" ] || [ -z "$JITSI_WEB_MIN_REPLICAS" ] && _missing+=("resources.jitsi.web.min_replicas")
  [ "$JITSI_WEB_MAX_REPLICAS" = "null" ] || [ -z "$JITSI_WEB_MAX_REPLICAS" ] && _missing+=("resources.jitsi.web.max_replicas")
  [ "$JVB_MIN_REPLICAS" = "null" ] || [ -z "$JVB_MIN_REPLICAS" ] && _missing+=("resources.jitsi.jvb.min_replicas")
  [ "$JVB_MAX_REPLICAS" = "null" ] || [ -z "$JVB_MAX_REPLICAS" ] && _missing+=("resources.jitsi.jvb.max_replicas")
  [ "$ROUNDCUBE_MIN_REPLICAS" = "null" ] || [ -z "$ROUNDCUBE_MIN_REPLICAS" ] && _missing+=("resources.roundcube.min_replicas")
  [ "$ROUNDCUBE_MAX_REPLICAS" = "null" ] || [ -z "$ROUNDCUBE_MAX_REPLICAS" ] && _missing+=("resources.roundcube.max_replicas")
  [ "$ADMIN_PORTAL_MIN_REPLICAS" = "null" ] || [ -z "$ADMIN_PORTAL_MIN_REPLICAS" ] && _missing+=("resources.admin_portal.min_replicas")
  [ "$ADMIN_PORTAL_MAX_REPLICAS" = "null" ] || [ -z "$ADMIN_PORTAL_MAX_REPLICAS" ] && _missing+=("resources.admin_portal.max_replicas")
  [ "$SYNAPSE_ADMIN_MIN_REPLICAS" = "null" ] || [ -z "$SYNAPSE_ADMIN_MIN_REPLICAS" ] && _missing+=("resources.synapse_admin.min_replicas")
  [ "$SYNAPSE_ADMIN_MAX_REPLICAS" = "null" ] || [ -z "$SYNAPSE_ADMIN_MAX_REPLICAS" ] && _missing+=("resources.synapse_admin.max_replicas")
  [ "$STALWART_MIN_REPLICAS" = "null" ] || [ -z "$STALWART_MIN_REPLICAS" ] && _missing+=("resources.stalwart.min_replicas")
  [ "$STALWART_MAX_REPLICAS" = "null" ] || [ -z "$STALWART_MAX_REPLICAS" ] && _missing+=("resources.stalwart.max_replicas")
  [ "$NEXTCLOUD_MIN_REPLICAS" = "null" ] || [ -z "$NEXTCLOUD_MIN_REPLICAS" ] && _missing+=("resources.nextcloud.min_replicas")
  [ "$NEXTCLOUD_MAX_REPLICAS" = "null" ] || [ -z "$NEXTCLOUD_MAX_REPLICAS" ] && _missing+=("resources.nextcloud.max_replicas")
  [ "$KEYCLOAK_REPLICAS" = "null" ] || [ -z "$KEYCLOAK_REPLICAS" ] && _missing+=("resources.keycloak.replicas")
  [ "$REDIS_REPLICAS" = "null" ] || [ -z "$REDIS_REPLICAS" ] && _missing+=("resources.redis.replicas")

  if [ ${#_missing[@]} -gt 0 ]; then
    echo "[ERROR] Required scaling config missing in $TENANT_CONFIG:" >&2
    for field in "${_missing[@]}"; do
      echo "  - $field" >&2
    done
    exit 1
  fi

  export DOCS_BACKEND_MIN_REPLICAS DOCS_BACKEND_MAX_REPLICAS DOCS_GUNICORN_WORKERS
  export DOCS_FRONTEND_MIN_REPLICAS DOCS_FRONTEND_MAX_REPLICAS
  export YPROVIDER_MIN_REPLICAS YPROVIDER_MAX_REPLICAS
  export ELEMENT_MIN_REPLICAS ELEMENT_MAX_REPLICAS
  export JITSI_WEB_MIN_REPLICAS JITSI_WEB_MAX_REPLICAS
  export JVB_MIN_REPLICAS JVB_MAX_REPLICAS JVB_PORT
  export ROUNDCUBE_MIN_REPLICAS ROUNDCUBE_MAX_REPLICAS
  export ROUNDCUBE_MEMORY_REQUEST ROUNDCUBE_MEMORY_LIMIT
  export ROUNDCUBE_CPU_REQUEST
  export ADMIN_PORTAL_MIN_REPLICAS ADMIN_PORTAL_MAX_REPLICAS
  export ACCOUNT_PORTAL_MIN_REPLICAS ACCOUNT_PORTAL_MAX_REPLICAS
  export SYNAPSE_ADMIN_MIN_REPLICAS SYNAPSE_ADMIN_MAX_REPLICAS
  export STALWART_MIN_REPLICAS STALWART_MAX_REPLICAS
  export STALWART_MEMORY_REQUEST STALWART_MEMORY_LIMIT
  export STALWART_CPU_REQUEST STALWART_STORAGE_SIZE
  export STALWART_SMTPS_PORT STALWART_SUBMISSION_PORT STALWART_IMAPS_PORT
  export STALWART_IMAPS_APP_PORT STALWART_SUBMISSION_APP_PORT
  export KEYCLOAK_REPLICAS REDIS_REPLICAS
  export SYNAPSE_REPLICAS
  export NEXTCLOUD_MIN_REPLICAS NEXTCLOUD_MAX_REPLICAS
  export NEXTCLOUD_CPU_REQUEST NEXTCLOUD_HPA_SCALEDOWN_WINDOW
  export EMAIL_PROBE_MEMORY_REQUEST EMAIL_PROBE_MEMORY_LIMIT
  export EMAIL_PROBE_CPU_REQUEST
}

# ---------------------------------------------------------------------------
# Internal: detect PG_HOST from cluster state
# ---------------------------------------------------------------------------
_mt_detect_pg() {
  if [ -n "${PG_HOST:-}" ]; then
    return 0
  fi

  if kubectl get service docs-postgresql-primary -n "$NS_DB" >/dev/null 2>&1; then
    export PG_SERVICE_NAME="docs-postgresql-primary"
  elif kubectl get service docs-postgresql -n "$NS_DB" >/dev/null 2>&1; then
    export PG_SERVICE_NAME="docs-postgresql"
  else
    echo "[WARNING] PostgreSQL service not found in $NS_DB namespace." >&2
    echo "[WARNING] PG_HOST will not be set. Run 'deploy_infra $MT_ENV' first if needed." >&2
    return 0
  fi
  export PG_HOST="${PG_SERVICE_NAME}.${NS_DB}.svc.cluster.local"
}

# ---------------------------------------------------------------------------
# Internal: load secrets from YAML into env vars
# ---------------------------------------------------------------------------
_mt_load_tenant_secrets() {
  # Batch-extract all secrets in one yq invocation
  eval "$(yq '
    "TF_VAR_linode_token=" + (.linode.token // "" | @sh) + "\n" +
    "TF_VAR_cloudflare_api_token=" + (.cloudflare.api_token // "" | @sh) + "\n" +
    "TF_VAR_cloudflare_zone_id=" + (.cloudflare.zone_id // "" | @sh) + "\n" +
    "TF_VAR_tls_email=" + (.tls.email // "" | @sh) + "\n" +
    "TF_VAR_postgres_password=" + (.database.postgres_password // "" | @sh) + "\n" +
    "TF_VAR_redis_password=" + (.database.redis_password // "" | @sh) + "\n" +
    "TF_VAR_docs_db_password=" + (.database.docs_password // "" | @sh) + "\n" +
    "TF_VAR_oidc_rp_client_secret_docs=" + (.oidc.docs_client_secret // "" | @sh) + "\n" +
    "TF_VAR_nextcloud_oidc_client_secret=" + (.oidc.nextcloud_client_secret // "" | @sh) + "\n" +
    "TF_VAR_matrix_registration_shared_secret=" + (.matrix.registration_shared_secret // "" | @sh) + "\n" +
    "SYNAPSE_DB_PASSWORD=" + (.matrix.synapse_password // "" | @sh) + "\n" +
    "SYNAPSE_OIDC_CLIENT_SECRET=" + (.oidc.synapse_client_secret // "" | @sh) + "\n" +
    "TF_VAR_turn_shared_secret=" + (.turn.shared_secret // "" | @sh) + "\n" +
    "TF_VAR_linode_object_storage_access_key=" + (.s3_matrix.access_key // "" | @sh) + "\n" +
    "TF_VAR_linode_object_storage_secret_key=" + (.s3_matrix.secret_key // "" | @sh) + "\n" +
    "S3_MATRIX_ACCESS_KEY=" + (.s3_matrix.access_key // "" | @sh) + "\n" +
    "S3_MATRIX_SECRET_KEY=" + (.s3_matrix.secret_key // "" | @sh) + "\n" +
    "TF_VAR_docs_s3_access_key=" + (.s3_docs.access_key // "" | @sh) + "\n" +
    "TF_VAR_docs_s3_secret_key=" + (.s3_docs.secret_key // "" | @sh) + "\n" +
    "TF_VAR_files_s3_access_key=" + (.s3_files.access_key // "" | @sh) + "\n" +
    "TF_VAR_files_s3_secret_key=" + (.s3_files.secret_key // "" | @sh) + "\n" +
    "S3_MAIL_ACCESS_KEY=" + (.s3_mail.access_key // "" | @sh) + "\n" +
    "S3_MAIL_SECRET_KEY=" + (.s3_mail.secret_key // "" | @sh) + "\n" +
    "TF_VAR_ssh_public_key=" + (.ssh.public_key // "" | @sh) + "\n" +
    "TF_VAR_grafana_admin_password=" + (.grafana.admin_password // "" | @sh) + "\n" +
    "TF_VAR_jitsi_jwt_app_secret=" + (.jitsi.jwt_app_secret // "" | @sh) + "\n" +
    "KEYCLOAK_ADMIN_PASSWORD=" + (.keycloak.admin_password // "" | @sh) + "\n" +
    "KEYCLOAK_DB_PASSWORD=" + (.keycloak.db_password // "" | @sh) + "\n" +
    "STALWART_ADMIN_PASSWORD=" + (.stalwart.admin_password // "" | @sh) + "\n" +
    "STALWART_DB_PASSWORD=" + (.database.stalwart_password // "" | @sh) + "\n" +
    "STALWART_OIDC_SECRET=" + (.oidc.stalwart_client_secret // "" | @sh) + "\n" +
    "ROUNDCUBE_OIDC_SECRET=" + (.oidc.roundcube_client_secret // "" | @sh) + "\n" +
    "ROUNDCUBE_DB_PASSWORD=" + (.database.roundcube_password // "" | @sh) + "\n" +
    "ADMIN_PORTAL_OIDC_SECRET=" + (.oidc.admin_portal_client_secret // "" | @sh) + "\n" +
    "ADMIN_PORTAL_NEXTAUTH_SECRET=" + (.admin_portal.nextauth_secret // "" | @sh) + "\n" +
    "ACCOUNT_PORTAL_OIDC_SECRET=" + (.oidc.account_portal_client_secret // "" | @sh) + "\n" +
    "ACCOUNT_PORTAL_NEXTAUTH_SECRET=" + (.account_portal.session_secret // "" | @sh) + "\n" +
    "GUEST_PROVISIONING_API_KEY=" + (.account_portal.guest_provisioning_api_key // "" | @sh) + "\n" +
    "REDIS_SESSION_PASSWORD=" + (.admin_portal.redis_password // "" | @sh) + "\n" +
    "BEGINSETUP_SECRET=" + (.admin_portal.beginsetup_secret // "" | @sh) + "\n" +
    "_ALERTBOT_ACCESS_TOKEN=" + (.alertbot.access_token // "" | @sh) + "\n" +
    "_ALERTBOT_ROOM_ID=" + (.alertbot.room_id // "" | @sh) + "\n" +
    "_DEPLOY_ROOM_ID=" + (.alertbot.deploy_room_id // "" | @sh) + "\n" +
    "_ALERTBOT_HOMESERVER=" + (.alertbot.homeserver // "" | @sh) + "\n" +
    "GOOGLE_CLIENT_ID=" + (.google.client_id // "" | @sh) + "\n" +
    "GOOGLE_CLIENT_SECRET=" + (.google.client_secret // "" | @sh) + "\n" +
    "HEALTHCHECKS_DEADMAN_URL=" + (.healthchecks.deadman_url // "" | @sh)
  ' "$TENANT_SECRETS")"

  # Derived secrets

  # Roundcube DES key: deterministic from tenant+env to avoid regenerating on each deploy.
  # If regenerated, all active Roundcube sessions are invalidated.
  export ROUNDCUBE_DES_KEY
  ROUNDCUBE_DES_KEY=$(echo -n "${MT_TENANT}${MT_ENV}roundcube" | sha256sum | cut -c1-24)

  # Synapse registration shared secret: set explicitly to prevent the Helm chart from
  # generating a new random value on every helm upgrade, which would change the config
  # Secret and trigger unnecessary pod restarts.
  export SYNAPSE_REGISTRATION_SHARED_SECRET="$TF_VAR_matrix_registration_shared_secret"

  # Synapse macaroon key: MUST be stable across deploys — if it changes, ALL existing
  # user sessions are invalidated. The Helm chart does NOT set this by default (Synapse
  # derives it from the signing key). We set it explicitly so it's stable regardless of
  # signing key changes.
  export SYNAPSE_MACAROON_SECRET_KEY
  SYNAPSE_MACAROON_SECRET_KEY=$(echo -n "synapse_macaroon:${TF_VAR_matrix_registration_shared_secret}" | shasum -a 256 | cut -d' ' -f1)
  export SYNAPSE_REDIS_PASSWORD="$TF_VAR_redis_password"
  export TURN_SHARED_SECRET="$TF_VAR_turn_shared_secret"

  # Alertbot: export only if non-empty and not "null"
  if [ -n "${_ALERTBOT_ACCESS_TOKEN:-}" ] && [ "$_ALERTBOT_ACCESS_TOKEN" != "null" ]; then
    export MATRIX_ALERTMANAGER_ACCESS_TOKEN="$_ALERTBOT_ACCESS_TOKEN"
  fi
  if [ -n "${_ALERTBOT_ROOM_ID:-}" ] && [ "$_ALERTBOT_ROOM_ID" != "null" ]; then
    export ALERTMANAGER_MATRIX_ROOM_ID="$_ALERTBOT_ROOM_ID"
  fi
  if [ -n "${_DEPLOY_ROOM_ID:-}" ] && [ "$_DEPLOY_ROOM_ID" != "null" ]; then
    export DEPLOY_MATRIX_ROOM_ID="$_DEPLOY_ROOM_ID"
  fi
  if [ -n "${_ALERTBOT_HOMESERVER:-}" ] && [ "$_ALERTBOT_HOMESERVER" != "null" ]; then
    export ALERTBOT_MATRIX_HOMESERVER="$_ALERTBOT_HOMESERVER"
  fi
  unset _ALERTBOT_ACCESS_TOKEN _ALERTBOT_ROOM_ID _DEPLOY_ROOM_ID _ALERTBOT_HOMESERVER

  # Export all TF_VAR_* and other secret vars
  export TF_VAR_linode_token TF_VAR_cloudflare_api_token TF_VAR_cloudflare_zone_id
  export TF_VAR_tls_email TF_VAR_postgres_password TF_VAR_redis_password
  export TF_VAR_docs_db_password TF_VAR_oidc_rp_client_secret_docs
  export TF_VAR_nextcloud_oidc_client_secret TF_VAR_matrix_registration_shared_secret
  export SYNAPSE_DB_PASSWORD SYNAPSE_OIDC_CLIENT_SECRET
  export TF_VAR_turn_shared_secret
  export TF_VAR_linode_object_storage_access_key TF_VAR_linode_object_storage_secret_key
  export S3_MATRIX_ACCESS_KEY S3_MATRIX_SECRET_KEY
  export TF_VAR_docs_s3_access_key TF_VAR_docs_s3_secret_key
  export TF_VAR_files_s3_access_key TF_VAR_files_s3_secret_key
  export S3_MAIL_ACCESS_KEY S3_MAIL_SECRET_KEY
  export TF_VAR_ssh_public_key TF_VAR_grafana_admin_password
  export TF_VAR_jitsi_jwt_app_secret
  export KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD
  export STALWART_ADMIN_PASSWORD STALWART_DB_PASSWORD STALWART_OIDC_SECRET
  export ROUNDCUBE_OIDC_SECRET ROUNDCUBE_DB_PASSWORD ROUNDCUBE_DES_KEY
  export ADMIN_PORTAL_OIDC_SECRET ADMIN_PORTAL_NEXTAUTH_SECRET
  export ACCOUNT_PORTAL_OIDC_SECRET ACCOUNT_PORTAL_NEXTAUTH_SECRET
  export GUEST_PROVISIONING_API_KEY
  export REDIS_SESSION_PASSWORD BEGINSETUP_SECRET
  export GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
  export HEALTHCHECKS_DEADMAN_URL
}

# ---------------------------------------------------------------------------
# Internal: get TURN server IP from phase1 terraform outputs
# ---------------------------------------------------------------------------
_mt_load_turn_server_ip() {
  if [ -n "${TURN_SERVER_IP:-}" ]; then
    return 0
  fi

  if [ -d "$REPO_ROOT/phase1" ]; then
    pushd "$REPO_ROOT/phase1" >/dev/null
      if terraform workspace select "$MT_ENV" >/dev/null 2>&1; then
        TURN_SERVER_IP=$(terraform output -raw turn_server_ip 2>/dev/null || echo "")
        if [ -n "$TURN_SERVER_IP" ] && [ "$TURN_SERVER_IP" != "null" ]; then
          export TURN_SERVER_IP
        fi
      fi
    popd >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Internal: export all vars (ensures everything is exported for sub-processes)
# ---------------------------------------------------------------------------
_mt_export_all() {
  export MT_ENV MT_TENANT TENANT TENANT_NAME REPO_ROOT REPO
  export TENANT_CONFIG TENANT_SECRETS KUBECONFIG
  export TENANT_DISPLAY_NAME TENANT_DOMAIN TENANT_ENV_DNS_LABEL
  export TENANT_COOKIE_DOMAIN TENANT_KEYCLOAK_REALM TENANT_DB_USER
  export S3_CLUSTER S3_BUCKET_PREFIX S3_DOCS_BUCKET S3_MATRIX_BUCKET S3_FILES_BUCKET S3_MAIL_BUCKET
  export DOCS_DB_NAME NEXTCLOUD_DB_NAME SYNAPSE_DB_NAME SYNAPSE_DB_USER
  export STALWART_DB_NAME STALWART_DB_USER ROUNDCUBE_DB_NAME ROUNDCUBE_DB_USER
  export INFRA_DOMAIN MAIL_SUBDOMAIN
  export BUCKET_NAME BASE_DOMAIN COOKIE_DOMAIN KEYCLOAK_REALM
  export EMAIL_DOMAIN SMTP_DOMAIN DEFAULT_EMAIL_QUOTA_MB
  export PRIVACY_POLICY_URL TERMS_OF_USE_URL ACCEPTABLE_USE_POLICY_URL
  export CALENDAR_ENABLED OFFICE_ENABLED MAIL_ENABLED JITSI_ENABLED
  export MATRIX_ENABLED DOCS_ENABLED FILES_ENABLED
  export WEBMAIL_ENABLED ADMIN_PORTAL_ENABLED ACCOUNT_PORTAL_ENABLED GOOGLE_IMPORT_ENABLED EMAIL_PROBE_ENABLED
  export EMAIL_PROBE_TARGET_EMAIL
  export MATRIX_HOST SYNAPSE_HOST SYNAPSE_ADMIN_HOST ADMIN_HOST ACCOUNT_HOST
  export KEYCLOAK_INTERNAL_URL="http://keycloak-keycloakx-http.infra-auth.svc.cluster.local"

  # Rate limiting: 1-minute sliding window for both envs, higher limit for dev
  if [ "$MT_ENV" = "dev" ]; then
    export RATE_LIMIT_MAX="${RATE_LIMIT_MAX:-2000}"       # ~33 QPS
  else
    export RATE_LIMIT_MAX="${RATE_LIMIT_MAX:-300}"        # ~5 QPS
  fi
  export RATE_LIMIT_WINDOW_MS="${RATE_LIMIT_WINDOW_MS:-60000}"  # 1 minute
  export DOCS_HOST FILES_HOST JITSI_HOST HOME_HOST AUTH_HOST
  export MAIL_HOST IMAP_HOST SMTP_HOST WEBMAIL_HOST CALENDAR_HOST OFFICE_HOST
  export MATRIX_SERVER_NAME WEBADMIN_HOST
  export TENANT_NS_PREFIX NS_MATRIX NS_DOCS NS_FILES NS_JITSI
  export NS_STALWART NS_WEBMAIL NS_ADMIN NS_OFFICE NS_HOME
  export NS_DB NS_AUTH NS_MONITORING NS_INGRESS NS_INGRESS_INTERNAL NS_CERTMANAGER NS_MAIL

  export HELM_DIFF_USE_HELM_TEMPLATE=true
}
