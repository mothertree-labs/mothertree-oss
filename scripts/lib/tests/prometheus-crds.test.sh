#!/usr/bin/env bash
# Unit tests for scripts/lib/prometheus-crds.sh (mt_apply_prometheus_crds and
# its helpers): the prometheus-operator CRD pre-apply that deploy_infra runs
# before the tier=system helmfile sync. Runs against fake kubectl / helm
# binaries — no cluster, no network. The fake `helm pull --untar` lays out the
# chart tree from fixture files. Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../common.sh
source "$HERE/../common.sh"
# shellcheck source=../prometheus-crds.sh
source "$HERE/../prometheus-crds.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export MT_TEST_CALLS="$TMP/calls"
export MT_TEST_HELM_OUT="$TMP/helm_out" MT_TEST_HELM_RC="$TMP/helm_rc"
export MT_TEST_PULL_RC="$TMP/pull_rc" MT_TEST_PULL_KINDS="$TMP/pull_kinds" MT_TEST_PULL_BAD="$TMP/pull_bad"
export MT_TEST_GET_RC="$TMP/get_rc" MT_TEST_GET_BEFORE="$TMP/get_before" MT_TEST_GET_AFTER="$TMP/get_after"
export MT_TEST_APPLY_RC="$TMP/apply_rc" MT_TEST_APPLIED_NAMES="$TMP/applied_names"
export KUBECONFIG="$TMP/kubeconfig.fake"
: > "$KUBECONFIG"

# --- fakes -------------------------------------------------------------------
# kubectl: `get crd` answers "before" until the first server-side apply has
# been recorded, "after" from then on; `apply --server-side` records the
# metadata.name of the file it was given (proves a real file was passed).
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" get crd "*)
        [ "$(cat "$MT_TEST_GET_RC")" = 0 ] || { echo "Unable to connect to the server: dial tcp: connection refused" >&2; exit 1; }
        if grep -q 'apply --server-side' "$MT_TEST_CALLS"; then cat "$MT_TEST_GET_AFTER"; else cat "$MT_TEST_GET_BEFORE"; fi
        exit 0 ;;
    *" apply --server-side "*)
        f=""; while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
        [ -s "$f" ] || { echo "fake-kubectl: -f file missing or empty: $f" >&2; exit 98; }
        [ "$(cat "$MT_TEST_APPLY_RC")" = 0 ] || { echo "error: Apply failed with 1 conflict" >&2; exit 1; }
        n=$(yq '.metadata.name' "$f"); echo "$n" >> "$MT_TEST_APPLIED_NAMES"
        echo "customresourcedefinition.apiextensions.k8s.io/$n serverside-applied"; exit 0 ;;
esac
echo "fake-kubectl: unscripted call: $*" >&2; exit 99
FAKE
# helm: `show chart` prints the scripted Chart.yaml; `pull --untar --untardir D`
# lays out D/kube-prometheus-stack/charts/crds/crds/crd-<kind>.yaml for every
# kind listed in MT_TEST_PULL_KINDS (one per line; a kind suffixed ":bad" gets
# a manifest whose kind/name do not match), refusing a non-empty untardir the
# way real helm does.
cat > "$TMP/bin/helm" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "helm $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" show chart "*) cat "$MT_TEST_HELM_OUT"; exit "$(cat "$MT_TEST_HELM_RC")" ;;
    *" pull "*)
        d=""; while [ $# -gt 0 ]; do [ "$1" = "--untardir" ] && d="$2"; shift; done
        [ -n "$d" ] || { echo "fake-helm: --untardir missing" >&2; exit 98; }
        [ "$(cat "$MT_TEST_PULL_RC")" = 0 ] || { echo 'Error: chart "kube-prometheus-stack" matching 91.4.0 not found in prometheus-community index. (try '"'"'helm repo update'"'"')' >&2; exit 1; }
        [ -e "$d/kube-prometheus-stack" ] && { echo "Error: failed to untar: a file or directory with the name $d/kube-prometheus-stack already exists" >&2; exit 1; }
        crd="$d/kube-prometheus-stack/charts/crds/crds"; mkdir -p "$crd"
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            case "$k" in
                *:bad) k="${k%:bad}"; printf '# fixture\napiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: somethingelse.monitoring.coreos.com\n' > "$crd/crd-$k.yaml" ;;
                *)     printf '# https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.94.0/example/prometheus-operator-crd/monitoring.coreos.com_%s.yaml\napiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: %s.monitoring.coreos.com\n  annotations:\n    controller-gen.kubebuilder.io/version: v0.22.0\n' "$k" "$k" > "$crd/crd-$k.yaml" ;;
            esac
        done < "$MT_TEST_PULL_KINDS"
        exit 0 ;;
esac
echo "fake-helm: unscripted call: $*" >&2; exit 99
FAKE
chmod +x "$TMP/bin/kubectl" "$TMP/bin/helm"
export PATH="$TMP/bin:$PATH"

# A helmfile fixture with the same shape as apps/helmfile.yaml.gotmpl
# (Go-templated namespace, two releases, literal version pin).
HELMFILE="$TMP/helmfile.yaml.gotmpl"
cat > "$HELMFILE" <<'HF'
environments:
  dev: {}
---
releases:
  - name: ingress-nginx
    namespace: {{ requiredEnv "NS_INGRESS" }}
    chart: ingress-nginx/ingress-nginx
    version: 4.14.3
  - name: kube-prometheus-stack
    namespace: {{ requiredEnv "NS_MONITORING" }}
    chart: prometheus-community/kube-prometheus-stack
    version: 91.4.0
    needs:
      - {{ requiredEnv "NS_INGRESS" }}/ingress-nginx
    values:
      - environments/{{ .Environment.Name }}/prometheus.yaml.gotmpl
HF

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}
contains() {  # contains <description> <needle> <haystack>
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); echo "FAIL: $1: [$2] not in: $3" ;; esac
}
EXPECTED_KINDS="alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers"
scenario() {  # reset to the happy path: 91.4.0 chart with all 10 CRDs, CRD absent before, present after
    : > "$MT_TEST_CALLS"; : > "$MT_TEST_APPLIED_NAMES"
    printf 'apiVersion: v2\nappVersion: v0.94.0\nname: kube-prometheus-stack\nversion: 91.4.0\n' > "$MT_TEST_HELM_OUT"
    echo 0 > "$MT_TEST_HELM_RC"; echo 0 > "$MT_TEST_PULL_RC"
    printf '%s\n' $EXPECTED_KINDS > "$MT_TEST_PULL_KINDS"
    echo 0 > "$MT_TEST_GET_RC"; : > "$MT_TEST_GET_BEFORE"
    printf 'prometheuses.monitoring.coreos.com\tv0.22.0' > "$MT_TEST_GET_AFTER"
    echo 0 > "$MT_TEST_APPLY_RC"
    rm -rf "$TMP/mktmp"; mkdir -p "$TMP/mktmp"
}
count_calls() { grep -c -- "$1" "$MT_TEST_CALLS" || true; }
run() { TMPDIR="$TMP/mktmp" mt_apply_prometheus_crds "$@"; }   # every run gets its own TMPDIR to prove cleanup

# --- chart version reader ---------------------------------------------------
check "reads the literal pin through the Go templates" "91.4.0" "$(mt_prometheus_chart_version "$HELMFILE" 2>/dev/null)"
out=$(mt_prometheus_chart_version "$TMP/nope.yaml" 2>&1); rc=$?
check "missing helmfile: rc" 1 "$rc"; contains "missing helmfile: names the path" "$TMP/nope.yaml" "$out"
sed 's/name: kube-prometheus-stack/name: something-else/' "$HELMFILE" > "$TMP/hf-none.yaml"
out=$(mt_prometheus_chart_version "$TMP/hf-none.yaml" 2>&1); rc=$?
check "no such release: rc" 1 "$rc"; contains "no such release: says found 0" "found 0" "$out"
{ cat "$HELMFILE"; printf '  - name: kube-prometheus-stack\n    chart: x/y\n    version: 1.2.3\n'; } > "$TMP/hf-two.yaml"
out=$(mt_prometheus_chart_version "$TMP/hf-two.yaml" 2>&1); rc=$?
check "duplicate release: rc" 1 "$rc"; contains "duplicate release: says found 2" "found 2" "$out"
sed 's/version: 91.4.0/version: {{ .Values.kpsVersion }}/' "$HELMFILE" > "$TMP/hf-tpl.yaml"
out=$(mt_prometheus_chart_version "$TMP/hf-tpl.yaml" 2>&1); rc=$?
check "templated version: rc" 1 "$rc"; contains "templated version: names the problem" "not a plain X.Y.Z literal" "$out"
# The real helmfile must stay readable by this parser (a refactor to
# control-flow templates would otherwise only surface as a failed deploy).
real=$(mt_prometheus_chart_version "$REPO_ROOT/apps/helmfile.yaml.gotmpl" 2>&1); rc=$?
check "real apps/helmfile.yaml.gotmpl: rc" 0 "$rc"
case "$real" in [0-9]*.[0-9]*.[0-9]*) check "real helmfile: semver pin" y y ;; *) check "real helmfile: semver pin" y "n: $real" ;; esac

# --- operator version (log line) --------------------------------------------
scenario
check "appVersion resolved" "v0.94.0" "$(mt_prometheus_operator_version 91.4.0 2>/dev/null)"
contains "helm asked for the pinned chart version" "helm show chart prometheus-community/kube-prometheus-stack --version 91.4.0" "$(cat "$MT_TEST_CALLS")"
scenario; printf 'apiVersion: v2\nname: kube-prometheus-stack\nversion: 91.4.0\n' > "$MT_TEST_HELM_OUT"
out=$(mt_prometheus_operator_version 91.4.0 2>&1); rc=$?
check "empty appVersion: rc" 1 "$rc"; contains "empty appVersion: names the problem" "has no appVersion" "$out"
scenario; printf 'appVersion: ""\n' > "$MT_TEST_HELM_OUT"
out=$(mt_prometheus_operator_version 91.4.0 2>&1); rc=$?
check "blank appVersion: rc" 1 "$rc"
scenario; printf 'appVersion: 0.94.0\n' > "$MT_TEST_HELM_OUT"
out=$(mt_prometheus_operator_version 91.4.0 2>&1); rc=$?
check "appVersion without v prefix: rc" 1 "$rc"; contains "appVersion without v: names it" "not a vX.Y.Z" "$out"
scenario; echo 1 > "$MT_TEST_HELM_RC"; echo 'Error: chart "kube-prometheus-stack" version "91.4.0" not found' > "$MT_TEST_HELM_OUT"
out=$(mt_prometheus_operator_version 91.4.0 2>&1); rc=$?
check "helm failure: rc" 1 "$rc"; contains "helm failure: shows helm's error" "not found" "$out"

# --- happy path: pull once, then 10 server-side applies ---------------------
scenario
out=$(run "$HELMFILE" 2>&1); rc=$?
check "happy: rc" 0 "$rc"
check "happy: one helm pull of the pinned chart" 1 "$(count_calls 'helm pull prometheus-community/kube-prometheus-stack --version 91.4.0 --untar --untardir ')"
contains "happy: pull lands in an mt-prom-crds.* dir under TMPDIR" "--untardir $TMP/mktmp/mt-prom-crds." "$(cat "$MT_TEST_CALLS")"
check "happy: 10 server-side applies" 10 "$(count_calls 'kubectl apply --server-side --force-conflicts --field-manager=mt-deploy-crds -f ')"
check "happy: applies read the chart's crds subchart files" 10 "$(count_calls '/kube-prometheus-stack/charts/crds/crds/crd-')"
check "happy: every CRD applied, in order" "$EXPECTED_KINDS" "$(sed 's/\.monitoring\.coreos\.com$//' "$MT_TEST_APPLIED_NAMES" | tr '\n' ' ' | sed 's/ $//')"
contains "happy: prints operator version" "(operator v0.94.0)" "$out"
contains "happy: prints before (absent on a cold cluster is not an error)" "controller-gen before: absent" "$out"
contains "happy: prints after" "controller-gen after:  v0.22.0" "$out"
first_apply=$(grep -n 'kubectl apply' "$MT_TEST_CALLS" | head -1 | cut -d: -f1)
pull_line=$(grep -n '^helm pull' "$MT_TEST_CALLS" | tail -1 | cut -d: -f1)
if [ "$pull_line" -lt "$first_apply" ]; then check "happy: pull before any apply" y y; else check "happy: pull before any apply" y "n (pull line $pull_line, first apply line $first_apply)"; fi
check "happy: temp dir removed afterwards" "" "$(ls -A "$TMP/mktmp")"
check "happy: cleanup variable reset" "" "$_MT_PROM_CRDS_TMPDIR"

# --- warm cluster: before shows the live annotation ------------------------
scenario; printf 'prometheuses.monitoring.coreos.com\tv0.13.0' > "$MT_TEST_GET_BEFORE"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "warm: rc" 0 "$rc"
contains "warm: before is the live version" "controller-gen before: v0.13.0" "$out"
contains "warm: after advanced" "controller-gen after:  v0.22.0" "$out"

# --- helm pull failure aborts before any apply -----------------------------
scenario; echo 1 > "$MT_TEST_PULL_RC"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "pull fails: rc" 1 "$rc"
check "pull fails: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "pull fails: shows helm's error" "not found in prometheus-community index" "$out"
contains "pull fails: says nothing was applied" "before any CRD is applied" "$out"
check "pull fails: temp dir removed on the failure path" "" "$(ls -A "$TMP/mktmp")"

# --- chart missing one expected kind: fail before any apply -----------------
scenario; grep -v '^probes$' "$MT_TEST_PULL_KINDS" > "$MT_TEST_PULL_KINDS.tmp" && mv "$MT_TEST_PULL_KINDS.tmp" "$MT_TEST_PULL_KINDS"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "missing kind: rc" 1 "$rc"
check "missing kind: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "missing kind: names it" "ships no CRD file for probes" "$out"
contains "missing kind: names the list to fix" "MT_PROMETHEUS_CRD_KINDS" "$out"

# --- chart ships an extra kind the list does not know: fail before any apply -
scenario; echo "newkinds" >> "$MT_TEST_PULL_KINDS"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "extra kind: rc" 1 "$rc"
check "extra kind: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "extra kind: names it" "ships CRDs not in MT_PROMETHEUS_CRD_KINDS: newkinds" "$out"

# --- a file whose kind/name is not the CRD it should be --------------------
scenario; sed -i.bak 's/^prometheuses$/prometheuses:bad/' "$MT_TEST_PULL_KINDS"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "wrong name: rc" 1 "$rc"
check "wrong name: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "wrong name: names the CRD" "is not the prometheuses CRD" "$out"

# --- empty appVersion: no pull, no apply ------------------------------------
scenario; printf 'apiVersion: v2\nname: kube-prometheus-stack\nversion: 91.4.0\n' > "$MT_TEST_HELM_OUT"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "no appVersion: rc" 1 "$rc"
check "no appVersion: zero pulls" 0 "$(count_calls '^helm pull')"
check "no appVersion: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "no appVersion: reason reaches the deploy log" "has no appVersion" "$out"

# --- unreadable helmfile: nothing else runs ---------------------------------
scenario
out=$(run "$TMP/hf-two.yaml" 2>&1); rc=$?
check "ambiguous pin: rc" 1 "$rc"
check "ambiguous pin: helm never called" 0 "$(count_calls '^helm ')"
contains "ambiguous pin: reason reaches the deploy log" "found 2" "$out"

# --- kubectl get failure (API unreachable) is fatal, not "absent" ----------
scenario; echo 1 > "$MT_TEST_GET_RC"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "get crd fails: rc" 1 "$rc"
check "get crd fails: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "get crd fails: refuses to guess" "refusing to guess the CRD state" "$out"

# --- kubectl get returns something unrecognisable: fatal, reason logged ----
scenario; printf 'somethingelse.monitoring.coreos.com\tv0.22.0' > "$MT_TEST_GET_BEFORE"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "unexpected get output: rc" 1 "$rc"
check "unexpected get output: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "unexpected get output: reason reaches the deploy log" "unexpected kubectl output reading CRD" "$out"

# --- apply failure stops the run ------------------------------------------
scenario; echo 1 > "$MT_TEST_APPLY_RC"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "apply fails: rc" 1 "$rc"
check "apply fails: stopped at the first" 1 "$(count_calls 'kubectl apply')"
contains "apply fails: says helmfile did not run" "helmfile sync did not run" "$out"
check "apply fails: temp dir removed" "" "$(ls -A "$TMP/mktmp")"

# --- CRD still absent after apply is an error ------------------------------
scenario; : > "$MT_TEST_GET_AFTER"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "absent after apply: rc" 1 "$rc"
contains "absent after apply: explains" "is 'absent' after a successful apply" "$out"

# --- stale dirs from a SIGKILLed run are swept, a fresh one is left alone --
scenario; mkdir -p "$TMP/mktmp/mt-prom-crds.stale" "$TMP/mktmp/mt-prom-crds.fresh"
touch -t 202001010000 "$TMP/mktmp/mt-prom-crds.stale"
out=$(run "$HELMFILE" 2>&1); rc=$?
check "sweep: rc" 0 "$rc"
check "sweep: only the fresh dir survives" "mt-prom-crds.fresh" "$(ls -A "$TMP/mktmp")"

# --- EXIT handler hook: notify.sh removes the dir this process created -----
scenario
out=$(TMPDIR="$TMP/mktmp" bash -c "
  source '$HERE/../common.sh'; source '$HERE/../prometheus-crds.sh'
  MT_NOTIFY_HOMESERVER= MT_NOTIFY_TOKEN= MT_NOTIFY_ROOM_ID= source '$HERE/../notify.sh'
  _MT_DEPLOY_SCRIPT_NAME=t; _MT_DEPLOY_CONTEXT=t; trap _mt_deploy_exit_handler EXIT
  _MT_PROM_CRDS_TMPDIR=\$(mktemp -d \"\$TMPDIR/mt-prom-crds.XXXXXX\")
  echo \"created \$_MT_PROM_CRDS_TMPDIR\"
  kill -TERM \$\$; sleep 1" 2>&1); rc=$?
contains "exit hook: dir was created" "created $TMP/mktmp/mt-prom-crds." "$out"
check "exit hook: SIGTERM'd script left no dir behind" "" "$(ls -A "$TMP/mktmp")"

# --- KUBECONFIG unset is refused ------------------------------------------
scenario
out=$(env -u KUBECONFIG bash -c "source '$HERE/../common.sh'; source '$HERE/../prometheus-crds.sh'; mt_apply_prometheus_crds '$HELMFILE'" 2>&1); rc=$?
check "no KUBECONFIG: rc" 1 "$rc"; contains "no KUBECONFIG: says so" "KUBECONFIG is not set" "$out"

echo "prometheus-crds: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
