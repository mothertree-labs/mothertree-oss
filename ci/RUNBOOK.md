# CI Server Runbook

Operational procedures for the Woodpecker CI host. It is `devhome-ci`, a
VM-like container (systemd + sshd) on the devhome box; see `devhome/README.md`
for the box and `CLAUDE.md` for the pipeline structure. `ci/ansible/playbook.yml`
is what is provisioned on it.

The server is `https://ci-devhome.mother-tree.org` (through the periscope). For
shell access, SSH to the box on the home LAN and enter the container:

```bash
ssh <operator>@<devhome-box>
sudo docker exec -it devhome-ci bash     # systemctl / sqlite3 steps below run in here
```

Every API snippet below needs an **admin** token (`/api/queue/info` is
admin-only and fails confusingly without one). It is `woodpecker_api_token`
in the private `config/platform/devhome/ci-ansible-vars.yml`:

```bash
WP=https://ci-devhome.mother-tree.org
WP_TOKEN=$(yq -r .woodpecker_api_token config/platform/devhome/ci-ansible-vars.yml)
```

---

## Queue-zombie jam (CI "stops starting pipelines")

Woodpecker leaks rows into the `tasks` queue table when pipelines are cancelled.
Orphaned rows hold agent worker slots, so new pipelines sit un-dispatched and CI
looks dead while actually being starved. Recurring since 3.14.x, and last
confirmed present on **3.17.0** (2026-09-09). The host now runs **3.18.1** and
the bug has *not* been re-confirmed there — if you hit this, note whether it
still reproduces. Tracked in #435.

Until 2026-09-09 a `woodpecker-queue-unjam` cron did this automatically. **It was
retired (#648) because it could not tell a jam from ordinary cancellation churn
and restarted Woodpecker on top of four healthy running pipelines.** Recovery is
now deliberate and manual — the procedure below is what that script did.

### Confirm it is actually a jam — do not skip this

The 2026-09-09 outage happened because two signals were treated as sufficient
when they are not. **Both are produced by ordinary cancelled pipelines** (and
`cancel_previous_pipeline_events` fires on every bot PR burst):

- `resubmitting expired task` lines in the server journal
- zombie rows in the `tasks` table

Neither says anything about whether the queue is starved. Nor does raw
saturation: `running_count == worker_count` with `pending_count` climbing is
**equally the signature of a healthy burst**, which is exactly what the cron
misread.

The real question is whether the occupied slots are *phantoms*. Get the ids of
the currently-running tasks, then ask whether their workflows have already
finished:

```bash
# 1. What is occupying the workers right now?
curl -s -H "Authorization: Bearer $WP_TOKEN" \
  $WP/api/queue/info | jq '.stats, (.running | map(.id))'
```

```bash
# 2. Are those specific ids phantoms? Substitute the ids from step 1.
#    A task is a zombie when its backing workflow is already in a terminal state.
sqlite3 -cmd ".timeout 5000" /var/lib/woodpecker/woodpecker.sqlite "
SELECT t.id, w.state FROM tasks t LEFT JOIN workflows w ON CAST(w.id AS TEXT) = t.id
WHERE t.id IN ('<id1>','<id2>');"
```

- Terminal states (`success`, `failure`, `killed`, `canceled`, `error`,
  `declined`, `skipped`) or a NULL/missing workflow ⇒ **phantom ⇒ genuine jam.**
- `running`, `pending`, `created`, `blocked` ⇒ real work ⇒ **not a jam.** Wait.

Two traps:

- **`agent_id=0` alone is not the zombie signature.** In healthy operation every
  DAG-blocked task has `agent_id=0`. On 2026-09-09 there were 46 such rows with
  `waiting_on_deps_count=46` and CI was completely fine.
- A terminal workflow with a lingering `tasks` row is normal for a few seconds
  after any cancellation.

### Recovery

**This restarts Woodpecker and kills anything in flight — that is precisely how
the retired cron caused an outage.** The gate must be *global* occupancy, not a
page of one repo's pipelines: during a bot burst a long-running deploy is easily
pushed off page 1, which was the 2026-09-09 condition exactly.

```bash
# 0. Sanity-check the DELETE's join before trusting it (see note below).
#    Must be NON-ZERO. If it is 0, STOP — the predicate would match every row.
DB=/var/lib/woodpecker/woodpecker.sqlite
sqlite3 "$DB" "SELECT count(*) FROM tasks t JOIN workflows w ON CAST(w.id AS TEXT)=t.id;"

# 1. Global gate — must print 0. Repeat this immediately before step 2;
#    a webhook can start a pipeline in the gap.
curl -s -H "Authorization: Bearer $WP_TOKEN" \
  "$WP/api/queue/info" | jq '.stats.running_count'

# 2. Stop services
systemctl stop woodpecker-agent woodpecker-server

# 3. Back up the DB. Full copy — it holds the CI secret store.
umask 077
BAK="${DB}.bak-jam-$(date -u +%Y%m%dT%H%M%SZ)"
sqlite3 "$DB" ".backup '$BAK'"
chmod 600 "$BAK"

# 4. Delete ONLY zombie rows. The terminal-state list is an allowlist, so
#    non-terminal states are preserved.
sqlite3 "$DB" "
DELETE FROM tasks WHERE NOT EXISTS (
  SELECT 1 FROM workflows w
  WHERE CAST(w.id AS TEXT) = tasks.id
    AND w.state NOT IN ('success','failure','killed','canceled','error','declined','skipped'));
SELECT changes();"

# 5. Restart, server first
systemctl start woodpecker-server
sleep 4
systemctl start woodpecker-agent

# 6. Verify BOTH units came back — the retired script had a self-heal for this
systemctl is-active woodpecker-server woodpecker-agent
curl -s -H "Authorization: Bearer $WP_TOKEN" \
  "$WP/api/agents" | jq -r '.[] | "\(.name) \(.version)"'
```

A DB delete alone is not enough — the queue is held in memory, so the server
restart is required.

**Why step 0 matters.** The predicate's fail-safe property depends on
`tasks.id` equalling the workflow id (true through v3.18.1). If a future version
changes that key, *every* row stops matching a workflow, the DELETE drops the
entire live queue — and a naive zombie count would report a huge number that
reads as confirmation to proceed. Step 0 turns that fail-open into fail-closed.
Note also that a NULL `w.state` is deleted rather than preserved, since
`NULL NOT IN (...)` is NULL.

**Delete your backup once CI is confirmed healthy.** `bak-jam-*` files are ~1 GB
unencrypted copies of the secret store, so they outlive credential rotation.
They *are* reaped by the next run of `ci/ansible/playbook.yml` (it prunes
`bak-autounjam-*` and `bak-jam-*`), but do not rely on that — remove it when
you are done.

---

## Reprovisioning the CI host

From an operator checkout (the box must be reachable over SSH):

```bash
ansible-playbook -i config/platform/devhome/ci-inventory.yml \
  -e @config/platform/devhome/ci-ansible-vars.yml ci/ansible/playbook.yml
```

**Pre-flight, in order:**

1. **No pipelines running.** The run recreates the Valkey container
   (`docker rm -f valkey`, no persistence configured), so **every CI tenant
   lease is destroyed**. See #547. Use the same global gate as above:
   ```bash
   curl -s -H "Authorization: Bearer $WP_TOKEN" \
     "$WP/api/queue/info" | jq '.stats'
   ```
2. **Sync the local checkout.** This runs the playbook from your
   *local* working copy, not from `origin/main`. A stale checkout silently
   provisions the wrong thing and still reports success:
   ```bash
   git fetch origin && git reset --hard origin/main
   git submodule update --init --recursive config/platform config/tenants
   grep -m1 'woodpecker_version:' ci/ansible/playbook.yml   # sanity-check the pin
   ```
3. **Check whether a Woodpecker upgrade is bundled.** If the pinned version
   differs from what is running, the playbook's drift guard restarts the server,
   waits for `/version` to report the new number, then restarts the agent for
   GRPC parity. Correct behaviour — but it means a routine converge is also an
   upgrade:
   ```bash
   # inside devhome-ci:
   /usr/local/bin/woodpecker-server --version
   ```

**Verify afterwards**: both services `active` and reporting the same version, and
the agent registered and online. The playbook itself ends by requiring a settled
agent: `/usr/local/bin/woodpecker-agent-stable` (active for 20s, no stale-ID
error). Do not use `:3000/healthz` for this; a crash-looping agent answers it
for a moment on every restart.

**Agent crash-looping with `AgentID not found in database`:** the agent was
restarted while it was still starting up (a quick double restart), so it
unregistered itself from the server after it had saved its ID to
`/etc/woodpecker/agent.conf`. The server looks healthy, but pipelines just queue.
The playbook no longer double-restarts and repairs this case itself; by hand,
empty the file so the agent registers afresh:

```bash
# inside devhome-ci:
systemctl stop woodpecker-agent
: > /etc/woodpecker/agent.conf && chown woodpecker:woodpecker /etc/woodpecker/agent.conf
systemctl start woodpecker-agent
```

Then re-check the fork-PR approval gate. A Woodpecker upgrade or a settings
migration can reset it. It must read exactly `forks` — check the **value**, not
merely that the field is populated, because `none` is also a populated value and
it is the one that disables the gate entirely:

```bash
curl -s -H "Authorization: Bearer $WP_TOKEN" $WP/api/repos/1 \
  | jq '{require_approval, approval_allowed_users}'
# expect: {"require_approval": "forks", "approval_allowed_users": []}
```

A non-empty `approval_allowed_users` bypasses the gate for those users. If either
value is unexpected, restore it and see the security notes in the private
`config/platform` submodule for why it matters.

---

## Scheduled devbox drift check

`.woodpecker/devbox-drift.yaml` runs `ci/scripts/devbox-drift.sh`. It builds the
minimal developer box (`scripts/devbox`, see `docs/devbox.md`) from the plain public
checkout in a throwaway k3d cluster inside devhome-ci, runs the admin-portal login
spec, then deletes the box. It holds the pool slot for the whole run (about 10–15
minutes with warm image caches), so a PR started meanwhile waits for it. The image
caches it creates (`devbox-cache-*` containers and volumes in devhome-ci's Docker)
are kept between runs on purpose.

The job needs one Woodpecker secret, `ci_valkey_password` (for the pool lease),
and that secret must allow the `cron` and `manual` events. Add those events to that
secret only: a manual run can target any branch, so `deploy_vault_password`,
`linode_token`, `github_pat` and the `e2e_pool*` secrets must keep their current
event list.

The schedule is a Woodpecker cron entry, stored in Woodpecker's database rather
than in this repo. Create it once (repo settings → Crons, or the API):

```bash
curl -s -X POST -H "Authorization: Bearer $WP_TOKEN" -H 'Content-Type: application/json' \
  $WP/api/repos/1/cron -d '{"name":"devbox-drift","branch":"main","schedule":"0 9 * * *"}'
```

The schedule is standard 5-field cron in the server's time zone (UTC); pick an hour
when no PRs run. Run it by hand with
"Run pipeline" on `main` in the UI: only this workflow runs on a manual event.
A failure shows as a failed cron pipeline on `main`. Reproduce it locally with
`scripts/devbox init --profile minimal && scripts/devbox up`.

---

## Related known issues

- **#646** — a cancelled workflow leaves its child steps at `success`/exit 0, so
  dependent workflows are dispatched anyway. Symptom: a red PR whose failure
  message is about infrastructure (`no LKE cluster`, `No pool lease found`)
  rather than the change under test. The real cause is that its pipeline was
  cancelled.
- **#647** — the stale-lock reclaim in `ci-infra-lock.sh` / `ci-deploy.sh` /
  `ci-lease-tenant.sh` does an unconditional `DEL` then `SET NX`, so two
  pipelines can both "acquire" the same lock and run concurrent `terraform apply`.
- **#650** — a lockfile-only change is treated as non-source, so the image
  rebuild is skipped and `:latest` is re-pointed at the old image.
- **#547** — re-running the CI playbook wipes Valkey leases.
