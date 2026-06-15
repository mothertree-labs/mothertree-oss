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

# Fetch a fresh kubeconfig for the live dev LKE cluster and write it to
# $1 (path). Each Woodpecker workflow gets its own workspace, so the
# fresh kubeconfig written by dev-bringup in ensure-dev-cluster doesn't
# propagate to deploy-dev-prep, deploy-dev-matrix, etc. — they would
# otherwise inherit whatever stale copy lives in the deploy vault.
# Returns 0 on success, non-zero on failure. Caller is expected to fall
# back to the vault's copy on failure (e.g. for prod where this isn't
# applicable).
ci_fetch_dev_kubeconfig() {
  local target="${1:?ci_fetch_dev_kubeconfig: target path required}"
  : "${LINODE_CLI_TOKEN:?LINODE_CLI_TOKEN required for kubeconfig fetch}"
  local cluster_label="${CLUSTER_LABEL:-matrix-cluster-dev}"
  local cluster_id
  cluster_id=$(curl -sf --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $LINODE_CLI_TOKEN" \
    https://api.linode.com/v4/lke/clusters 2>/dev/null \
    | jq -r --arg label "$cluster_label" '.data[] | select(.label==$label) | .id' \
    | head -n1 || true)
  if [ -z "$cluster_id" ] || [ "$cluster_id" = "null" ]; then
    return 1
  fi
  local kcfg_b64
  kcfg_b64=$(curl -sf --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $LINODE_CLI_TOKEN" \
    "https://api.linode.com/v4/lke/clusters/${cluster_id}/kubeconfig" 2>/dev/null \
    | jq -r '.kubeconfig // empty' || true)
  if [ -z "$kcfg_b64" ]; then
    return 1
  fi
  umask 077
  echo "$kcfg_b64" | base64 -d > "$target"
  umask 022
}

# ── Deploy-vault decryption ─────────────────────────────────────
# Path to the dev-only vault password, provisioned to the CI host by Ansible
# (ci/ansible/playbook.yml, from the `deploy_vault_password_dev` var). Override
# via CI_DEV_VAULT_PASS_FILE for testing.
CI_DEV_VAULT_PASS_FILE="${CI_DEV_VAULT_PASS_FILE:-/home/woodpecker/deploy-vaults/dev-vault-pass}"

# Decrypt a deploy vault into <out_tar>, choosing the right password per env.
#
#   ci_decrypt_vault <vault_file> <env> <out_tar>
#
# prod / prod-eu: use the shared DEPLOY_VAULT_PASSWORD (unchanged behaviour).
# dev: the dev vault is re-keyed with its OWN password so it can be shared with
#   a contributor without exposing prod/prod-eu. If the host has the dev
#   password file, try the dev password FIRST and fall back to the shared one —
#   ansible-vault tries each --vault-id until one decrypts, so this works whether
#   or not the dev vault has been re-keyed yet (no migration flag-day). If the
#   dev password file is absent (env not yet provisioned), dev falls through to
#   the shared path unchanged.
#
# Requires DEPLOY_VAULT_PASSWORD in the environment (callers already enforce it).
ci_decrypt_vault() {
  local vault_file="${1:?ci_decrypt_vault: vault_file required}"
  local env="${2:?ci_decrypt_vault: env required}"
  local out_tar="${3:?ci_decrypt_vault: out_tar required}"
  : "${DEPLOY_VAULT_PASSWORD:?DEPLOY_VAULT_PASSWORD is required}"

  if [[ "$env" == "dev" && -s "$CI_DEV_VAULT_PASS_FILE" ]]; then
    # Stage the shared password in a 0600 temp file so both passwords can be
    # offered as labelled vault-ids. ansible-vault tries each until one opens.
    # Write it inside the caller's output dir (its WORK_DIR), which the caller's
    # EXIT trap scrubs — so a kill mid-decrypt can't orphan the password file.
    local shared_pw_file rc=0
    shared_pw_file=$(mktemp "$(dirname "$out_tar")/.vpw-XXXXXX")
    chmod 600 "$shared_pw_file"
    printf '%s\n' "$DEPLOY_VAULT_PASSWORD" > "$shared_pw_file"
    ansible-vault decrypt "$vault_file" \
      --vault-id "dev@${CI_DEV_VAULT_PASS_FILE}" \
      --vault-id "shared@${shared_pw_file}" \
      --output "$out_tar" || rc=$?
    rm -f "$shared_pw_file"
    return "$rc"
  fi

  ansible-vault decrypt "$vault_file" \
    --vault-password-file <(echo "$DEPLOY_VAULT_PASSWORD") \
    --output "$out_tar"
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
