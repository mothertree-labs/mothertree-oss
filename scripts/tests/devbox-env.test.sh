#!/usr/bin/env bash
# Unit tests for the helpers that let a developer box (devbox: k3d on a laptop,
# cluster.edge: local) share the deploy scripts with the public environments:
#
#   cluster.edge / mt_is_local_edge / mt_ingress_public_ip   (scripts/lib/platform.sh)
#   plain-clone detection + MT_*_DIR overrides               (scripts/lib/paths.sh)
#   PgBouncer Deployment render with/without the mesh        (apps/deploy-pgbouncer.sh)
#   shared PostgreSQL bootstrap SQL                          (scripts/lib/pg-bootstrap-sql.sh)
#   s3.endpoint / internal_endpoint / addressing_style       (scripts/lib/config.sh, docs-config)
#   local-CA trust injection into a Deployment               (scripts/lib/local-ca.sh)
#   DEVBOX_TRUST=process + the image-cache mirror config     (scripts/devbox)
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

# ── config.sh: S3 endpoint settings ───────────────────────────────────────
s3_of() {  # <yq edit for the example tenant config> -> "endpoint|internal|style|ssl" or fails
  local t="$TEST_TMP/s3t.$RANDOM"
  # Hermetic: own infra dir + terraform outputs, and a kubectl that always
  # fails, so nothing from the checkout or a live cluster leaks in.
  mkdir -p "$t/tenants/ex" "$t/infra" "$t/bin"
  yq "$1" "$REPO_ROOT/tenants/.example/dev.config.yaml" > "$t/tenants/ex/dev.config.yaml"
  cp "$REPO_ROOT/tenants/.example/dev.secrets.yaml.example" "$t/tenants/ex/dev.secrets.yaml"
  : > "$t/project.conf"
  printf 'keycloak:\n  replicas: 1\n' > "$t/infra/dev.config.yaml"
  printf 'TURN_SERVER_IP=192.0.2.1\n' > "$t/infra/terraform-outputs.dev.env"
  printf '#!/bin/sh\nexit 1\n' > "$t/bin/kubectl"; chmod +x "$t/bin/kubectl"
  env -i PATH="$t/bin:$PATH" HOME="$HOME" bash -c '
    set -euo pipefail
    REPO_ROOT="$1"; MT_ENV=dev; MT_TENANT=ex; MT_TENANTS_DIR="$2/tenants"; MT_PROJECT_CONF="$2/project.conf"
    MT_INFRA_CONFIG_DIR="$2/infra"
    export REPO_ROOT MT_ENV MT_TENANT MT_TENANTS_DIR MT_PROJECT_CONF MT_INFRA_CONFIG_DIR
    source "$REPO_ROOT/scripts/lib/common.sh"; source "$REPO_ROOT/scripts/lib/config.sh"
    mt_load_tenant_config >/dev/null 2>&1
    echo "$S3_ENDPOINT|$S3_INTERNAL_ENDPOINT|$S3_ADDRESSING_STYLE|$S3_USE_SSL|$S3_INTERNAL_HOST|$S3_INTERNAL_PORT|$S3_INTERNAL_SSL|$S3_USE_PATH_STYLE"' _ "$REPO_ROOT" "$t" 2>/dev/null
}
s3_main() { s3_of "$1" | cut -d'|' -f1-4; }   # endpoint|internal|style|ssl
s3_split() { s3_of "$1" | cut -d'|' -f5-8; }  # host|port|ssl|path-style (Nextcloud)
cluster=$(yq '.s3.cluster' "$REPO_ROOT/tenants/.example/dev.config.yaml")
check "S3 defaults are Linode, virtual-host, TLS" \
  test "$(s3_main '.')" = "https://${cluster}.linodeobjects.com|https://${cluster}.linodeobjects.com|virtual|True"
check "s3.endpoint override; internal defaults to it" \
  test "$(s3_main '.s3.endpoint = "https://s3.x.localhost" | .s3.addressing_style = "path"')" = "https://s3.x.localhost|https://s3.x.localhost|path|True"
check "s3.internal_endpoint override (http)" \
  test "$(s3_main '.s3.endpoint = "https://s3.x.localhost" | .s3.internal_endpoint = "http://gw.ns.svc:7070"')" = "https://s3.x.localhost|http://gw.ns.svc:7070|virtual|True"
check "plain-http endpoint turns AWS_S3_USE_SSL off" \
  test "$(s3_of '.s3.endpoint = "http://s3.x.localhost"' | cut -d'|' -f4)" = "False"
check "split S3 defaults are what Nextcloud had hardcoded" \
  test "$(s3_split '.')" = "${cluster}.linodeobjects.com|443|true|false"
check "split S3 for an http gateway with a port, path-style" \
  test "$(s3_split '.s3.internal_endpoint = "http://gw.ns.svc.cluster.local:7070" | .s3.addressing_style = "path"')" = "gw.ns.svc.cluster.local|7070|false|true"
check "split S3 for https without a port" \
  test "$(s3_split '.s3.endpoint = "https://s3.x.localhost/"')" = "s3.x.localhost|443|true|false"
check_not "s3.addressing_style must be virtual or path" s3_of '.s3.addressing_style = "dns"'
check_not "s3.endpoint must be a URL" s3_of '.s3.endpoint = "s3.x.localhost"'
check_not "s3.endpoint rejects quotes" s3_of '.s3.endpoint = "https://a\"b.example.com"'
check_not "s3.endpoint rejects a path" s3_of '.s3.endpoint = "https://s3.example.com/bucket"'
check "s3.internal_endpoint may carry a port" \
  test "$(s3_of '.s3.internal_endpoint = "http://gw.ns.svc.cluster.local:7070"' | cut -d'|' -f2)" = "http://gw.ns.svc.cluster.local:7070"

# docs-config renders byte-identically to the pre-endpoint template on the defaults.
docs_env() { env -i PATH="$PATH" S3_CLUSTER="$cluster" S3_ENDPOINT="https://${cluster}.linodeobjects.com" \
  S3_ADDRESSING_STYLE=virtual S3_USE_SSL=True BUCKET_NAME=b DOCS_HOST=docs.example.com AUTH_HOST=auth.example.com "$@"; }
legacy_docs=$(sed -e "s|\${S3_ENDPOINT}|https://\${S3_CLUSTER}.linodeobjects.com|g" \
  -e 's|"${S3_ADDRESSING_STYLE}"|"virtual"|' -e 's|"${S3_USE_SSL}"|"True"|' "$REPO_ROOT/docs/docs-config.yaml.tpl")
check "docs-config: default S3 values render as before" \
  test "$(docs_env envsubst < "$REPO_ROOT/docs/docs-config.yaml.tpl" | grep -v '^ *#')" = "$(printf '%s\n' "$legacy_docs" | docs_env envsubst | grep -v '^ *#')"
check "docs-config: no hardcoded linodeobjects endpoint left" \
  test "$(grep -c 'linodeobjects' "$REPO_ROOT/docs/docs-config.yaml.tpl")" = "1"

# Nextcloud OIDC job: public edges still discover Keycloak at https://$AUTH_HOST.
nc_job_env() { env -i PATH="$PATH" AUTH_HOST=auth.example.com TENANT_KEYCLOAK_REALM=r FILES_HOST=files.example.com "$@"; }
legacy_nc=$(sed "s|\${OIDC_DISCOVERY_BASE}|https://\${AUTH_HOST}|" "$REPO_ROOT/docs/nextcloud-oidc-config-job.yaml.tpl")
check "nextcloud-oidc job: public-edge discovery URL renders as before" \
  test "$(nc_job_env OIDC_DISCOVERY_BASE=https://auth.example.com envsubst '${AUTH_HOST} ${OIDC_DISCOVERY_BASE} ${TENANT_KEYCLOAK_REALM} ${FILES_HOST}' < "$REPO_ROOT/docs/nextcloud-oidc-config-job.yaml.tpl")" = \
       "$(printf '%s\n' "$legacy_nc" | nc_job_env envsubst '${AUTH_HOST} ${TENANT_KEYCLOAK_REALM} ${FILES_HOST}')"
check "deploy-nextcloud: public edges use https://\$AUTH_HOST" \
  grep -qF 'OIDC_DISCOVERY_BASE="https://${AUTH_HOST}"' "$REPO_ROOT/apps/deploy-nextcloud.sh"

# Stalwart: the S3 store endpoint renders as the old hardcoded Linode value.
check "stalwart: default S3 endpoint renders as before" \
  test "$(env -i PATH="$PATH" S3_CLUSTER=us-lax-1 S3_INTERNAL_ENDPOINT=https://us-lax-1.linodeobjects.com envsubst '${S3_CLUSTER} ${S3_INTERNAL_ENDPOINT}' < "$REPO_ROOT/apps/manifests/stalwart/stalwart.yaml.tpl")" = \
       "$(sed 's|${S3_INTERNAL_ENDPOINT}|https://${S3_CLUSTER}.linodeobjects.com|' "$REPO_ROOT/apps/manifests/stalwart/stalwart.yaml.tpl" | env -i PATH="$PATH" S3_CLUSTER=us-lax-1 envsubst '${S3_CLUSTER}')"

# Jitsi JVB: public edges keep require-stun and STUN via the TURN server.
jvb_env() { env -i PATH="$PATH" JVB_PORT=31000 JITSI_HOST=jitsi.example.com TURN_SERVER_IP=192.0.2.9 \
  JVB_MIN_REPLICAS=1 NS_JITSI=tn-x-jitsi JVB_PUBLIC_IP= "$@"; }
jvb_vars='${JVB_PORT} ${JITSI_HOST} ${TURN_SERVER_IP} ${JVB_MIN_REPLICAS} ${NS_JITSI} ${JVB_PUBLIC_IP} ${JVB_REQUIRE_STUN} ${JVB_STUN_SERVERS}'
legacy_jvb=$(sed -e 's|require-stun = ${JVB_REQUIRE_STUN}|require-stun = true|' \
  -e 's|value: "${JVB_STUN_SERVERS}"|value: "${TURN_SERVER_IP}:3478"|' "$REPO_ROOT/apps/manifests/jitsi/jvb.yaml.tpl")
check "jvb: public-edge render unchanged (require-stun, STUN via TURN)" \
  test "$(jvb_env JVB_REQUIRE_STUN=true JVB_STUN_SERVERS=192.0.2.9:3478 envsubst "$jvb_vars" < "$REPO_ROOT/apps/manifests/jitsi/jvb.yaml.tpl")" = \
       "$(printf '%s\n' "$legacy_jvb" | jvb_env envsubst "$jvb_vars")"
check "deploy-jitsi passes the STUN vars to envsubst" \
  grep -qF '${JVB_REQUIRE_STUN} ${JVB_STUN_SERVERS}' "$REPO_ROOT/apps/deploy-jitsi.sh"

# ── local-ca.sh: trust injection ──────────────────────────────────────────
trust_out="$TEST_TMP/backend.yaml"
cp "$REPO_ROOT/docs/backend-deployment.yaml" "$trust_out"
before_env=$(yq '.spec.template.spec.containers[] | select(.name == "backend") | .env | length' "$trust_out")
before_vols=$(yq '.spec.template.spec.volumes | length' "$trust_out")
trust() { ( print_error() { echo "$*" >&2; }; source "$REPO_ROOT/scripts/lib/local-ca.sh"; mt_local_ca_trust "$@" ) 2>/dev/null; }
check "mt_local_ca_trust edits the backend Deployment" trust "$trust_out" backend AWS_CA_BUNDLE
check "AWS_CA_BUNDLE points at the mounted CA" \
  test "$(yq '.spec.template.spec.containers[] | select(.name == "backend") | .env[] | select(.name == "AWS_CA_BUNDLE") | .value' "$trust_out")" = "/etc/mt-local-ca/ca.crt"
check "existing env vars are kept" \
  test "$(yq '.spec.template.spec.containers[] | select(.name == "backend") | .env | length' "$trust_out")" = "$((before_env + 1))"
check "the CA ConfigMap is added as a volume" \
  test "$(yq '.spec.template.spec.volumes | length' "$trust_out")" = "$((before_vols + 1))"
check "and mounted read-only" \
  test "$(yq '.spec.template.spec.containers[] | select(.name == "backend") | .volumeMounts[] | select(.name == "mt-local-ca") | .readOnly' "$trust_out")" = "true"
check_not "unknown container is an error" trust "$trust_out" nosuch AWS_CA_BUNDLE
check_not "invalid env var name is an error" trust "$TEST_TMP/backend.yaml" backend 'bad-name'

# ── scripts/devbox: CA trust without root + image caches ──────────────────
# Hermetic: a temp .devbox, and stub docker/k3d/mkcert on PATH that only log.
DBX="$TEST_TMP/box/.devbox"
STUBS="$TEST_TMP/stubs"; mkdir -p "$STUBS"
STUB_LOG="$TEST_TMP/stub.log"; : > "$STUB_LOG"
for s in docker k3d mkcert; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n[ "%s" != mkcert ]\n' "$s" "$STUB_LOG" "$s" > "$STUBS/$s"
  chmod +x "$STUBS/$s"
done
devbox() { PATH="$STUBS:$PATH" MT_DEVBOX_DIR="$DBX" "$REPO_ROOT/scripts/devbox" "$@"; }
check "init with DEVBOX_TRUST=process succeeds without root" \
  env DEVBOX_TRUST=process bash -c "$(declare -f devbox); STUBS='$STUBS' DBX='$DBX' REPO_ROOT='$REPO_ROOT' devbox init --profile minimal >/dev/null 2>&1"
check_not "process trust never calls mkcert" grep -q '^mkcert' "$STUB_LOG"
check "process trust writes the extended bundle" test -s "$DBX/ca/bundle.pem"
check "the bundle ends with the devbox CA" \
  test "$(tail -n "$(wc -l < "$DBX/ca/rootCA.pem")" "$DBX/ca/bundle.pem")" = "$(cat "$DBX/ca/rootCA.pem")"
check "the bundle also carries the system CAs" \
  test "$(grep -c 'BEGIN CERTIFICATE' "$DBX/ca/bundle.pem")" -gt 1
dbx_env=$(devbox env 2>/dev/null)
check "env points curl at the bundle" grep -qF "export CURL_CA_BUNDLE=$DBX/ca/bundle.pem" <<<"$dbx_env"
check "env points Go/OpenSSL at the bundle" grep -qF "export SSL_CERT_FILE=$DBX/ca/bundle.pem" <<<"$dbx_env"
check "env points Node at the CA" grep -qF "export NODE_EXTRA_CA_CERTS=$DBX/ca/rootCA.pem" <<<"$dbx_env"
mv "$DBX/ca/bundle.pem" "$TEST_TMP/bundle.pem"
check_not "system trust (no bundle) exports no CA overrides" grep -q 'SSL_CERT_FILE\|CURL_CA_BUNDLE' <<<"$(devbox env 2>/dev/null)"
check "an unknown DEVBOX_TRUST is rejected" grep -q 'DEVBOX_TRUST must be system' <<<"$(env DEVBOX_TRUST=bogus bash -c "$(declare -f devbox); STUBS='$STUBS' DBX='$DBX' REPO_ROOT='$REPO_ROOT' devbox init 2>&1")"
mv "$TEST_TMP/bundle.pem" "$DBX/ca/bundle.pem"

# cache_up with a docker stub that reports nothing existing.
: > "$STUB_LOG"
printf '#!/usr/bin/env bash\necho "docker $*" >> "%s"\ncase "$1 $2" in "network inspect"|"container inspect") exit 1 ;; esac\n' "$STUB_LOG" > "$STUBS/docker"
check "cache_up runs with no caches yet" \
  bash -c "PATH='$STUBS':\$PATH MT_DEVBOX_DIR='$DBX'; export PATH MT_DEVBOX_DIR; source '$REPO_ROOT/scripts/devbox' env >/dev/null; cache_up >/dev/null"
REG="$DBX/registries.yaml"
check "registries.yaml mirrors the four upstreams" \
  test "$(yq '.mirrors | keys | join(" ")' "$REG")" = "docker.io ghcr.io quay.io registry.k8s.io"
check "docker.io goes to its cache over the cache network" \
  test "$(yq '.mirrors."docker.io".endpoint[0]' "$REG")" = "http://devbox-cache-docker-io:5000"
check "registry.k8s.io cache name is a valid container name" \
  test "$(yq '.mirrors."registry.k8s.io".endpoint[0]' "$REG")" = "http://devbox-cache-registry-k8s-io:5000"
check "one cache container per upstream" test "$(grep -c '^docker run ' "$STUB_LOG")" = 4
check "the cache network is created" grep -q '^docker network create .*devbox-cache$' "$STUB_LOG"
check "caches drop all capabilities" test "$(grep '^docker run ' "$STUB_LOG" | grep -c -- '--cap-drop ALL --security-opt no-new-privileges')" = 4
check "caches never expire content" test "$(grep '^docker run ' "$STUB_LOG" | grep -c 'REGISTRY_PROXY_TTL=0s')" = 4
check_not "caches publish no ports" grep -qE '^docker run .*(-p |--publish)' "$STUB_LOG"
check "Docker Hub cache proxies registry-1.docker.io" \
  grep -q '^docker run .*devbox-cache-docker-io .*REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io ' "$STUB_LOG"
check "the cache image is a pinned registry tag" \
  grep -qE '^DEVBOX_CACHE_IMAGE="registry:[0-9]+\.[0-9]+\.[0-9]+"$' "$REPO_ROOT/scripts/devbox"
check "k3d gets the mirror config at create time" \
  grep -qF -- '--registry-config "$DEVBOX_DIR/registries.yaml"' "$REPO_ROOT/scripts/devbox"

# up on a fresh .devbox (no images.env yet) must reach the portal build; it
# used to die silently there (sed on the missing file + pipefail).
up_fresh() {  # <cmd_build body>
  bash -c "PATH='$STUBS':\$PATH MT_DEVBOX_DIR='$DBX'; export PATH MT_DEVBOX_DIR
    source '$REPO_ROOT/scripts/devbox' env >/dev/null
    cluster_up() { :; }; postgres_up() { :; }; cmd_build() { $1; }
    cmd_up" 2>&1
}
rm -f "$DBX/images.env"
check "up on a fresh .devbox reaches the portal build" \
  grep -q '^BUILD admin-portal$' <<<"$(up_fresh 'echo BUILD $1; exit 0')"
check "a failing command is named, not silent" \
  grep -qE 'failed \(exit 1\) at line [0-9]+: false' <<<"$(up_fresh false)"
check "die() prints only its own message" \
  test "$(up_fresh 'die boom' | grep -c 'devbox\]')" = 1

# Profiles: what init writes, and what the e2e specs are told is off.
profile_of() {  # <profile> -> generated tenant config path
  local d="$TEST_TMP/prof-$1/.devbox"
  bash -c "PATH='$STUBS':\$PATH MT_DEVBOX_DIR='$d' DEVBOX_TRUST=process '$REPO_ROOT/scripts/devbox' init --profile $1" >/dev/null 2>&1
  printf '%s' "$d/tenants/devbox/devbox.config.yaml"
}
disabled_of() {  # <profile> -> E2E_DISABLED_FEATURES for that profile
  bash -c "PATH='$STUBS':\$PATH MT_DEVBOX_DIR='$TEST_TMP/prof-$1/.devbox'; export PATH MT_DEVBOX_DIR
    source '$REPO_ROOT/scripts/devbox' env >/dev/null; disabled_features"
}
FULL=$(profile_of full); MIN=$(profile_of minimal)
check "full profile: calendar on" test "$(yq .features.calendar_enabled "$FULL")" = true
check "full profile: magic-link login on" test "$(yq .features.login_methods.magic_link "$FULL")" = true
check "full profile: office and LLM off" test "$(yq '.features.office_enabled, .features.llm_enabled' "$FULL" | tr '\n' ' ')" = "false false "
check "minimal profile: calendar and magic link off" \
  test "$(yq '.features.calendar_enabled, .features.login_methods.magic_link' "$MIN" | tr '\n' ' ')" = "false false "
check "full profile: e2e skips exactly what is off" \
  test "$(disabled_of full)" = "smtp,turn,office,google_import,llm,google_sso,external_mail"
check "minimal profile: e2e skips the apps it lacks" \
  grep -qE '(^|,)matrix,docs,files(,|$)' <<<"$(disabled_of minimal)"

# everything profile: full + Office + LLM, with the model in the infra config.
EV=$(profile_of everything)
EVI="${EV%/tenants/devbox/devbox.config.yaml}/infra/devbox.config.yaml"
check "everything profile: Office and LLM on" test "$(yq '.features.office_enabled, .features.llm_enabled' "$EV" | tr '\n' ' ')" = "true true "
check "everything profile: still has calendar and magic link" test "$(yq '.features.calendar_enabled, .features.login_methods.magic_link' "$EV" | tr '\n' ' ')" = "true true "
check "everything profile: infra config turns the LLM on with the default model" \
  test "$(yq '.llm.enabled, .llm.model' "$EVI" | tr '\n' ' ')" = "true llama3.2:1b "
check "full profile: no LLM in the infra config" test "$(yq '.llm // "none"' "${FULL%/tenants/devbox/devbox.config.yaml}/infra/devbox.config.yaml")" = none
check "everything profile: e2e skips nothing it deploys" \
  test "$(disabled_of everything)" = "smtp,turn,google_import,google_sso,external_mail"
EVD="$TEST_TMP/prof-everything/.devbox"
# Arguments go through as real argv (never pasted into a shell string: one
# of them is a shell-injection probe).
evinit() { PATH="$STUBS:$PATH" MT_DEVBOX_DIR="$EVD" DEVBOX_TRUST=process "$REPO_ROOT/scripts/devbox" init "$@" 2>&1; }
evinit --llm-model qwen2.5:0.5b >/dev/null
check "--llm-model is written and remembered" test "$(yq .llm.model "$EVI"):$(cat "$EVD/llm-model")" = "qwen2.5:0.5b:qwen2.5:0.5b"
evinit >/dev/null
check "a later init keeps the chosen model" test "$(yq .llm.model "$EVI")" = "qwen2.5:0.5b"
check "--llm-model rejects a leading dash (would be an ollama option)" grep -q 'must be an Ollama model' <<<"$(evinit --llm-model '-foo')"
check "--llm-model rejects shell metacharacters" grep -q 'must be an Ollama model' <<<"$(evinit --llm-model 'x;touch /nonexistent-probe')"
check "--llm-model is refused on other profiles" grep -q 'only applies to --profile everything' <<<"$(evinit --profile full --llm-model qwen2.5:0.5b)"
evinit --profile everything >/dev/null

# local-ca: what each trust variable points at.
ca_trust_of() {  # <env var> -> value written into a one-container Deployment
  local m="$TEST_TMP/catrust.$RANDOM.yaml"
  printf 'kind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: app\n' > "$m"
  ( source "$REPO_ROOT/scripts/lib/common.sh"; source "$REPO_ROOT/scripts/lib/local-ca.sh"
    mt_local_ca_trust "$m" app "$1" >/dev/null 2>&1 ) || return 1
  V="$1" yq '.spec.template.spec.containers[0].env[] | select(.name == strenv(V)) | .value' "$m"
}
check "local CA: SSL_CERT_DIR -> the mount directory" test "$(ca_trust_of SSL_CERT_DIR)" = /etc/mt-local-ca
check "local CA: SSL_CERT_FILE -> public roots + CA bundle" test "$(ca_trust_of SSL_CERT_FILE)" = /etc/mt-local-ca/bundle.pem
check "local CA: REQUESTS_CA_BUNDLE -> the bundle" test "$(ca_trust_of REQUESTS_CA_BUNDLE)" = /etc/mt-local-ca/bundle.pem
check "local CA: AWS_CA_BUNDLE -> the CA alone" test "$(ca_trust_of AWS_CA_BUNDLE)" = /etc/mt-local-ca/ca.crt
mdoc="$TEST_TMP/catrust-multi.yaml"
printf 'kind: Secret\nmetadata: {name: s}\n---\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: app\n---\nkind: Service\nmetadata: {name: s}\n' > "$mdoc"
check "local CA: trust works on a multi-document manifest (Open WebUI's)" \
  bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/local-ca.sh'; mt_local_ca_trust '$mdoc' app SSL_CERT_FILE >/dev/null 2>&1"
check "local CA: only the Deployment gets the mount" \
  test "$(yq ea '[select(.kind == "Deployment") | .spec.template.spec.volumes[]] | length' "$mdoc"):$(yq ea '[select(.kind != "Deployment") | select(.spec != null)] | length' "$mdoc")" = "1:0"

# Nextcloud: public edges keep wopi_url = https://$OFFICE_HOST and set no public_wopi_url.
rd_render() { env -i PATH="$PATH" OFFICE_HOST=office.example.com "$@" envsubst '${OFFICE_HOST} ${RICHDOCUMENTS_WOPI_URL} ${RICHDOCUMENTS_PUBLIC_WOPI_URL}' < "$REPO_ROOT/docs/nextcloud-oidc-config-job.yaml.tpl"; }
check "richdocuments: public edge wopi_url renders as before" \
  grep -qF "richdocuments wopi_url --value='https://office.example.com'" <<<"$(rd_render RICHDOCUMENTS_WOPI_URL=https://office.example.com RICHDOCUMENTS_PUBLIC_WOPI_URL=)"
check "richdocuments: public edge sets no public_wopi_url" \
  grep -qF 'if [ -n "" ]; then' <<<"$(rd_render RICHDOCUMENTS_WOPI_URL=https://office.example.com RICHDOCUMENTS_PUBLIC_WOPI_URL=)"
check "deploy-nextcloud: public edges keep wopi_url on https://\$OFFICE_HOST" \
  grep -qF 'RICHDOCUMENTS_WOPI_URL="https://${OFFICE_HOST}"' "$REPO_ROOT/apps/deploy-nextcloud.sh"
check "deploy_infra: the LLM on local edge only with llm.enabled" \
  grep -qF "mt_is_local_edge && [ \"\$(yq '.llm.enabled // false' \"\$MT_INFRA_CONFIG\")\" != \"true\" ]" "$REPO_ROOT/scripts/deploy_infra"

# ── infra-config.sh: mail.smtp_relay host rules ───────────────────────────
relay_of() {  # <edge or ""> <host> -> "host|port" or fails
  # The full config `devbox init` generated above, with only edge/relay edited.
  local t="$TEST_TMP/relay.$RANDOM"
  cp -R "$DBX" "$t"; : > "$t/kubeconfig"
  E="$1" H="$2" yq -i '.mail.smtp_relay.host = strenv(H) | .mail.smtp_relay.port = 1025
    | (select(strenv(E) == "") | del(.cluster.edge)) // .
    | (select(strenv(E) != "") | .cluster.edge = strenv(E)) // .
    | (select(strenv(E) != "local") | .cluster.public_ip = "203.0.113.7") // .' "$t/infra/devbox.config.yaml"
  env -i PATH="$PATH" HOME="$HOME" bash -c '
    set -euo pipefail
    REPO_ROOT="$1"; MT_ENV=devbox; MT_INFRA_CONFIG_DIR="$2/infra"; MT_PROJECT_CONF="$2/project.conf"; MT_TENANTS_DIR="$2/tenants"
    KUBECONFIG="$2/kubeconfig"
    export REPO_ROOT MT_ENV MT_INFRA_CONFIG_DIR MT_PROJECT_CONF MT_TENANTS_DIR KUBECONFIG
    source "$REPO_ROOT/scripts/lib/common.sh"; source "$REPO_ROOT/scripts/lib/infra-config.sh"
    mt_load_infra_config >/dev/null
    printf "%s|%s" "$SMTP_RELAY_HOST" "$SMTP_RELAY_PORT"' _ "$REPO_ROOT" "$t" 2>/dev/null
}
MP=mailpit.infra-mailpit.svc.cluster.local.
check "local edge: in-cluster relay name accepted" test "$(relay_of local "$MP")" = "$MP|1025"
check "local edge: a mesh IP is still accepted" test "$(relay_of local 100.64.99.1)" = "100.64.99.1|1025"
check "public edge: mesh IP relay unchanged" test "$(relay_of public 100.64.99.1)" = "100.64.99.1|1025"
check_not "public edge: in-cluster name refused" relay_of public "$MP"
check_not "no edge (devhome default): in-cluster name refused" relay_of "" "$MP"
check_not "local edge: relative cluster name refused" relay_of local "${MP%.}"
check_not "local edge: internet hostname refused" relay_of local smtp.example.com
check_not "local edge: name with a TOML quote refused" relay_of local 'a".infra.svc.cluster.local.'

# ── deploy-stalwart.sh: in-cluster relay route ────────────────────────────
check "stalwart: in-cluster relay is its own branch, before the tailnet one" \
  test "$(grep -n 'SMTP_RELAY_HOST:-}" == \*.svc.cluster.local.' "$REPO_ROOT/apps/deploy-stalwart.sh" | cut -d: -f1)" \
       -lt "$(grep -n 'elif \[ -n "${SMTP_RELAY_HOST:-}" \]; then' "$REPO_ROOT/apps/deploy-stalwart.sh" | head -1 | cut -d: -f1)"
check "stalwart: in-cluster relay egress is scoped to the relay namespace" \
  grep -qF 'kubernetes.io/metadata.name: ${SMTP_RELAY_NAMESPACE}' "$REPO_ROOT/apps/deploy-stalwart.sh"
check "devbox: infra config points the relay at Mailpit" \
  grep -qF 'DEVBOX_MAILPIT_RELAY="mailpit.infra-mailpit.svc.cluster.local."' "$REPO_ROOT/scripts/devbox"

echo "devbox-env: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
