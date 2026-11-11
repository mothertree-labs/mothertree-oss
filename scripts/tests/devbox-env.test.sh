#!/usr/bin/env bash
# Unit tests for the helpers that let a developer box (devbox: k3d on a laptop,
# cluster.edge: local) share the deploy scripts with the public environments:
#
#   cluster.edge / mt_is_local_edge / mt_ingress_public_ip   (scripts/lib/platform.sh)
#   plain-clone detection + MT_*_DIR overrides               (scripts/lib/paths.sh)
#   PgBouncer Deployment render with/without the mesh        (apps/deploy-pgbouncer.sh)
#   shared PostgreSQL bootstrap SQL                          (scripts/lib/pg-bootstrap-sql.sh)
#
#   scripts/tests/devbox-env.test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLATFORM_SH="$REPO_ROOT/scripts/lib/platform.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }
check() { local desc="$1"; shift; if "$@"; then ok; else fail "$desc"; fi; }
check_not() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok; fi; }

# ── platform.sh: cluster.edge ─────────────────────────────────────────────
mkdir -p "$TEST_TMP/repo/config/platform/infra" "$TEST_TMP/repo/scripts/lib"
touch "$TEST_TMP/repo/config/platform/README.md"
cp "$REPO_ROOT/scripts/lib/paths.sh" "$TEST_TMP/repo/scripts/lib/"
cfg="$TEST_TMP/repo/config/platform/infra"

edge_of() {  # <env> -> prints "<platform> <edge> <public_ip>" or fails
  ( REPO_ROOT="$TEST_TMP/repo" MT_ENV="$1"
    unset MT_CLUSTER_PLATFORM MT_CLUSTER_EDGE MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED _MT_PLATFORM_ENV
    # shellcheck source=../lib/platform.sh
    source "$PLATFORM_SH"
    mt_load_cluster_platform
    echo "$MT_CLUSTER_PLATFORM $MT_CLUSTER_EDGE ${MT_PUBLIC_INGRESS_IP:-}" ) 2>/dev/null
}

printf 'keycloak:\n  replicas: 1\n' > "$cfg/plain.config.yaml"
check "no cluster block: lke, public edge" test "$(edge_of plain)" = "lke public "
check "missing infra config: lke, public edge" test "$(edge_of nonexistent)" = "lke public "

printf 'cluster:\n  platform: lke\n  edge: public\n' > "$cfg/lkepub.config.yaml"
check "explicit lke + public" test "$(edge_of lkepub)" = "lke public "

printf 'cluster:\n  platform: lke\n  edge: local\n' > "$cfg/lkelocal.config.yaml"
check_not "lke + edge local must fail" edge_of lkelocal

printf 'cluster:\n  platform: k3s\n  public_ip: "203.0.113.7"\n' > "$cfg/box.config.yaml"
check "k3s default edge is public (devhome unchanged)" test "$(edge_of box)" = "k3s public 203.0.113.7"

printf 'cluster:\n  platform: k3s\n  edge: public\n' > "$cfg/k3spubnoip.config.yaml"
check_not "k3s + public edge still requires public_ip" edge_of k3spubnoip

printf 'cluster:\n  platform: k3s\n  edge: local\n' > "$cfg/devbox.config.yaml"
check "k3s + local: ingress IP is loopback" test "$(edge_of devbox)" = "k3s local 127.0.0.1"

printf 'cluster:\n  platform: k3s\n  edge: local\n  public_ip: "203.0.113.7"\n' > "$cfg/confused.config.yaml"
check_not "k3s + local + public_ip must fail" edge_of confused

printf 'cluster:\n  platform: k3s\n  edge: lan\n  public_ip: "203.0.113.7"\n' > "$cfg/badedge.config.yaml"
check_not "unknown edge must fail" edge_of badedge

is_local_of() {
  ( REPO_ROOT="$TEST_TMP/repo" MT_ENV="$1"
    unset MT_CLUSTER_PLATFORM MT_CLUSTER_EDGE MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED _MT_PLATFORM_ENV
    source "$PLATFORM_SH"
    mt_is_local_edge ) 2>/dev/null
}
check "mt_is_local_edge true on devbox" is_local_of devbox
check_not "mt_is_local_edge false on k3s public" is_local_of box
check_not "mt_is_local_edge false on lke" is_local_of plain

# The load cache must not hand one env's edge to another env in the same shell
# (MT_INFRA_CONFIG is the resolved path for one env, so a switch clears it).
cache_switch() {
  ( REPO_ROOT="$TEST_TMP/repo"
    unset MT_CLUSTER_PLATFORM MT_CLUSTER_EDGE MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED _MT_PLATFORM_ENV
    source "$PLATFORM_SH"
    MT_ENV=devbox; mt_load_cluster_platform; a="$MT_CLUSTER_EDGE"
    MT_ENV=box; unset MT_INFRA_CONFIG; mt_load_cluster_platform; b="$MT_CLUSTER_EDGE"
    echo "$a $b" ) 2>/dev/null
}
check "platform cache re-reads edge per env" test "$(cache_switch)" = "local public"

# A stale MT_CLUSTER_PLATFORM from an older caller (no edge) must not short-circuit.
stale_platform() {
  ( REPO_ROOT="$TEST_TMP/repo" MT_ENV=devbox
    unset MT_CLUSTER_EDGE MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED
    export MT_CLUSTER_PLATFORM=k3s _MT_PLATFORM_ENV=devbox
    source "$PLATFORM_SH"
    mt_load_cluster_platform
    echo "$MT_CLUSTER_EDGE ${MT_PUBLIC_INGRESS_IP:-}" ) 2>/dev/null
}
check "platform without edge is reloaded" test "$(stale_platform)" = "local 127.0.0.1"

# mt_ingress_public_ip on a local edge never asks kubectl.
mkdir -p "$TEST_TMP/bin"
printf '#!/usr/bin/env bash\necho "kubectl $*" >> "$KUBECTL_LOG"\n' > "$TEST_TMP/bin/kubectl"
chmod +x "$TEST_TMP/bin/kubectl"
export KUBECTL_LOG="$TEST_TMP/kubectl.log"; : > "$KUBECTL_LOG"
ip_local=$( PATH="$TEST_TMP/bin:$PATH" REPO_ROOT="$TEST_TMP/repo" MT_ENV=devbox
  unset MT_CLUSTER_PLATFORM MT_CLUSTER_EDGE MT_PUBLIC_INGRESS_IP MT_INFRA_CONFIG _MT_PLATFORM_LOADED _MT_PLATFORM_ENV
  source "$PLATFORM_SH"; mt_ingress_public_ip 2>/dev/null )
check "local-edge ingress IP is 127.0.0.1" test "$ip_local" = "127.0.0.1"
check "local-edge ingress IP never reads the Service" test ! -s "$KUBECTL_LOG"

# ── paths.sh: plain clone + overrides ────────────────────────────────────
PATHS_SH="$REPO_ROOT/scripts/lib/paths.sh"
resolve() {  # <repo> <fn> [arg] -> prints the resolved var, or fails
  ( REPO_ROOT="$1"
    unset MT_TENANTS_DIR MT_PROJECT_CONF MT_INFRA_CONFIG _MT_PATHS_LOADED
    [ -n "${O_TENANTS:-}" ] && export MT_TENANTS_DIR="$O_TENANTS"
    [ -n "${O_PROJECT:-}" ] && export MT_PROJECT_CONF="$O_PROJECT"
    [ -n "${O_INFRA:-}" ]   && export MT_INFRA_CONFIG_DIR="$O_INFRA"
    # shellcheck source=../lib/paths.sh
    source "$PATHS_SH"
    case "$2" in
      tenants) _mt_resolve_tenants_dir; echo "$MT_TENANTS_DIR" ;;
      project) _mt_resolve_project_conf; echo "$MT_PROJECT_CONF" ;;
      infra)   _mt_resolve_infra_config "$3"; echo "$MT_INFRA_CONFIG" ;;
    esac ) 2>/dev/null
}

# Plain clone: empty submodule dirs + a flat tenants/ (the .example template).
pc="$TEST_TMP/plain"; mkdir -p "$pc/config/tenants" "$pc/config/platform" "$pc/tenants/.example"
check "plain clone: empty config/tenants falls through to tenants/" test "$(resolve "$pc" tenants)" = "$pc/tenants"
check "plain clone: no project.conf -> empty" test "$(resolve "$pc" project)" = ""
check "plain clone: no infra config -> empty" test "$(resolve "$pc" infra dev)" = ""

# Populated submodules still win (operators, CI).
sm="$TEST_TMP/sub"; mkdir -p "$sm/config/tenants/acme" "$sm/config/platform/infra" "$sm/tenants"
touch "$sm/config/platform/project.conf" "$sm/config/platform/infra/dev.config.yaml"
check "populated config/tenants wins" test "$(resolve "$sm" tenants)" = "$sm/config/tenants"
check "submodule project.conf" test "$(resolve "$sm" project)" = "$sm/config/platform/project.conf"
check "submodule infra config" test "$(resolve "$sm" infra dev)" = "$sm/config/platform/infra/dev.config.yaml"

# Overrides win over a populated submodule and never fall back to it.
ov="$TEST_TMP/devbox-cfg"; mkdir -p "$ov/tenants/devbox" "$ov/infra"
touch "$ov/project.conf" "$ov/infra/devbox.config.yaml"
check "MT_TENANTS_DIR override" test "$(O_TENANTS="$ov/tenants" resolve "$sm" tenants)" = "$ov/tenants"
check "MT_PROJECT_CONF override" test "$(O_PROJECT="$ov/project.conf" resolve "$sm" project)" = "$ov/project.conf"
check "MT_INFRA_CONFIG_DIR override" test "$(O_INFRA="$ov/infra" resolve "$sm" infra devbox)" = "$ov/infra/devbox.config.yaml"
check_not "MT_INFRA_CONFIG_DIR set without <env>.config.yaml must fail (no fallback)" env O_INFRA="$ov/infra" bash -c "$(declare -f resolve); PATHS_SH='$PATHS_SH' resolve '$sm' infra dev"
check_not "MT_TENANTS_DIR pointing nowhere must fail" env O_TENANTS="$ov/nope" bash -c "$(declare -f resolve); PATHS_SH='$PATHS_SH' resolve '$sm' tenants"
check_not "MT_PROJECT_CONF pointing nowhere must fail" env O_PROJECT="$ov/nope.conf" bash -c "$(declare -f resolve); PATHS_SH='$PATHS_SH' resolve '$sm' project"

# ── PgBouncer render: mesh on is the template verbatim, mesh off drops the sidecar
tpl="$REPO_ROOT/apps/manifests/pgbouncer/pgbouncer-deployment.yaml.tpl"
render_pgb() {  # <mesh true|false> -> rendered Deployment, as deploy-pgbouncer.sh does
  ( export NS_DB=infra-db PG_VM_TAILSCALE_IP=10.0.0.5 HEADSCALE_URL=https://hs.example.com \
      CHECKSUM_PGBOUNCER_CONFIG=a CHECKSUM_PGBOUNCER_USERLIST=b PGBOUNCER_REPLICAS=1
    out="$TEST_TMP/pgb-$1.yaml"
    envsubst '${NS_DB} ${PG_VM_TAILSCALE_IP} ${HEADSCALE_URL} ${CHECKSUM_PGBOUNCER_CONFIG} ${CHECKSUM_PGBOUNCER_USERLIST} ${PGBOUNCER_REPLICAS}' < "$tpl" > "$out"
    [ "$1" = "false" ] && yq -i 'del(.spec.template.spec.initContainers)' "$out"
    cat "$out" )
}
mesh_on=$(render_pgb true)
mesh_off=$(render_pgb false)
check "mesh on keeps the tailscale sidecar" test "$(yq '.spec.template.spec.initContainers[0].name' <<<"$mesh_on")" = "tailscale"
check "mesh off has no initContainers" test "$(yq '.spec.template.spec.initContainers' <<<"$mesh_off")" = "null"
check "mesh off keeps the pgbouncer container and PG host" \
  test "$(yq '.spec.template.spec.containers[0].env[] | select(.name=="DATABASES_HOST") | .value' <<<"$mesh_off")" = "10.0.0.5"
check "the sidecar is the template's only initContainer" \
  test "$(yq '.spec.template.spec.initContainers | length' <<<"$mesh_on")" = "1"
# deploy-pgbouncer.sh must render mesh-on without any post-processing.
check "deploy-pgbouncer only post-processes when mesh is false" \
  grep -q 'if \[ "\$PGBOUNCER_MESH" = "false" \]; then' "$REPO_ROOT/apps/deploy-pgbouncer.sh"

# ── shared PG bootstrap SQL ───────────────────────────────────────────────
# shellcheck source=../lib/pg-bootstrap-sql.sh
source "$REPO_ROOT/scripts/lib/pg-bootstrap-sql.sh"
printf "database:\n  postgres_password: \"p'g\"\npgbouncer:\n  auth_password: b1\nkeycloak:\n  db_password: k1\n" > "$TEST_TMP/s.yaml"
sql=$(mt_pg_bootstrap_sql "$TEST_TMP/s.yaml")
check "SQL quotes passwords as literals" grep -qF "ALTER ROLE postgres WITH PASSWORD 'p''g';" <<<"$sql"
check "SQL creates the keycloak database" grep -qF "CREATE DATABASE keycloak OWNER keycloak" <<<"$sql"
check "SQL grants pg_shadow to pgbouncer" grep -qF "GRANT SELECT ON pg_catalog.pg_shadow TO pgbouncer;" <<<"$sql"
printf "database:\n  postgres_password: x\n" > "$TEST_TMP/partial.yaml"
check_not "SQL refuses a secrets file with missing passwords" bash -c "source \"$REPO_ROOT/scripts/lib/pg-bootstrap-sql.sh\"; mt_pg_bootstrap_sql \"$TEST_TMP/partial.yaml\" 2>/dev/null"

# ── true-by-default flags: an explicit false must survive ─────────────────
# yq's `//` replaces false as well as null, so `x // true` can never be false.
for f in scripts/lib/config.sh scripts/lib/infra-config.sh; do
  check_not "$f: no '// true' defaults" grep -nE "^[^#]*// true" "$REPO_ROOT/$f"
done
flag_of() { printf '%s' "$1" | yq '.x | tostring | sub("^null$"; "true")'; }
check "default-true idiom: false stays false" test "$(flag_of 'x: false')" = "false"
check "default-true idiom: unset is true" test "$(flag_of 'y: 1')" = "true"
check "default-true idiom: true stays true" test "$(flag_of 'x: true')" = "true"

echo "devbox-env: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
