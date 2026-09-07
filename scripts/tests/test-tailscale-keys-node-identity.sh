#!/usr/bin/env bash
# Unit tests for the node-identity helpers in scripts/lib/tailscale-keys.sh
# (mt_ts_find_online_nodes, mt_ts_resolve_node, mt_ts_adopt_pod_state_secret,
# mt_ts_prune_pod_state_secrets) against stubbed kubectl / curl / sleep.
# No cluster, no network. Run:  bash scripts/tests/test-tailscale-keys-node-identity.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
STUB_DIR=$(mktemp -d)
export STUB_DIR
trap 'rm -rf "$STUB_DIR"' EXIT
mkdir -p "$STUB_DIR/bin" "$STUB_DIR/fx"

# ---------------------------------------------------------------------------
# Stubs. Every stub logs its argv; fixtures live in $STUB_DIR/fx.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/kubectl.log"
args="$*"
case "$args" in
  "get pods -n "*" -l "*" -o json")            cat "$STUB_DIR/fx/pods.json" ;;
  "get secrets -n "*" -o json")                cat "$STUB_DIR/fx/secrets.json" ;;
  "get secret "*" --ignore-not-found -o name")
    grep -qx -- "$3" "$STUB_DIR/fx/secrets.list" 2>/dev/null && echo "secret/$3"; exit 0 ;;
  "get secret "*" -o json")                     cat "$STUB_DIR/fx/secret-$3.json" ;;
  "get pod "*" --ignore-not-found -o name")
    case "$3" in *boom*) echo "Error from server: etcd timeout"; exit 1 ;; esac
    grep -qx -- "$3" "$STUB_DIR/fx/pods.list" 2>/dev/null && echo "pod/$3"; exit 0 ;;
  "exec -n "*" -- tailscale status --json")    cat "$STUB_DIR/fx/status.json" ;;
  "create -f -")                               cat > "$STUB_DIR/created.json"; echo "secret/stub created" ;;
  "delete secret "*)                            echo "$3" >> "$STUB_DIR/deleted.log"; echo "secret \"$3\" deleted" ;;
  *) echo "stub kubectl: unexpected args: $args" >&2; exit 99 ;;
esac
STUB
cat > "$STUB_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null   # the Authorization header arrives as a --config file on stdin
n=$(( $(cat "$STUB_DIR/curl.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/curl.count"
if [ -n "${STUB_CURL_FAIL:-}" ]; then echo "curl: (22) The requested URL returned error: 500" >&2; exit 22; fi
url="${*: -1}"
case "$url" in
  */api/v1/node) if [ -f "$STUB_DIR/fx/nodes.$n.json" ]; then cat "$STUB_DIR/fx/nodes.$n.json"; else cat "$STUB_DIR/fx/nodes.json"; fi ;;
  *) echo "stub curl: unexpected url: $url" >&2; exit 98 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/bin/sleep"
chmod +x "$STUB_DIR/bin/"*
export PATH="$STUB_DIR/bin:$PATH"

export HEADSCALE_URL="https://headscale.example.com"
export HEADSCALE_API_KEY="stub-api-key"
# shellcheck source=../lib/tailscale-keys.sh
source "$REPO_ROOT/scripts/lib/tailscale-keys.sh"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected: $2"$'\n'"actual:   $3"; fi; }
reset_stubs() {
  rm -f "$STUB_DIR"/kubectl.log "$STUB_DIR"/created.json "$STUB_DIR"/deleted.log "$STUB_DIR"/curl.count "$STUB_DIR"/fx/nodes.*.json
  : > "$STUB_DIR/fx/secrets.list"; : > "$STUB_DIR/fx/pods.list"
  echo '{"items":[]}' > "$STUB_DIR/fx/pods.json"
  echo '{"items":[]}' > "$STUB_DIR/fx/secrets.json"
  _mt_deploy_changed=false
}

# Synthetic fixtures (ids, addresses, suffixes and timestamps are made up; only
# the SHAPE mirrors Headscale: .name is the advertised hostname, .givenName gets
# a random suffix on a collision, .tags carries the ACL tags).
node() { # id name givenName online ip tags-json
  printf '{"id":"%s","name":"%s","givenName":"%s","online":%s,"ipAddresses":["%s","fd7a:115c:a1e0::1"],"tags":%s,"lastSeen":"2026-01-01T00:00:00Z"}' "$@"
}
NODES_MIXED="{\"nodes\":[
  $(node 1 prom-mesh-prod-eu prom-mesh-prod-eu false 100.64.1.10 '["tag:monitoring"]'),
  $(node 2 prom-mesh-prod-eu prom-mesh-prod-eu-abc12 true 100.64.1.11 '["tag:monitoring"]'),
  $(node 3 prom-eu-bridge-prod prom-eu-bridge-prod-def34 true 100.64.1.12 '["tag:monitoring"]'),
  $(node 4 prom-mesh-dev prom-mesh-dev true 100.64.1.13 '["tag:monitoring"]'),
  $(node 5 prom-mesh-prod-eu prom-mesh-prod-eu-ghi56 true 100.64.1.14 '["tag:other"]')
]}"
NODES_TWO="{\"nodes\":[
  $(node 2 prom-mesh-prod-eu prom-mesh-prod-eu-abc12 true 100.64.1.11 '["tag:monitoring"]'),
  $(node 6 prom-mesh-prod-eu prom-mesh-prod-eu-jkl78 true 100.64.1.15 '["tag:monitoring"]')
]}"
NODES_NONE='{"nodes":[]}'

echo "# mt_ts_find_online_nodes"
reset_stubs
printf '%s' "$NODES_MIXED" > "$STUB_DIR/fx/nodes.json"
out=$(mt_ts_find_online_nodes '^prom-mesh-prod-eu$' tag:monitoring)
assert_eq "exact env regex → the one online, tagged node (suffix-renamed givenName, IPv4 only)" \
  "$(printf 'prom-mesh-prod-eu-abc12\t100.64.1.11')" "$out"
out=$(mt_ts_find_online_nodes '^prom-mesh-' tag:monitoring | sort)
assert_eq "prefix regex → every online tagged prom-mesh-* node" \
  "$(printf 'prom-mesh-dev\t100.64.1.13\nprom-mesh-prod-eu-abc12\t100.64.1.11')" "$out"
out=$(mt_ts_find_online_nodes '^prom-eu-bridge-prod$' tag:monitoring)
assert_eq "consumer's own node is findable by its advertised name" "$(printf 'prom-eu-bridge-prod-def34\t100.64.1.12')" "$out"
if STUB_CURL_FAIL=1 mt_ts_find_online_nodes '^prom-mesh-' tag:monitoring >/dev/null 2>&1; then
  fail "API error → returns 1"; else ok "API error → returns 1"; fi

echo "# mt_ts_resolve_node"
reset_stubs
printf '%s' "$NODES_MIXED" > "$STUB_DIR/fx/nodes.json"
out=$(mt_ts_resolve_node '^prom-mesh-prod-eu$' tag:monitoring 0)
assert_eq "single match → printed" "$(printf 'prom-mesh-prod-eu-abc12\t100.64.1.11')" "$out"
reset_stubs
printf '%s' "$NODES_TWO" > "$STUB_DIR/fx/nodes.json"
if mt_ts_resolve_node '^prom-mesh-prod-eu$' tag:monitoring 0 >/dev/null; then fail "two online → returns 1"; else ok "two online → returns 1"; fi
assert_eq "two online → reason ambiguous" ambiguous "$MT_TS_RESOLVE_REASON"
assert_eq "two online → both candidates reported" 2 "$(printf '%s\n' "$MT_TS_RESOLVE_CANDIDATES" | grep -c .)"
reset_stubs
printf '%s' "$NODES_NONE" > "$STUB_DIR/fx/nodes.json"
if mt_ts_resolve_node '^prom-mesh-prod-eu$' tag:monitoring 0 >/dev/null; then fail "none online → returns 1"; else ok "none online → returns 1"; fi
assert_eq "none online → reason none" none "$MT_TS_RESOLVE_REASON"
reset_stubs
printf '%s' "$NODES_TWO" > "$STUB_DIR/fx/nodes.1.json"     # superseded node still shows online...
printf '%s' "$NODES_MIXED" > "$STUB_DIR/fx/nodes.2.json"   # ...and drops off on the next poll
out=$(mt_ts_resolve_node '^prom-mesh-prod-eu$' tag:monitoring 30)
assert_eq "transient ambiguity is retried until a single node remains" "$(printf 'prom-mesh-prod-eu-abc12\t100.64.1.11')" "$out"
assert_eq "  (took exactly two API calls)" 2 "$(cat "$STUB_DIR/curl.count")"
reset_stubs
if STUB_CURL_FAIL=1 mt_ts_resolve_node '^prom-mesh-' tag:monitoring 30 >/dev/null 2>&1; then fail "API error → returns 1 immediately"; else ok "API error → returns 1 immediately"; fi
assert_eq "API error → reason api" api "$MT_TS_RESOLVE_REASON"

echo "# mt_ts_adopt_pod_state_secret"
NS=infra-monitoring; PFX=prometheus-mesh-expose; POD="$PFX-5d9f8c7b6-abcde"
PODS_RUNNING="{\"items\":[{\"metadata\":{\"name\":\"$POD\"},\"status\":{\"phase\":\"Running\"}}]}"
STATE_JSON="{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"type\":\"Opaque\",\"metadata\":{\"name\":\"$PFX-tailscale-state-$POD\",\"namespace\":\"$NS\",\"uid\":\"u\",\"resourceVersion\":\"123\",\"creationTimestamp\":\"2026-01-01T00:00:00Z\",\"managedFields\":[{\"manager\":\"x\"}]},\"data\":{\"_current-profile\":\"cHJvZmlsZS0x\",\"profile-1\":\"c3RhdGU=\",\"_machinekey\":\"bWs=\"}}"
reset_stubs
echo "$PFX-tailscale-state" > "$STUB_DIR/fx/secrets.list"
mt_ts_adopt_pod_state_secret "$NS" "$PFX" "app=$PFX" >/dev/null
assert_eq "fixed Secret present → no create, not adopted" "false|absent" "$MT_TS_STATE_ADOPTED|$([ -f "$STUB_DIR/created.json" ] && echo created || echo absent)"
reset_stubs
mt_ts_adopt_pod_state_secret "$NS" "$PFX" "app=$PFX" >/dev/null
assert_eq "no running pod → no create" "absent" "$([ -f "$STUB_DIR/created.json" ] && echo created || echo absent)"
reset_stubs
printf '%s' "$PODS_RUNNING" > "$STUB_DIR/fx/pods.json"
mt_ts_adopt_pod_state_secret "$NS" "$PFX" "app=$PFX" >/dev/null
assert_eq "running pod without a per-pod Secret → no create" "absent" "$([ -f "$STUB_DIR/created.json" ] && echo created || echo absent)"
reset_stubs
printf '%s' "$PODS_RUNNING" > "$STUB_DIR/fx/pods.json"
echo "$PFX-tailscale-state-$POD" > "$STUB_DIR/fx/secrets.list"
printf '%s' "$STATE_JSON" > "$STUB_DIR/fx/secret-$PFX-tailscale-state-$POD.json"
echo '{"BackendState":"Running","Self":{"Online":false,"TailscaleIPs":["100.64.1.11"]}}' > "$STUB_DIR/fx/status.json"
mt_ts_adopt_pod_state_secret "$NS" "$PFX" "app=$PFX" >/dev/null
assert_eq "sidecar Running but offline → not adopted (fresh registration instead)" "false|absent" "$MT_TS_STATE_ADOPTED|$([ -f "$STUB_DIR/created.json" ] && echo created || echo absent)"
echo '{"BackendState":"NeedsLogin","Self":{"Online":false}}' > "$STUB_DIR/fx/status.json"
mt_ts_adopt_pod_state_secret "$NS" "$PFX" "app=$PFX" >/dev/null
assert_eq "sidecar NeedsLogin → not adopted" "false" "$MT_TS_STATE_ADOPTED"
echo '{"BackendState":"Running","Self":{"Online":true,"TailscaleIPs":["100.64.1.11"]}}' > "$STUB_DIR/fx/status.json"
# Not in a $(...): the function's globals must reach this shell.
mt_ts_adopt_pod_state_secret "$NS" "$PFX" "app=$PFX" > "$STUB_DIR/adopt.out"
out=$(cat "$STUB_DIR/adopt.out")
assert_eq "live sidecar → adopted + change tracker flagged" "true|true" "$MT_TS_STATE_ADOPTED|$_mt_deploy_changed"
assert_eq "  created Secret carries the fixed name in the same namespace" "$PFX-tailscale-state $NS" \
  "$(jq -r '"\(.metadata.name) \(.metadata.namespace)"' "$STUB_DIR/created.json")"
assert_eq "  created Secret carries the state data verbatim" \
  "$(printf '%s' "$STATE_JSON" | jq -cS '.data')" "$(jq -cS '.data' "$STUB_DIR/created.json")"
assert_eq "  server-set metadata is dropped" "null null null null" \
  "$(jq -r '"\(.metadata.uid) \(.metadata.resourceVersion) \(.metadata.creationTimestamp) \(.metadata.managedFields)"' "$STUB_DIR/created.json")"
assert_eq "  log names the pod and its mesh IP" 1 "$(printf '%s\n' "$out" | grep -c "adopted the node identity of $POD (mesh IP 100.64.1.11)")"
assert_eq "  the node key never appears on a kubectl command line" 0 "$(grep -c 'c3RhdGU=' "$STUB_DIR/kubectl.log" || true)"

echo "# mt_ts_prune_pod_state_secrets"
reset_stubs
KEEP="$PFX-5d9f8c7b6-abcde"; GONE="$PFX-5d9f8c7b6-fghij"; BOOM="$PFX-5d9f8c7b6-boom1"
jq -cn --arg p "$PFX" --arg keep "$KEEP" --arg gone "$GONE" --arg boom "$BOOM" '{items: [
  {metadata:{name: ($p + "-tailscale-state")}},
  {metadata:{name: ($p + "-tailscale-state-" + $keep)}},
  {metadata:{name: ($p + "-tailscale-state-" + $gone)}},
  {metadata:{name: ($p + "-tailscale-state-" + $boom)}},
  {metadata:{name: ($p + "-tailscale-state-manual-copy")}},
  {metadata:{name: ($p + "-tailscale-auth")}},
  {metadata:{name: "pg-metrics-bridge-tailscale-state-pg-metrics-bridge-1234567890-zzzzz"}}
]}' > "$STUB_DIR/fx/secrets.json"
echo "$KEEP" > "$STUB_DIR/fx/pods.list"
out=$(mt_ts_prune_pod_state_secrets "$NS" "$PFX")
assert_eq "only the per-pod Secret of the vanished pod is deleted" "$PFX-tailscale-state-$GONE" "$(cat "$STUB_DIR/deleted.log" 2>/dev/null)"
assert_eq "  summary counts: 1 pruned, 3 kept (live pod, lookup error, non-pod suffix)" 1 "$(printf '%s\n' "$out" | grep -c -- '1 pruned, 3 kept')"
reset_stubs
mt_ts_prune_pod_state_secrets "$NS" "$PFX" >/dev/null
assert_eq "nothing matching → nothing deleted" "absent" "$([ -f "$STUB_DIR/deleted.log" ] && echo deleted || echo absent)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
