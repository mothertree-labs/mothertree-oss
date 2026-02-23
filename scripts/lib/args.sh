#!/bin/bash
# Shared CLI argument parser for Mothertree scripts
#
# Source this and call mt_parse_args "$@" to get standardized argument parsing.
# Sets well-known variables (MT_ENV, MT_TENANT, etc.) and collects script-specific
# flags into MT_EXTRA_ARGS for the calling script to inspect.
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/args.sh"
#   mt_parse_args "$@"
#   # MT_ENV, MT_TENANT, etc. are now set
#
# Well-known parameters (handled by this library):
#   -e <env>  / --env=<env>     Environment name (also accepted as positional arg)
#   -t <name> / --tenant=<name> Tenant name
#   --secrets-file=<path>       Override tenant secrets file location
#   --infra-secrets-file=<path> Override infrastructure secrets file location
#   --nesting-level=<n>         Nesting level for deploy notifications
#   -h / --help                 Show usage (calls mt_usage if defined by caller)
#
# Script-specific flags (collected into MT_EXTRA_ARGS array):
#   --plan, --destroy, --create-alert-user, --vpn, --jitsi-tester,
#   --jitsi_tester=yes|no, --email=*, --name=*, etc.
#
# The caller can define a mt_usage() function before calling mt_parse_args
# to provide script-specific help text.

# Guard against double-sourcing
if [ "${_MT_ARGS_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_ARGS_LOADED=1

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT
# ---------------------------------------------------------------------------
if [ -z "${REPO_ROOT:-}" ]; then
  # Walk up from scripts/lib/ to repo root
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export REPO_ROOT

# Also set REPO for backward compat (used by some scripts and notify.sh)
# Conditional: preserve any REPO value set before args.sh was sourced
export REPO="${REPO:-${REPO_ROOT}}"

# ---------------------------------------------------------------------------
# mt_parse_args — parse CLI arguments into well-known variables
# ---------------------------------------------------------------------------
mt_parse_args() {
  # Defaults
  MT_ENV="${MT_ENV:-}"
  MT_TENANT="${MT_TENANT:-}"
  MT_SECRETS_FILE="${MT_SECRETS_FILE:-}"
  MT_INFRA_SECRETS_FILE="${MT_INFRA_SECRETS_FILE:-}"
  MT_NESTING_LEVEL="${MT_NESTING_LEVEL:-0}"
  MT_EXTRA_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e)
        MT_ENV="$2"; shift 2 ;;
      --env=*)
        MT_ENV="${1#*=}"; shift ;;
      -t)
        MT_TENANT="$2"; shift 2 ;;
      --tenant=*)
        MT_TENANT="${1#*=}"; shift ;;
      --secrets-file=*)
        MT_SECRETS_FILE="${1#*=}"; shift ;;
      --infra-secrets-file=*)
        MT_INFRA_SECRETS_FILE="${1#*=}"; shift ;;
      --nesting-level=*)
        MT_NESTING_LEVEL="${1#*=}"; shift ;;
      -h|--help)
        if declare -f mt_usage >/dev/null 2>&1; then
          mt_usage
        else
          echo "Usage: $0 -e <env> [-t <tenant>] [options]"
        fi
        exit 0
        ;;
      --*)
        # Script-specific flag — pass through
        MT_EXTRA_ARGS+=("$1"); shift ;;
      -*)
        # Unknown short flag
        echo "[ERROR] Unknown option: $1" >&2
        if declare -f mt_usage >/dev/null 2>&1; then
          mt_usage
        fi
        exit 1
        ;;
      *)
        # Positional argument: first is env, second is tenant (for backward compat)
        if [ -z "$MT_ENV" ]; then
          MT_ENV="$1"
        elif [ -z "$MT_TENANT" ]; then
          MT_TENANT="$1"
        else
          echo "[ERROR] Unexpected argument: $1" >&2
          if declare -f mt_usage >/dev/null 2>&1; then
            mt_usage
          fi
          exit 1
        fi
        shift
        ;;
    esac
  done

  # Export for sub-processes and helmfile/envsubst
  export MT_ENV
  export MT_TENANT
  export MT_SECRETS_FILE
  export MT_INFRA_SECRETS_FILE
  export MT_NESTING_LEVEL

  # Backward-compat aliases used throughout the codebase
  export TENANT="${MT_TENANT}"
  export TENANT_NAME="${MT_TENANT}"

  # Set nesting level for notify.sh (must be set before sourcing it)
  _MT_NOTIFY_NESTING_LEVEL="$MT_NESTING_LEVEL"
  export _MT_NOTIFY_NESTING_LEVEL
}

# ---------------------------------------------------------------------------
# mt_require_env — fail fast if MT_ENV is not set
# ---------------------------------------------------------------------------
mt_require_env() {
  if [ -z "${MT_ENV:-}" ]; then
    echo "[ERROR] Environment is required. Use -e <env> or pass as positional argument." >&2
    if declare -f mt_usage >/dev/null 2>&1; then
      mt_usage
    fi
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# mt_require_tenant — fail fast if MT_TENANT is not set
# ---------------------------------------------------------------------------
mt_require_tenant() {
  if [ -z "${MT_TENANT:-}" ]; then
    echo "[ERROR] Tenant is required. Use -t <tenant> or --tenant=<tenant>." >&2
    if declare -f mt_usage >/dev/null 2>&1; then
      mt_usage
    fi
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# mt_has_flag — check if a flag is in MT_EXTRA_ARGS
# Usage: if mt_has_flag "--plan"; then ...
# ---------------------------------------------------------------------------
mt_has_flag() {
  local flag="$1"
  local arg
  for arg in "${MT_EXTRA_ARGS[@]+"${MT_EXTRA_ARGS[@]}"}"; do
    if [ "$arg" = "$flag" ]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# mt_get_flag_value — get value of a --key=value flag from MT_EXTRA_ARGS
# Usage: val=$(mt_get_flag_value "--jitsi_tester")
# ---------------------------------------------------------------------------
mt_get_flag_value() {
  local prefix="$1"
  local arg
  for arg in "${MT_EXTRA_ARGS[@]+"${MT_EXTRA_ARGS[@]}"}"; do
    if [[ "$arg" == "${prefix}="* ]]; then
      echo "${arg#*=}"
      return 0
    fi
  done
  return 1
}
