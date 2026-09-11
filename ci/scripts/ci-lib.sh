#!/usr/bin/env bash
# Shared library for CI scripts — Valkey helpers and pipeline liveness checks.
#
# Source this file to get:
#   vcli()                          — Valkey CLI wrapper (requires CI_VALKEY_PASSWORD)
#   vcli_del_if()                   — atomic compare-and-delete (never steal a
#                                     lock another waiter has just won)
#   vcli_renew_if()                 — atomic TTL refresh, only if still ours
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

# ── Guarded TTL refresh ─────────────────────────────────────────
# Refresh <key>'s TTL only if it still holds <expected-value>. Echoes 1 when the
# TTL was extended, 0 when the key had changed hands or expired.
#
# The unguarded form of this — `SET <key> <us> XX EX <ttl>` with the result
# discarded — is the same family of bug as vcli_del_if's: if the key expired in
# the window, XX is a silent no-op and the caller proceeds believing it holds a
# lock it does not; if someone else acquired, XX overwrites their holder value.
vcli_renew_if() {  # vcli_renew_if <key> <expected-value> <ttl-seconds>
  # See vcli_del_if: never ${n:?} here — it would abort a caller's EXIT trap.
  if [[ -z "${1:-}" || -z "${2:-}" || -z "${3:-}" ]]; then
    echo "vcli_renew_if: key, expected value and ttl are all required" >&2
    return 2
  fi
  local key="$1"
  local expected="$2"
  local ttl="$3"
  vcli EVAL \
    "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('expire', KEYS[1], ARGV[2]) else return 0 end" \
    1 "$key" "$expected" "$ttl"
}

# ── Atomic compare-and-delete ───────────────────────────────────
# Delete <key> only if it still holds <expected-value>. Echoes 1 when the key
# was deleted, 0 when it had changed hands (or vanished) in the meantime.
#
# Every lock in CI is a `SET NX EX` whose value identifies the holder. The
# acquire is atomic; a bare `GET` followed by `DEL` is not. Two waiters that
# observe the SAME dead holder will both issue the DEL, and the second one
# deletes the lock the first has just won — so both believe they hold it.
#
# That is not hypothetical: on 2026-09-09 pipelines #2131 and #2132 both printed
# "Acquired infra lock" through exactly this path and then ran concurrent
# `terraform apply` against phase1-dev/terraform.tfstate (issue #647).
#
# Doing the compare and the delete in one Lua body makes it atomic: only the
# holder value we actually observed can be removed.
vcli_del_if() {  # vcli_del_if <key> <expected-value>
  # NOT ${1:?...}: a parameter-expansion failure exits the shell outright and is
  # NOT caught by `|| true`. These run inside ci-deploy.sh's EXIT trap, where an
  # abort would skip _cleanup and leave the decrypted deploy vault and tenant
  # *.secrets.yaml on disk. Return non-zero instead. ${1:-} so `set -u` does not
  # re-create the abort when an argument is genuinely absent.
  if [[ -z "${1:-}" || -z "${2:-}" ]]; then
    echo "vcli_del_if: key and expected value are both required" >&2
    return 2
  fi
  local key="$1"
  local expected="$2"
  vcli EVAL \
    "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end" \
    1 "$key" "$expected"
}

# ── Linode API: dev kubeconfig fetch ────────────────────────────
# Tunables (env-overridable; scripts/tests/ci-lib-kubeconfig-fetch.test.sh
# shrinks them):
#   CI_KCFG_FETCH_MAX_WAIT      total seconds of back-off budget before giving
#                               up (default 300 — an LKE cluster answers 503
#                               "kubeconfig is not yet available" for minutes
#                               after creation, pipeline #2090)
#   CI_KCFG_FETCH_BACKOFF       first back-off in seconds, doubles per retry
#   CI_KCFG_FETCH_MAX_BACKOFF   cap on one back-off / an honoured Retry-After
#   CI_KCFG_FETCH_MAX_ATTEMPTS  hard cap on attempts (belt and braces when a
#                               Retry-After of 0 would otherwise spin)
#   CI_LINODE_API               API base (tests point it at a stub)
CI_KCFG_FETCH_MAX_WAIT="${CI_KCFG_FETCH_MAX_WAIT:-300}"
CI_KCFG_FETCH_BACKOFF="${CI_KCFG_FETCH_BACKOFF:-10}"
CI_KCFG_FETCH_MAX_BACKOFF="${CI_KCFG_FETCH_MAX_BACKOFF:-60}"
CI_KCFG_FETCH_MAX_ATTEMPTS="${CI_KCFG_FETCH_MAX_ATTEMPTS:-40}"
CI_LINODE_API="${CI_LINODE_API:-https://api.linode.com/v4}"
# Set by ci_fetch_dev_kubeconfig on failure: one line the caller can print.
CI_KCFG_FETCH_LAST_ERROR=""

# _ci_linode_get <url> <body_out> <headers_out>
# One authenticated GET. Prints the HTTP status ("000" when curl itself
# failed) and returns curl's exit code. Response body and headers land in the
# two files; curl's own stderr in <headers_out>.err so a transport failure
# carries a reason too. The token travels only in the -H argument — it is
# never echoed and curl is never run with -v.
_ci_linode_get() {
  local url="$1" body="$2" hdrs="$3" status rc=0
  status=$(curl -sS --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $LINODE_CLI_TOKEN" \
    -o "$body" -D "$hdrs" -w '%{http_code}' "$url" 2>"${hdrs}.err") || rc=$?
  printf '%s' "${status:-000}"
  return "$rc"
}

# _ci_linode_reason <status> <body> <headers>
# One-line, secret-free explanation of a failed call: Linode's JSON error
# reasons when present, else the first 200 bytes of the body, else curl's
# stderr for a transport failure.
_ci_linode_reason() {
  local status="$1" body="$2" hdrs="$3" reason=""
  if [ "$status" = "000" ]; then
    reason=$(tr '\n' ' ' <"${hdrs}.err" 2>/dev/null | cut -c1-200)
    reason="${reason:-transport failure (no curl stderr)}"
  else
    reason=$(jq -r '[.errors[]? | (.field // "" | if . == "" then "" else . + ": " end) + .reason] | join("; ")' "$body" 2>/dev/null || true)
    if [ -z "$reason" ]; then
      reason=$(tr '\n' ' ' <"$body" 2>/dev/null | cut -c1-200)
    fi
    reason="${reason:-(empty body)}"
  fi
  # Belt and braces: Linode's error envelope never reflects request headers,
  # but an intermediary's error page might. The token must never reach a
  # Woodpecker log, whatever produced the text.
  if [ -n "${LINODE_CLI_TOKEN:-}" ]; then
    reason="${reason//"$LINODE_CLI_TOKEN"/[REDACTED]}"
  fi
  printf '%s' "$reason"
}

# Fetch a fresh kubeconfig for the live dev LKE cluster and write it to
# $1 (path). Each Woodpecker workflow gets its own workspace, so the
# fresh kubeconfig written by dev-bringup in ensure-dev-cluster doesn't
# propagate to deploy-dev-prep, deploy-dev-matrix, etc. — and the dev vault
# deliberately carries NO kubeconfig (on-demand clusters make any copy stale
# by a reaper cycle). The Linode API is therefore the only source, so this
# retries instead of giving up on the first hiccup:
#   429            → wait Retry-After (capped), retry
#   5xx / curl err → back off (exponential, capped), retry
#   other 4xx      → not retryable: fail now with the reason (401/403 = token,
#                    404 = cluster vanished)
# Returns 0 on success, 2 when no cluster carries the label (dev reaped or
# ensure-dev-cluster has not run — a state, not a transport error, so no
# retry), 1 on any other failure. Every failure is explained on stderr and in
# CI_KCFG_FETCH_LAST_ERROR. Pipeline #2089 lost 3 of 9 parallel app steps to
# the old single-shot, stderr-swallowing version of this function.
ci_fetch_dev_kubeconfig() {
  local target="${1:?ci_fetch_dev_kubeconfig: target path required}"
  : "${LINODE_CLI_TOKEN:?LINODE_CLI_TOKEN required for kubeconfig fetch}"
  # The bearer token goes wherever CI_LINODE_API points: refuse anything but
  # https so a stray override cannot ship it in clear text.
  case "$CI_LINODE_API" in
    https://*) ;;
    *)
      CI_KCFG_FETCH_LAST_ERROR="CI_LINODE_API must be an https:// URL (got '$CI_LINODE_API')"
      echo "ci_fetch_dev_kubeconfig: $CI_KCFG_FETCH_LAST_ERROR" >&2
      return 1
      ;;
  esac
  local cluster_label="${CLUSTER_LABEL:-matrix-cluster-dev}"
  local tmp body hdrs
  tmp=$(mktemp -d)
  body="$tmp/body"
  hdrs="$tmp/hdrs"
  local elapsed=0 attempt=0 backoff="$CI_KCFG_FETCH_BACKOFF"
  local phase="list" cluster_id="" url status rc reason wait retry_after kcfg_b64 old_umask
  CI_KCFG_FETCH_LAST_ERROR=""
  while :; do
    attempt=$((attempt + 1))
    if [ "$phase" = "list" ]; then
      url="$CI_LINODE_API/lke/clusters"
    else
      url="$CI_LINODE_API/lke/clusters/${cluster_id}/kubeconfig"
    fi
    rc=0
    status=$(_ci_linode_get "$url" "$body" "$hdrs") || rc=$?
    if [ "$rc" -eq 0 ] && [ "$status" = "200" ]; then
      if [ "$phase" = "list" ]; then
        cluster_id=$(jq -r --arg label "$cluster_label" '.data[]? | select(.label==$label) | .id' "$body" 2>/dev/null | head -n1 || true)
        if [ -z "$cluster_id" ] || [ "$cluster_id" = "null" ]; then
          CI_KCFG_FETCH_LAST_ERROR="no LKE cluster labelled '$cluster_label' (dev reaped, or ensure-dev-cluster has not run)"
          echo "ci_fetch_dev_kubeconfig: $CI_KCFG_FETCH_LAST_ERROR" >&2
          rm -rf "$tmp"
          return 2
        fi
        phase="kubeconfig"
        attempt=0   # attempt numbers in the log are per phase
        continue
      fi
      kcfg_b64=$(jq -r '.kubeconfig // empty' "$body" 2>/dev/null || true)
      if [ -n "$kcfg_b64" ]; then
        old_umask=$(umask)
        umask 077
        printf '%s' "$kcfg_b64" | base64 -d > "$target"
        umask "$old_umask"
        rm -rf "$tmp"
        return 0
      fi
      reason="HTTP 200 but no kubeconfig in the response"
    else
      reason="HTTP $status: $(_ci_linode_reason "$status" "$body" "$hdrs")"
      case "$status" in
        429|5[0-9][0-9]|000) ;;
        4[0-9][0-9])
          CI_KCFG_FETCH_LAST_ERROR="$phase call failed, not retryable — $reason"
          echo "ci_fetch_dev_kubeconfig: $CI_KCFG_FETCH_LAST_ERROR" >&2
          rm -rf "$tmp"
          return 1
          ;;
      esac
    fi
    # Retryable. Honour Retry-After on 429, otherwise exponential back-off.
    wait="$backoff"
    if [ "$status" = "429" ]; then
      retry_after=$(grep -i '^retry-after:' "$hdrs" 2>/dev/null | head -n1 | tr -d '\r' | awk '{print $2}')
      if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        wait="$retry_after"
      fi
    fi
    [ "$wait" -gt "$CI_KCFG_FETCH_MAX_BACKOFF" ] && wait="$CI_KCFG_FETCH_MAX_BACKOFF"
    if [ $((elapsed + wait)) -gt "$CI_KCFG_FETCH_MAX_WAIT" ] || [ "$attempt" -ge "$CI_KCFG_FETCH_MAX_ATTEMPTS" ]; then
      CI_KCFG_FETCH_LAST_ERROR="gave up after $attempt attempt(s) and ${elapsed}s of back-off; last $phase call: $reason"
      echo "ci_fetch_dev_kubeconfig: $CI_KCFG_FETCH_LAST_ERROR" >&2
      rm -rf "$tmp"
      return 1
    fi
    echo "ci_fetch_dev_kubeconfig: $phase attempt $attempt failed ($reason); retrying in ${wait}s (${elapsed}s/${CI_KCFG_FETCH_MAX_WAIT}s back-off used)" >&2
    sleep "$wait"
    elapsed=$((elapsed + wait))
    backoff=$((backoff * 2))
    [ "$backoff" -gt "$CI_KCFG_FETCH_MAX_BACKOFF" ] && backoff="$CI_KCFG_FETCH_MAX_BACKOFF"
  done
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

# ── Config submodule clone ──────────────────────────────────────
# Clone the private config submodules (config/platform, config/tenants) into
# the checkout. config/platform carries the committed, encrypted deploy vaults
# (config/platform/ci/deploy-vault-<env>.vault) that ci_decrypt_committed_vault
# reads, so this MUST run BEFORE vault decryption — not after, as it did when
# the vault was sourced from the CI host (GitHub issue #463). Uses GITHUB_PAT
# (a Woodpecker pipeline secret, not something stored in the vault, so there is
# no chicken-and-egg) to rewrite the SSH submodule URLs to authenticated HTTPS;
# --global so the child git processes spawned by `submodule update` inherit it.
# Leaves the cwd at <repo_root>.
#
#   ci_clone_config_submodules <repo_root>
ci_clone_config_submodules() {
  local repo_root="${1:?ci_clone_config_submodules: repo_root required}"
  cd "$repo_root" || return 1
  if [[ -n "${GITHUB_PAT:-}" ]]; then
    git config --global url."https://x-access-token:${GITHUB_PAT}@github.com/".insteadOf "git@github.com:"
    echo "Configured git URL rewriting for private submodule access"
  fi
  echo "Initializing config submodules..."
  git submodule update --init config/platform config/tenants || {
    echo "ERROR: Failed to init config submodules." >&2
    echo "Ensure GITHUB_PAT secret is set and has access to the private config repos." >&2
    return 1
  }
}

# ── Committed deploy-vault decryption ───────────────────────────
# Decrypt the env's deploy vault from the COMMITTED copy inside the cloned
# config/platform submodule (config/platform/ci/deploy-vault-<env>.vault) — the
# single source of truth. A merged vault change is therefore picked up by the
# next pipeline run with no operator reprovision (GitHub issue #463).
#
# There is deliberately NO fallback to the old host-provisioned copy under
# /home/woodpecker/deploy-vaults: a missing committed vault is a hard error, not
# a silent downgrade to a possibly-stale host copy (project rule: fail fast,
# never silently skip). Password selection is unchanged — delegated to
# ci_decrypt_vault (dev-only password for dev, shared operator password for
# prod/prod-eu). Requires ci_clone_config_submodules to have run first.
#
#   ci_decrypt_committed_vault <repo_root> <env> <out_tar>
ci_decrypt_committed_vault() {
  local repo_root="${1:?ci_decrypt_committed_vault: repo_root required}"
  local env="${2:?ci_decrypt_committed_vault: env required}"
  local out_tar="${3:?ci_decrypt_committed_vault: out_tar required}"
  local vault_file="$repo_root/config/platform/ci/deploy-vault-${env}.vault"
  if [[ ! -f "$vault_file" ]]; then
    echo "ERROR: Committed deploy vault not found: $vault_file" >&2
    echo "       Expected it in the config/platform submodule — run ci_clone_config_submodules first." >&2
    return 1
  fi
  ci_decrypt_vault "$vault_file" "$env" "$out_tar"
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
