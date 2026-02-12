Common utilities for k6 tests (helpers, thresholds, shared config loaders).

CSV users
---------
- Provide a CSV with lines in the format: `username,password`.
- Supply to k6 via one of:
  - `USERS_CSV_PATH=/path/to/users.csv`
  - `USERS_CSV_INLINE=<base64(csv)>`

Selection policy
----------------
- Default: per-VU assignment — user index = `(__VU - 1) % users.length`.
- Optional: round-robin per-iteration when `USERS_ROUND_ROBIN=1`.
- Guardrail: if `K6_VUS > users.length` and `USERS_ALLOW_REUSE!=1`, the test fails early.

Docs auth (Keycloak ROPC)
-------------------------
- Required envs:
  - `KEYCLOAK_BASE_URL`, `KEYCLOAK_REALM`
  - `KEYCLOAK_CLIENT_ID` (and optionally `KEYCLOAK_CLIENT_SECRET`)
- Protected checks (optional): set `DOCS_PROTECTED_PATH` (e.g., `/api/v1.0/user/me`) to exercise authenticated endpoints.

Runner and manifests
--------------------
- Local runner: `apps/scripts/perf/run-local.sh --env dev --users perf/users/example.csv <suite> <scenario>`
- Cluster (prod manifests): mount a Secret named `perf-users` with key `users.csv` at `/data/users.csv`, and set `USERS_CSV_PATH=/data/users.csv`.




