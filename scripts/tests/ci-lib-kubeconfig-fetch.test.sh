#!/usr/bin/env bash
# Unit tests for ci_fetch_dev_kubeconfig (ci/scripts/ci-lib.sh).
#
# Stubs `curl` and `sleep` with shell functions so every Linode API response
# is scripted and no time passes. Run directly or via the validate pipeline:
#
#   scripts/tests/ci-lib-kubeconfig-fetch.test.sh
#
# Scenario file format (one line per curl call the function will make):
#   <status>|<body>|<retry-after>      e.g.  503|{"errors":[{"reason":"x"}]}|
#   000 = transport failure (curl exits 7 and writes to stderr)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# ci-lib.sh resolves a Valkey CLI at source time; provide a no-op one so the
# suite runs on machines without redis-cli/valkey-cli.
mkdir -p "$TEST_TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/redis-cli"
chmod +x "$TEST_TMP/bin/redis-cli"
export PATH="$TEST_TMP/bin:$PATH"

# shellcheck source=../../ci/scripts/ci-lib.sh
source "$REPO_ROOT/ci/scripts/ci-lib.sh"

# A token that must NEVER appear in any output the function produces.
export LINODE_CLI_TOKEN="tok-SECRET-do-not-print-4d2f"
export CLUSTER_LABEL="matrix-cluster-dev"
export CI_LINODE_API="https://linode.invalid/v4"

SCENARIO="$TEST_TMP/scenario"
CALLS="$TEST_TMP/calls"
SLEEPS="$TEST_TMP/sleeps"
URLS="$TEST_TMP/urls"

# ── stubs ─────────────────────────────────────────────────────────────────
# curl stub: consumes the next scenario line, writes body/headers to the
# paths given via -o / -D, prints the status like -w '%{http_code}'.
curl() {
  local out="" hdr="" url="" a
  local -a args=("$@")
  local i=0
  while [ $i -lt ${#args[@]} ]; do
    a="${args[$i]}"
    case "$a" in
      -o) i=$((i + 1)); out="${args[$i]}" ;;
      -D) i=$((i + 1)); hdr="${args[$i]}" ;;
      -H|-w|--connect-timeout|--max-time) i=$((i + 1)) ;;
      http*) url="$a" ;;
    esac
    i=$((i + 1))
  done
  local n
  n=$(cat "$CALLS" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$CALLS"
  echo "$url" >> "$URLS"
  local line
  line=$(sed -n "${n}p" "$SCENARIO")
  [ -n "$line" ] || { echo "curl stub: scenario exhausted at call $n" >&2; return 99; }
  local status body ra
  status="${line%%|*}"
  body="${line#*|}"
  ra="${body##*|}"
  body="${body%|*}"
  printf '%s' "$body" > "$out"
  if [ "$status" = "000" ]; then
    : > "$hdr"
    echo "curl: (7) Failed to connect to linode.invalid port 443: Connection refused" >&2
    printf '000'
    return 7
  fi
  {
    printf 'HTTP/2 %s\r\n' "$status"
    [ -n "$ra" ] && printf 'Retry-After: %s\r\n' "$ra"
    printf '\r\n'
  } > "$hdr"
  printf '%s' "$status"
  return 0
}

sleep() {
  echo "$1" >> "$SLEEPS"
}

# ── harness ───────────────────────────────────────────────────────────────
PASS=0
FAIL=0
KCFG_B64=$(printf 'apiVersion: v1\nkind: Config\n' | base64 | tr -d '\n')
LIST_OK='{"data":[{"id":651432,"label":"matrix-cluster-dev"},{"id":1,"label":"matrix-cluster-prod"}]}'
KCFG_OK="{\"kubeconfig\":\"$KCFG_B64\"}"
NOT_YET='{"errors":[{"field":"","reason":"Cluster kubeconfig is not yet available. Please try again later."}]}'

# run_case <name> <expected_rc> <expected_sleeps> <stderr_must_contain> <scenario lines...>
run_case() {
  local name="$1" want_rc="$2" want_sleeps="$3" want_err="$4"
  shift 4
  printf '%s\n' "$@" > "$SCENARIO"
  : > "$CALLS"; : > "$SLEEPS"; : > "$URLS"
  local target="$TEST_TMP/kubeconfig.$RANDOM"
  local err="$TEST_TMP/stderr"
  local rc=0
  ci_fetch_dev_kubeconfig "$target" 2>"$err" || rc=$?
  local got_sleeps
  got_sleeps=$(tr '\n' ' ' <"$SLEEPS" | sed 's/ $//')
  local ok=1
  [ "$rc" = "$want_rc" ] || { echo "  rc: want $want_rc got $rc"; ok=0; }
  [ "$got_sleeps" = "$want_sleeps" ] || { echo "  sleeps: want '$want_sleeps' got '$got_sleeps'"; ok=0; }
  if [ -n "$want_err" ] && ! grep -q -- "$want_err" "$err"; then
    echo "  stderr lacks '$want_err':"; sed 's/^/    /' "$err"; ok=0
  fi
  if grep -q "$LINODE_CLI_TOKEN" "$err" "$URLS"; then
    echo "  TOKEN LEAKED into stderr/urls"; ok=0
  fi
  if [ "$want_rc" = 0 ]; then
    if [ "$(cat "$target")" != "$(printf 'apiVersion: v1\nkind: Config\n')" ]; then
      echo "  target content wrong"; ok=0
    fi
    local mode
    mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")
    [ "$mode" = "600" ] || { echo "  target mode: want 600 got $mode"; ok=0; }
  else
    [ ! -s "$target" ] || { echo "  target written on failure"; ok=0; }
  fi
  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name"
  fi
}

# Defaults from ci-lib.sh unless a case overrides: backoff 10 → 20 → 40 → 60, budget 300s.
export CI_KCFG_FETCH_BACKOFF=10 CI_KCFG_FETCH_MAX_WAIT=300 CI_KCFG_FETCH_MAX_BACKOFF=60 CI_KCFG_FETCH_MAX_ATTEMPTS=40

run_case "happy path: list 200 → kubeconfig 200, no sleeps" 0 "" "" \
  "200|$LIST_OK|" "200|$KCFG_OK|"

run_case "kubeconfig 503 'not yet available' ×2 then 200 (pipeline #2090 shape)" 0 "10 20" "not yet available" \
  "200|$LIST_OK|" "503|$NOT_YET|" "503|$NOT_YET|" "200|$KCFG_OK|"

run_case "429 on list honours Retry-After: 7" 0 "7" "HTTP 429" \
  "429|{\"errors\":[{\"reason\":\"Too Many Requests\"}]}|7" "200|$LIST_OK|" "200|$KCFG_OK|"

run_case "429 without Retry-After uses back-off" 0 "10" "" \
  "429|rate limited|" "200|$LIST_OK|" "200|$KCFG_OK|"

run_case "Retry-After above the cap is clamped to 60" 0 "60" "" \
  "429||600" "200|$LIST_OK|" "200|$KCFG_OK|"

run_case "curl transport failure ×2 then success" 0 "10 20" "Connection refused" \
  "000||" "000||" "200|$LIST_OK|" "200|$KCFG_OK|"

run_case "401 is not retried" 1 "" "not retryable" \
  "401|{\"errors\":[{\"reason\":\"Invalid Token\"}]}|"

run_case "404 on kubeconfig (cluster vanished) is not retried" 1 "" "HTTP 404" \
  "200|$LIST_OK|" "404|{\"errors\":[{\"reason\":\"Not found\"}]}|"

run_case "no cluster with the label → rc 2, no retry" 2 "" "no LKE cluster labelled" \
  '200|{"data":[{"id":1,"label":"matrix-cluster-prod"}]}|'

run_case "200 with empty kubeconfig is retried" 0 "10" "no kubeconfig in the response" \
  "200|$LIST_OK|" '200|{"kubeconfig":""}|' "200|$KCFG_OK|"

CI_KCFG_FETCH_MAX_WAIT=25 \
run_case "persistent 503 gives up when the budget is exhausted (10 + 20 > 25)" 1 "10" "gave up after 2 attempt" \
  "200|$LIST_OK|" "503|$NOT_YET|" "503|$NOT_YET|" "503|$NOT_YET|"

CI_KCFG_FETCH_MAX_ATTEMPTS=3 \
run_case "attempt cap stops a Retry-After: 0 spin" 1 "0 0" "gave up after 3 attempt" \
  "429||0" "429||0" "429||0" "429||0"

echo
echo "ci_fetch_dev_kubeconfig: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
