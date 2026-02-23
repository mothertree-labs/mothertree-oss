#!/bin/bash
# Deploy notification library
# Source this from any deploy script to get start/end notifications on stderr
# and (optionally) in a Matrix room via the alertbot user.
#
# Usage:
#   source "${REPO}/scripts/lib/notify.sh"
#   mt_deploy_start "script-name"
#
# The EXIT trap will automatically send a completion message with duration and
# exit code. Manual notifications can be sent with:
#   mt_notify "your message"
#
# Credential resolution (first non-empty wins):
#   1. Env vars: MT_NOTIFY_HOMESERVER, MT_NOTIFY_TOKEN, MT_NOTIFY_ROOM_ID
#   2. Alertbot fallback vars set by config.sh / infra-config.sh
#   3. Auto-discovery from infra tenant secrets (requires MT_ENV + yq)

# Guard against double-sourcing
if [ "${_MT_NOTIFY_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_NOTIFY_LOADED=1

# ---------------------------------------------------------------------------
# Resolve repo root (works whether REPO or REPO_ROOT is set)
# ---------------------------------------------------------------------------
_MT_NOTIFY_REPO="${REPO:-${REPO_ROOT:-}}"
if [ -z "$_MT_NOTIFY_REPO" ]; then
  _MT_NOTIFY_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# ---------------------------------------------------------------------------
# Load credentials: env vars > alertbot fallback > infra tenant secrets
# ---------------------------------------------------------------------------

# Fallback: reuse alertbot credentials set by config.sh / infra-config.sh
if [ -z "${MT_NOTIFY_TOKEN:-}" ] && [ -n "${MATRIX_ALERTMANAGER_ACCESS_TOKEN:-}" ]; then
  MT_NOTIFY_TOKEN="$MATRIX_ALERTMANAGER_ACCESS_TOKEN"
fi
# Prefer the dedicated deploy room; fall back to the alerts room
if [ -z "${MT_NOTIFY_ROOM_ID:-}" ] && [ -n "${DEPLOY_MATRIX_ROOM_ID:-}" ]; then
  MT_NOTIFY_ROOM_ID="$DEPLOY_MATRIX_ROOM_ID"
fi
if [ -z "${MT_NOTIFY_ROOM_ID:-}" ] && [ -n "${ALERTMANAGER_MATRIX_ROOM_ID:-}" ]; then
  MT_NOTIFY_ROOM_ID="$ALERTMANAGER_MATRIX_ROOM_ID"
fi
if [ -z "${MT_NOTIFY_HOMESERVER:-}" ] && [ -n "${ALERTBOT_MATRIX_HOMESERVER:-}" ]; then
  MT_NOTIFY_HOMESERVER="$ALERTBOT_MATRIX_HOMESERVER"
fi
if [ -z "${MT_NOTIFY_HOMESERVER:-}" ] && [ -n "${MATRIX_HOST:-}" ]; then
  MT_NOTIFY_HOMESERVER="https://${MATRIX_HOST}"
fi

# Last resort: discover credentials from infra tenant secrets directly.
# This covers scripts like manage_infra that don't load tenant/infra config
# before sourcing notify.sh. Requires MT_ENV and yq.
# Uses the same discovery logic as infra-config.sh: find the tenant whose
# dns.domain matches infra.domain (the "infra tenant").
if [ -z "${MT_NOTIFY_TOKEN:-}" ] || [ -z "${MT_NOTIFY_ROOM_ID:-}" ] || [ -z "${MT_NOTIFY_HOMESERVER:-}" ]; then
  if [ -n "${MT_ENV:-}" ] && command -v yq &>/dev/null; then
    # Step 1: discover INFRA_DOMAIN from any tenant config
    _nt_infra_domain=""
    for _nt_td in "$_MT_NOTIFY_REPO/tenants"/*/; do
      _nt_config="${_nt_td}${MT_ENV}.config.yaml"
      if [ -f "$_nt_config" ]; then
        _nt_infra_domain=$(yq '.infra.domain // .dns.domain' "$_nt_config" 2>/dev/null)
        break
      fi
    done

    # Step 2: find the tenant whose dns.domain == INFRA_DOMAIN
    if [ -n "$_nt_infra_domain" ] && [ "$_nt_infra_domain" != "null" ]; then
      for _nt_td in "$_MT_NOTIFY_REPO/tenants"/*/; do
        _nt_config="${_nt_td}${MT_ENV}.config.yaml"
        _nt_secrets="${_nt_td}${MT_ENV}.secrets.yaml"
        [ -f "$_nt_config" ] && [ -f "$_nt_secrets" ] || continue
        _nt_domain=$(yq '.dns.domain // ""' "$_nt_config" 2>/dev/null)
        [ "$_nt_domain" = "$_nt_infra_domain" ] || continue

        # Found the infra tenant — load credentials
        if [ -z "${MT_NOTIFY_TOKEN:-}" ]; then
          _nt_token=$(yq '.alertbot.access_token // ""' "$_nt_secrets" 2>/dev/null)
          [ -n "$_nt_token" ] && [ "$_nt_token" != "null" ] && MT_NOTIFY_TOKEN="$_nt_token"
        fi
        if [ -z "${MT_NOTIFY_ROOM_ID:-}" ]; then
          _nt_room=$(yq '.alertbot.deploy_room_id // ""' "$_nt_secrets" 2>/dev/null)
          [ -n "$_nt_room" ] && [ "$_nt_room" != "null" ] && MT_NOTIFY_ROOM_ID="$_nt_room"
        fi
        if [ -z "${MT_NOTIFY_ROOM_ID:-}" ]; then
          _nt_room=$(yq '.alertbot.room_id // ""' "$_nt_secrets" 2>/dev/null)
          [ -n "$_nt_room" ] && [ "$_nt_room" != "null" ] && MT_NOTIFY_ROOM_ID="$_nt_room"
        fi
        if [ -z "${MT_NOTIFY_HOMESERVER:-}" ]; then
          _nt_hs=$(yq '.alertbot.homeserver // ""' "$_nt_secrets" 2>/dev/null)
          if [ -n "$_nt_hs" ] && [ "$_nt_hs" != "null" ]; then
            MT_NOTIFY_HOMESERVER="$_nt_hs"
          else
            _nt_dns_label=$(yq '.dns.env_dns_label // ""' "$_nt_config" 2>/dev/null)
            if [ -n "$_nt_dns_label" ] && [ "$_nt_dns_label" != "null" ]; then
              MT_NOTIFY_HOMESERVER="https://matrix.${_nt_dns_label}.${_nt_infra_domain}"
            else
              MT_NOTIFY_HOMESERVER="https://matrix.${_nt_infra_domain}"
            fi
          fi
        fi
        break
      done
    fi
    unset _nt_td _nt_secrets _nt_config _nt_token _nt_room _nt_hs _nt_dns_label _nt_domain _nt_infra_domain
  fi
fi

# ---------------------------------------------------------------------------
# Internal: detect whether Matrix is configured
# ---------------------------------------------------------------------------
_mt_notify_matrix_ok() {
  [ -n "${MT_NOTIFY_HOMESERVER:-}" ] && [ -n "${MT_NOTIFY_TOKEN:-}" ] && [ -n "${MT_NOTIFY_ROOM_ID:-}" ]
}

# ---------------------------------------------------------------------------
# Internal: send a message to the Matrix room (best-effort, never fails the script)
# ---------------------------------------------------------------------------
_mt_notify_matrix_send() {
  local plain="$1"
  local html="${2:-$1}"
  local msgtype="${3:-m.text}"
  _mt_notify_matrix_ok || return 0

  local txn_id
  txn_id="mt_$(date +%s%N)_$$"

  local json
  if [ -n "${_MT_NOTIFY_THREAD_ROOT:-}" ]; then
    # Send as a thread reply to the first message
    json=$(jq -n --arg body "$plain" --arg html "$html" --arg msgtype "$msgtype" \
      --arg root "$_MT_NOTIFY_THREAD_ROOT" \
      '{msgtype: $msgtype, body: $body, format: "org.matrix.custom.html", formatted_body: $html,
        "m.relates_to": {rel_type: "m.thread", event_id: $root}}')
  else
    json=$(jq -n --arg body "$plain" --arg html "$html" --arg msgtype "$msgtype" \
      '{msgtype: $msgtype, body: $body, format: "org.matrix.custom.html", formatted_body: $html}')
  fi

  # URL-encode room ID (! and : are special)
  local encoded_room
  encoded_room=$(printf '%s' "$MT_NOTIFY_ROOM_ID" | jq -sRr @uri)

  local response http_code
  response=$(curl -sS --max-time 10 -w '\n%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer ${MT_NOTIFY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$json" \
    "${MT_NOTIFY_HOMESERVER}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn_id}" \
    2>/dev/null) || true

  http_code=$(echo "$response" | tail -1)
  response=$(echo "$response" | sed '$d')

  # On first send failure, warn on stderr so operators notice misconfigured credentials
  if [ "${_MT_NOTIFY_WARNED:-}" != "1" ] && [ -n "$http_code" ] && [ "$http_code" != "200" ]; then
    echo "[DEPLOY] WARNING: Matrix notification failed (HTTP $http_code) — check alertbot credentials for tenant ${TENANT:-unknown}" >&2
    _MT_NOTIFY_WARNED=1
  fi

  # Capture event_id from the first message to use as thread root for subsequent messages.
  # Only create a new thread root at nesting level 0 — nested scripts must inherit the
  # parent's thread root via the exported env var, never start their own top-level thread.
  if [ -z "${_MT_NOTIFY_THREAD_ROOT:-}" ] && [ "${_MT_NOTIFY_NESTING_LEVEL:-0}" -eq 0 ] && [ -n "${response:-}" ]; then
    _MT_NOTIFY_THREAD_ROOT=$(echo "$response" | jq -r '.event_id // empty' 2>/dev/null) || true
    export _MT_NOTIFY_THREAD_ROOT
  fi
}

# ---------------------------------------------------------------------------
# Public: send a notification (stderr + Matrix)
# ---------------------------------------------------------------------------
mt_notify() {
  local plain="$1"
  local html="${2:-$1}"
  local msgtype="${3:-m.text}"
  local indent="" html_indent="" i
  for ((i=0; i<${_MT_NOTIFY_NESTING_LEVEL:-0}; i++)); do
    indent+=$'\t'
    html_indent+="&emsp;&emsp;"
  done
  echo "[DEPLOY] ${indent}${plain}" >&2
  _mt_notify_matrix_send "${indent}${plain}" "${html_indent}${html}" "$msgtype"
}

# ---------------------------------------------------------------------------
# Internal: build context string (env, tenant, git hash)
# ---------------------------------------------------------------------------
_mt_notify_context() {
  local parts=()
  [ -n "${MT_ENV:-}" ] && parts+=("env=$MT_ENV")
  [ -n "${TENANT:-}" ] && parts+=("tenant=$TENANT")
  local git_hash
  git_hash=$(git -C "$_MT_NOTIFY_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  parts+=("$git_hash")
  echo "${parts[*]}"
}

# ---------------------------------------------------------------------------
# Internal: EXIT trap handler
# ---------------------------------------------------------------------------
_mt_deploy_exit_handler() {
  local exit_code=$?
  local elapsed=""
  if [ -n "${_MT_DEPLOY_START_TS:-}" ]; then
    local end_ts
    end_ts=$(date +%s)
    local dur=$(( end_ts - _MT_DEPLOY_START_TS ))
    local mins=$(( dur / 60 ))
    local secs=$(( dur % 60 ))
    elapsed=" (${mins}m${secs}s)"
  fi

  local name="${_MT_DEPLOY_SCRIPT_NAME:-deploy}"
  if [ $exit_code -eq 0 ]; then
    mt_notify "${name} finished OK${elapsed} [${_MT_DEPLOY_CONTEXT}]" \
              "✅ <b>${name}</b> finished OK${elapsed} [${_MT_DEPLOY_CONTEXT}]"
  else
    mt_notify "${name} FAILED (exit $exit_code)${elapsed} [${_MT_DEPLOY_CONTEXT}]" \
              "❌ <b>${name}</b> FAILED (exit $exit_code)${elapsed} [${_MT_DEPLOY_CONTEXT}]" \
              "m.notice"
  fi
}

# ---------------------------------------------------------------------------
# Public: call once at the top of a script to send start notification and
#         register the EXIT trap for automatic end notification.
# ---------------------------------------------------------------------------
mt_deploy_start() {
  local script_name="${1:-deploy}"
  _MT_DEPLOY_SCRIPT_NAME="$script_name"
  _MT_DEPLOY_START_TS=$(date +%s)
  _MT_DEPLOY_CONTEXT="$(_mt_notify_context)"

  # Build the thread-root summary line:
  #   ENV [TENANT] Script Name HH:MM (hash abc1234)
  local git_hash
  git_hash=$(git -C "$_MT_NOTIFY_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local env_upper=""
  [ -n "${MT_ENV:-}" ] && env_upper="$(echo "$MT_ENV" | tr '[:lower:]' '[:upper:]') "
  local tenant_upper=""
  [ -n "${TENANT:-}" ] && tenant_upper="$(echo "$TENANT" | tr '[:lower:]' '[:upper:]') "
  # Title-case the script name: replace underscores with spaces, capitalise each word
  local pretty_name
  pretty_name=$(echo "$script_name" | tr '_' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
  local ts
  ts=$(date +%H:%M)
  local summary="${env_upper}${tenant_upper}${pretty_name} ${ts} (hash ${git_hash})"

  # Send summary as the thread root (plain text on stderr, rich in Matrix)
  mt_notify "$summary" "🚀 <b>${summary}</b>"

  # Send the detailed "started" line as a threaded reply
  mt_notify "$script_name started [${_MT_DEPLOY_CONTEXT}]" \
            "<b>${script_name}</b> started [${_MT_DEPLOY_CONTEXT}]"

  trap _mt_deploy_exit_handler EXIT
}
