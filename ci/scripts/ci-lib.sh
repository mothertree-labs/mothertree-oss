#!/usr/bin/env bash
# Shared library for CI scripts — Valkey helpers and pipeline liveness checks.
#
# Source this file to get:
#   vcli()                          — Valkey CLI wrapper (requires CI_VALKEY_PASSWORD)
#   _extract_pipeline_number()      — parse pipeline number from lock values
#   _pipeline_is_alive()            — check if a Woodpecker pipeline is still running
#
# Liveness checks query the local Woodpecker API to detect stale locks held
# by pipelines that have already finished (killed, failed, succeeded without
# releasing their lock). This prevents indefinite waits when a lock holder
# dies without cleanup.

# ── Valkey CLI wrapper ──────────────────────────────────────────
_CI_VCLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)

vcli() {
  : "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"
  $_CI_VCLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning "$@"
}

# ── Woodpecker API helpers ──────────────────────────────────────
# Token is deployed to the CI host by Ansible (ci/ansible/playbook.yml).
_WP_API_TOKEN_FILE="/home/woodpecker/.woodpecker-api-token"
_WP_API_URL="http://localhost:8000/api"
_WP_REPO_ID="${CI_REPO_ID:-1}"

# Extract pipeline number from lock values like "123" or "123#pull_request".
_extract_pipeline_number() {
  echo "${1%%#*}"
}

# Check if a Woodpecker pipeline is still alive (running or pending).
#
# Returns 0 (true) if:
#   - Pipeline is running/pending/started (alive)
#   - API token is not available (can't check — fail open)
#   - API call fails (network issue — fail open)
#   - Response can't be parsed (fail open)
#
# Returns 1 (false) if:
#   - Pipeline status is definitively terminal (success/failure/killed/error/declined)
#
# Usage:
#   if ! _pipeline_is_alive "$pipeline_number"; then
#     echo "Pipeline #$pipeline_number is dead — force-acquiring lock"
#   fi
_pipeline_is_alive() {
  local pipeline_number="$1"
  [[ -z "$pipeline_number" ]] && return 0
  # Validate numeric to prevent URL path injection from corrupted Valkey values
  [[ "$pipeline_number" =~ ^[0-9]+$ ]] || return 0

  # Read API token — skip check if not available
  local token
  if [[ -f "$_WP_API_TOKEN_FILE" ]]; then
    token=$(<"$_WP_API_TOKEN_FILE")
  else
    return 0
  fi
  [[ -z "$token" ]] && return 0

  local response
  response=$(curl -sf --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $token" \
    "$_WP_API_URL/repos/$_WP_REPO_ID/pipelines/$pipeline_number" 2>/dev/null) || return 0

  local status
  status=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null) || return 0

  case "$status" in
    running|pending|started) return 0 ;;
    "") return 0 ;;
    *) return 1 ;;
  esac
}
