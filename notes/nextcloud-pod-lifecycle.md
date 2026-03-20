# Nextcloud Pod Lifecycle & Maintenance Mechanisms

Deep dive into how Nextcloud pods initialize, maintain state, and handle upgrades in the Mothertree emptyDir-based architecture.

## Architecture Overview

Nextcloud runs on **emptyDir** (no PVC). Every pod restart starts from scratch. Identity (instanceid, passwordsalt, secret) is persisted in a K8s Secret and re-seeded on every boot. App store apps are re-downloaded on every boot from URLs stored in a ConfigMap.

```
Pod Startup Sequence:
┌──────────────────────────────────────────────────────────────────────┐
│ 1. Init Container: install-pandoc                                    │
│    └─ Downloads Pandoc binary to emptyDir volume                     │
│                                                                      │
│ 2. Init Container: seed-identity (identity-init.sh)                  │
│    ├─ Extracts custom apps from ConfigMap tar.gz                     │
│    ├─ Downloads app store apps from appstore-urls ConfigMap           │
│    ├─ Rsyncs /usr/src/nextcloud/ → emptyDir                         │
│    ├─ Writes version.php (triggers upgrade detection if mismatched)  │
│    ├─ Writes config.php with identity + DB settings                  │
│    └─ Creates .ncdata sentinel, fixes ownership                      │
│                                                                      │
│ 3. Nextcloud Entrypoint (from image)                                 │
│    ├─ Detects config.php exists → skips first-install                │
│    ├─ Compares version.php to image version                          │
│    │   └─ If mismatch: rsyncs source + runs occ upgrade              │
│    ├─ Loads *.config.php from /var/www/html/config/                  │
│    ├─ Executes before-starting hooks                                 │
│    └─ Starts Apache                                                  │
│                                                                      │
│ 4. Before-Starting Hook (before-starting-hook.sh)                    │
│    ├─ Checks needsDbUpgrade → runs occ upgrade if needed             │
│    ├─ Enforces OIDC-only login (allow_multiple_user_backends=0)      │
│    ├─ Enables guest_bridge + sharebymail                             │
│    ├─ Configures guest_bridge API settings from env vars             │
│    ├─ Sets share security policies (links, expiry, no federation)    │
│    └─ Copies oidc-health.php into place (for readiness probe)        │
│                                                                      │
│ 5. Apache starts → probes begin                                      │
│    ├─ Startup probe: GET /status.php (30s initial, 5min window)      │
│    ├─ Liveness probe: GET /status.php (10s period, 3 failures)       │
│    └─ Readiness probe: php oidc-health.php (OIDC config check)       │
│                                                                      │
│ 6. Sidecar: cron (runs /cron.php every 5 minutes)                   │
└──────────────────────────────────────────────────────────────────────┘
```

## Component Details

### Init Container: seed-identity (`identity-init.sh`)

**Source**: `apps/manifests/nextcloud/identity-init-configmap.yaml`

Runs on every pod start. Two modes:
- **First install** (NC_INSTANCE_ID not set): Extracts custom apps, writes mimetypemapping, downloads app store apps, then exits. Lets the Nextcloud entrypoint handle initial installation.
- **Subsequent boots** (NC_INSTANCE_ID set): All of the above, plus rsyncs Nextcloud source from image, writes version.php and config.php with identity values, creates .ncdata sentinel.

Key data sources:
- `nextcloud-identity` Secret → NC_INSTANCE_ID, NC_PASSWORD_SALT, NC_SECRET, NC_VERSION, NC_TRUSTED_DOMAINS
- `nextcloud-custom-apps` ConfigMap → tar.gz of custom apps (files_linkeditor, jitsi_calendar, guest_bridge)
- `nextcloud-appstore-urls` ConfigMap → app download URLs (user_oidc, calendar, richdocuments, external, notify_push)

### Before-Starting Hook (`before-starting-hook.sh`)

**Source**: `apps/manifests/nextcloud/before-starting-hook.sh`

Mounted at `/docker-entrypoint-hooks.d/before-starting/`. Runs after Nextcloud init but before Apache starts. **Only runs once per pod lifecycle** (at startup).

Critical operations:
1. **occ upgrade** — checks `occ status --output=json` for `needsDbUpgrade:true`, runs upgrade if needed
2. **OIDC enforcement** — sets `allow_multiple_user_backends=0` (each pod resets this on boot because emptyDir wipes the DB setting enforcement)
3. **App enables** — guest_bridge (first!) then sharebymail
4. **Guest bridge config** — writes API URL + key to per-pod config.php
5. **Share security** — link sharing on, no password enforcement, no federation
6. **Health check install** — copies oidc-health.php to webroot

### Probes

**Liveness** (`GET /status.php`): Deep health check that loads all app classes via `OC_App::loadApps()`. Returns JSON with `needsDbUpgrade` field. HTTP 200 even when `needsDbUpgrade: true` — **does not cause pod restart on upgrade-needed state**.

**Readiness** (`php oidc-health.php`): Lightweight check that queries `oc_appconfig` for `allow_multiple_user_backends`. Returns exit 0 (healthy) if OIDC-only mode is active. **Does not check needsDbUpgrade state**.

**Startup** (`GET /status.php`): 5-minute window for before-starting hook to complete.

### Deploy-Time Jobs

**nextcloud-db-init** (postgres:16 image): Creates database + user + grants. Runs once per deploy.

**nextcloud-oidc-config** (bitnami/kubectl image): Waits for pod Ready, then exec's into the pod to install/configure apps via occ commands. Installs user_oidc, calendar, richdocuments, external, files_linkeditor, guest_bridge, sharebymail. Configures OIDC provider, share settings, theming.

### App Store URLs ConfigMap

**Critical lifecycle detail** — two-phase management to prevent split-brain:
1. **Step 5c** (pre-deploy): CREATE only if missing (first deploy). Never updates here.
2. **Step 9c.1** (post-deploy): UPDATE after all occ commands complete. Safe for future pods.

This prevents version mismatches during rolling updates / HPA scale-up. But see the failure mode below.

### Deploy Script Helpers

**`_get_nc_pod()`**: Finds a Ready, non-Terminating Nextcloud pod. Used for all exec operations.

**`_nc_occ_retry()`**: Runs occ commands with automatic retry on "require upgrade" errors. If HPA-scaled pods run `occ upgrade` via their before-starting hook between deploy script commands, this catches the resulting errors and reconciles.

## The Failure Mode: Split-Brain App Versions

### What happened (2026-03-20 incident)

1. Manual pod rescheduling killed one of three Nextcloud pods
2. Replacement pod's init container downloaded app versions from `nextcloud-appstore-urls` ConfigMap
3. The ConfigMap had been updated at step 9c.1 during a **previous** deploy with newer richdocuments URLs (9.0.5)
4. The old pods still had richdocuments 9.0.3 files on their emptyDir
5. New pod's before-starting hook ran `occ upgrade` → upgraded richdocuments DB schema to 9.0.5
6. Two old pods now had a **file/DB version mismatch**: 9.0.3 files vs 9.0.5 DB schema
7. Old pods entered `needsDbUpgrade: true` state → 503 on all app routes
8. Liveness probe (`/status.php`) still returned HTTP 200 → Kubernetes did not restart them
9. Readiness probe (`oidc-health.php`) checks OIDC config, not upgrade state → no signal

### Why the before-starting hook didn't help

The before-starting hook correctly handles `needsDbUpgrade` — **but only at pod startup**. For pods that are already running, there is no mechanism to detect or react to the upgrade-needed state.

### Why the probes didn't catch it

- **Liveness probe**: `/status.php` returns HTTP 200 with `needsDbUpgrade: true` in the JSON body. Kubernetes HTTP probes only check the status code, not the response body. Pod stays alive.
- **Readiness probe**: `oidc-health.php` checks `allow_multiple_user_backends` value, not upgrade state. Pod stays in service, serving 503s.

### The fundamental gap

```
After a partial pod restart with app version drift:

Pod A (old):  richdocuments 9.0.3 files + DB schema 9.0.5 → needsDbUpgrade → 503
Pod B (old):  richdocuments 9.0.3 files + DB schema 9.0.5 → needsDbUpgrade → 503
Pod C (new):  richdocuments 9.0.5 files + DB schema 9.0.5 → healthy → 200
```

There is no runtime mechanism for Pods A and B to recover without being restarted. The only fix is manual (`occ upgrade` on each pod) or a rolling restart.

## All OCC Command Execution Points

| Command | Where | When |
|---------|-------|------|
| `occ upgrade` | before-starting hook | Pod startup (if needsDbUpgrade) |
| `occ upgrade` | deploy script step 7a | During deploy (if needed) |
| `occ upgrade` | `_nc_occ_retry()` | During deploy (if concurrent upgrade detected) |
| `occ upgrade` | deploy script step 9d | Pre-theming reconciliation |
| `occ status --output=json` | before-starting hook | Pod startup (upgrade check) |
| `occ config:app:set` | before-starting hook | Pod startup (OIDC, share settings) |
| `occ app:enable` | before-starting hook | Pod startup (guest_bridge, sharebymail) |
| `occ config:system:set` | before-starting hook | Pod startup (guest_bridge API) |
| `occ app:install/enable` | OIDC config job | Deploy (all apps) |
| `occ db:add-missing-indices` | OIDC config job | Deploy |
| `occ config:app:set` | OIDC config job | Deploy (OIDC provider, app settings) |
| `occ maintenance:*` | deploy script | Deploy (htaccess, mimetypes) |
| `occ theming:config` | deploy script step 9d | Deploy |
| `occ notify_push:self-test` | deploy script step 9c | Deploy |

## Key Design Decisions & Constraints

1. **EmptyDir over PVC**: Enables RollingUpdate strategy (zero-downtime deploys), avoids PVC access mode limitations. Cost: every pod start rebuilds from scratch.

2. **Identity in K8s Secret**: instanceid/passwordsalt/secret survive pod restarts. Extracted after first install, seeded on subsequent boots.

3. **App store URLs in ConfigMap**: Apps re-downloaded on every boot. Two-phase update (create-only pre-deploy, update post-deploy) prevents version mismatches during deploys — but doesn't prevent mismatches from partial restarts between deploys.

4. **Before-starting hook for enforcement**: OIDC-only login, share settings, and guest_bridge config must be set on every pod because emptyDir wipes per-pod config.php state. Hook runs once at startup.

5. **No upgrade sidecar**: The cron sidecar runs `/cron.php` only (background tasks). There is no sidecar or periodic job that checks for and handles `needsDbUpgrade` on running pods.

6. **Probes don't detect upgrade state**: By design — running `occ upgrade` from a probe would be dangerous (maintenance mode affects all pods). But this means pods in upgrade-needed state serve 503s indefinitely.
