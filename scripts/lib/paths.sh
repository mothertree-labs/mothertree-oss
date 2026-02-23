#!/bin/bash
# Path resolution for Mothertree config files
#
# Supports two layouts:
#   1. Submodule layout: config/ contains private submodules
#      - config/tenants/     -> tenant configs
#      - config/platform/    -> project.conf, infra configs, themes
#   2. Legacy flat layout: everything at repo root
#      - tenants/            -> tenant configs
#      - project.conf        -> project config
#      - infra/*.config.yaml -> infra configs
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/paths.sh"
#   _mt_resolve_tenants_dir       # sets MT_TENANTS_DIR
#   _mt_resolve_project_conf      # sets MT_PROJECT_CONF (may be empty)
#   _mt_resolve_infra_config dev  # sets MT_INFRA_CONFIG (may be empty)

# Guard against double-sourcing
if [ "${_MT_PATHS_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_PATHS_LOADED=1

# ---------------------------------------------------------------------------
# _mt_resolve_tenants_dir — find the tenants config directory
#
# Resolution order:
#   1. MT_TENANTS_DIR env var (explicit override)
#   2. $REPO_ROOT/config/tenants/ (submodule layout)
#   3. $REPO_ROOT/tenants/ (legacy flat layout)
#
# Sets and exports MT_TENANTS_DIR. Exits with error if no directory found.
# ---------------------------------------------------------------------------
_mt_resolve_tenants_dir() {
  # Already resolved
  if [ -n "${MT_TENANTS_DIR:-}" ] && [ -d "$MT_TENANTS_DIR" ]; then
    export MT_TENANTS_DIR
    return 0
  fi

  # Submodule layout
  if [ -d "$REPO_ROOT/config/tenants" ]; then
    MT_TENANTS_DIR="$REPO_ROOT/config/tenants"
    export MT_TENANTS_DIR
    return 0
  fi

  # Legacy flat layout
  if [ -d "$REPO_ROOT/tenants" ]; then
    MT_TENANTS_DIR="$REPO_ROOT/tenants"
    export MT_TENANTS_DIR
    return 0
  fi

  echo "[ERROR] No tenant config directory found." >&2
  echo "Expected: \$REPO_ROOT/config/tenants/ (private config submodule)" >&2
  echo "      or: \$REPO_ROOT/tenants/ (legacy layout)" >&2
  echo "" >&2
  echo "To get started: cp -r tenants/.example tenants/myorg && edit tenants/myorg/dev.config.yaml" >&2
  echo "If you have submodule access: git submodule update --init" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# _mt_resolve_project_conf — find project.conf
#
# Resolution order:
#   1. $REPO_ROOT/config/platform/project.conf (submodule layout)
#   2. $REPO_ROOT/project.conf (legacy flat layout)
#
# Sets and exports MT_PROJECT_CONF. Empty string if not found (not an error —
# project.conf is optional for OSS users who set env vars directly).
# ---------------------------------------------------------------------------
_mt_resolve_project_conf() {
  # Submodule layout
  if [ -f "$REPO_ROOT/config/platform/project.conf" ]; then
    MT_PROJECT_CONF="$REPO_ROOT/config/platform/project.conf"
    export MT_PROJECT_CONF
    return 0
  fi

  # Legacy flat layout
  if [ -f "$REPO_ROOT/project.conf" ]; then
    MT_PROJECT_CONF="$REPO_ROOT/project.conf"
    export MT_PROJECT_CONF
    return 0
  fi

  MT_PROJECT_CONF=""
  export MT_PROJECT_CONF
}

# ---------------------------------------------------------------------------
# _mt_resolve_infra_config — find the infra config for an environment
#
# Usage: _mt_resolve_infra_config <env>
#
# Resolution order:
#   1. $REPO_ROOT/config/platform/infra/<env>.config.yaml (submodule layout)
#   2. $REPO_ROOT/infra/<env>.config.yaml (legacy flat layout)
#
# Sets and exports MT_INFRA_CONFIG. Empty string if not found.
# ---------------------------------------------------------------------------
_mt_resolve_infra_config() {
  local env="${1:?Usage: _mt_resolve_infra_config <env>}"

  # Submodule layout
  if [ -f "$REPO_ROOT/config/platform/infra/${env}.config.yaml" ]; then
    MT_INFRA_CONFIG="$REPO_ROOT/config/platform/infra/${env}.config.yaml"
    export MT_INFRA_CONFIG
    return 0
  fi

  # Legacy flat layout
  if [ -f "$REPO_ROOT/infra/${env}.config.yaml" ]; then
    MT_INFRA_CONFIG="$REPO_ROOT/infra/${env}.config.yaml"
    export MT_INFRA_CONFIG
    return 0
  fi

  MT_INFRA_CONFIG=""
  export MT_INFRA_CONFIG
}
