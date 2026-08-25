# Changelog

All notable changes to Mothertree will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Open WebUI upgraded to 0.11.0 and the web-search wiring adjusted for it:
  the 0.11 forced-RAG handler only runs under legacy function calling, so
  `DEFAULT_MODEL_PARAMS={"function_calling":"legacy"}` is set in the tenant
  template (fresh DBs) and `deploy-llm-webui.sh` upserts
  `models.default_params` into webui.db for existing installs. The
  feature permission (`features.web_search`)
  defaults to enabled on 0.11.0, so no per-user grants are needed. Verified
  live on dev as a role=user JWT: search triggers, sources + citations
  returned, answer cites the fetched 2026 population figure.
- Web-search functional gate in `deploy-llm-webui.sh` (step 11,
  `apps/websearch-gate/websearch-gate.py`): after every Open WebUI deploy,
  the gate runs inside the pod as a provisioned role=`user` account and
  verifies the feature end to end — SearXNG JSON canary, then a chat
  completion with `features.web_search=true` asserting the response cites a
  non-empty `sources` array (structural assertion, so LLM nondeterminism
  cannot flake it). Catches upgrades that break search without breaking the
  deployment (pod healthy, OIDC fine, model list renders, but search
  silently never runs — the 0.9.6→0.11 native-function-calling regression).
  Fails the deploy loudly; verified to pass on 0.9.6 with current wiring,
  pass on 0.11.0 with `function_calling=legacy`, and fail (exit 1, no
  sources) on a naive 0.11.0 bump.
- LLM web search for Open WebUI, self-hosted via SearXNG (the alternative
  provider route from `docs/plans/llm/web-search.md`; no external API key).
  A shared `searxng` deployment now lives in `infra-llm`
  (`apps/manifests/llm/searxng.yaml`, deployed by `apps/deploy-llm.sh`) and
  serves an Open WebUI-compatible JSON search API. All Open WebUI tenant
  deployments (`apps/manifests/llm/open-webui-tenant.yaml.tpl`) enable web
  search against it with `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=searxng`,
  `SEARXNG_QUERY_URL`, and `BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true`.
  The bypass flag is a narrow workaround for the 0.9.6 RAG gap where
  `type: web_search` collections are dropped by the retrieval access-control
  path: page texts go straight into the chat context, and file/knowledge-base
  RAG access control is unaffected. Also sets
  `BYPASS_MODEL_ACCESS_CONTROL=true`: 0.9.6 filters `/api/models` for
  non-admin users through per-model access control and drops non-registered
  (Ollama) models, so regular users saw an empty model selector; the flag is
  the documented escape hatch and per-model grants are not used on the shared
  single-model setup. Verified end-to-end on dev (SearXNG JSON API → Open
  WebUI retrieval → sources + cited answer; user-role JWT sees both models).

### Fixed
- LLM stack memory-pressure eviction storms on the fixed-size dev pool
  (autoscaling is disabled there): the web-search gate's inference left the
  model resident in Ollama for `OLLAMA_KEEP_ALIVE` (30m) — ~1.7Gi squatting
  after every deploy — which pushed nodes into memory-pressure eviction
  (webui/ollama pods killed, `NoSchedule` taints, CoreDNS rollout timeouts
  failing unrelated deploy steps). The gate now unloads the model
  (`keep_alive: 0`) after its check, pass or fail. Ollama's Deployment also
  switches to kill-before-create rollouts (`maxUnavailable: 1, maxSurge: 0`):
  with surge, old + new pods need both memory requests simultaneously, which
  cannot schedule on the packed fixed-size pool and wedged the rollout
  Pending forever.
- Recurring `deploy-dev-nextcloud` / `deploy-dev-roundcube` CI flakes caused by
  PgBouncer serving a stale cached login error after a tenant DB was dropped and
  recreated (CI pipeline #1746). PgBouncer pools are keyed on (database, user)
  and only clear a cached `database ... does not exist (server_login_retry)`
  failure on the next successful server login for that exact pool; with two
  PgBouncer replicas behind one ClusterIP, db-init succeeding (as `postgres`, a
  different pool, possibly a different replica) proved nothing about the pool
  the app then used — the Nextcloud install Job burned its whole backoff on the
  cached error, and Roundcube's container-start `initdb` failed silently,
  leaving an unusable schema and a rollout timeout. Fixes:
  - New `mt_pgbouncer_verify_db` gate (`scripts/lib/common.sh`) runs after
    db-init in `deploy-nextcloud.sh` and `deploy-roundcube.sh`: it connects as
    the app user to the tenant DB via **every** PgBouncer pod IP, retrying past
    the `server_login_retry` window so each poisoned pool is forced to re-login
    and heal. If a pod still can't serve the pool it fails the deploy loudly at
    that point, naming the pod, instead of three steps later with a mystery
    SQLSTATE.
  - Roundcube's schema verification now requires the `session` table (the exact
    relation the readiness probe checks) in addition to the
    `system.roundcube-version` marker, so a partially-built schema can no longer
    pass verification and then wedge the readiness gate. On dev pool tenants a
    partial schema that `initdb --update` cannot converge is reset
    (`DROP SCHEMA public CASCADE` + full re-init); prod still fails loudly
    rather than auto-wiping.
- ACME DNS-01 challenge records accumulated in the shared Cloudflare zone until
  it hit its record quota, wedging cert renewals. cert-manager creates ephemeral
  `_acme-challenge.<name>` TXT records during DNS-01 validation and removes them
  once solved, but a cluster torn down mid-challenge (notably the ephemeral dev
  clusters, which share the same zone as prod) orphans them. Over weeks these
  filled the zone's ~200-record cap; cert-manager then got Cloudflare error
  `81045: Record quota exceeded` and could not create the TXT records for the
  apex/wildcard renewal, which sat `pending` for 42h (caught by the
  `CertificateRenewalStuck` alert, ~29 days before actual expiry). Added an
  hourly `acme-challenge-cleanup` CronJob (namespace `infra-cert-manager`,
  deployed by `deploy_infra`) that prunes `_acme-challenge.*` TXT records older
  than 6h from the infra zone. The age threshold protects in-flight challenges
  (which complete within minutes); deletes are idempotent so running it in more
  than one environment against the shared zone is safe. Scoped to the infra zone
  only — per-tenant zones (which have far fewer records) are not yet swept.
- Cert-expiry alerting was silently dead. The cert-manager `ServiceMonitor`
  was missing the `release: kube-prometheus-stack` label that
  kube-prometheus-stack's Prometheus uses to select ServiceMonitors, so
  `certmanager_certificate_*` metrics were never scraped and the
  `CertificateExpiringSoon` / `CertificateNotReady` alerts had no input data.
  The Blackbox HTTPS endpoint probes were also blind: they traverse Cloudflare
  and measure CF's edge cert (auto-renewed by CF, ~85 days remaining), not our
  origin Let's Encrypt cert. Added the missing label, plus two new alerts on
  metrics that are scraped independently of cert-manager:
  `IngressCertExpiringSoon` (uses `nginx_ingress_controller_ssl_expire_time_seconds`,
  per-host, sourced from the cert the ingress controller is actually serving)
  and `CertificateRenewalStuck` (fires 24h after cert-manager's scheduled
  renewal hasn't happened — catches stuck renewals ~30 days before expiry
  instead of 7).
- Wildcard TLS renewal deadlock: split per-tenant TLS into two Certificates
  (`wildcard-tls` for `*.domain` + `*.internal-domain`, and `apex-tls` for the
  bare apex). cert-manager's ACME scheduler deduplicates challenges by
  `(DNSName, Type)` only — a single Certificate that combines `*.example.com`
  with `example.com` produces two authorizations at the same
  `_acme-challenge.example.com` FQDN and the scheduler will never process the
  second one (cert-manager#8643, behavior is reaffirmed as design intent in
  v1.20). The first issuance can succeed by luck when one authz is cached on
  the Let's Encrypt account; every fresh renewal deadlocks. Splitting the
  Certificate puts each authz on its own Order, sidestepping the dedup. The
  `matrix-wellknown` ingress now references the `apex-tls-${TENANT_NAME}`
  secret.
- deploy-stalwart: force CoreDNS rollout (and node-local-dns DaemonSet, when present) on rewrite change so all replicas converge before the SMTP smoke test runs. Closes the cold-start race where provision-smtp's smoke test resolved `mail.<domain>` to the public LB IP via a lagging CoreDNS replica or a stale node-local cache.

## [0.9.3] - 2026-03-13

### Added
- E2E test for full user onboarding flow (#194)
- Exponential backoff and dead-letter queue for failed iTIP calendar processing (#197)
- Valkey-based tenant pool leasing for parallel CI builds (#181)
- Standalone portal deploy scripts extracted from create_env (#178)

### Changed
- Redirect guests through OIDC login to avoid redundant name prompt (#177)
- Dev environment: remove HPAs, fix replicas, right-size memory requests (#182)
- Bump ejs 4.0.1 → 5.0.1 in admin-portal and account-portal (#172, #173)
- Bump express-rate-limit 8.2.1 → 8.3.0 in admin-portal and account-portal (#170, #171)
- Bump admin-portal to 0.9.4 and account-portal to 0.11.3 (#198)

### Fixed
- Email sharing with existing Keycloak users (#175)
- Guest landing page redirecting to Nextcloud instead of passkey setup (#165)
- Federated sharing causing email share routing failures (#164)
- CI shard-5 email test reliability (#193)
- E2E test user leak via pipeline-scoped prefixes (#179)
- Invite-user E2E cleanup causing stale user accumulation (#174)

## [0.9.2] - 2026-03-07

### Added
- Playwright-based load tests for concurrent browser simulation (#153)

### Changed
- Nextcloud CPU requests configurable through tenant config (#158)

### Fixed
- Calendar invitation emails failing on multi-pod Nextcloud (#163)
- OIDC config job overriding sharebymail enable (#159)
- HPA field manager conflict between Helm SSA and kubectl patch (#160)
- Guest bridge config not persistent across pod restarts (#157)
- Nextcloud HPA scaleDown stabilization window not applied post-deploy (#156)
- Email sharing: re-enabled sharebymail with guest_bridge suppression (#155)
- Invite emails showing "the platform" instead of realm name (#154)

## [0.9.1] - 2026-03-05

### Fixed
- CalDAV Schedule-Reply header to prevent iMIP feedback loop (#150)
- Collabora E2E test: use WebDAV upload instead of filechooser UI (#148)
- Nextcloud upload test cleanup, use WebDAV + Recent view (#149)

### Changed
- Removed CPU limits from all managed pods, bumped low Jitsi CPU requests (#151)

## [0.9.0] - 2026-03-05

### Added
- Nextcloud HPA with configurable scale-down behavior (#130)
- Nextcloud OIDC readiness probe (#143)
- Keyboard shortcuts plugin for Roundcube (#109)
- E2E tests for calendar invitation lifecycle (#107)
- Nextcloud OIDC-only login persistence across pod restarts with smoke tests (#117)
- Docs backend gunicorn workers configurable per tenant (#144)
- HPA alert for docs backend (#134)
- CI `ci-logs` command for build log retrieval

### Fixed
- Collabora WOPI CheckFileInfo routing via internal ingress (#122)
- Nextcloud OIDC login breakage (#143)
- Nextcloud 503 on HPA scale-up by running occ upgrade in before-starting hook (#132)
- Nextcloud theming failure after app installs (#135)
- Nextcloud Helm 4 SSA conflict with chart's built-in HPA (#140)
- Helm 4 SSA conflict: use `--sync-args` instead of `--args` for helmfile sync
- Docs backend crash loop: relaxed probes, added HPA alert (#134)
- Docs backend boto3 version pin (#128)
- PostgreSQL connection exhaustion in dev (#129)
- Guest bridge ECONNRESET by using internal service URL (#121)
- OIDC endpoint timeout handling during Nextcloud login (#116)
- Calendar automation REPLY processing for Nextcloud UI-created events (#147)

### Changed
- Removed CPU limits from all workloads, fixed low CPU requests (#145)
- Increased Vector log collector memory limits to fix OOMKill on busy nodes
- Disabled sharebymail and enforced share security policies (#123)
- Disabled Keycloak brute force protection for dev environment (#137)
- Increased Prometheus memory limits in dev, reduced retention to 7d (#127)
- Hardened CI agent against crash recovery failures (#112)
- Separated CI and local E2E test users to prevent deletion conflicts (#113)

## [0.8.0] - 2026-03-01

Baseline release — platform release versioning introduced.

### Added
- Platform-level `VERSION` file and release version string (`0.8.0-<commit>[-M]`)
- `/version` endpoint on admin and account portals
- `scripts/lib/release.sh` for deploy-time version computation
