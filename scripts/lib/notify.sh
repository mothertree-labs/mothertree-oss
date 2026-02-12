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
# Configuration (env vars or notify.env at repo root):
#   MT_NOTIFY_HOMESERVER  — Matrix homeserver URL  (e.g. https://matrix.example.com)
#   MT_NOTIFY_TOKEN       — Bot access token
#   MT_NOTIFY_ROOM_ID     — Room to post in

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
# Load credentials: env vars > notify.env > alertbot fallback
# ---------------------------------------------------------------------------
if [ -z "${MT_NOTIFY_HOMESERVER:-}" ] || [ -z "${MT_NOTIFY_TOKEN:-}" ] || [ -z "${MT_NOTIFY_ROOM_ID:-}" ]; then
  if [ -f "$_MT_NOTIFY_REPO/notify.env" ]; then
    # shellcheck disable=SC1091
    source "$_MT_NOTIFY_REPO/notify.env"
  fi
fi

# Fallback: reuse alertbot credentials set by create_env
if [ -z "${MT_NOTIFY_TOKEN:-}" ] && [ -n "${MATRIX_ALERTMANAGER_ACCESS_TOKEN:-}" ]; then
  MT_NOTIFY_TOKEN="$MATRIX_ALERTMANAGER_ACCESS_TOKEN"
fi
if [ -z "${MT_NOTIFY_ROOM_ID:-}" ] && [ -n "${ALERTMANAGER_MATRIX_ROOM_ID:-}" ]; then
  MT_NOTIFY_ROOM_ID="$ALERTMANAGER_MATRIX_ROOM_ID"
fi
if [ -z "${MT_NOTIFY_HOMESERVER:-}" ] && [ -n "${MATRIX_HOST:-}" ]; then
  MT_NOTIFY_HOMESERVER="https://${MATRIX_HOST}"
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
  json=$(jq -n --arg body "$plain" --arg html "$html" --arg msgtype "$msgtype" \
    '{msgtype: $msgtype, body: $body, format: "org.matrix.custom.html", formatted_body: $html}')

  # URL-encode room ID (! and : are special)
  local encoded_room
  encoded_room=$(printf '%s' "$MT_NOTIFY_ROOM_ID" | jq -sRr @uri)

  curl -sS --max-time 10 -o /dev/null \
    -X PUT \
    -H "Authorization: Bearer ${MT_NOTIFY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$json" \
    "${MT_NOTIFY_HOMESERVER}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn_id}" \
    2>/dev/null || true
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

  mt_notify "$script_name started [${_MT_DEPLOY_CONTEXT}]" \
            "🚀 <b>${script_name}</b> started [${_MT_DEPLOY_CONTEXT}]"

  trap _mt_deploy_exit_handler EXIT
}
