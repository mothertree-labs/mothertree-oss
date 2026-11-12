#!/usr/bin/env bash
# Managed by Ansible (ci/ansible/playbook.yml).
#
# Exit 0 when woodpecker-agent has finished starting up and is registered:
# its unit has been active for at least MIN_UP seconds, and its log since that
# start has no "AgentID not found in database". Exit 1 otherwise; the reason
# goes to stderr.
#
# Why not the agent's :3000/healthz or /version: they answer as soon as the
# process binds the port, before it reads agent.conf and registers, so a
# crash-looping agent answers them for a moment on every restart. A
# crash-looping unit never stays active for longer than its RestartSec (10s)
# plus a start, so MIN_UP is above that.
set -euo pipefail

UNIT=woodpecker-agent
MIN_UP="${MIN_UP:-20}"

state=$(systemctl is-active "$UNIT" || true)
if [ "$state" != "active" ]; then
  echo "$UNIT is $state" >&2
  exit 1
fi

since=$(systemctl show -p ActiveEnterTimestamp --value "$UNIT")
up=$(( $(date +%s) - $(date -d "$since" +%s) ))
if [ "$up" -lt "$MIN_UP" ]; then
  echo "$UNIT active for ${up}s only (need ${MIN_UP}s)" >&2
  exit 1
fi

# Captured first: `journalctl | grep -q` under pipefail would report "no
# match" when grep's early exit SIGPIPEs journalctl, and a journalctl error
# must fail the check, not pass it.
log=$(journalctl -u "$UNIT" --since "$since" --no-pager)
if grep -q 'AgentID not found in database' <<<"$log"; then
  echo "$UNIT has a stale agent ID (AgentID not found in database)" >&2
  exit 1
fi
