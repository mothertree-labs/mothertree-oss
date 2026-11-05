#!/usr/bin/env bash
# Unit tests for the helpers that let a second dev-class environment (devhome:
# single-node k3s behind a periscope) share the scripts with the Linode envs:
#
#   mt_is_dev_class / mt_is_prod_like   (scripts/lib/common.sh)
#   mt_load_cluster_platform / mt_ingress_public_ip   (scripts/lib/platform.sh)
#   ci_pool_slots / ci_fetch_dev_kubeconfig file override   (ci/scripts/ci-lib.sh)
#   the .woodpecker env-name parameterisation
#
#   scripts/tests/devhome-env.test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLATFORM_SH="$REPO_ROOT/scripts/lib/platform.sh"   # the code under test, before REPO_ROOT is faked
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }
check() { local desc="$1"; shift; if "$@"; then ok; else fail "$desc"; fi; }
check_not() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok; fi; }

# ── mt_is_dev_class / mt_is_prod_like ─────────────────────────────────────
(
  # shellcheck source=../lib/common.sh
  source "$REPO_ROOT/scripts/lib/common.sh"
  for e in dev devhome dev2; do
    MT_ENV="$e"; mt_is_dev_class || { echo "FAIL: $e should be dev-class" >&2; exit 1; }
    mt_is_prod_like && { echo "FAIL: $e should not be prod-like" >&2; exit 1; }
  done
  # prod-like: prod, prod-eu, an unset env (the safe direction), and names that
  # merely contain "dev" somewhere other than as the prefix.
  for e in prod prod-eu "" staging mydev dev-eu DEV devx-prod devhome-eu; do
    MT_ENV="$e"; mt_is_dev_class && { echo "FAIL: '$e' should not be dev-class" >&2; exit 1; }
    mt_is_prod_like || { echo "FAIL: '$e' should be prod-like" >&2; exit 1; }
  done
  unset MT_ENV
  mt_is_prod_like || { echo "FAIL: unset MT_ENV should be prod-like" >&2; exit 1; }
) && ok || fail "env class helpers"

# ── platform.sh ───────────────────────────────────────────────────────────
mkdir -p "$TEST_TMP/repo/config/platform/infra" "$TEST_TMP/repo/scripts/lib"
cp "$REPO_ROOT/scripts/lib/paths.sh" "$TEST_TMP/repo/scripts/lib/"
cfg="$TEST_TMP/repo/config/platform/infra"

platform_of() {  # <env> -> prints "<platform> <public_ip>" or fails
  ( REPO_ROOT="$TEST_TMP/repo" MT_ENV="$1"
    unset MT_CLUSTER_PLATFORM MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED _MT_PLATFORM_ENV
    # shellcheck source=../lib/platform.sh
    source "$PLATFORM_SH"
    mt_load_cluster_platform
    echo "$MT_CLUSTER_PLATFORM ${MT_PUBLIC_INGRESS_IP:-}" ) 2>/dev/null
}

printf 'keycloak:\n  replicas: 1\n' > "$cfg/plain.config.yaml"
check "no cluster block defaults to lke" test "$(platform_of plain)" = "lke "
check "missing infra config defaults to lke" test "$(platform_of nonexistent)" = "lke "

printf 'cluster:\n  platform: k3s\n  public_ip: "203.0.113.7"\n' > "$cfg/box.config.yaml"
check "k3s with public_ip" test "$(platform_of box)" = "k3s 203.0.113.7"

printf 'cluster:\n  platform: k3s\n' > "$cfg/nopub.config.yaml"
check_not "k3s without public_ip must fail" platform_of nopub

printf 'cluster:\n  platform: k3s\n  public_ip: "lb.example.com"\n' > "$cfg/host.config.yaml"
check_not "k3s with a hostname public_ip must fail" platform_of host

printf 'cluster:\n  platform: eks\n' > "$cfg/eks.config.yaml"
check_not "unknown platform must fail" platform_of eks

# mt_ingress_public_ip: k3s never asks kubectl; lke reads the Service status.
mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "kubectl $*" >> "$KUBECTL_LOG"
printf '%s' "${FAKE_LB_IP:-}"
EOS
chmod +x "$TEST_TMP/bin/kubectl"
export KUBECTL_LOG="$TEST_TMP/kubectl.log"

ingress_ip_of() {
  ( PATH="$TEST_TMP/bin:$PATH" REPO_ROOT="$TEST_TMP/repo" MT_ENV="$1"
    export FAKE_LB_IP="${2:-}"
    unset MT_CLUSTER_PLATFORM MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED _MT_PLATFORM_ENV
    source "$PLATFORM_SH"
    mt_ingress_public_ip ) 2>/dev/null
}
: > "$KUBECTL_LOG"
check "k3s ingress IP is cluster.public_ip" test "$(ingress_ip_of box 10.9.9.9)" = "203.0.113.7"
check "k3s ingress IP never reads the Service" test ! -s "$KUBECTL_LOG"
check "lke ingress IP is the Service LB IP" test "$(ingress_ip_of plain 198.51.100.4)" = "198.51.100.4"
check_not "lke without an LB IP returns non-zero" ingress_ip_of plain ""

suffix_of() {
  ( REPO_ROOT="$TEST_TMP/repo" MT_ENV="$1"
    unset MT_CLUSTER_PLATFORM MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED _MT_PLATFORM_ENV
    source "$PLATFORM_SH"
    mt_coredns_custom_suffix ) 2>/dev/null
}
check "CoreDNS custom key suffix on LKE is include" test "$(suffix_of plain)" = "include"
check "CoreDNS custom key suffix on k3s is override" test "$(suffix_of box)" = "override"

# ── ci-lib.sh ─────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/redis-cli"
chmod +x "$TEST_TMP/bin/redis-cli"
(
  export PATH="$TEST_TMP/bin:$PATH"
  # shellcheck source=../../ci/scripts/ci-lib.sh
  source "$REPO_ROOT/ci/scripts/ci-lib.sh"
  unset CI_POOL_SLOTS
  [ "$(ci_pool_slots | tr '\n' ' ')" = "pool1 pool2 " ] || { echo "FAIL: default pools" >&2; exit 1; }
  [ "$(CI_POOL_SLOTS=pool1 ci_pool_slots)" = "pool1" ] || { echo "FAIL: single pool" >&2; exit 1; }
  # A bad entry fails the whole list and prints NOTHING (callers use
  # process substitution, so partial output would silently truncate the list).
  out=$(CI_POOL_SLOTS="pool1 evil" ci_pool_slots 2>/dev/null) && { echo "FAIL: bad slot accepted" >&2; exit 1; }
  [ -z "$out" ] || { echo "FAIL: bad list printed '$out'" >&2; exit 1; }
  CI_POOL_SLOTS="  " ci_pool_slots >/dev/null 2>&1 && { echo "FAIL: empty list accepted" >&2; exit 1; }

  # Kubeconfig file override: copied, no Linode token needed, no API call.
  unset LINODE_CLI_TOKEN
  printf 'apiVersion: v1\nkind: Config\n' > "$TEST_TMP/kc-src"
  MT_CI_DEV_KUBECONFIG_FILE="$TEST_TMP/kc-src" ci_fetch_dev_kubeconfig "$TEST_TMP/kc-out" \
    || { echo "FAIL: file override returned non-zero" >&2; exit 1; }
  cmp -s "$TEST_TMP/kc-src" "$TEST_TMP/kc-out" || { echo "FAIL: kubeconfig not copied" >&2; exit 1; }
  # Set but missing: an error, never a fall-through to the Linode API.
  MT_CI_DEV_KUBECONFIG_FILE="$TEST_TMP/missing" ci_fetch_dev_kubeconfig "$TEST_TMP/kc-out2" 2>/dev/null \
    && { echo "FAIL: missing override file accepted" >&2; exit 1; }
  exit 0
) && ok || fail "ci-lib pool slots / kubeconfig override"

# ── .woodpecker: no hard-coded dev env in deploy commands ──────────────────
# Every dev deploy command takes the env from MT_CI_DEV_ENV (default dev) so a
# devhome CI host can run the same pipeline files. `$$` defers expansion from
# Woodpecker's YAML substitution to the step's shell.
bad=$(grep -nE 'ci/scripts/ci-deploy(-app)?\.sh dev( |$)' "$REPO_ROOT"/.woodpecker/*.yaml || true)
check "no .woodpecker deploy command hard-codes env=dev${bad:+: $bad}" test -z "$bad"
param=$(grep -cE 'ci/scripts/ci-deploy(-app)?\.sh "\$\$\{MT_CI_DEV_ENV:-dev\}"' "$REPO_ROOT"/.woodpecker/*.yaml | awk -F: '{s+=$2} END {print s}')
check ".woodpecker dev deploys use MT_CI_DEV_ENV (found $param)" test "$param" -ge 15

# ── helmfile: devhome env + Linode-only releases gated ────────────────────
hf="$REPO_ROOT/apps/helmfile.yaml.gotmpl"
check "helmfile declares the devhome environment" grep -qE '^  devhome: \{\}' "$hf"
gated=$(grep -c 'installed: {{ ne (env "MT_CLUSTER_PLATFORM" | default "lke") "k3s" }}' "$hf")
check "both cloud-firewall releases are skipped on k3s (found $gated)" test "$gated" -eq 2
check "environments/devhome resolves to the dev values" test -f "$REPO_ROOT/apps/environments/devhome/ingress-nginx.yaml.gotmpl"

echo "devhome-env: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
