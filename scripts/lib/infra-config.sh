#!/bin/bash
# Infrastructure configuration loader for Mothertree scripts
#
# Source this and call mt_load_infra_config to load all config needed by
# deploy_infra (shared infrastructure deployment).
#
# Unlike config.sh (which is per-tenant), this operates per-environment.
# It discovers the "infra tenant" (whose dns.domain matches infra.domain),
# loads alerting config, derives infra hostnames, and sets namespace vars.
#
# Prerequisites:
#   - MT_ENV must be set (via args.sh or directly)
#   - REPO_ROOT must be set (via args.sh or directly)
#   - yq must be installed
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/infra-config.sh"
#   mt_load_infra_config

# Guard against double-sourcing
if [ "${_MT_INFRA_CONFIG_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# mt_load_infra_config — main entry point
# ---------------------------------------------------------------------------
mt_load_infra_config() {
  if [ "${_MT_INFRA_CONFIG_LOADED:-}" = "1" ]; then
    return 0
  fi
  _MT_INFRA_CONFIG_LOADED=1

  if [ -z "${MT_ENV:-}" ]; then
    echo "[ERROR] MT_ENV is not set." >&2
    exit 1
  fi
  if [ -z "${REPO_ROOT:-}" ]; then
    echo "[ERROR] REPO_ROOT is not set." >&2
    exit 1
  fi

  # Resolve config paths (supports submodule and legacy layouts)
  source "${REPO_ROOT}/scripts/lib/paths.sh"
  _mt_resolve_tenants_dir
  _mt_resolve_infra_config "$MT_ENV"

  _mt_infra_set_kubeconfig
  _mt_infra_set_namespaces
  _mt_infra_load_env_config
  _mt_infra_discover_domain
  _mt_infra_load_alerting
  _mt_infra_load_shared_secrets
  _mt_infra_derive_hostnames
  _mt_infra_set_placeholder_namespaces
  _mt_infra_load_terraform_outputs
}

# ---------------------------------------------------------------------------
# Internal: set KUBECONFIG from convention
# ---------------------------------------------------------------------------
_mt_infra_set_kubeconfig() {
  export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"
  if [ ! -f "$KUBECONFIG" ]; then
    echo "[ERROR] Kubeconfig not found: $KUBECONFIG" >&2
    echo "Run './scripts/manage_infra $MT_ENV' first to create the cluster." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Internal: set infrastructure namespace variables
# ---------------------------------------------------------------------------
_mt_infra_set_namespaces() {
  export NS_DB="infra-db"
  export NS_AUTH="infra-auth"
  export NS_MONITORING="infra-monitoring"
  export NS_INGRESS="infra-ingress"
  export NS_INGRESS_INTERNAL="infra-ingress-internal"
  export NS_CERTMANAGER="infra-cert-manager"
  export NS_MAIL="infra-mail"
}

# ---------------------------------------------------------------------------
# Internal: load environment-level infra config (infra/<env>.config.yaml)
# ---------------------------------------------------------------------------
_mt_infra_load_env_config() {
  local infra_config="${MT_INFRA_CONFIG:-}"
  if [ -n "$infra_config" ] && [ -f "$infra_config" ]; then
    echo "[INFO] Loading infrastructure config from $infra_config"
    KEYCLOAK_REPLICAS=$(yq '.keycloak.replicas // 2' "$infra_config")
    export KEYCLOAK_REPLICAS

    # PostgreSQL version and VM tuning (passed to Ansible for postgresql.conf)
    POSTGRES_VERSION=$(yq '.postgresql.version // ""' "$infra_config")
    export POSTGRES_VERSION
    PG_SHARED_BUFFERS=$(yq '.postgresql.shared_buffers // ""' "$infra_config")
    PG_EFFECTIVE_CACHE_SIZE=$(yq '.postgresql.effective_cache_size // ""' "$infra_config")
    PG_MAX_CONNECTIONS=$(yq '.postgresql.max_connections // ""' "$infra_config")
    PG_WORK_MEM=$(yq '.postgresql.work_mem // ""' "$infra_config")
    PG_MAINTENANCE_WORK_MEM=$(yq '.postgresql.maintenance_work_mem // ""' "$infra_config")
    export PG_SHARED_BUFFERS PG_EFFECTIVE_CACHE_SIZE PG_MAX_CONNECTIONS
    export PG_WORK_MEM PG_MAINTENANCE_WORK_MEM

    # pgBackRest backup config (non-secret parts)
    PGBACKREST_S3_ENDPOINT=$(yq '.pgbackrest.s3_endpoint // ""' "$infra_config")
    PGBACKREST_S3_BUCKET=$(yq '.pgbackrest.s3_bucket // ""' "$infra_config")
    PGBACKREST_S3_REGION=$(yq '.pgbackrest.s3_region // ""' "$infra_config")
    export PGBACKREST_S3_ENDPOINT PGBACKREST_S3_BUCKET PGBACKREST_S3_REGION

    # PgBouncer + Tailscale sidecar (external PG VM connectivity)
    PGBOUNCER_ENABLED=$(yq '.pgbouncer.enabled // false' "$infra_config")
    PG_VM_TAILSCALE_IP=$(yq '.pgbouncer.pg_vm_tailscale_ip // ""' "$infra_config")
    PGBOUNCER_MAX_CLIENT_CONN=$(yq '.pgbouncer.max_client_conn // 400' "$infra_config")
    PGBOUNCER_DEFAULT_POOL_SIZE=$(yq '.pgbouncer.default_pool_size // 15' "$infra_config")
    PGBOUNCER_MIN_POOL_SIZE=$(yq '.pgbouncer.min_pool_size // 2' "$infra_config")
    PGBOUNCER_RESERVE_POOL_SIZE=$(yq '.pgbouncer.reserve_pool_size // 2' "$infra_config")
    export PGBOUNCER_ENABLED PG_VM_TAILSCALE_IP
    export PGBOUNCER_MAX_CLIENT_CONN PGBOUNCER_DEFAULT_POOL_SIZE PGBOUNCER_MIN_POOL_SIZE PGBOUNCER_RESERVE_POOL_SIZE

    # Headscale coordination server
    HEADSCALE_URL=$(yq '.headscale.url // ""' "$infra_config")
    HEADSCALE_DOMAIN=$(yq '.headscale.domain // ""' "$infra_config")
    HEADSCALE_BASE_DOMAIN=$(yq '.headscale.base_domain // ""' "$infra_config")
    HEADSCALE_TAILSCALE_IP=$(yq '.headscale.tailscale_ip // ""' "$infra_config")
    export HEADSCALE_URL HEADSCALE_DOMAIN HEADSCALE_BASE_DOMAIN HEADSCALE_TAILSCALE_IP

    # TURN server Tailscale IP (for Ansible inventory mesh fallback)
    TURN_TAILSCALE_IP=$(yq '.turn.tailscale_ip // ""' "$infra_config")
    export TURN_TAILSCALE_IP

    # Postfix relay VM on Tailscale mesh (replaces VPN server mail relay)
    POSTFIX_RELAY_IP=$(yq '.postfix_relay.tailscale_ip // ""' "$infra_config")
    export POSTFIX_RELAY_IP
  else
    echo "[WARNING] Infrastructure config not found: $infra_config"
    echo "[WARNING] Using defaults: PG_READ_REPLICAS=1, KEYCLOAK_REPLICAS=2"
    export PG_READ_REPLICAS=1
    export KEYCLOAK_REPLICAS=2
    export PGBOUNCER_ENABLED=false
  fi
}

# ---------------------------------------------------------------------------
# Internal: discover INFRA_DOMAIN and INFRA_TENANT from tenant configs
# ---------------------------------------------------------------------------
_mt_infra_discover_domain() {
  # Find INFRA_DOMAIN from first available tenant config
  INFRA_DOMAIN=""
  local _td _tcf
  for _td in "$MT_TENANTS_DIR"/*/; do
    _tcf="$_td/${MT_ENV}.config.yaml"
    if [ -f "$_tcf" ]; then
      INFRA_DOMAIN=$(yq '.infra.domain // .dns.domain' "$_tcf")
      break
    fi
  done
  if [ -z "$INFRA_DOMAIN" ] || [ "$INFRA_DOMAIN" = "null" ]; then
    echo "[ERROR] Could not determine INFRA_DOMAIN from any tenant config" >&2
    exit 1
  fi
  export INFRA_DOMAIN
  export INFRA_NAME="Mothertree"

  # Find the "infra tenant" — the tenant whose dns.domain matches INFRA_DOMAIN
  INFRA_TENANT_DIR=""
  local _td2 _tcf2 _td_domain
  for _td2 in "$MT_TENANTS_DIR"/*/; do
    _tcf2="${_td2}/${MT_ENV}.config.yaml"
    if [ -f "$_tcf2" ]; then
      _td_domain=$(yq '.dns.domain // ""' "$_tcf2")
      if [ "$_td_domain" = "$INFRA_DOMAIN" ]; then
        INFRA_TENANT_DIR="$_td2"
        break
      fi
    fi
  done

  if [ -z "$INFRA_TENANT_DIR" ]; then
    echo "[ERROR] No tenant found with dns.domain == '$INFRA_DOMAIN'" >&2
    echo "[ERROR] One tenant's dns.domain must match INFRA_DOMAIN for alerting config." >&2
    exit 1
  fi

  INFRA_TENANT_NAME=$(basename "$INFRA_TENANT_DIR")
  export INFRA_TENANT_NAME INFRA_TENANT_DIR
  echo "[INFO] Infra tenant: $INFRA_TENANT_NAME (dns.domain=$INFRA_DOMAIN)"
}

# ---------------------------------------------------------------------------
# Internal: load alerting config/secrets from the infra tenant
# ---------------------------------------------------------------------------
_mt_infra_load_alerting() {
  local _infra_secrets="${INFRA_TENANT_DIR}/${MT_ENV}.secrets.yaml"
  local _infra_config="${INFRA_TENANT_DIR}/${MT_ENV}.config.yaml"

  # Use override if provided
  if [ -n "${MT_INFRA_SECRETS_FILE:-}" ] && [ -f "$MT_INFRA_SECRETS_FILE" ]; then
    _infra_secrets="$MT_INFRA_SECRETS_FILE"
  fi

  # Load alerting secrets from infra tenant
  if [ -f "$_infra_secrets" ]; then
    local _room_id _deploy_room_id _deadman_url _access_token
    _room_id=$(yq '.alertbot.room_id // ""' "$_infra_secrets")
    if [ -n "$_room_id" ] && [ "$_room_id" != "null" ]; then
      export ALERTMANAGER_MATRIX_ROOM_ID="$_room_id"
      echo "[INFO] AlertManager Matrix room ID loaded from infra tenant secrets"
    else
      echo "[WARN] alertbot.room_id not set in $INFRA_TENANT_NAME secrets"
    fi

    _deploy_room_id=$(yq '.alertbot.deploy_room_id // ""' "$_infra_secrets")
    if [ -n "$_deploy_room_id" ] && [ "$_deploy_room_id" != "null" ]; then
      export DEPLOY_MATRIX_ROOM_ID="$_deploy_room_id"
      echo "[INFO] Deploy Matrix room ID loaded from infra tenant secrets"
    else
      echo "[WARN] alertbot.deploy_room_id not set in $INFRA_TENANT_NAME secrets"
    fi

    _deadman_url=$(yq '.healthchecks.deadman_url // ""' "$_infra_secrets")
    if [ -n "$_deadman_url" ] && [ "$_deadman_url" != "null" ]; then
      export HEALTHCHECKS_DEADMAN_URL="$_deadman_url"
      echo "[INFO] Healthchecks.io dead man's switch URL loaded"
    else
      echo "[WARN] healthchecks.deadman_url not set in $INFRA_TENANT_NAME secrets"
    fi

    _access_token=$(yq '.alertbot.access_token // ""' "$_infra_secrets")
    if [ -n "$_access_token" ] && [ "$_access_token" != "null" ]; then
      export MATRIX_ALERTMANAGER_ACCESS_TOKEN="$_access_token"
      echo "[INFO] AlertManager Matrix access token loaded"
    else
      echo "[WARN] alertbot.access_token not set in $INFRA_TENANT_NAME secrets"
    fi

    local _alertbot_hs
    _alertbot_hs=$(yq '.alertbot.homeserver // ""' "$_infra_secrets")
    if [ -n "$_alertbot_hs" ] && [ "$_alertbot_hs" != "null" ]; then
      export ALERTBOT_MATRIX_HOMESERVER="$_alertbot_hs"
      echo "[INFO] Alertbot Matrix homeserver override: $ALERTBOT_MATRIX_HOMESERVER"
    fi

    # TURN shared secret — infrastructure-level (one coturn server, one secret)
    local _turn_secret
    _turn_secret=$(yq '.turn.shared_secret // ""' "$_infra_secrets")
    if [ -n "$_turn_secret" ] && [ "$_turn_secret" != "null" ]; then
      export TF_VAR_turn_shared_secret="$_turn_secret"
      echo "[INFO] TURN shared secret loaded from infra tenant secrets"
    else
      echo "[WARN] turn.shared_secret not set in $INFRA_TENANT_NAME secrets"
    fi
  else
    echo "[WARN] Infra tenant secrets file not found: $_infra_secrets"
  fi

  # Load oncall email from infra tenant config
  local _oncall_email
  _oncall_email=$(yq '.alerting.oncall_email // ""' "$_infra_config")
  if [ -n "$_oncall_email" ] && [ "$_oncall_email" != "null" ] && [ "$_oncall_email" != "oncall@example.com" ]; then
    export ALERTMANAGER_EMAIL_TO="$_oncall_email"
    echo "[INFO] AlertManager email recipient: $ALERTMANAGER_EMAIL_TO"
  else
    echo "[ERROR] alerting.oncall_email is not configured in: $_infra_config" >&2
    echo "[ERROR] Add 'alerting: oncall_email: you@example.com' to $_infra_config" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Internal: load shared infrastructure secrets (Keycloak, Grafana)
#
# These are needed by helmfile tier=system sync (Grafana admin password)
# and Keycloak deployment. Must be loaded early — before helmfile runs.
# ---------------------------------------------------------------------------
_mt_infra_load_shared_secrets() {
  local _infra_secrets="${INFRA_TENANT_DIR}/${MT_ENV}.secrets.yaml"
  if [ -n "${MT_INFRA_SECRETS_FILE:-}" ] && [ -f "$MT_INFRA_SECRETS_FILE" ]; then
    _infra_secrets="$MT_INFRA_SECRETS_FILE"
  fi

  if [ ! -f "$_infra_secrets" ]; then
    echo "[WARN] Infra tenant secrets not found: $_infra_secrets" >&2
    echo "[WARN] Grafana admin password and Keycloak passwords will use defaults" >&2
    return 0
  fi

  # Batch-extract shared infra secrets
  local _kc_admin _kc_db _grafana_pw
  _kc_admin=$(yq '.keycloak.admin_password // ""' "$_infra_secrets")
  _kc_db=$(yq '.keycloak.db_password // ""' "$_infra_secrets")
  _grafana_pw=$(yq '.grafana.admin_password // ""' "$_infra_secrets")

  if [ -n "$_kc_admin" ] && [ "$_kc_admin" != "null" ]; then
    export KEYCLOAK_ADMIN_PASSWORD="$_kc_admin"
    echo "[INFO] Keycloak admin password loaded from infra tenant secrets"
  else
    echo "[WARN] keycloak.admin_password not set in $INFRA_TENANT_NAME secrets" >&2
  fi

  if [ -n "$_kc_db" ] && [ "$_kc_db" != "null" ]; then
    export KEYCLOAK_DB_PASSWORD="$_kc_db"
    echo "[INFO] Keycloak DB password loaded from infra tenant secrets"
  else
    echo "[WARN] keycloak.db_password not set in $INFRA_TENANT_NAME secrets" >&2
  fi

  if [ -n "$_grafana_pw" ] && [ "$_grafana_pw" != "null" ]; then
    export TF_VAR_grafana_admin_password="$_grafana_pw"
    echo "[INFO] Grafana admin password loaded from infra tenant secrets"
  else
    echo "[WARN] grafana.admin_password not set in $INFRA_TENANT_NAME secrets" >&2
    echo "[WARN] Grafana will use default password ('changeme')" >&2
  fi

  local _microsocks_pw
  _microsocks_pw=$(yq '.microsocks.password // ""' "$_infra_secrets")
  if [ -n "$_microsocks_pw" ] && [ "$_microsocks_pw" != "null" ]; then
    export MICROSOCKS_PASSWORD="$_microsocks_pw"
    echo "[INFO] Microsocks SOCKS5 password loaded from infra tenant secrets"
  fi

  # Cloudflare, TLS, Linode, and PostgreSQL credentials (used by deploy_infra)
  local _cf_token _cf_zone _tls_email _linode_token _pg_password
  _cf_token=$(yq '.cloudflare.api_token // ""' "$_infra_secrets")
  _cf_zone=$(yq '.cloudflare.zone_id // ""' "$_infra_secrets")
  _tls_email=$(yq '.tls.email // ""' "$_infra_secrets")
  _linode_token=$(yq '.linode.token // ""' "$_infra_secrets")
  _pg_password=$(yq '.database.postgres_password // ""' "$_infra_secrets")

  [ -n "$_cf_token" ] && [ "$_cf_token" != "null" ] && export TF_VAR_cloudflare_api_token="$_cf_token"
  [ -n "$_cf_zone" ] && [ "$_cf_zone" != "null" ] && export TF_VAR_cloudflare_zone_id="$_cf_zone"
  [ -n "$_tls_email" ] && [ "$_tls_email" != "null" ] && export TF_VAR_tls_email="$_tls_email"
  [ -n "$_linode_token" ] && [ "$_linode_token" != "null" ] && export TF_VAR_linode_token="$_linode_token"
  [ -n "$_pg_password" ] && [ "$_pg_password" != "null" ] && export TF_VAR_postgres_password="$_pg_password"

  echo "[INFO] Infrastructure credentials loaded (Cloudflare, TLS, Linode, PostgreSQL)"

  # AWS SES SMTP relay (optional — only for prod outbound mail)
  local _ses_endpoint _ses_username _ses_password
  _ses_endpoint=$(yq '.ses.smtp_endpoint // ""' "$_infra_secrets")
  _ses_username=$(yq '.ses.smtp_username // ""' "$_infra_secrets")
  _ses_password=$(yq '.ses.smtp_password // ""' "$_infra_secrets")
  if [ -n "$_ses_endpoint" ] && [ "$_ses_endpoint" != "null" ] && \
     [ -n "$_ses_username" ] && [ "$_ses_username" != "null" ] && \
     [ -n "$_ses_password" ] && [ "$_ses_password" != "null" ]; then
    export SES_SMTP_ENDPOINT="$_ses_endpoint"
    export SES_SMTP_USERNAME="$_ses_username"
    export SES_SMTP_PASSWORD="$_ses_password"
    echo "[INFO] AWS SES SMTP relay credentials loaded from infra tenant secrets"
  fi

  # Tailscale pre-auth keys (generic + per-component tagged keys for ACL enforcement)
  local _ts_authkey
  _ts_authkey=$(yq '.tailscale.authkey // ""' "$_infra_secrets")
  if [ -n "$_ts_authkey" ] && [ "$_ts_authkey" != "null" ]; then
    export TAILSCALE_AUTHKEY="$_ts_authkey"
    echo "[INFO] Tailscale auth key loaded from infra tenant secrets"
  fi
  # Per-component keys: when ACLs are enabled, each component needs a key
  # with the correct tag so new pods register with the right permissions.
  # Falls back to generic TAILSCALE_AUTHKEY if not set.
  local _ts_pgb_key _ts_postfix_key _ts_router_key _ts_metrics_key _ts_turn_key
  _ts_pgb_key=$(yq '.tailscale.pgbouncer_authkey // ""' "$_infra_secrets")
  _ts_postfix_key=$(yq '.tailscale.postfix_authkey // ""' "$_infra_secrets")
  _ts_router_key=$(yq '.tailscale.router_authkey // ""' "$_infra_secrets")
  _ts_metrics_key=$(yq '.tailscale.metrics_authkey // ""' "$_infra_secrets")
  _ts_turn_key=$(yq '.tailscale.turn_authkey // ""' "$_infra_secrets")
  [ -n "$_ts_pgb_key" ] && [ "$_ts_pgb_key" != "null" ] && export TAILSCALE_AUTHKEY_PGBOUNCER="$_ts_pgb_key"
  [ -n "$_ts_postfix_key" ] && [ "$_ts_postfix_key" != "null" ] && export TAILSCALE_AUTHKEY_POSTFIX="$_ts_postfix_key"
  [ -n "$_ts_router_key" ] && [ "$_ts_router_key" != "null" ] && export TAILSCALE_AUTHKEY_ROUTER="$_ts_router_key"
  [ -n "$_ts_metrics_key" ] && [ "$_ts_metrics_key" != "null" ] && export TAILSCALE_AUTHKEY_METRICS="$_ts_metrics_key"
  [ -n "$_ts_turn_key" ] && [ "$_ts_turn_key" != "null" ] && export TAILSCALE_AUTHKEY_TURN="$_ts_turn_key"
  # Headscale API key for in-cluster key rotator CronJob
  local _ts_rotator_api_key
  _ts_rotator_api_key=$(yq '.tailscale.rotator_api_key // ""' "$_infra_secrets")
  if [ -n "$_ts_rotator_api_key" ] && [ "$_ts_rotator_api_key" != "null" ]; then
    export TAILSCALE_ROTATOR_API_KEY="$_ts_rotator_api_key"
    echo "[INFO] Tailscale rotator API key loaded from infra tenant secrets"
  fi

  # PgBouncer auth password (optional — only when PGBOUNCER_ENABLED=true)
  if [ "${PGBOUNCER_ENABLED:-false}" = "true" ]; then
    local _pgb_auth_pw
    _pgb_auth_pw=$(yq '.pgbouncer.auth_password // ""' "$_infra_secrets")
    [ -n "$_pgb_auth_pw" ] && [ "$_pgb_auth_pw" != "null" ] && export PGBOUNCER_AUTH_PASSWORD="$_pgb_auth_pw"
    echo "[INFO] PgBouncer auth password loaded from infra tenant secrets"
  fi

  # pgBackRest secrets (S3 credentials + encryption)
  local _pgb_s3_key _pgb_s3_secret _pgb_cipher
  _pgb_s3_key=$(yq '.pgbackrest.s3_key // ""' "$_infra_secrets")
  _pgb_s3_secret=$(yq '.pgbackrest.s3_secret // ""' "$_infra_secrets")
  _pgb_cipher=$(yq '.pgbackrest.cipher_pass // ""' "$_infra_secrets")
  [ -n "$_pgb_s3_key" ] && [ "$_pgb_s3_key" != "null" ] && export PGBACKREST_S3_KEY="$_pgb_s3_key"
  [ -n "$_pgb_s3_secret" ] && [ "$_pgb_s3_secret" != "null" ] && export PGBACKREST_S3_SECRET="$_pgb_s3_secret"
  [ -n "$_pgb_cipher" ] && [ "$_pgb_cipher" != "null" ] && export PGBACKREST_CIPHER_PASS="$_pgb_cipher"
  if [ -n "${PGBACKREST_S3_KEY:-}" ]; then
    echo "[INFO] pgBackRest S3 credentials loaded from infra tenant secrets"
  fi

  # PostgreSQL monitoring exporter password
  local _pg_exporter_pw
  _pg_exporter_pw=$(yq '.postgres_exporter.password // ""' "$_infra_secrets")
  [ -n "$_pg_exporter_pw" ] && [ "$_pg_exporter_pw" != "null" ] && export POSTGRES_EXPORTER_PASSWORD="$_pg_exporter_pw"
  if [ -n "${POSTGRES_EXPORTER_PASSWORD:-}" ]; then
    echo "[INFO] PostgreSQL exporter password loaded from infra tenant secrets"
  fi
}

# ---------------------------------------------------------------------------
# Internal: derive infrastructure hostnames
# ---------------------------------------------------------------------------
_mt_infra_derive_hostnames() {
  local infra_subdomain=""
  if [ "$MT_ENV" = "prod" ]; then
    export INFRA_ENV_DNS_LABEL=""
  else
    export INFRA_ENV_DNS_LABEL="$MT_ENV"
    infra_subdomain="${MT_ENV}."
  fi

  export AUTH_HOST="auth.${infra_subdomain}${INFRA_DOMAIN}"
  export PROMETHEUS_HOST="prometheus.internal.${infra_subdomain}${INFRA_DOMAIN}"
  export GRAFANA_HOST="grafana.internal.${infra_subdomain}${INFRA_DOMAIN}"
  export ALERTMANAGER_HOST="alertmanager.internal.${infra_subdomain}${INFRA_DOMAIN}"
  export SMTP_DOMAIN="${infra_subdomain}${INFRA_DOMAIN}"

  # Derive MATRIX_HOST from infra tenant config (needed by deploy-alerting.sh)
  local _infra_config="${INFRA_TENANT_DIR}/${MT_ENV}.config.yaml"
  local _infra_env_dns_label
  _infra_env_dns_label=$(yq '.dns.env_dns_label // ""' "$_infra_config")
  if [ -n "$_infra_env_dns_label" ] && [ "$_infra_env_dns_label" != "null" ]; then
    export MATRIX_HOST="matrix.${_infra_env_dns_label}.${INFRA_DOMAIN}"
  else
    export MATRIX_HOST="matrix.${INFRA_DOMAIN}"
  fi

  echo "[INFO] Infrastructure domain: $INFRA_DOMAIN"
  echo "[INFO] Infrastructure DNS label: ${INFRA_ENV_DNS_LABEL:-<none>}"
  echo "[INFO] Auth host: $AUTH_HOST"
  echo "[INFO] Grafana host: $GRAFANA_HOST"
  echo "[INFO] Matrix host: $MATRIX_HOST"
}

# ---------------------------------------------------------------------------
# Internal: set placeholder namespaces for helmfile parsing
# (helmfile parses all releases, even those not in the deploy selector)
# ---------------------------------------------------------------------------
_mt_infra_set_placeholder_namespaces() {
  export NS_MATRIX="placeholder-matrix"
  export NS_DOCS="placeholder-docs"
  export NS_FILES="placeholder-files"
  export NS_JITSI="placeholder-jitsi"
  export NS_OFFICE="placeholder-office"
}

# ---------------------------------------------------------------------------
# Internal: load Terraform outputs from static env file
#
# The outputs file is generated by manage_infra after phase1 terraform apply.
# Supports env var override via MT_TERRAFORM_OUTPUTS_FILE, otherwise looks
# for terraform-outputs.<env>.env alongside the infra config file.
# ---------------------------------------------------------------------------
_mt_infra_load_terraform_outputs() {
  echo "[INFO] Loading phase1 Terraform outputs..."

  # Resolve outputs file path (supports env var override)
  local _tf_outputs_file="${MT_TERRAFORM_OUTPUTS_FILE:-}"
  if [ -z "$_tf_outputs_file" ] && [ -n "${MT_INFRA_CONFIG:-}" ]; then
    _tf_outputs_file="${MT_INFRA_CONFIG%/*}/terraform-outputs.${MT_ENV}.env"
  fi

  if [ -z "$_tf_outputs_file" ] || [ ! -f "$_tf_outputs_file" ]; then
    echo "[ERROR] Terraform outputs file not found: ${_tf_outputs_file:-<not resolved>}" >&2
    echo "[ERROR] Run './scripts/manage_infra -e $MT_ENV --phase1' to generate it." >&2
    exit 1
  fi

  echo "[INFO] Loading Terraform outputs from $_tf_outputs_file"
  # shellcheck disable=SC1090
  source "$_tf_outputs_file"
  export TURN_SERVER_IP LKE_CLUSTER_ID HEADSCALE_SERVER_IP POSTGRES_SERVER_IP POSTFIX_RELAY_SERVER_IP

  echo "[INFO] TURN server IP: ${TURN_SERVER_IP:-<not set>}"
  echo "[INFO] Headscale server IP: ${HEADSCALE_SERVER_IP:-<not set>}"
  echo "[INFO] PostgreSQL server IP: ${POSTGRES_SERVER_IP:-<not set>}"
  echo "[INFO] Postfix relay server IP: ${POSTFIX_RELAY_SERVER_IP:-<not set>}"
  echo "[INFO] Postfix relay Tailscale IP: ${POSTFIX_RELAY_IP:-<not set>}"
}
