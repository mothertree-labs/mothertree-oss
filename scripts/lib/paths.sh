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
# Explicit overrides win over both layouts (scripts/devbox points them at its
# gitignored .devbox/ tree):
#   MT_TENANTS_DIR      tenant config directory
#   MT_INFRA_CONFIG_DIR directory holding <env>.config.yaml (and
#                       terraform-outputs.<env>.env, see infra-config.sh)
#   MT_PROJECT_CONF     project.conf file
#
# A plain `git clone` of the public repo has EMPTY config/tenants and
# config/platform directories (uninitialised submodules). An empty submodule
# directory is treated as absent, so it never shadows the flat layout.
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

# _mt_dir_populated <dir> — true if <dir> exists and has at least one entry.
# An uninitialised git submodule is an empty directory.
_mt_dir_populated() {
  [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# _mt_resolve_tenants_dir — find the tenants config directory
#
# Resolution order:
#   1. MT_TENANTS_DIR env var (explicit override)
#   2. $REPO_ROOT/config/tenants/ (submodule layout, only if populated)
#   3. $REPO_ROOT/tenants/ (legacy flat layout)
#
# Sets and exports MT_TENANTS_DIR. Exits with error if no directory found, or
# if MT_TENANTS_DIR is set to a directory that does not exist.
# ---------------------------------------------------------------------------
_mt_resolve_tenants_dir() {
  # Already resolved / explicit override. A set-but-missing override is an
  # error: falling back to another layout would deploy someone else's config.
  if [ -n "${MT_TENANTS_DIR:-}" ]; then
    if [ -d "$MT_TENANTS_DIR" ]; then
      export MT_TENANTS_DIR
      return 0
    fi
    echo "[ERROR] MT_TENANTS_DIR is set to '$MT_TENANTS_DIR', which is not a directory." >&2
    exit 1
  fi

  # Submodule layout
  if _mt_dir_populated "$REPO_ROOT/config/tenants"; then
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
#   1. MT_PROJECT_CONF env var (explicit override; must be an existing file)
#   2. $REPO_ROOT/config/platform/project.conf (submodule layout)
#   3. $REPO_ROOT/project.conf (legacy flat layout)
#
# Sets and exports MT_PROJECT_CONF. Empty string if not found (not an error —
# project.conf is optional for OSS users who set env vars directly).
# ---------------------------------------------------------------------------
_mt_resolve_project_conf() {
  # Explicit override
  if [ -n "${MT_PROJECT_CONF:-}" ]; then
    if [ -f "$MT_PROJECT_CONF" ]; then
      export MT_PROJECT_CONF
      return 0
    fi
    echo "[ERROR] MT_PROJECT_CONF is set to '$MT_PROJECT_CONF', which is not a file." >&2
    exit 1
  fi

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
#   1. $MT_INFRA_CONFIG_DIR/<env>.config.yaml (explicit override; when set,
#      the layouts below are NOT consulted and a missing file is an error)
#   2. $REPO_ROOT/config/platform/infra/<env>.config.yaml (submodule layout)
#   3. $REPO_ROOT/infra/<env>.config.yaml (legacy flat layout)
#
# Sets and exports MT_INFRA_CONFIG. Empty string if not found (layouts 2/3).
# ---------------------------------------------------------------------------
_mt_resolve_infra_config() {
  local env="${1:?Usage: _mt_resolve_infra_config <env>}"

  # Explicit override
  # A set override with no config for this env is an error: falling back to
  # defaults (or another layout) would deploy -e <env> with someone else's
  # settings — e.g. `eval "$(scripts/devbox env)"` left in a shell, then -e prod.
  if [ -n "${MT_INFRA_CONFIG_DIR:-}" ]; then
    if [ -f "$MT_INFRA_CONFIG_DIR/${env}.config.yaml" ]; then
      MT_INFRA_CONFIG="$MT_INFRA_CONFIG_DIR/${env}.config.yaml"
      export MT_INFRA_CONFIG
      return 0
    fi
    echo "[ERROR] MT_INFRA_CONFIG_DIR is set to '$MT_INFRA_CONFIG_DIR', which has no ${env}.config.yaml (unset it to use the normal config layout)." >&2
    exit 1
  fi

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
