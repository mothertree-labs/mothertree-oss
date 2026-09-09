#!/usr/bin/env bash
# Unit tests for scripts/lib/nextcloud-db.sh (issue #548): the schema probe,
# the verified drop, and the cold-start orphan guard that deploy-nextcloud.sh
# runs when the tenant has no nextcloud-identity Secret. The Job transport
# (mt_probe_job) is replaced by a scripted fake so every verdict path — and
# every "no verdict" path — is exercised without a cluster. Invoked by
# ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "$HERE/../common.sh"
# shellcheck source=../nextcloud-db.sh
source "$HERE/../nextcloud-db.sh"

export MT_PROBE_BACKOFF_BASE=0 MT_PROBE_POLL_INTERVAL=0
export NS_DB="infra-db"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}

# --- fake transport ----------------------------------------------------------
# Each call to mt_probe_job consumes the next entry of the scripted queue and
# prints the canned output it names. mt_kubectl_probe runs the transport inside
# $(...), i.e. in a subshell, so the fake keeps its state in files: the job
# prefix (nc-schema-probe / nc-drop) and the NC_DB env of every call are
# appended to $CALLS_FILE so tests can assert what ran, in what order, against
# which database.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CALLS_FILE="$TMP/calls"; QUEUE_FILE="$TMP/queue"; POS_FILE="$TMP/pos"
reset() { : > "$CALLS_FILE"; printf '%s\n' "$@" > "$QUEUE_FILE"; echo 0 > "$POS_FILE"; }
mt_probe_job() {
    local ns="$1" prefix="$2" db=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            --env) case "$2" in NC_DB=*) db="${2#NC_DB=}" ;; esac; shift 2 ;;
            --env-from-secret|--timeout) shift 2 ;;
            --) break ;;
            *) shift ;;
        esac
    done
    printf '%s/%s:%s\n' "$ns" "$prefix" "$db" >> "$CALLS_FILE"
    local pos step
    pos=$(cat "$POS_FILE"); echo $((pos + 1)) > "$POS_FILE"
    step=$(sed -n "$((pos + 1))p" "$QUEUE_FILE"); step="${step:-lost}"
    case "$step" in
        present)  printf 'MT_PROBE_DETAIL=db=1 schema=1\nMT_PROBE_VERDICT=OK\n' ;;
        empty)    printf 'MT_PROBE_DETAIL=db=1 schema=0\nMT_PROBE_VERDICT=MISSING\n' ;;
        absent)   printf 'MT_PROBE_DETAIL=db=0 schema=0\nMT_PROBE_VERDICT=MISSING\n' ;;
        drop-ok)  printf 'DROP DATABASE\nMT_PROBE_VERDICT=OK\n' ;;
        drop-fail) printf 'ERROR:  database "x" is being accessed by other users\nMT_PROBE_VERDICT=FAIL\n' ;;
        lost)     printf '[mt_probe_job: job/x in %s reached no terminal condition within 180s]\n' "$ns" ;;
        conn-fail) printf 'nc-schema-probe: catalog query failed\n' ;;   # script ran, psql could not connect: no sentinel
    esac
    return 0
}
calls() { grep -c . "$CALLS_FILE" || true; }
seq_calls() { tr '\n' ' ' < "$CALLS_FILE"; }

# --- mt_nc_db_name_ok ---------------------------------------------------------
mt_nc_db_name_ok nextcloud_mothertree; check "plain tenant name ok" 0 "$?"
mt_nc_db_name_ok nextcloud_acme-corp_2; check "hyphen/digits ok" 0 "$?"
mt_nc_db_name_ok roundcube_mothertree; check "other prefix refused" 1 "$?"
mt_nc_db_name_ok 'nextcloud_x"; DROP DATABASE postgres; --'; check "injection refused" 1 "$?"
mt_nc_db_name_ok nextcloud_; check "empty tenant refused" 1 "$?"
mt_nc_db_name_ok ""; check "empty name refused" 1 "$?"

# --- mt_nc_schema_probe -------------------------------------------------------
reset present
mt_nc_schema_probe nextcloud_t >/dev/null; rc=$?
check "present -> 0" 0 "$rc"; check "present detail" "db=1 schema=1" "$MT_PROBE_DETAIL"
check "present one call" 1 "$(calls)"
check "probe runs in NS_DB with the db in env" "infra-db/nc-schema-probe:nextcloud_t " "$(seq_calls)"

reset absent
mt_nc_schema_probe nextcloud_t >/dev/null; rc=$?
check "absent -> 1" 1 "$rc"; check "absent detail" "db=0 schema=0" "$MT_PROBE_DETAIL"

reset empty
mt_nc_schema_probe nextcloud_t >/dev/null; rc=$?
check "db without schema -> 1" 1 "$rc"; check "empty detail" "db=1 schema=0" "$MT_PROBE_DETAIL"

reset lost lost lost
mt_nc_schema_probe nextcloud_t >/dev/null 2>&1; rc=$?
check "lost x3 -> 2 (UNKNOWN)" 2 "$rc"; check "lost retried 3x" 3 "$(calls)"
check "lost verdict" UNKNOWN "$MT_PROBE_VERDICT"

reset conn-fail conn-fail present
mt_nc_schema_probe nextcloud_t >/dev/null 2>&1; rc=$?
check "connect failures then answer -> 0" 0 "$rc"; check "retried until verdict" 3 "$(calls)"

reset present
mt_nc_schema_probe 'nextcloud_x;drop' >/dev/null 2>&1; rc=$?
check "bad name -> 2 without running a Job" 2 "$rc"; check "bad name no call" 0 "$(calls)"

# --- mt_nc_drop_db_verified ---------------------------------------------------
reset drop-ok absent
mt_nc_drop_db_verified nextcloud_t >/dev/null 2>&1; rc=$?
check "drop then verified absent -> 0" 0 "$rc"
check "drop then probe, in order" "infra-db/nc-drop:nextcloud_t infra-db/nc-schema-probe:nextcloud_t " "$(seq_calls)"

reset drop-fail drop-fail
mt_nc_drop_db_verified nextcloud_t >/dev/null 2>&1; rc=$?
check "drop FAIL -> 1" 1 "$rc"; check "drop FAIL is definitive, no retry, no probe" 1 "$(calls)"

reset lost lost
mt_nc_drop_db_verified nextcloud_t >/dev/null 2>&1; rc=$?
check "drop lost x2 -> 1" 1 "$rc"; check "drop lost retried twice, no probe" 2 "$(calls)"

reset drop-ok present
mt_nc_drop_db_verified nextcloud_t >/dev/null 2>&1; rc=$?
check "drop OK but DB still present -> 1" 1 "$rc"

reset drop-ok empty
mt_nc_drop_db_verified nextcloud_t >/dev/null 2>&1; rc=$?
check "drop OK but DB still in catalog (schema=0) -> 1" 1 "$rc"

reset drop-ok lost lost lost
mt_nc_drop_db_verified nextcloud_t >/dev/null 2>&1; rc=$?
check "drop OK but verification lost -> 1" 1 "$rc"

reset drop-ok absent
mt_nc_drop_db_verified 'nextcloud_x;drop' >/dev/null 2>&1; rc=$?
check "bad name never reaches DROP" 1 "$rc"; check "bad name no call (drop)" 0 "$(calls)"

# --- mt_nc_cold_start_guard ---------------------------------------------------
reset absent
mt_nc_cold_start_guard nextcloud_t dev t >/dev/null 2>&1; rc=$?
check "dev, DB absent -> proceed" 0 "$rc"; check "action clean" clean "$MT_NC_COLD_START_ACTION"
check "clean: probe only" 1 "$(calls)"

reset empty
mt_nc_cold_start_guard nextcloud_t dev t >/dev/null 2>&1; rc=$?
check "dev, DB present but no schema -> proceed (db-init owns it)" 0 "$rc"
check "action clean (empty db)" clean "$MT_NC_COLD_START_ACTION"

reset present drop-ok absent
mt_nc_cold_start_guard nextcloud_t dev t >/dev/null 2>&1; rc=$?
check "dev, orphan -> dropped, proceed" 0 "$rc"; check "action dropped" dropped "$MT_NC_COLD_START_ACTION"
check "orphan: probe, drop, verify" "infra-db/nc-schema-probe:nextcloud_t infra-db/nc-drop:nextcloud_t infra-db/nc-schema-probe:nextcloud_t " "$(seq_calls)"

reset present drop-fail drop-fail
mt_nc_cold_start_guard nextcloud_t dev t >/dev/null 2>&1; rc=$?
check "dev, orphan, drop fails -> abort" 1 "$rc"; check "action stays unknown on failed drop" unknown "$MT_NC_COLD_START_ACTION"

reset present drop-ok present
mt_nc_cold_start_guard nextcloud_t dev t >/dev/null 2>&1; rc=$?
check "dev, orphan, drop unverified -> abort" 1 "$rc"

reset present
mt_nc_cold_start_guard nextcloud_t prod t >/dev/null 2>&1; rc=$?
check "prod, orphan -> refuse" 1 "$rc"; check "action refused" refused "$MT_NC_COLD_START_ACTION"
check "prod never drops" 1 "$(calls)"
case "$(seq_calls)" in *nc-drop*) check "prod no drop call" none drop ;; *) check "prod no drop call" none none ;; esac

reset present
mt_nc_cold_start_guard nextcloud_t prod-eu t >/dev/null 2>&1; rc=$?
check "prod-eu, orphan -> refuse" 1 "$rc"; check "prod-eu never drops" 1 "$(calls)"

reset absent
mt_nc_cold_start_guard nextcloud_t prod t >/dev/null 2>&1; rc=$?
check "prod, DB absent -> proceed" 0 "$rc"

reset lost lost lost
mt_nc_cold_start_guard nextcloud_t dev t >/dev/null 2>&1; rc=$?
check "dev, UNKNOWN -> fail closed" 1 "$rc"; check "action unknown" unknown "$MT_NC_COLD_START_ACTION"
check "unknown: 3 probes, no drop" 3 "$(calls)"
case "$(seq_calls)" in *nc-drop*) check "unknown no drop call" none drop ;; *) check "unknown no drop call" none none ;; esac

reset lost lost present drop-ok absent
mt_nc_cold_start_guard nextcloud_t dev t >/dev/null 2>&1; rc=$?
check "dev, verdict on 3rd attempt -> acts on it" 0 "$rc"; check "late verdict action" dropped "$MT_NC_COLD_START_ACTION"

reset present drop-ok absent
mt_nc_cold_start_guard nextcloud_other dev t >/dev/null 2>&1; rc=$?
check "dev, orphan but DB is not this tenant's by convention -> refuse" 1 "$rc"
check "mismatch action refused" refused "$MT_NC_COLD_START_ACTION"
check "mismatch: probe only, never drop" 1 "$(calls)"

reset absent
mt_nc_cold_start_guard nextcloud_other dev t >/dev/null 2>&1; rc=$?
check "dev, DB absent, mismatched name -> still a clean cold start (nothing to drop)" 0 "$rc"

# --- mt_nc_k8s_state (fake kubectl as a function) ------------------------------
kubectl() {
    printf 'kubectl %s\n' "$*" >> "$CALLS_FILE"
    case "$K8S_SCENARIO" in
        present)   echo "secret/nextcloud-identity" ;;
        notfound)  echo 'Error from server (NotFound): secrets "nextcloud-identity" not found' >&2; return 1 ;;
        ns_missing) echo 'Error from server (NotFound): namespaces "tn-t-files" not found' >&2; return 1 ;;
        refused)   echo 'The connection to the server 1.2.3.4:443 was refused - did you specify the right host or port?' >&2; return 1 ;;
        timeout)   echo 'Unable to connect to the server: dial tcp 1.2.3.4:443: i/o timeout' >&2; return 1 ;;
        forbidden) echo 'Error from server (Forbidden): secrets "nextcloud-identity" is forbidden' >&2; return 1 ;;
        weird)     echo "" ;;
    esac
}
K8S_SCENARIO=present;   mt_nc_k8s_state tn-t-files secret nextcloud-identity; check "k8s present -> 0" 0 "$?"
K8S_SCENARIO=notfound;  mt_nc_k8s_state tn-t-files secret nextcloud-identity; check "k8s NotFound -> 1" 1 "$?"
K8S_SCENARIO=ns_missing; mt_nc_k8s_state tn-t-files secret nextcloud-identity; check "k8s namespace NotFound -> 1" 1 "$?"
K8S_SCENARIO=refused;   mt_nc_k8s_state tn-t-files secret nextcloud-identity; check "k8s connection refused -> 2" 2 "$?"
case "$MT_NC_K8S_ERROR" in *refused*) check "k8s error text kept" y y ;; *) check "k8s error text kept" y n ;; esac
K8S_SCENARIO=timeout;   mt_nc_k8s_state tn-t-files secret nextcloud-identity; check "k8s timeout -> 2" 2 "$?"
K8S_SCENARIO=forbidden; mt_nc_k8s_state tn-t-files secret nextcloud-identity; check "k8s Forbidden -> 2 (not absent)" 2 "$?"
K8S_SCENARIO=weird;     mt_nc_k8s_state tn-t-files secret nextcloud-identity; check "k8s exit 0 with empty output -> 2" 2 "$?"
unset -f kubectl

echo ""
echo "nextcloud-db.test.sh: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
