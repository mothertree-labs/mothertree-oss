#!/bin/bash
# Tailscale pre-auth key verification and rotation via the Headscale REST API.
#
# The single implementation behind:
#   - apps/deploy-{pgbouncer,pg-metrics-bridge,tailscale-router,metrics-federation}.sh
#       mt_ts_ensure_secret   bootstrap (mint) or verify/rotate a sidecar's auth Secret
#   - the tailscale-key-rotator CronJob — this file is mounted verbatim into its
#     ConfigMap and sourced by rotate.sh (bash in alpine/k8s, no common.sh)
#       mt_ts_run_components  verify every component's Secret; rotate + restart if bad
#   - scripts/check-tailscale-keys (operator CLI: check / --rotate / --force)
#   - scripts/deploy_infra --rotate-all-keys
#
# Why "verify the key in the Secret" instead of "best key for the tag": the
# previous rotator picked the longest-lived Headscale key carrying the tag and
# never looked at what the Kubernetes Secret held. A multi-tag bootstrap key
# expiring in 2036 masked Secrets that had held a dead, untagged key since
# 2026-03-31 — until a pod recreation surfaced "authkey expired" in prod (#613).
#
# Headscale 0.28/0.29 API facts this relies on (verified against the live servers;
# Ansible pins 0.29.3 — re-check on the next Renovate bump):
#   GET  /api/v1/preauthkey -> {preAuthKeys:[{id, key:"hskey-auth-<prefix>-***", reusable,
#                               ephemeral, used, expiration, createdAt, aclTags[], user{}}]}
#                              The value of a 0.28+ key is never returned (legacy pre-0.28
#                              keys come back in full and never prefix-match, so a Secret
#                              holding one is rotated exactly once; a server listing ONLY
#                              legacy keys is refused until one 0.28-format key exists);
#                              expired keys stay listed; `used` stays false for reusable keys.
#   POST /api/v1/preauthkey -> {preAuthKey:{id, key:<full value, shown exactly once>, ...}}
#   POST /api/v1/preauthkey/expire {id}, DELETE /api/v1/preauthkey?id= (id-based)
#   A full key value starts with exactly the redacted prefix, so the key a Secret
#   holds is identified by prefix match. Every mint is followed by a self-check that
#   the matcher recognises the key it just created — a matcher regression fails the
#   run instead of rotating every sidecar daily. Nothing in this file prints a key
#   value, and no key value is ever placed on a command line.
#
# Deliberately NOT done here: expiring the superseded key after a rotation. prod and
# prod-eu share one Headscale and, until every Secret has been rotated once, share
# bootstrap keys (e.g. both pgbouncer Secrets hold the same key), so expiring a key
# one cluster stopped using can break the other cluster's next pod recreation. A
# superseded key stays valid until its own expiry (90 days for minted keys); the
# legacy long-lived bootstrap keys are to be expired by hand once no Secret holds
# them (scripts/check-tailscale-keys -e <env> on every cluster reports what does).
#
# The sidecar-log proof after a restart is real for pods with a per-pod state Secret
# (pgbouncer, pg-metrics-bridge): a new pod is a fresh registration and Headscale
# validates the key. The subnet router and the metrics federation pair keep a
# fixed-name state Secret (stable node identity and mesh IP — see the node
# identity helpers at the end of this file) and re-register an existing node,
# for which Headscale does not re-validate the auth key (the router pod restarted
# fine on 2026-09-02 with an expired key in the Secret) — so for those the proof
# only shows the restart worked, not the new key.
#
# Requirements: bash 3.2+, curl, jq, kubectl. Env: HEADSCALE_URL, HEADSCALE_API_KEY.
# Portability: no GNU-only flags — runs on busybox (CronJob) and macOS (operators).
#
# Tunables (env):
#   MT_TS_THRESHOLD_DAYS    rotate when fewer days remain            (default 30)
#   MT_TS_KEY_LIFETIME_DAYS lifetime of minted keys                  (default 90)
#   MT_TS_ROLLOUT_TIMEOUT   seconds to wait for a restarted rollout  (default 180)
#   MT_TS_SIDECAR_TIMEOUT   seconds to wait for sidecar auth proof   (default 120)
#   MT_TS_FORCE_ROTATE=1    rotate every Secret regardless of verdict
#   MT_TS_CHECK_ONLY=1      report verdicts, change nothing

# Guard against double-sourcing
if [ "${_MT_TAILSCALE_KEYS_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_TAILSCALE_KEYS_LOADED=1

MT_TS_THRESHOLD_DAYS="${MT_TS_THRESHOLD_DAYS:-30}"
MT_TS_KEY_LIFETIME_DAYS="${MT_TS_KEY_LIFETIME_DAYS:-90}"
MT_TS_ROLLOUT_TIMEOUT="${MT_TS_ROLLOUT_TIMEOUT:-180}"
MT_TS_SIDECAR_TIMEOUT="${MT_TS_SIDECAR_TIMEOUT:-120}"
MT_TS_HEADSCALE_USER="${MT_TS_HEADSCALE_USER:-infra}"
MT_TS_SIDECAR_CONTAINER="${MT_TS_SIDECAR_CONTAINER:-tailscale}"

# containerboot prints the success line only after `tailscale up` returned 0
# (fresh registration and reused node state alike — verified on prod pods).
MT_TS_SUCCESS_RE='Startup complete, waiting for shutdown signal'
MT_TS_FAILURE_RE='authkey expired|authkey already used|invalid auth ?key|machineAuthorized=false|tailscale up failed|failed to auth tailscale'

# Populated by mt_ts_keys_fetch
MT_TS_KEYS=""
MT_TS_PREFIX_LEN=0

# Populated by mt_ts_key_verdict / mt_ts_mint / mt_ts_ensure_secret / mt_ts_run_components
MT_TS_VERDICT=""
MT_TS_MINTED_ID=""
MT_TS_MINTED_VALUE=""
MT_TS_KEY_ID=""
MT_TS_KEY_DAYS_LEFT=""
MT_TS_SECRET_CHANGED=false
MT_TS_RUN_ROTATED=0
MT_TS_RUN_NEEDS=0
MT_TS_RUN_ERRORS=0

# ---------------------------------------------------------------------------
# Logging — delegates to common.sh's print_* when loaded (deploy scripts),
# plain timestamped lines otherwise (CronJob).
# ---------------------------------------------------------------------------
_ts_log() {
  if declare -f print_status >/dev/null 2>&1; then print_status "$*"
  else echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; fi
}
_ts_warn() {
  if declare -f print_warning >/dev/null 2>&1; then print_warning "$*"
  else echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] WARNING: $*"; fi
}
_ts_err() {
  if declare -f print_error >/dev/null 2>&1; then print_error "$*"
  else echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; fi
}

# ---------------------------------------------------------------------------
# _ts_api <METHOD> <path> [json-body] — authenticated Headscale API call.
# The bearer token is handed to curl through a config file on stdin, never argv.
# ---------------------------------------------------------------------------
_ts_api() {
  : "${HEADSCALE_URL:?HEADSCALE_URL not set}"
  : "${HEADSCALE_API_KEY:?HEADSCALE_API_KEY not set}"
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$HEADSCALE_API_KEY" \
      | curl -sfS --max-time 30 --config - -X "$method" \
          -H 'Content-Type: application/json' -d "$body" "${HEADSCALE_URL}${path}"
  else
    printf 'header = "Authorization: Bearer %s"\n' "$HEADSCALE_API_KEY" \
      | curl -sfS --max-time 30 --config - -X "$method" "${HEADSCALE_URL}${path}"
  fi
}

# ---------------------------------------------------------------------------
# mt_ts_keys_fetch — load the pre-auth key list into MT_TS_KEYS and derive the
# redacted-prefix length. Fails loudly if the API is unreachable or the key
# format is not the one this file understands.
# ---------------------------------------------------------------------------
mt_ts_keys_fetch() {
  MT_TS_KEYS=$(_ts_api GET /api/v1/preauthkey) || { _ts_err "Headscale API: cannot list pre-auth keys at ${HEADSCALE_URL:-<unset>}"; return 1; }
  MT_TS_PREFIX_LEN=$(printf '%s' "$MT_TS_KEYS" | jq -r '
    [.preAuthKeys[]?.key | select(endswith("-***")) | rtrimstr("-***") | length] | unique
    | if length == 0 then 0 elif length == 1 then .[0] else "ambiguous" end') || return 1
  if [ "$MT_TS_PREFIX_LEN" = "ambiguous" ]; then
    _ts_err "Headscale returned redacted keys of differing prefix lengths — refusing to match by prefix"
    return 1
  fi
  local n
  n=$(printf '%s' "$MT_TS_KEYS" | jq '.preAuthKeys | length')
  # A non-empty list with no key in the expected redacted form means the API
  # changed shape: with prefix length 0 nothing would ever match and every
  # component would be rotated on every run. Refuse instead.
  if [ "$n" -gt 0 ] && [ "$MT_TS_PREFIX_LEN" -eq 0 ]; then
    _ts_err "Headscale listed $n keys but none in the expected 'hskey-auth-<prefix>-***' form — refusing to match by prefix"
    return 1
  fi
  _ts_log "Headscale ${HEADSCALE_URL}: $n pre-auth keys listed"
}

# ---------------------------------------------------------------------------
# _ts_exists <kind> <name> <ns> — "present" / "absent", or return 1 on any API
# error (Forbidden, timeout, ...). NotFound must never be confused with an
# error: an error skipped as "absent" would silently drop a component from
# coverage — the very blind spot this library exists to close.
# ---------------------------------------------------------------------------
_ts_exists() {
  local kind="$1" name="$2" ns="${3:-}" out
  if [ -n "$ns" ]; then
    out=$(kubectl get "$kind" "$name" -n "$ns" --ignore-not-found -o name 2>&1) || { _ts_err "  kubectl get $kind/$name -n $ns failed: $(printf '%s\n' "$out" | tail -1)"; return 1; }
  else
    out=$(kubectl get "$kind" "$name" --ignore-not-found -o name 2>&1) || { _ts_err "  kubectl get $kind/$name failed: $(printf '%s\n' "$out" | tail -1)"; return 1; }
  fi
  # Decide on the "<kind>/<name>" line itself: stderr is merged in for the
  # error message above, and kubectl can print exit-0 warnings there (client/
  # server version skew) that must not read as "present".
  if printf '%s\n' "$out" | grep -cxE "[a-z0-9.]+/$name" >/dev/null; then echo present; else echo absent; fi
}

# ---------------------------------------------------------------------------
# mt_ts_secret_read <ns> <secret> — print the Secret's TS_AUTHKEY (empty if the
# key is absent from an existing Secret). Fails on any kubectl error, including
# NotFound — probe existence with _ts_exists first. Callers capture the output
# into a variable and never echo it.
# ---------------------------------------------------------------------------
mt_ts_secret_read() {
  kubectl get secret "$2" -n "$1" -o go-template='{{if index .data "TS_AUTHKEY"}}{{index .data "TS_AUTHKEY" | base64decode}}{{end}}'
}

# ---------------------------------------------------------------------------
# mt_ts_match_secret_key <value> — print the Headscale key object (compact JSON)
# whose redacted prefix matches the value, or nothing.
# ---------------------------------------------------------------------------
mt_ts_match_secret_key() {
  local value="$1" prefix
  [ "$MT_TS_PREFIX_LEN" -gt 0 ] || { echo ""; return 0; }
  prefix="${value:0:$MT_TS_PREFIX_LEN}"
  # Via the environment, not --arg: for a value that is not a key of this
  # server (legacy full-format key, garbage) the prefix is part of a secret.
  printf '%s' "$MT_TS_KEYS" | MT_TS_PREFIX="$prefix" jq -c \
    '[.preAuthKeys[] | select((.key | rtrimstr("-***")) == env.MT_TS_PREFIX)] | .[0] // empty'
}

# ---------------------------------------------------------------------------
# mt_ts_key_verdict <key-json-or-empty> <tag>
# Sets MT_TS_VERDICT ("" = the key is fine; otherwise the reason to rotate),
# MT_TS_KEY_ID and MT_TS_KEY_DAYS_LEFT.
# ---------------------------------------------------------------------------
mt_ts_key_verdict() {
  local key="$1" tag="$2" now exp
  MT_TS_VERDICT=""; MT_TS_KEY_ID=""; MT_TS_KEY_DAYS_LEFT=""
  if [ -z "$key" ]; then
    MT_TS_VERDICT="key not found on this Headscale server (minted elsewhere, or deleted)"
    return 0
  fi
  MT_TS_KEY_ID=$(printf '%s' "$key" | jq -r '.id')
  now=$(date -u +%s)
  exp=$(printf '%s' "$key" | jq -r '(.expiration // "9999-12-31T00:00:00Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null) || exp=""
  case "$exp" in
    ''|*[!0-9]*) MT_TS_VERDICT="key id $MT_TS_KEY_ID has an unparseable expiration ($(printf '%s' "$key" | jq -c '.expiration'))"; return 0 ;;
  esac
  MT_TS_KEY_DAYS_LEFT=$(( (exp - now) / 86400 ))
  if [ "$exp" -le "$now" ]; then
    MT_TS_VERDICT="key id $MT_TS_KEY_ID expired $(( -MT_TS_KEY_DAYS_LEFT )) days ago"
  elif [ "$(printf '%s' "$key" | jq -r '.reusable')" != "true" ]; then
    MT_TS_VERDICT="key id $MT_TS_KEY_ID is single-use"
  elif ! printf '%s' "$key" | jq -e --arg t "$tag" '(.aclTags // []) | any(. == $t)' >/dev/null; then
    MT_TS_VERDICT="key id $MT_TS_KEY_ID lacks $tag (tags: $(printf '%s' "$key" | jq -c '.aclTags // []'))"
  elif ! printf '%s' "$key" | jq -e --arg t "$tag" '(.aclTags // []) == [$t]' >/dev/null; then
    # A node registers with every tag on its key; extra tags = extra ACL reach.
    MT_TS_VERDICT="key id $MT_TS_KEY_ID carries tags beyond $tag (tags: $(printf '%s' "$key" | jq -c '.aclTags // []'))"
  elif [ "$exp" -lt $(( now + MT_TS_THRESHOLD_DAYS * 86400 )) ]; then
    MT_TS_VERDICT="key id $MT_TS_KEY_ID expires in $MT_TS_KEY_DAYS_LEFT days (threshold ${MT_TS_THRESHOLD_DAYS})"
  fi
}

# ---------------------------------------------------------------------------
# mt_ts_mint <tag> — create a reusable, tagged pre-auth key. The result is
# returned in MT_TS_MINTED_ID / MT_TS_MINTED_VALUE (globals, not stdout: a
# command substitution would run this in a subshell and lose the id). Callers
# clear MT_TS_MINTED_VALUE as soon as the key has been written.
# ---------------------------------------------------------------------------
mt_ts_mint() {
  local tag="$1" user_id exp_iso body resp key
  MT_TS_MINTED_ID=""; MT_TS_MINTED_VALUE=""
  user_id=$(_ts_api GET /api/v1/user | jq -r --arg u "$MT_TS_HEADSCALE_USER" '.users[] | select(.name == $u) | .id') || return 1
  [ -n "$user_id" ] || { _ts_err "Headscale user '$MT_TS_HEADSCALE_USER' not found"; return 1; }
  exp_iso=$(jq -rn --argjson s "$(( $(date -u +%s) + MT_TS_KEY_LIFETIME_DAYS * 86400 ))" '$s | todateiso8601')
  body=$(jq -cn --arg u "$user_id" --arg e "$exp_iso" --arg t "$tag" \
    '{user:$u, reusable:true, ephemeral:false, expiration:$e, aclTags:[$t]}')
  resp=$(_ts_api POST /api/v1/preauthkey "$body") || { _ts_err "Headscale API: failed to create a $tag key"; return 1; }
  key=$(printf '%s' "$resp" | jq -r '.preAuthKey.key // empty')
  [ -n "$key" ] || { _ts_err "Headscale returned no key value (response length ${#resp})"; return 1; }
  MT_TS_MINTED_ID=$(printf '%s' "$resp" | jq -r '.preAuthKey.id // empty')
  [ -n "$MT_TS_MINTED_ID" ] || { _ts_err "Headscale returned no key id (response length ${#resp})"; return 1; }
  MT_TS_MINTED_VALUE="$key"
}

# ---------------------------------------------------------------------------
# mt_ts_key_revoke <id> — expire, then delete, a key this run minted but could
# not use (best effort; errors are logged, not fatal).
# ---------------------------------------------------------------------------
mt_ts_key_revoke() {
  local id="$1"
  [ -n "$id" ] || return 0
  _ts_api POST /api/v1/preauthkey/expire "$(jq -cn --arg id "$id" '{id:$id}')" >/dev/null 2>&1 || _ts_warn "  could not expire key id $id"
  _ts_api DELETE "/api/v1/preauthkey?id=$id" >/dev/null 2>&1 || _ts_warn "  could not delete key id $id (left expired)"
}

# ---------------------------------------------------------------------------
# mt_ts_secret_write <ns> <secret> <value> [app-label]
# Create the Secret (kubectl create: no last-applied annotation carrying the
# value) or merge-patch TS_AUTHKEY into an existing one. The value travels via
# the environment into jq and via stdin into kubectl — never argv.
# ---------------------------------------------------------------------------
mt_ts_secret_write() {
  local ns="$1" secret="$2" app="${4:-}"
  local state
  state=$(_ts_exists secret "$secret" "$ns") || return 1
  if [ "$state" = present ]; then
    # Also drop the last-applied annotation the old `kubectl apply` bootstrap
    # left behind — it still carries the previous key in plaintext.
    MT_TS_NEW_VALUE="$3" jq -cn '{metadata:{annotations:{"kubectl.kubernetes.io/last-applied-configuration":null}}, stringData:{TS_AUTHKEY:env.MT_TS_NEW_VALUE}}' \
      | kubectl patch secret "$secret" -n "$ns" --type=merge --patch-file /dev/stdin >/dev/null
  else
    MT_TS_NEW_VALUE="$3" jq -cn --arg n "$secret" --arg ns "$ns" --arg app "$app" '
      {apiVersion:"v1", kind:"Secret", type:"Opaque",
       metadata:({name:$n, namespace:$ns} + (if $app != "" then {labels:{app:$app}} else {} end)),
       stringData:{TS_AUTHKEY:env.MT_TS_NEW_VALUE}}' \
      | kubectl create -f - >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# mt_ts_ensure_secret <ns> <secret> <tag> [app-label]
# Make sure the Secret holds a reusable key carrying <tag> with more than
# MT_TS_THRESHOLD_DAYS left; mint + write one otherwise (or if it is missing).
# Sets MT_TS_SECRET_CHANGED=true when the Secret was (or, under
# MT_TS_CHECK_ONLY, would be) written, and flags common.sh's change tracker so
# the calling deploy script restarts the Deployment.
# ---------------------------------------------------------------------------
mt_ts_ensure_secret() {
  local ns="$1" secret="$2" tag="$3" app="${4:-}" value reason label
  MT_TS_SECRET_CHANGED=false
  [ -n "$MT_TS_KEYS" ] || mt_ts_keys_fetch || return 1
  label="$ns/$secret"
  local state
  state=$(_ts_exists secret "$secret" "$ns") || return 1
  if [ "$state" = present ]; then
    value=$(mt_ts_secret_read "$ns" "$secret") || { _ts_err "  $label: cannot read the Secret"; return 1; }
    if [ "${MT_TS_FORCE_ROTATE:-0}" = "1" ]; then
      reason="forced rotation"
    elif [ -z "$value" ]; then
      reason="Secret has no TS_AUTHKEY"
    else
      mt_ts_key_verdict "$(mt_ts_match_secret_key "$value")" "$tag"
      reason="$MT_TS_VERDICT"
    fi
    value=""
    if [ -z "$reason" ]; then
      _ts_log "  $label: OK — key id $MT_TS_KEY_ID carries $tag, $MT_TS_KEY_DAYS_LEFT days left"
      return 0
    fi
    _ts_warn "  $label: ROTATE — $reason"
  else
    _ts_log "  $label: missing — bootstrapping a $tag key"
  fi

  MT_TS_SECRET_CHANGED=true
  if [ "${MT_TS_CHECK_ONLY:-0}" = "1" ]; then
    return 0
  fi
  mt_ts_mint "$tag" || return 1
  value="$MT_TS_MINTED_VALUE"; MT_TS_MINTED_VALUE=""
  # Self-check before writing: the matcher must recognise the key it just
  # minted (fresh list, same prefix logic). If it cannot, every future run
  # would report "not found" and rotate again — fail now, revoke the key.
  local seen
  if ! mt_ts_keys_fetch; then value=""; mt_ts_key_revoke "$MT_TS_MINTED_ID"; return 1; fi
  seen=$(mt_ts_match_secret_key "$value" | jq -r '.id // empty')
  if [ "$seen" != "$MT_TS_MINTED_ID" ]; then
    value=""
    _ts_err "  $label: minted key id $MT_TS_MINTED_ID is not recognised by the prefix matcher (matched: '${seen:-none}') — refusing to write it"
    mt_ts_key_revoke "$MT_TS_MINTED_ID"
    return 1
  fi
  if ! mt_ts_secret_write "$ns" "$secret" "$value" "$app"; then
    value=""; _ts_err "  $label: failed to write the new key"; mt_ts_key_revoke "$MT_TS_MINTED_ID"; return 1
  fi
  value=""
  _mt_deploy_changed=true   # common.sh change tracker (harmless when common.sh is not loaded)
  _ts_log "  $label: new $tag key written (expires in ${MT_TS_KEY_LIFETIME_DAYS} days)"
}

# ---------------------------------------------------------------------------
# mt_ts_wait_rollout <ns> <deployment> [timeout] — poll until the Deployment's
# current generation is fully updated and available. Uses get (no watch RBAC).
# ---------------------------------------------------------------------------
mt_ts_wait_rollout() {
  local ns="$1" name="$2" timeout="${3:-$MT_TS_ROLLOUT_TIMEOUT}" start=$SECONDS state
  while :; do
    state=$(kubectl get deployment "$name" -n "$ns" -o json 2>/dev/null | jq -r '
      ((.status.observedGeneration // 0) >= .metadata.generation)
      and ((.status.updatedReplicas // 0) == (.spec.replicas // 1))
      and ((.status.replicas // 0) == (.spec.replicas // 1))
      and ((.status.availableReplicas // 0) == (.spec.replicas // 1))') || state=false
    if [ "$state" = "true" ]; then
      _ts_log "  $ns/$name: rollout complete ($((SECONDS - start))s)"
      return 0
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      _ts_err "  $ns/$name: rollout did not complete within ${timeout}s"
      kubectl get pods -n "$ns" -o wide 2>/dev/null | sed 's/^/      /' || true
      return 1
    fi
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# mt_ts_verify_sidecar <ns> <pod-selector> [timeout]
# Every non-terminating pod matching the selector must log containerboot's
# success line; any failure marker fails immediately with the evidence.
# ---------------------------------------------------------------------------
mt_ts_verify_sidecar() {
  local ns="$1" sel="$2" timeout="${3:-$MT_TS_SIDECAR_TIMEOUT}" start=$SECONDS pods pod logs all_ok count
  while :; do
    pods=$(kubectl get pods -n "$ns" -l "$sel" -o json 2>/dev/null \
      | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name') || pods=""
    if [ -n "$pods" ]; then
      all_ok=true
      for pod in $pods; do
        logs=$(kubectl logs -n "$ns" "$pod" -c "$MT_TS_SIDECAR_CONTAINER" --tail=2000 2>/dev/null) || logs=""
        # grep -c, not -q: -q exits on the first match and printf then dies of
        # SIGPIPE, which `pipefail` reports as a failed pipeline (false negative).
        if printf '%s\n' "$logs" | grep -cE "$MT_TS_FAILURE_RE" >/dev/null; then
          _ts_err "  $ns/$pod: Tailscale sidecar failed to authenticate:"
          printf '%s\n' "$logs" | grep -E "$MT_TS_FAILURE_RE" | tail -3 | sed 's/^/      /'
          return 1
        fi
        printf '%s\n' "$logs" | grep -cE "$MT_TS_SUCCESS_RE" >/dev/null || all_ok=false
      done
      if [ "$all_ok" = true ]; then
        count=$(printf '%s\n' "$pods" | grep -c .)
        _ts_log "  $ns ($sel): Tailscale sidecar authenticated on $count pod(s)"
        return 0
      fi
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      _ts_err "  $ns ($sel): no sidecar reported '$MT_TS_SUCCESS_RE' within ${timeout}s"
      for pod in $pods; do
        echo "    --- $pod ($MT_TS_SIDECAR_CONTAINER, last 20 lines) ---"
        kubectl logs -n "$ns" "$pod" -c "$MT_TS_SIDECAR_CONTAINER" --tail=20 2>&1 | sed 's/^/      /' || true
      done
      return 1
    fi
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# mt_ts_rotate_deployment <ns> <deployment> <pod-selector>
# Restart the Deployment so its pods pick up the new key, then prove the
# sidecar authenticated. Used after mt_ts_ensure_secret changed the Secret.
# ---------------------------------------------------------------------------
mt_ts_rotate_deployment() {
  local ns="$1" name="$2" sel="$3" replicas
  replicas=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
  if [ "${replicas:-1}" = "0" ]; then
    _ts_warn "  $ns/$name is scaled to 0 — key written, nothing to restart or verify"
    return 0
  fi
  _ts_log "  restarting deployment/$name in $ns..."
  kubectl rollout restart "deployment/$name" -n "$ns" >/dev/null || { _ts_err "  $ns/$name: rollout restart failed"; return 1; }
  mt_ts_wait_rollout "$ns" "$name" || return 1
  mt_ts_verify_sidecar "$ns" "$sel" || return 1
}

# ---------------------------------------------------------------------------
# mt_ts_run_components <components.conf> [component-filter]
# One line per component: name|acl_tag|secret|namespace|deployment/<name>|pod-selector
# Components whose namespace or Deployment is absent are skipped (their deploy
# script bootstraps the key). Honors MT_TS_CHECK_ONLY and MT_TS_FORCE_ROTATE.
# Returns 1 when any component errored. Totals in MT_TS_RUN_{ROTATED,NEEDS,ERRORS}.
# ---------------------------------------------------------------------------
mt_ts_run_components() {
  local conf="$1" only="${2:-}" comp tag secret ns deploy sel kind name
  MT_TS_RUN_ROTATED=0; MT_TS_RUN_NEEDS=0; MT_TS_RUN_ERRORS=0
  [ -f "$conf" ] || { _ts_err "components file not found: $conf"; return 1; }
  mt_ts_keys_fetch || return 1
  # Read the config on fd 3 so nothing inside the loop can consume it via stdin.
  while IFS='|' read -r comp tag secret ns deploy sel <&3 || [ -n "$comp" ]; do
    case "$comp" in ''|'#'*) continue ;; esac
    if [ -n "$only" ] && [ "$comp" != "$only" ]; then continue; fi
    _ts_log "--- $comp ($tag) ---"
    if [ -z "$tag" ] || [ -z "$secret" ] || [ -z "$ns" ] || [ -z "$deploy" ] || [ -z "$sel" ]; then
      _ts_err "  malformed components line for '$comp' (expected name|tag|secret|namespace|deployment/<name>|selector)"
      MT_TS_RUN_ERRORS=$((MT_TS_RUN_ERRORS + 1)); continue
    fi
    local state
    if ! state=$(_ts_exists namespace "$ns"); then MT_TS_RUN_ERRORS=$((MT_TS_RUN_ERRORS + 1)); continue; fi
    if [ "$state" = absent ]; then _ts_log "  namespace $ns absent — skipping"; continue; fi
    kind="${deploy%%/*}"; name="${deploy#*/}"
    if [ "$kind" != "deployment" ]; then
      _ts_err "  unsupported workload kind '$kind' for $comp"; MT_TS_RUN_ERRORS=$((MT_TS_RUN_ERRORS + 1)); continue
    fi
    if ! state=$(_ts_exists deployment "$name" "$ns"); then MT_TS_RUN_ERRORS=$((MT_TS_RUN_ERRORS + 1)); continue; fi
    if [ "$state" = absent ]; then _ts_log "  deployment/$name absent in $ns — skipping (its deploy script bootstraps the key)"; continue; fi
    if ! mt_ts_ensure_secret "$ns" "$secret" "$tag"; then
      MT_TS_RUN_ERRORS=$((MT_TS_RUN_ERRORS + 1)); continue
    fi
    [ "$MT_TS_SECRET_CHANGED" = true ] || continue
    if [ "${MT_TS_CHECK_ONLY:-0}" = "1" ]; then
      MT_TS_RUN_NEEDS=$((MT_TS_RUN_NEEDS + 1)); continue
    fi
    if mt_ts_rotate_deployment "$ns" "$name" "$sel"; then
      MT_TS_RUN_ROTATED=$((MT_TS_RUN_ROTATED + 1))
    else
      MT_TS_RUN_ERRORS=$((MT_TS_RUN_ERRORS + 1))
    fi
  done 3< "$conf"

  if [ "${MT_TS_CHECK_ONLY:-0}" = "1" ]; then
    _ts_log "=== Check complete: $MT_TS_RUN_NEEDS Secret(s) need rotation, $MT_TS_RUN_ERRORS error(s) ==="
  else
    _ts_log "=== Rotation complete: $MT_TS_RUN_ROTATED rotated, $MT_TS_RUN_ERRORS error(s) ==="
  fi
  [ "$MT_TS_RUN_ERRORS" -eq 0 ]
}

# ===========================================================================
# Node identity helpers — for sidecars that keep ONE Headscale node across pod
# recreations via a fixed-name state Secret (subnet router, metrics federation).
# Also used for the one-time migration away from per-pod state Secrets and for
# pruning the per-pod ones that pod churn leaves behind.
# ===========================================================================

# ---------------------------------------------------------------------------
# mt_ts_find_online_nodes <name-regex> <tag>
# One line per ONLINE Headscale node whose advertised hostname (.name — the
# sidecar's TS_HOSTNAME, unlike .givenName which Headscale suffixes on a
# collision) matches <name-regex> and whose tags include <tag>:
#     <givenName>\t<ipv4>
# Prints nothing when none match; returns 1 only on an API error.
# ---------------------------------------------------------------------------
mt_ts_find_online_nodes() {
  local re="$1" tag="$2" nodes
  nodes=$(_ts_api GET /api/v1/node) || { _ts_err "Headscale API: cannot list nodes at ${HEADSCALE_URL:-<unset>}"; return 1; }
  printf '%s' "$nodes" | jq -r --arg re "$re" --arg t "$tag" '
    .nodes[]
    | select(.online == true)
    | select((.name // "") | test($re))
    | select(((.tags // []) + (.validTags // []) + (.forcedTags // [])) | any(. == $t))
    | "\(.givenName // .name)\t\([.ipAddresses[]? | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))] | .[0] // "")"'
}

# ---------------------------------------------------------------------------
# mt_ts_resolve_node <name-regex> <tag> [timeout] — exactly ONE online node.
# Prints "<givenName>\t<ipv4>" and returns 0. Zero or several matches are
# retried until the timeout (right after a re-registration Headscale can show
# the superseded node online for a few seconds next to the new one), then
# return 1 with MT_TS_RESOLVE_REASON = none | ambiguous and the candidates in
# MT_TS_RESOLVE_CANDIDATES. An API error returns 1 immediately (reason: api).
# ---------------------------------------------------------------------------
MT_TS_RESOLVE_REASON=""
MT_TS_RESOLVE_CANDIDATES=""
MT_TS_RESOLVE_INTERVAL="${MT_TS_RESOLVE_INTERVAL:-5}"
mt_ts_resolve_node() {
  local re="$1" tag="$2" timeout="${3:-60}" start=$SECONDS found n
  MT_TS_RESOLVE_REASON=""; MT_TS_RESOLVE_CANDIDATES=""
  while :; do
    # On an API error the captured text is the error line (print_error writes
    # to stdout when common.sh is loaded) — hand it back so the caller can show it.
    found=$(mt_ts_find_online_nodes "$re" "$tag") || { MT_TS_RESOLVE_REASON=api; printf '%s\n' "$found"; return 1; }
    n=$(printf '%s\n' "$found" | grep -c . || true)
    if [ "$n" -eq 1 ] && [ -n "$(printf '%s' "$found" | cut -f2)" ]; then
      printf '%s\n' "$found"
      return 0
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      # shellcheck disable=SC2034  # read by the calling deploy script
      MT_TS_RESOLVE_CANDIDATES="$found"
      # shellcheck disable=SC2034
      if [ "$n" -eq 0 ]; then MT_TS_RESOLVE_REASON=none; else MT_TS_RESOLVE_REASON=ambiguous; fi
      return 1
    fi
    sleep "$MT_TS_RESOLVE_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# mt_ts_adopt_pod_state_secret <ns> <prefix> <pod-selector>
# One-time migration from a per-pod state Secret ("<prefix>-tailscale-state-<pod>")
# to the fixed-name one ("<prefix>-tailscale-state") that keeps the sidecar's
# Headscale node — and therefore its mesh IP — across pod recreations. The
# running pod's state is copied only while that pod's tailscaled is Running and
# online, so a dead registration (#613) is never carried over: the alternative
# is a fresh node, which the discovery in the consumer handles. Returns 0 in
# every non-error case; sets MT_TS_STATE_ADOPTED=true and flags common.sh's
# change tracker when it wrote the Secret (the Deployment must restart to load it).
# ---------------------------------------------------------------------------
MT_TS_STATE_ADOPTED=false
MT_TS_ADOPT_EXEC_RETRIES="${MT_TS_ADOPT_EXEC_RETRIES:-3}"
mt_ts_adopt_pod_state_secret() {
  local ns="$1" prefix="$2" sel="$3" fixed="$2-tailscale-state" state pods pod per_pod ready status ip attempt=0
  MT_TS_STATE_ADOPTED=false
  state=$(_ts_exists secret "$fixed" "$ns") || return 1
  if [ "$state" = present ]; then
    _ts_log "  $ns/$fixed: fixed-name state Secret present — node identity is stable"
    return 0
  fi
  # A LOST answer must never read as "no pod": that would register a fresh
  # node (new mesh IP) on the strength of an API hiccup (#623). Only a
  # definite answer from the API server decides; an error fails the deploy.
  # stderr is captured on its own (as _ts_exists does): kubectl prints exit-0
  # notices there (deprecation "Warning:" headers, client/server version
  # skew) that must not turn a valid JSON answer into "not JSON".
  local errf="${TMPDIR:-/tmp}/mt-ts-adopt-$$.err"
  if ! pods=$(kubectl get pods -n "$ns" -l "$sel" -o json 2>"$errf"); then
    _ts_err "  $ns/$fixed: cannot list pods ($sel) — refusing to guess whether a node identity exists: $(tail -1 "$errf" 2>/dev/null)"
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"
  pod=$(printf '%s' "$pods" | jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")] | .[0].metadata.name // empty' 2>/dev/null) \
    || { _ts_err "  $ns/$fixed: pod list for $sel is not JSON — refusing to guess"; return 1; }
  if [ -z "$pod" ]; then
    _ts_log "  $ns/$fixed: absent and no running pod to adopt from — the sidecar will register a fresh node"
    return 0
  fi
  per_pod="${prefix}-tailscale-state-${pod}"
  state=$(_ts_exists secret "$per_pod" "$ns") || return 1
  if [ "$state" = absent ]; then
    _ts_log "  $ns/$fixed: absent; $pod has no per-pod state Secret — the sidecar will register a fresh node"
    return 0
  fi
  # The API server's view of the sidecar container IS a definite answer: a
  # sidecar that is not ready (crash-looping on a dead key, #613) has nothing
  # worth adopting — a fresh registration is the repair, not a failure.
  ready=$(printf '%s' "$pods" | jq -r --arg p "$pod" --arg c "$MT_TS_SIDECAR_CONTAINER" \
    '.items[] | select(.metadata.name == $p) | [.status.initContainerStatuses[]?, .status.containerStatuses[]?] | map(select(.name == $c)) | .[0].ready // false')
  if [ "$ready" != "true" ]; then
    _ts_warn "  $ns/$fixed: not adopting $per_pod — $pod's $MT_TS_SIDECAR_CONTAINER container is not ready; the sidecar will register a fresh node"
    return 0
  fi
  # tailscaled's own view. kubectl exec rides the cluster's konnectivity proxy,
  # so a failure here is a LOST answer: retried, then fatal — never "offline".
  while :; do
    if status=$(kubectl exec -n "$ns" "$pod" -c "$MT_TS_SIDECAR_CONTAINER" -- tailscale status --json 2>"$errf"); then rm -f "$errf"; break; fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$MT_TS_ADOPT_EXEC_RETRIES" ]; then
      _ts_err "  $ns/$fixed: cannot query tailscaled in $pod ($attempt attempts) — refusing to register a fresh node on a lost answer: $(tail -1 "$errf" 2>/dev/null)"
      rm -f "$errf"
      return 1
    fi
    sleep 5
  done
  if ! printf '%s' "$status" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _ts_err "  $ns/$fixed: tailscale status in $pod returned no JSON — refusing to guess: $(printf '%s\n' "$status" | tail -1)"
    return 1
  fi
  if ! printf '%s' "$status" | jq -e '.BackendState == "Running" and (.Self.Online // false)' >/dev/null 2>&1; then
    _ts_warn "  $ns/$fixed: not adopting $per_pod — $pod's tailscaled is $(printf '%s' "$status" | jq -r '.BackendState // "?"') / Online=$(printf '%s' "$status" | jq -r '.Self.Online // false'); the sidecar will register a fresh node"
    return 0
  fi
  ip=$(printf '%s' "$status" | jq -r '.Self.TailscaleIPs[0] // "?"')
  # Copy type + data under the fixed name, dropping server-set metadata. The
  # node key travels kubectl -> jq -> kubectl over pipes, never through argv.
  if kubectl get secret "$per_pod" -n "$ns" -o json \
      | jq --arg n "$fixed" '{apiVersion, kind, type, data, metadata: {name: $n, namespace: .metadata.namespace, labels: (.metadata.labels // {})}}' \
      | kubectl create -f - >/dev/null; then
    _mt_deploy_changed=true   # common.sh change tracker (harmless when common.sh is not loaded)
    # shellcheck disable=SC2034  # read by callers / tests
    MT_TS_STATE_ADOPTED=true
    _ts_log "  $ns/$fixed: adopted the node identity of $pod (mesh IP $ip) from $per_pod"
  else
    _ts_err "  $ns/$fixed: failed to create the fixed-name state Secret from $per_pod"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# mt_ts_prune_pod_state_secrets <ns> <prefix>
# Delete per-pod state Secrets "<prefix>-tailscale-state-<pod>" whose pod no
# longer exists (every recreation of a per-pod-state sidecar leaves one behind;
# each also backs an offline Headscale node the cleanup CronJob removes). The
# fixed-name "<prefix>-tailscale-state" never matches (no "-<pod>" suffix), a
# Secret whose pod still exists — Running or Terminating — is kept, and a
# failed pod lookup keeps the Secret: deleting on a lost answer is the #623 trap.
# ---------------------------------------------------------------------------
mt_ts_prune_pod_state_secrets() {
  local ns="$1" prefix="$2" names name pod state deleted=0 kept=0
  # Names only (-o name): no Secret body ever passes through this pipeline.
  names=$(kubectl get secrets -n "$ns" -o name 2>&1) \
    || { _ts_warn "  $ns: cannot list Secrets — nothing pruned: $(printf '%s\n' "$names" | tail -1)"; return 0; }
  names=$(printf '%s\n' "$names" | grep "^secret/${prefix}-tailscale-state-" | cut -d/ -f2- || true)
  [ -n "$names" ] || return 0
  for name in $names; do
    pod="${name#"${prefix}-tailscale-state-"}"
    # Only pod-shaped suffixes: <deployment>-<replicaset hash>-<5 chars>
    case "$pod" in
      "${prefix}"-*-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;;
      *) kept=$((kept + 1)); continue ;;
    esac
    if ! state=$(_ts_exists pod "$pod" "$ns"); then kept=$((kept + 1)); continue; fi
    if [ "$state" = present ]; then kept=$((kept + 1)); continue; fi
    if kubectl delete secret "$name" -n "$ns" --ignore-not-found >/dev/null 2>&1; then
      _ts_log "  $ns/$name: pruned (pod $pod is gone)"; deleted=$((deleted + 1))
    else
      _ts_warn "  $ns/$name: could not delete"; kept=$((kept + 1))
    fi
  done
  _ts_log "  $ns: per-pod state Secrets of $prefix — $deleted pruned, $kept kept"
}
