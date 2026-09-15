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
# The CRD set is derived from the chart pin, never pinned separately:
#   chart version (helmfile.yaml.gotmpl) -> chart appVersion (helm show chart)
#   -> prometheus-operator tag -> the operator repo's example/prometheus-operator-crd/
# so a Renovate bump of the chart line is the only edit and there is no second
# pin to drift.
#
# `--server-side --force-conflicts --field-manager=mt-deploy-crds`: the live
# CRDs are owned by field manager `helm/Apply` from the first install, and
# server-side apply also sidesteps the client-side last-applied annotation
# (the Prometheus CRD alone is ~850 KB — far past the annotation limit). The
# field manager name makes this script's ownership visible in managedFields.
#
# Fail fast (CLAUDE.md "Fail Fast — Never Silently Skip"): every step returns
# non-zero and names the fix. All CRD manifests are downloaded and validated
# BEFORE the first apply, so a network failure leaves the cluster untouched —
# never a half-upgraded CRD set.

# Guard against double-sourcing
if [ "${_MT_PROMETHEUS_CRDS_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_PROMETHEUS_CRDS_LOADED=1

# The 10 CRDs shipped by prometheus-operator (upstream: kubectl apply --server-side
# -f example/prometheus-operator-crd/monitoring.coreos.com_<kind>.yaml).
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
MT_PROMETHEUS_CRD_BASE_URL="${MT_PROMETHEUS_CRD_BASE_URL:-https://raw.githubusercontent.com/prometheus-operator/prometheus-operator}"
MT_PROMETHEUS_CRD_FIELD_MANAGER="mt-deploy-crds"
MT_PROMETHEUS_CHART="prometheus-community/kube-prometheus-stack"
MT_PROMETHEUS_RELEASE="kube-prometheus-stack"
# The CRD whose controller-gen annotation is reported before/after (it is the
# largest and the one every chart major touches).
MT_PROMETHEUS_CRD_PROBE="prometheuses.monitoring.coreos.com"

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
# Renovate tracks the literal line, and a templated version has no CRD tag.
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
    print_error "Keep it a literal line: Renovate tracks it and the CRD tag is derived from it." >&2
    return 1
  fi
  printf '%s\n' "$versions"
}

# ---------------------------------------------------------------------------
# mt_prometheus_operator_version <chart version>
# Prints the chart's appVersion, i.e. the prometheus-operator tag (vX.Y.Z).
# Needs the prometheus-community repo added and updated (deploy_infra does
# both before this step runs).
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
    print_error "chart $MT_PROMETHEUS_CHART $chart_ver has no appVersion — cannot derive the prometheus-operator CRD tag" >&2
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
    *) print_error "unexpected kubectl output reading CRD $MT_PROMETHEUS_CRD_PROBE: $out"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _mt_prometheus_crd_file_ok <file> <kind>
# A 200 from a proxy/captive page or a redirect is still not a CRD: require
# the manifest to be the CustomResourceDefinition it claims to be.
# ---------------------------------------------------------------------------
_mt_prometheus_crd_file_ok() {
  local file="$1" kind="$2" got want
  want="CustomResourceDefinition $kind.monitoring.coreos.com"
  got=$(yq '.kind + " " + .metadata.name' "$file" 2>&1)
  if [ "$got" != "$want" ]; then
    print_error "downloaded $file is not the $kind CRD (expected '$want', got '$got')"
    print_error "The download completed but did not return the manifest — an error page or redirect? Aborting before any CRD is applied."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# mt_apply_prometheus_crds <helmfile.yaml.gotmpl>
# Resolve chart -> operator tag, download + validate all 10 CRDs, then
# server-side apply them. Prints the operator version and the probe CRD's
# controller-gen annotation before and after. Idempotent.
# ---------------------------------------------------------------------------
mt_apply_prometheus_crds() {
  local helmfile="${1:?mt_apply_prometheus_crds: path to helmfile.yaml.gotmpl required}"
  local tmp rc=0
  if [ -z "${KUBECONFIG:-}" ]; then
    print_error "mt_apply_prometheus_crds: KUBECONFIG is not set"
    return 1
  fi
  if ! tmp=$(mktemp -d); then
    print_error "mt_apply_prometheus_crds: mktemp -d failed"
    return 1
  fi
  # No `trap EXIT` here: deploy_infra's notification trap owns EXIT (see the
  # ses-credentials block there). The worker is called under `||`, which also
  # disables errexit inside it, so every step in it checks its own status.
  _mt_apply_prometheus_crds_in "$helmfile" "$tmp" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_mt_apply_prometheus_crds_in() {
  local helmfile="$1" tmp="$2"
  local chart_ver op_ver before after kind url file

  chart_ver=$(mt_prometheus_chart_version "$helmfile") || return 1
  op_ver=$(mt_prometheus_operator_version "$chart_ver") || return 1
  print_status "prometheus-operator CRDs: chart $MT_PROMETHEUS_CHART $chart_ver -> operator $op_ver"

  before=$(_mt_prometheus_crd_annotation) || return 1
  print_status "  $MT_PROMETHEUS_CRD_PROBE controller-gen before: $before"

  # Download + validate everything before touching the cluster.
  for kind in "${MT_PROMETHEUS_CRD_KINDS[@]}"; do
    url="$MT_PROMETHEUS_CRD_BASE_URL/$op_ver/example/prometheus-operator-crd/monitoring.coreos.com_$kind.yaml"
    file="$tmp/monitoring.coreos.com_$kind.yaml"
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 -o "$file" "$url"; then
      print_error "CRD download failed: $url"
      print_error "Aborting before any CRD is applied. Check that operator tag $op_ver exists upstream and that this host can reach raw.githubusercontent.com."
      return 1
    fi
    _mt_prometheus_crd_file_ok "$file" "$kind" || return 1
  done
  print_status "  downloaded and validated ${#MT_PROMETHEUS_CRD_KINDS[@]} CRD manifests for $op_ver"

  for kind in "${MT_PROMETHEUS_CRD_KINDS[@]}"; do
    file="$tmp/monitoring.coreos.com_$kind.yaml"
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
  print_success "prometheus-operator CRDs at $op_ver (server-side applied, field manager $MT_PROMETHEUS_CRD_FIELD_MANAGER)"
}
