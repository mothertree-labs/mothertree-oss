#!/bin/bash
# prometheus-operator CRD pre-apply for the kube-prometheus-stack Helm release.
#
# Source from a deploy script AFTER common.sh (needs the print_* helpers):
#   source "${REPO_ROOT}/scripts/lib/prometheus-crds.sh"
#   mt_apply_prometheus_crds "${REPO_ROOT}/apps/helmfile.yaml.gotmpl"
#
# Why this exists: Helm installs a chart's CRDs exactly once — on first install,
# from the chart's `crds` subchart — and never upgrades them. Every
# kube-prometheus-stack major that bumps prometheus-operator ships new CRD
# schemas, and a field the new operator reads but the old CRD does not know is
# silently pruned on write. Nothing in this repo re-applied the CRDs after the
# first install, so a cluster's CRDs stay frozen at the schema of whichever
# chart version first installed it. deploy_infra calls this immediately before
# the tier=system `helmfile sync`; it is idempotent (server-side apply) and
# harmless on a cold cluster (it pre-installs what the chart would).
#
# Where the CRDs come from: the chart artifact itself. `helm pull` of the
# pinned chart version (helmfile.yaml.gotmpl) is untarred to a temp dir and
# the manifests under charts/crds/crds/crd-<kind>.yaml are applied. They are
# the upstream prometheus-operator files (byte-identical plus a one-line URL
# comment), so this is bound to the exact artifact helm is about to install:
# no operator-tag indirection, no second host to trust or reach, and no
# checksum to maintain because the manifests ARE the chart. The chart's
# appVersion (the operator tag) is resolved only to print it, so the deploy
# log says which operator the CRDs belong to.
#
# `--server-side --force-conflicts --field-manager=mt-deploy-crds`: the live
# CRDs are owned by field manager `helm/Apply` from the first install, and
# server-side apply also sidesteps the client-side last-applied annotation
# (the Prometheus CRD alone is ~850 KB — far past the annotation limit). The
# field manager name makes this script's ownership visible in managedFields.
#
# Fail fast (CLAUDE.md "Fail Fast — Never Silently Skip"): every step returns
# non-zero and names the fix. The chart is pulled and every expected CRD file
# is validated BEFORE the first apply, so a failed pull or a chart whose CRD
# set differs from MT_PROMETHEUS_CRD_KINDS leaves the cluster untouched —
# never a half-upgraded CRD set.

# Guard against double-sourcing
if [ "${_MT_PROMETHEUS_CRDS_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_PROMETHEUS_CRDS_LOADED=1

# The CRDs prometheus-operator ships (chart: charts/crds/crds/crd-<kind>.yaml).
# The chart's set must match this list exactly — a kind missing from the chart
# or shipped by the chart but absent here fails the step before any apply.
MT_PROMETHEUS_CRD_KINDS=(
  alertmanagerconfigs
  alertmanagers
  podmonitors
  probes
  prometheusagents
  prometheuses
  prometheusrules
  scrapeconfigs
  servicemonitors
  thanosrulers
)
MT_PROMETHEUS_CRD_FIELD_MANAGER="mt-deploy-crds"
MT_PROMETHEUS_CHART="prometheus-community/kube-prometheus-stack"
MT_PROMETHEUS_RELEASE="kube-prometheus-stack"
# The CRD whose controller-gen annotation is reported before/after (it is the
# largest and the one every chart major touches).
MT_PROMETHEUS_CRD_PROBE="prometheuses.monitoring.coreos.com"
# Temp-dir name prefix. The directory this process creates is recorded in
# _MT_PROM_CRDS_TMPDIR so notify.sh's EXIT handler can remove it if the deploy
# dies mid-step (SIGTERM from a cancelled pipeline); mt_apply_prometheus_crds
# also removes it on every return path itself.
MT_PROMETHEUS_CRD_TMP_PREFIX="mt-prom-crds"
_MT_PROM_CRDS_TMPDIR=""

# The three value-returning helpers below are called as $(...): their stdout
# is the value, so their diagnostics go to stderr or the deploy log would show
# a bare failure with the reason swallowed.

# ---------------------------------------------------------------------------
# mt_prometheus_chart_version <helmfile.yaml.gotmpl>
# Prints the literal `version:` of the kube-prometheus-stack release.
#
# The helmfile is Go-templated, so yq cannot read it as-is. Every `{{ ... }}`
# in that file is a scalar value (requiredEnv / .Environment.Name), so
# replacing each with a placeholder leaves valid YAML. A future control-flow
# template ({{- if }} / {{ range }}) would break the parse — and this function
# then fails loudly instead of guessing, which is the intended behaviour.
# Exactly one release with that name and a plain X.Y.Z literal is required:
# Renovate tracks the literal line, and a templated version cannot be pulled.
# ---------------------------------------------------------------------------
mt_prometheus_chart_version() {
  local helmfile="${1:?mt_prometheus_chart_version: helmfile path required}"
  local versions count
  if [ ! -f "$helmfile" ]; then
    print_error "mt_prometheus_chart_version: helmfile not found: $helmfile" >&2
    return 1
  fi
  if ! versions=$(sed -E 's/\{\{[^}]*\}\}/X/g' "$helmfile" \
      | yq ".releases[] | select(.name == \"$MT_PROMETHEUS_RELEASE\") | .version" 2>&1); then
    print_error "mt_prometheus_chart_version: cannot parse $helmfile as YAML after stripping templates: $versions" >&2
    print_error "Only scalar {{ }} templates are supported in the helmfile; a control-flow block needs this reader updated." >&2
    return 1
  fi
  count=$(printf '%s\n' "$versions" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$count" -ne 1 ]; then
    print_error "mt_prometheus_chart_version: expected exactly one release named $MT_PROMETHEUS_RELEASE with a version: in $helmfile, found $count" >&2
    return 1
  fi
  if ! [[ "$versions" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_error "mt_prometheus_chart_version: $MT_PROMETHEUS_RELEASE version '$versions' in $helmfile is not a plain X.Y.Z literal" >&2
    print_error "Keep it a literal line: Renovate tracks it and the chart is pulled by it." >&2
    return 1
  fi
  printf '%s\n' "$versions"
}

# ---------------------------------------------------------------------------
# mt_prometheus_operator_version <chart version>
# Prints the chart's appVersion, i.e. the prometheus-operator tag (vX.Y.Z).
# Log-only: the CRDs come from the chart tarball, but the deploy log (and the
# CHANGELOG) name the operator the CRDs belong to, so an empty appVersion is
# still an error. Needs the prometheus-community repo added and updated
# (deploy_infra does both before this step runs).
# ---------------------------------------------------------------------------
mt_prometheus_operator_version() {
  local chart_ver="${1:?mt_prometheus_operator_version: chart version required}"
  local chart_yaml app
  if ! chart_yaml=$(helm show chart "$MT_PROMETHEUS_CHART" --version "$chart_ver" 2>&1); then
    print_error "helm show chart $MT_PROMETHEUS_CHART --version $chart_ver failed: $chart_yaml" >&2
    print_error "Is the prometheus-community helm repo added and updated, and does chart $chart_ver exist in it?" >&2
    return 1
  fi
  if ! app=$(printf '%s\n' "$chart_yaml" | yq '.appVersion // ""' 2>&1); then
    print_error "cannot parse 'helm show chart' output for $MT_PROMETHEUS_CHART $chart_ver: $app" >&2
    return 1
  fi
  if [ -z "$app" ] || [ "$app" = "null" ]; then
    print_error "chart $MT_PROMETHEUS_CHART $chart_ver has no appVersion — cannot tell which prometheus-operator the CRDs belong to" >&2
    return 1
  fi
  if ! [[ "$app" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_error "chart $MT_PROMETHEUS_CHART $chart_ver appVersion '$app' is not a vX.Y.Z prometheus-operator tag" >&2
    return 1
  fi
  printf '%s\n' "$app"
}

# ---------------------------------------------------------------------------
# _mt_prometheus_crd_annotation
# Prints the controller-gen version of the live probe CRD, "absent" when the
# CRD does not exist (a cold cluster — fine), or "present, unannotated".
# Any other kubectl failure is fatal: an unreachable API or a wrong
# KUBECONFIG must never read as "cold start".
# ---------------------------------------------------------------------------
_mt_prometheus_crd_annotation() {
  local out
  if ! out=$(kubectl get crd "$MT_PROMETHEUS_CRD_PROBE" --ignore-not-found \
      -o jsonpath='{.metadata.name}{"\t"}{.metadata.annotations.controller-gen\.kubebuilder\.io/version}'); then
    print_error "cannot read CRD $MT_PROMETHEUS_CRD_PROBE (KUBECONFIG=${KUBECONFIG:-unset}) — refusing to guess the CRD state" >&2
    return 1
  fi
  case "$out" in
    "")                       echo "absent" ;;
    "$MT_PROMETHEUS_CRD_PROBE"$'\t') echo "present, unannotated" ;;
    "$MT_PROMETHEUS_CRD_PROBE"$'\t'*) echo "${out#*$'\t'}" ;;
    *) print_error "unexpected kubectl output reading CRD $MT_PROMETHEUS_CRD_PROBE: $out" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _mt_prometheus_crd_file_ok <file> <kind>
# Require the manifest to be the CustomResourceDefinition it claims to be —
# a chart that renamed or restructured its crds subchart must fail here, not
# at apply time with three CRDs already replaced.
# ---------------------------------------------------------------------------
_mt_prometheus_crd_file_ok() {
  local file="$1" kind="$2" got want
  want="CustomResourceDefinition $kind.monitoring.coreos.com"
  got=$(yq '.kind + " " + .metadata.name' "$file" 2>&1)
  if [ "$got" != "$want" ]; then
    print_error "$file is not the $kind CRD (expected '$want', got '$got')"
    print_error "The chart's crds subchart does not ship what this step expects. Aborting before any CRD is applied."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# mt_prometheus_crds_cleanup
# Remove the temp dir this process created (if any). Called on every return
# path of mt_apply_prometheus_crds and by notify.sh's EXIT handler, so a
# cancelled pipeline (SIGTERM — bash runs the EXIT trap on it) cleans up too.
# Only this process's own directory is removed: dev and prod deploy_infra can
# run concurrently on the CI host, so a glob would delete a live run's files
# out from under its kubectl apply.
# ---------------------------------------------------------------------------
mt_prometheus_crds_cleanup() {
  if [ -n "$_MT_PROM_CRDS_TMPDIR" ]; then
    # Never fail here: this also runs from deploy_infra's EXIT trap under
    # errexit, where a failing rm would abort the handler before the deploy
    # notification is sent and replace the script's exit code with 1.
    rm -rf "$_MT_PROM_CRDS_TMPDIR" \
      || print_warning "could not remove CRD temp dir $_MT_PROM_CRDS_TMPDIR (left for the stale sweep)"
    _MT_PROM_CRDS_TMPDIR=""
  fi
}

# ---------------------------------------------------------------------------
# mt_apply_prometheus_crds <helmfile.yaml.gotmpl>
# Resolve the chart pin, pull the chart, validate all CRD files, then
# server-side apply them. Prints the operator version and the probe CRD's
# controller-gen annotation before and after. Idempotent.
# ---------------------------------------------------------------------------
mt_apply_prometheus_crds() {
  local helmfile="${1:?mt_apply_prometheus_crds: path to helmfile.yaml.gotmpl required}"
  local tmproot rc=0
  if [ -z "${KUBECONFIG:-}" ]; then
    print_error "mt_apply_prometheus_crds: KUBECONFIG is not set"
    return 1
  fi
  tmproot="${TMPDIR:-/tmp}"
  # A run killed with SIGKILL gets no EXIT trap; sweep its leftovers (this
  # step takes seconds, so anything older than an hour is not a live run).
  find "$tmproot" -maxdepth 1 -type d -name "$MT_PROMETHEUS_CRD_TMP_PREFIX.*" -mmin +60 -exec rm -rf {} + 2>/dev/null \
    || print_warning "could not sweep stale $MT_PROMETHEUS_CRD_TMP_PREFIX.* dirs under $tmproot (continuing)"
  if ! _MT_PROM_CRDS_TMPDIR=$(mktemp -d "$tmproot/$MT_PROMETHEUS_CRD_TMP_PREFIX.XXXXXX"); then
    _MT_PROM_CRDS_TMPDIR=""
    print_error "mt_apply_prometheus_crds: mktemp -d under $tmproot failed"
    return 1
  fi
  # No `trap EXIT` here: deploy_infra's notification trap owns EXIT and calls
  # mt_prometheus_crds_cleanup itself. The worker is called under `||`, which
  # also disables errexit inside it, so every step in it checks its own status.
  _mt_apply_prometheus_crds_in "$helmfile" "$_MT_PROM_CRDS_TMPDIR" || rc=$?
  mt_prometheus_crds_cleanup
  return "$rc"
}

_mt_apply_prometheus_crds_in() {
  local helmfile="$1" tmp="$2"
  local chart_ver op_ver before after kind file crd_dir pull_out
  local -a shipped

  chart_ver=$(mt_prometheus_chart_version "$helmfile") || return 1
  op_ver=$(mt_prometheus_operator_version "$chart_ver") || return 1
  print_status "prometheus-operator CRDs: chart $MT_PROMETHEUS_CHART $chart_ver (operator $op_ver)"

  before=$(_mt_prometheus_crd_annotation) || return 1
  print_status "  $MT_PROMETHEUS_CRD_PROBE controller-gen before: $before"

  # Pull the exact chart artifact helmfile is about to install. --untardir
  # must be a fresh directory (helm refuses one that already holds the chart
  # tree), which the per-run mktemp guarantees.
  if ! pull_out=$(helm pull "$MT_PROMETHEUS_CHART" --version "$chart_ver" --untar --untardir "$tmp" 2>&1); then
    print_error "helm pull $MT_PROMETHEUS_CHART --version $chart_ver failed: $pull_out"
    print_error "Aborting before any CRD is applied. Is the prometheus-community repo updated and chart $chart_ver in its index?"
    return 1
  fi
  crd_dir="$tmp/${MT_PROMETHEUS_CHART##*/}/charts/crds/crds"
  if [ ! -d "$crd_dir" ]; then
    print_error "chart $chart_ver has no charts/crds/crds directory (looked in $crd_dir)"
    print_error "The chart restructured its crds subchart — update scripts/lib/prometheus-crds.sh. Aborting before any CRD is applied."
    return 1
  fi

  # The chart's CRD set must be exactly MT_PROMETHEUS_CRD_KINDS: a missing file
  # means the step would leave a CRD stale, an extra one means the operator
  # ships a kind this list does not know. Both are checked before any apply.
  for kind in "${MT_PROMETHEUS_CRD_KINDS[@]}"; do
    file="$crd_dir/crd-$kind.yaml"
    if [ ! -f "$file" ]; then
      print_error "chart $chart_ver ships no CRD file for $kind (expected $file)"
      print_error "Aborting before any CRD is applied — the chart's CRD set no longer matches MT_PROMETHEUS_CRD_KINDS in scripts/lib/prometheus-crds.sh."
      return 1
    fi
    _mt_prometheus_crd_file_ok "$file" "$kind" || return 1
  done
  shipped=()
  for file in "$crd_dir"/crd-*.yaml; do
    kind="${file##*/crd-}"; kind="${kind%.yaml}"
    case " ${MT_PROMETHEUS_CRD_KINDS[*]} " in
      *" $kind "*) ;;
      *) shipped+=("$kind") ;;
    esac
  done
  if [ "${#shipped[@]}" -gt 0 ]; then
    print_error "chart $chart_ver ships CRDs not in MT_PROMETHEUS_CRD_KINDS: ${shipped[*]}"
    print_error "Add them to the list in scripts/lib/prometheus-crds.sh so they are applied too. Aborting before any CRD is applied."
    return 1
  fi
  print_status "  validated ${#MT_PROMETHEUS_CRD_KINDS[@]} CRD manifests from the chart artifact"

  for kind in "${MT_PROMETHEUS_CRD_KINDS[@]}"; do
    file="$crd_dir/crd-$kind.yaml"
    if ! kubectl apply --server-side --force-conflicts \
        --field-manager="$MT_PROMETHEUS_CRD_FIELD_MANAGER" -f "$file"; then
      print_error "kubectl apply --server-side failed for $kind.monitoring.coreos.com"
      print_error "Fix the API error above and re-run deploy_infra; the remaining CRDs were not applied and helmfile sync did not run."
      return 1
    fi
  done

  after=$(_mt_prometheus_crd_annotation) || return 1
  print_status "  $MT_PROMETHEUS_CRD_PROBE controller-gen after:  $after"
  case "$after" in
    absent|"present, unannotated")
      print_error "$MT_PROMETHEUS_CRD_PROBE is '$after' after a successful apply — the CRD manifest is not what the operator ships"
      return 1 ;;
  esac
  print_success "prometheus-operator CRDs from chart $chart_ver (operator $op_ver) server-side applied, field manager $MT_PROMETHEUS_CRD_FIELD_MANAGER"
}
