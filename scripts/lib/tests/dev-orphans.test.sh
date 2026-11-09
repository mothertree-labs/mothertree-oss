#!/usr/bin/env bash
# Unit tests for scripts/lib/dev-orphans.sh (CFW firewall orphan selection used
# by scripts/destroy-dev-cluster.sh). Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dev-orphans.sh
source "$HERE/../dev-orphans.sh"

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi; }

# Shaped like `linode-cli firewalls list --json`.
FW='[
 {"id":1,"label":"lke-100001","entities":[{"type":"linode","label":"lke100001-1-a"}]},
 {"id":2,"label":"lke-100002","entities":[]},
 {"id":3,"label":"lke-100003"},
 {"id":11,"label":"lke-100006","entities":null},
 {"id":12,"label":"lke-100007","entities":{}},
 {"id":4,"label":"lke-100004","entities":[{"type":"linode","label":"lke100004-1-b"}]},
 {"id":5,"label":"lke-111111","entities":[{"type":"linode","label":"still-attached"}]},
 {"id":6,"label":"postgres-dev-firewall","entities":[]},
 {"id":7,"label":"lke-222222-extra","entities":[]},
 {"id":8,"label":"my-lke-333333","entities":[]},
 {"id":9,"label":null,"entities":[]},
 {"id":10,"label":"lke-1000","entities":[]}
]'
LIVE=$'100001\n100004'

OUT=$(mt_cfw_orphan_firewalls "$FW" "$LIVE"); RC=$?
check "rc" 0 "$RC"
check "selects only dead-cluster, unattached lke-<id>" $'2\tlke-100002\n10\tlke-1000' "$OUT"
case "$OUT" in *lke-100003*|*lke-100006*|*lke-100007*) check "missing/null/non-array entities kept" kept deleted ;; *) check "missing/null/non-array entities kept" kept kept ;; esac
case "$OUT" in *lke-100001*) check "live-cluster firewall kept" kept deleted ;; *) check "live-cluster firewall kept" kept kept ;; esac
case "$OUT" in *lke-111111*) check "attached firewall kept" kept deleted ;; *) check "attached firewall kept" kept kept ;; esac
case "$OUT" in *postgres-dev*|*extra*|*my-lke*) check "non-CFW labels kept" kept deleted ;; *) check "non-CFW labels kept" kept kept ;; esac

# lke-1000 vs live 100004: exact id match, not prefix.
check "id match is exact, not a prefix" yes "$(printf '%s\n' "$OUT" | grep -q $'^10\tlke-1000$' && echo yes || echo no)"

# Fail closed.
mt_cfw_orphan_firewalls "$FW" "" >/dev/null 2>&1; check "empty live list fails" 1 $?
mt_cfw_orphan_firewalls "$FW" $'  \n ' >/dev/null 2>&1; check "whitespace live list fails" 1 $?
mt_cfw_orphan_firewalls "$FW" $'100001\nnull' >/dev/null 2>&1; check "non-numeric live id fails" 1 $?
mt_cfw_orphan_firewalls "not json" "$LIVE" >/dev/null 2>&1; check "bad firewall JSON fails" 1 $([ $? -ne 0 ] && echo 1 || echo 0)

# Nothing to do.
OUT=$(mt_cfw_orphan_firewalls '[]' "$LIVE"); check "no firewalls -> empty" "" "$OUT"

echo "dev-orphans: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
