#!/usr/bin/env bash
# Pure selection helpers for scripts/destroy-dev-cluster.sh orphan sweeps.
# No API calls here: callers pass the JSON in, so the rules are unit-testable
# (scripts/lib/tests/dev-orphans.test.sh).

# mt_cfw_orphan_firewalls <firewalls-json> <live-cluster-ids (newline-separated)>
#
# Prints "<id>\t<label>" for every Cloud Firewall Controller firewall that is
# safe to delete: label exactly `lke-<digits>`, that cluster id NOT live, and
# ZERO attached entities. A missing or null `entities` field counts as
# "cannot tell" and the firewall is kept. Fails (rc 1) on unparseable JSON or an empty /
# non-numeric live list — an empty list would make every lke- firewall,
# prod's included, look orphaned.
mt_cfw_orphan_firewalls() {
    local fw_json="$1" live_ids="$2"
    if [ -z "${live_ids//[[:space:]]/}" ] || printf '%s\n' "$live_ids" | grep -v -q -E '^[0-9]+$|^$'; then
        echo "mt_cfw_orphan_firewalls: live cluster id list is empty or not numeric" >&2
        return 1
    fi
    local live_json
    live_json=$(printf '%s\n' "$live_ids" | grep -E '^[0-9]+$' | jq -R . | jq -s .) || return 1
    jq -r --argjson live "$live_json" '
        .[]
        | select((.label | type) == "string" and (.label | test("^lke-[0-9]+$")))
        | select((.label | ltrimstr("lke-")) as $cid | ($live | index($cid)) | not)
        | select((.entities | type) == "array" and (.entities | length) == 0)
        | "\(.id)\t\(.label)"' <<< "$fw_json"
}
