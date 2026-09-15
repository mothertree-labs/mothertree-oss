#!/usr/bin/env bash
# Unit tests for scripts/lib/prometheus-crds.sh (mt_apply_prometheus_crds and
# its helpers): the prometheus-operator CRD pre-apply that deploy_infra runs
# before the tier=system helmfile sync. Runs against fake kubectl / helm / curl
# binaries — no cluster, no network. Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../common.sh
source "$HERE/../common.sh"
# shellcheck source=../prometheus-crds.sh
source "$HERE/../prometheus-crds.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export MT_TEST_CALLS="$TMP/calls" MT_TEST_URLS="$TMP/urls"
export MT_TEST_HELM_OUT="$TMP/helm_out" MT_TEST_HELM_RC="$TMP/helm_rc"
export MT_TEST_CURL_FAIL_ON="$TMP/curl_fail_on" MT_TEST_CURL_BODY="$TMP/curl_body"
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
cat > "$TMP/bin/helm" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "helm $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" show chart "*) cat "$MT_TEST_HELM_OUT"; exit "$(cat "$MT_TEST_HELM_RC")" ;;
esac
echo "fake-helm: unscripted call: $*" >&2; exit 99
FAKE
# curl: writes a minimal CRD named after the URL's file (or an HTML page when
# scripted); fails with curl's HTTP-error exit code when the URL contains the
# scripted substring.
cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "curl $*" >> "$MT_TEST_CALLS"
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; http*) url="$1" ;; esac; shift; done
echo "$url" >> "$MT_TEST_URLS"
fail_on=$(cat "$MT_TEST_CURL_FAIL_ON")
if [ -n "$fail_on" ] && [[ "$url" == *"$fail_on"* ]]; then
    echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
fi
base="${url##*/}"; kind="${base#monitoring.coreos.com_}"; kind="${kind%.yaml}"
if [ "$(cat "$MT_TEST_CURL_BODY")" = html ]; then
    printf '<html><body>rate limited</body></html>\n' > "$out"
else
    printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: %s.monitoring.coreos.com\n  annotations:\n    controller-gen.kubebuilder.io/version: v0.22.0\n' "$kind" > "$out"
fi
exit 0
FAKE
chmod +x "$TMP/bin/kubectl" "$TMP/bin/helm" "$TMP/bin/curl"
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
scenario() {  # reset to the happy path: v0.94.0 chart, CRD absent before, present after
    : > "$MT_TEST_CALLS"; : > "$MT_TEST_URLS"; : > "$MT_TEST_APPLIED_NAMES"
    printf 'apiVersion: v2\nappVersion: v0.94.0\nname: kube-prometheus-stack\nversion: 91.4.0\n' > "$MT_TEST_HELM_OUT"
    echo 0 > "$MT_TEST_HELM_RC"; : > "$MT_TEST_CURL_FAIL_ON"; echo crd > "$MT_TEST_CURL_BODY"
    echo 0 > "$MT_TEST_GET_RC"; : > "$MT_TEST_GET_BEFORE"
    printf 'prometheuses.monitoring.coreos.com\tv0.22.0' > "$MT_TEST_GET_AFTER"
    echo 0 > "$MT_TEST_APPLY_RC"
}
count_calls() { grep -c -- "$1" "$MT_TEST_CALLS" || true; }
EXPECTED_KINDS="alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers"

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

# --- operator version resolver ----------------------------------------------
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

# --- happy path: 10 downloads, then 10 server-side applies ------------------
scenario; mkdir -p "$TMP/mktmp"
out=$(TMPDIR="$TMP/mktmp" mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "happy: rc" 0 "$rc"
check "happy: 10 server-side applies" 10 "$(count_calls 'kubectl apply --server-side --force-conflicts --field-manager=mt-deploy-crds -f ')"
check "happy: 10 downloads" 10 "$(wc -l < "$MT_TEST_URLS" | tr -d ' ')"
check "happy: every CRD applied, in order" "$EXPECTED_KINDS" "$(sed 's/\.monitoring\.coreos\.com$//' "$MT_TEST_APPLIED_NAMES" | tr '\n' ' ' | sed 's/ $//')"
check "happy: URLs use the operator tag from appVersion" 10 "$(grep -c '/prometheus-operator/prometheus-operator/v0.94.0/example/prometheus-operator-crd/monitoring.coreos.com_' "$MT_TEST_URLS")"
contains "happy: prints operator version" "operator v0.94.0" "$out"
contains "happy: prints before (absent on a cold cluster is not an error)" "controller-gen before: absent" "$out"
contains "happy: prints after" "controller-gen after:  v0.22.0" "$out"
# all downloads precede the first apply
first_apply=$(grep -n 'kubectl apply' "$MT_TEST_CALLS" | head -1 | cut -d: -f1)
last_curl=$(grep -n '^curl ' "$MT_TEST_CALLS" | tail -1 | cut -d: -f1)
[ "$last_curl" -lt "$first_apply" ] && check "happy: all downloads before any apply" y y || check "happy: all downloads before any apply" y "n (last curl line $last_curl, first apply line $first_apply)"
check "happy: download dir removed afterwards" "" "$(ls -A "$TMP/mktmp")"

# --- warm cluster: before shows the live annotation ------------------------
scenario; printf 'prometheuses.monitoring.coreos.com\tv0.13.0' > "$MT_TEST_GET_BEFORE"
out=$(mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "warm: rc" 0 "$rc"
contains "warm: before is the live version" "controller-gen before: v0.13.0" "$out"
contains "warm: after advanced" "controller-gen after:  v0.22.0" "$out"

# --- curl failure aborts before any apply ----------------------------------
scenario; echo "monitoring.coreos.com_probes.yaml" > "$MT_TEST_CURL_FAIL_ON"; rm -rf "$TMP/mktmp"; mkdir -p "$TMP/mktmp"
out=$(TMPDIR="$TMP/mktmp" mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "curl fails: rc" 1 "$rc"
check "curl fails: download dir removed on the failure path" "" "$(ls -A "$TMP/mktmp")"
check "curl fails: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "curl fails: names the URL" "/v0.94.0/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml" "$out"
contains "curl fails: says nothing was applied" "before any CRD is applied" "$out"

# --- a 200 that is not a CRD (error page) aborts before any apply ----------
scenario; echo html > "$MT_TEST_CURL_BODY"
out=$(mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "html body: rc" 1 "$rc"
check "html body: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "html body: names the CRD" "is not the alertmanagerconfigs CRD" "$out"

# --- empty appVersion: no download, no apply --------------------------------
scenario; printf 'apiVersion: v2\nname: kube-prometheus-stack\nversion: 91.4.0\n' > "$MT_TEST_HELM_OUT"
out=$(mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "no appVersion: rc" 1 "$rc"
check "no appVersion: zero downloads" 0 "$(count_calls '^curl ')"
check "no appVersion: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "no appVersion: reason reaches the deploy log" "has no appVersion" "$out"

# --- unreadable helmfile: nothing else runs ---------------------------------
scenario
out=$(mt_apply_prometheus_crds "$TMP/hf-two.yaml" 2>&1); rc=$?
check "ambiguous pin: rc" 1 "$rc"
check "ambiguous pin: helm never called" 0 "$(count_calls '^helm ')"
contains "ambiguous pin: reason reaches the deploy log" "found 2" "$out"

# --- kubectl get failure (API unreachable) is fatal, not "absent" ----------
scenario; echo 1 > "$MT_TEST_GET_RC"
out=$(mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "get crd fails: rc" 1 "$rc"
check "get crd fails: zero applies" 0 "$(count_calls 'kubectl apply')"
contains "get crd fails: refuses to guess" "refusing to guess the CRD state" "$out"

# --- apply failure stops the run ------------------------------------------
scenario; echo 1 > "$MT_TEST_APPLY_RC"
out=$(mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "apply fails: rc" 1 "$rc"
check "apply fails: stopped at the first" 1 "$(count_calls 'kubectl apply')"
contains "apply fails: says helmfile did not run" "helmfile sync did not run" "$out"

# --- CRD still absent after apply is an error ------------------------------
scenario; : > "$MT_TEST_GET_AFTER"
out=$(mt_apply_prometheus_crds "$HELMFILE" 2>&1); rc=$?
check "absent after apply: rc" 1 "$rc"
contains "absent after apply: explains" "is 'absent' after a successful apply" "$out"

# --- KUBECONFIG unset is refused ------------------------------------------
scenario
out=$(env -u KUBECONFIG bash -c "source '$HERE/../common.sh'; source '$HERE/../prometheus-crds.sh'; mt_apply_prometheus_crds '$HELMFILE'" 2>&1); rc=$?
check "no KUBECONFIG: rc" 1 "$rc"; contains "no KUBECONFIG: says so" "KUBECONFIG is not set" "$out"

echo "prometheus-crds: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
