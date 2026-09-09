# CI Server Runbook

Operational procedures for the Woodpecker CI VM (`ci/`). See `CLAUDE.md` for
the pipeline structure and `ci/ansible/playbook.yml` for what is provisioned.

Access is Tailscale-only by design — `ssh root@100.64.0.19`. A timeout on the
public `:22` is intentional, not a fault.

Every API snippet below needs an **admin** token (`/api/queue/info` is
admin-only and fails confusingly without one):

```bash
WP_TOKEN=$(security find-generic-password -a mothertree -s woodpecker-api-token -w)
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
  https://ci.mother-tree.org/api/queue/info | jq '.stats, (.running | map(.id))'
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
  "https://ci.mother-tree.org/api/queue/info" | jq '.stats.running_count'

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
  "https://ci.mother-tree.org/api/agents" | jq -r '.[] | "\(.name) \(.version)"'
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
They *are* reaped by the next `provision-ci.sh` run (`ci/ansible/playbook.yml`
prunes `bak-autounjam-*` and `bak-jam-*`), but do not rely on that — remove it
when you are done.

---

## Reprovisioning the CI box

```bash
./ci/scripts/provision-ci.sh --ansible-only
```

**Pre-flight, in order:**

1. **No pipelines running.** The run recreates the Valkey container
   (`docker rm -f valkey`, no persistence configured), so **every CI tenant
   lease is destroyed**. See #547. Use the same global gate as above:
   ```bash
   curl -s -H "Authorization: Bearer $WP_TOKEN" \
     "https://ci.mother-tree.org/api/queue/info" | jq '.stats'
   ```
2. **Sync the local checkout.** `provision-ci.sh` runs the playbook from your
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
   ssh root@100.64.0.19 '/usr/local/bin/woodpecker-server --version'
   ```

**Verify afterwards**: both services `active` and reporting the same version, and
the agent registered and online.

Then re-check the fork-PR approval gate. A Woodpecker upgrade or a settings
migration can reset it. It must read exactly `forks` — check the **value**, not
merely that the field is populated, because `none` is also a populated value and
it is the one that disables the gate entirely:

```bash
curl -s -H "Authorization: Bearer $WP_TOKEN" https://ci.mother-tree.org/api/repos/1 \
  | jq '{require_approval, approval_allowed_users}'
# expect: {"require_approval": "forks", "approval_allowed_users": []}
```

A non-empty `approval_allowed_users` bypasses the gate for those users. If either
value is unexpected, restore it and see the security notes in the private
`config/platform` submodule for why it matters.

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
- **#547** — `provision-ci.sh` wipes Valkey leases.
