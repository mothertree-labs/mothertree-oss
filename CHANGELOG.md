# Changelog

All notable changes to Mothertree will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
