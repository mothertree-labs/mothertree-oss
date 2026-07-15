# Changelog

All notable changes to Mothertree will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
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
