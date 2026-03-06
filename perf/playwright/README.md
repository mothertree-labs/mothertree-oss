# Playwright Load Tests

Browser-based load testing for Mothertree. Simulates 20 concurrent users navigating
the platform simultaneously using real Chromium browsers.

Unlike the k6 tests (API-level), these tests exercise the full browser rendering path:
Keycloak OIDC flows, SSO propagation, SPA loading, WebSocket connections, and WebDAV
file operations — all under concurrent load.

## Quick Start

```bash
# 1. Provision 20 load test users in dev (one-time, requires kubectl)
./perf/playwright/provision-users.sh -e dev -t example create

# 2. Install dependencies
cd perf/playwright && npm install

# 3. Run the load test (20 headless browsers)
npm test

# 4. View the report
npm run report
```

## Running Options

```bash
# Headless (default) — 20 concurrent users
npm test

# Headed — watch 20 browsers at once
npm run test:headed

# Fewer users (if your machine struggles)
npm run test:5      # 5 users
npm run test:10     # 10 users

# Custom worker count
npx playwright test --project=load --workers=12

# Repeat the journey multiple times per user (sustained load)
npx playwright test --project=load --repeat-each=3

# Enable the idle soak phase (hold connections for 60s)
LOAD_SOAK_SECONDS=60 npm test
```

## Test Phases

Each user (worker) runs through these phases sequentially:

| Phase | What it tests | Key pressure points |
|-------|--------------|-------------------|
| 1. SSO Login | Keycloak OIDC password flow | Keycloak DB, session creation |
| 2. Dashboard Browse | Account portal pages | Portal Node.js, Redis sessions |
| 3. Cross-App SSO | Files, Docs, Element via SSO | Keycloak token validation, ingress |
| 4. File Upload | WebDAV PUT + DELETE in Nextcloud | PHP-FPM, S3, PostgreSQL |
| 5. Idle Soak | Hold Element WebSocket open | Synapse, ingress connections |

Phase 5 is opt-in — set `LOAD_SOAK_SECONDS=60` (or any duration) to enable it.

## User Management

```bash
# Create users (idempotent — skips existing)
./perf/playwright/provision-users.sh -e dev -t example create

# Create only 10 users
./perf/playwright/provision-users.sh -e dev -t example create --count 10

# Delete all load test users
./perf/playwright/provision-users.sh -e dev -t example delete
```

Users are named `load-01` through `load-20`, all with password `load-testpass`.
Each Playwright worker picks a unique user by its worker index.

## Interpreting Results

- **Console output**: Each user logs timing per phase — look for outliers
- **HTML report** (`npm run report`): Pass/fail per worker, failure screenshots
- **Cluster monitoring**: Watch Grafana/kubectl during the run:
  ```bash
  kubectl --kubeconfig=kubeconfig.dev.yaml top pods -A
  kubectl --kubeconfig=kubeconfig.dev.yaml get events -A --sort-by='.lastTimestamp' | tail -20
  ```

## Architecture

```
perf/playwright/
  playwright.config.ts       # 20 workers, generous timeouts
  tests/
    user-journey.spec.ts     # Main load test (all phases)
  helpers/
    load-users.ts            # User pool: load-01..load-20
  provision-users.sh         # Create/delete users via dev-test-users.sh
```

Imports auth helpers (`keycloakLogin`, `urls`, `selectors`) from `e2e/helpers/` —
read-only dependency, no modifications to the E2E test suite.
