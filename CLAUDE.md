# Mothertree Project

> **Private config override**: If `config/platform/CLAUDE.private.md` exists (from the private platform submodule), its instructions supplement and take precedence over this file.

Multi-tenant collaboration platform on Kubernetes. Provides Matrix (chat), Docs, Files, Jitsi (video), and Email per tenant.

## Tech Stack

- **Cloud**: Linode (LKE cluster, g6-standard-4, us-lax region, autoscaler min=1 max=5)
- **IaC**: Terraform (workspaces per env) + Ansible (Headscale, PostgreSQL VM, TURN server)
- **K8s Deployment**: Helmfile + Helm charts + raw manifests (apps/manifests/)
- **DNS**: Cloudflare API (A, CNAME, MX, TXT, SRV records)
- **Storage**: PostgreSQL (dedicated external VM per env, connected via Tailscale mesh; PgBouncer in K8s), S3 (Linode Objects, us-lax-1), Redis (per-tenant)
- **Auth**: Keycloak (OIDC, per-tenant realms)
- **Email**: Internet → cluster NodeBalancer:25 → K8s Postfix+OpenDKIM → per-tenant Stalwart (inbound); K8s Postfix → AWS SES (outbound)
- **Mesh Network**: Headscale (self-hosted Tailscale control plane) — all VMs and K8s PgBouncer pods join the WireGuard mesh (100.64.0.0/10 CGNAT)
- **Monitoring**: Prometheus + Grafana + AlertManager + Vector (logs)
- **Tools**: helmfile, yq, kubectl, terraform, ansible, gh (GitHub CLI)

## Directory Map

```
config/          Private config submodules (optional, for operators)
  platform/      Container registry, infra sizing, theme overrides, CLAUDE.private.md
  tenants/       Per-tenant configs (domains, databases, S3 buckets, resources)
phase1/          Terraform: LKE cluster, Headscale, PostgreSQL VM, TURN server
modules/         Terraform modules: lke-cluster/, headscale/, postgres-server/, helm-bootstrap/
apps/            Application deployment layer
  helmfile.yaml.gotmpl   Main helmfile (Go-templated, env-aware)
  values/                Base Helm values (all environments)
  environments/dev/      Dev-specific value overrides (.yaml.gotmpl)
  environments/prod/     Prod-specific value overrides (.yaml.gotmpl)
  manifests/             Raw K8s manifests per component
  deploy-*.sh            Per-component deployment scripts
  admin-portal/          Node.js admin app (Express + EJS + OIDC)
scripts/         Orchestration scripts (manage_infra, deploy_infra, create_env)
  lib/             Shared libraries (common.sh, args.sh, config.sh, infra-config.sh, paths.sh, notify.sh)
  build-deploy-vaults.sh   Build encrypted CI deploy vault archives
tenants/         Per-tenant config (or use config/tenants/ submodule)
  .example/      Template for new tenants
ansible/         VM configuration (Headscale, PostgreSQL, TURN/CoTURN)
ci/              CI server (Woodpecker)
  terraform/     CI VM provisioning (Linode)
  ansible/       CI VM configuration (tools, vaults, deploy keys)
  scripts/       CI pipeline scripts (ci-deploy.sh, build-image.sh, lease/release)
.woodpecker/     Woodpecker pipeline definitions
```

## Three-Phase Deployment

1. **`./scripts/manage_infra -e <env>`** — Terraform, DNS, LKE firewall, Ansible (runs locally, requires Tailscale mesh access). Generates `terraform-outputs.<env>.env` after phase1 apply.
2. **`./scripts/deploy_infra -e <env>`** — Shared K8s infra (ingress, certs, PgBouncer, Keycloak, Postfix, monitoring) — CI-able. Requires `terraform-outputs.<env>.env` from step 1.
3. **`./scripts/create_env -e <env> -t <tenant> [--create-alert-user]`** — Tenant apps (Synapse, Element, Docs, Files, Jitsi, Stalwart, Roundcube, Admin Portal) — CI-able

`manage_infra` supports phase selectors: `--phase1`, `--dns`, `--firewall`, `--ansible` (default: all).
`--plan` and `--destroy` are phase1-only modifiers.

On initial setup of a new environment, DNS must run after deploy_infra creates the ingress:
```bash
manage_infra -e <env> --phase1          # Create cluster, Headscale, PG VM, TURN
deploy_infra -e <env>                   # Deploy K8s infra (creates ingress LB, PgBouncer)
manage_infra -e <env> --dns             # Create DNS records (needs LB IP)
manage_infra -e <env> --firewall --ansible  # Firewall rules + configure VMs via Ansible
```

Sub-scripts are fully self-contained and independently runnable:
```bash
./apps/deploy-docs.sh -e dev -t example
./apps/deploy-stalwart.sh -e prod -t acme
```

## CI/CD (Woodpecker)

Woodpecker CI runs on a dedicated Linode VM (`ci/`). All pipeline files are in `.woodpecker/`.

**PR pipeline** (dev):
```
validate ─────────────┐
build-images ──────────┤  (starts immediately, parallel with validate)
ci-lease ──────────────┤
e2e-setup ─────────────┤
deploy-dev ────────────┤  → deploy_infra -e dev + create_env -e dev -t <leased-tenant>
                       │
           e2e-shard-1..10  → Playwright tests against freshly deployed code
                       │
               ci-release   → release Valkey lease + cleanup KC users
                       │
           mothertree-build → gate (required status check)
```

**Main merge pipeline** (prod):
Same as above, but deploy-dev is a no-op (step-level `when: pull_request`). After the gate passes:
```
deploy-prod → deploy_infra -e prod + create_env -e prod -t <all tenants>
```

**Secrets architecture**:
- Kubeconfigs, terraform outputs, and tenant secrets are stored as **Ansible Vault-encrypted archives** on the CI host (`/home/woodpecker/deploy-vaults/{dev,prod}.vault`)
- Decrypted into temp dirs at build time, cleaned up on exit
- Private config submodules cloned via GitHub PAT (fine-grained, read-only)
- Vault password stored as Woodpecker secret `deploy_vault_password`
- Build vaults with `scripts/build-deploy-vaults.sh` (uses `lpass` for vault password)

**Key files**: `ci/scripts/ci-deploy.sh` (deploy wrapper), `.woodpecker/deploy-dev.yaml`, `.woodpecker/deploy-prod.yaml`, `ci/ansible/playbook.yml` (CI box provisioning), `scripts/build-deploy-vaults.sh` (vault assembly)

## Namespace Conventions

- `infra-*` — Shared infrastructure: `infra-ingress`, `infra-ingress-internal`, `infra-cert-manager`, `infra-db`, `infra-auth`, `infra-monitoring`, `infra-mail`
- `tn-<tenant>-*` — Per-tenant: `tn-<tenant>-matrix`, `tn-<tenant>-docs`, `tn-<tenant>-files`, `tn-<tenant>-jitsi`, `tn-<tenant>-mail`, `tn-<tenant>-webmail`, `tn-<tenant>-admin`

## DNS Patterns

- **Prod**: `matrix.example.com`, `mail.example.com`, `lb2.prod.example.com`
- **Dev**: `matrix.dev.example.com`, `mail.dev.example.com`, `lb1.dev.example.com`
- **Prod internal**: `grafana.prod.example.com`, `prometheus.prod.example.com` (prefix is `prod`, NOT `internal`)
- **Dev internal**: `grafana.internal.dev.example.com`, `prometheus.internal.dev.example.com` (prefix is `internal.dev`)
- Tenant subdomains CNAME to `lb2.prod.example.com` (prod) or `lb1.{env_label}.example.com` (dev/prod-eu)
- `env_dns_label`: empty string for prod, `"dev"` for dev

## Tenant Config Structure

Each tenant has a config directory (either `config/tenants/<name>/` or `tenants/<name>/`) with `{env}.config.yaml` sections:
- `tenant` (name, display_name, env)
- `dns` (domain, subdomains, env_dns_label, cookie_domain)
- `keycloak` (realm name)
- `smtp` (domain)
- `database` (docs_db, nextcloud_db, stalwart_db, roundcube_db)
- `s3` (bucket_prefix, per-service buckets, cluster)
- `resources` (min/max replicas, memory/cpu per component)
- `features` (jitsi_enabled, mail_enabled, webmail_enabled, admin_portal_enabled, calendar_enabled)

Secrets in `{env}.secrets.yaml`: linode/cloudflare tokens, DB passwords, OIDC client secrets, S3 keys, DKIM keys, Jitsi JWT, alertbot token.

See `tenants/.example/` for a complete template.

## Config Path Resolution

Scripts use `scripts/lib/paths.sh` to locate config files, supporting two layouts:
1. **Submodule layout**: `config/tenants/`, `config/platform/project.conf`, `config/platform/infra/`
2. **Legacy flat layout**: `tenants/`, `project.conf`, `infra/*.config.yaml`

The resolution is automatic — if the submodule layout exists, it's preferred. Otherwise falls back to flat layout.

## Helmfile Structure

**File**: `apps/helmfile.yaml.gotmpl` — environments: dev, prod

**Tiers**: `tier=system` (infra components), `tier=infra` (Keycloak), `tier=apps` (tenant apps)

Deploy with labels: `helmfile -e <env> -l name=<release> sync`

## Script Architecture

All scripts use shared libraries in `scripts/lib/`:
- **`scripts/lib/common.sh`** — Shared utilities: `print_status`, `print_error`, `poll_pod_ready`, `dump_pod_diagnostics`, etc.
- **`scripts/lib/args.sh`** — CLI argument parser: `mt_parse_args "$@"` sets `MT_ENV`, `MT_TENANT`, `MT_NESTING_LEVEL`
- **`scripts/lib/config.sh`** — Tenant config loader: `mt_load_tenant_config` loads all config/secrets from YAML and exports env vars
- **`scripts/lib/infra-config.sh`** — Infrastructure config loader: `mt_load_infra_config` for `deploy_infra`
- **`scripts/lib/paths.sh`** — Config path resolution: `_mt_resolve_tenants_dir`, `_mt_resolve_project_conf`, `_mt_resolve_infra_config`
- **`scripts/lib/notify.sh`** — Deploy notification hooks

Every sub-script follows this pattern:
```bash
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"
mt_parse_args "$@"
source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config
```

## Conditional Restart System (mt_apply / mt_restart_if_changed)

Deploy scripts use `mt_apply` (wraps `kubectl apply`, tracks "configured"/"created" output) and `mt_restart_if_changed` (only does `kubectl rollout restart` when changes were detected) to avoid restarting pods unnecessarily during deploys. This prevents disrupting active Jitsi calls, document editing sessions, and user login sessions.

**Per-component tracking**: Jitsi and Admin Portal use separate trackers for different components. For example, a web-config change won't restart Prosody, and an admin-portal image change won't restart Redis. The tracking is scoped via `mt_reset_change_tracker` calls between component groups, with dependency flags like `_jitsi_secrets_changed` carried forward.

**Debugging deploy issues**: If a service isn't picking up new config after a deploy, the conditional restart system may be the cause. The `mt_apply` wrapper detects changes by grepping kubectl output for "configured"/"created" — if `kubectl apply` reports "unchanged" but the pod needs restarting (e.g., a Secret's data changed but its metadata didn't), the restart will be skipped. To force a restart, run `kubectl rollout restart <resource> -n <namespace>` manually.

**When modifying deploy scripts**: If you add a new ConfigMap or Secret that a pod depends on, make sure its `kubectl apply` is wrapped with `mt_apply` so changes are tracked. If you add it with plain `kubectl apply`, config changes won't trigger a pod restart.

## Key Env Vars (set by config.sh)

`MT_ENV`, `MT_TENANT`, `KUBECONFIG`, `NS_MATRIX`, `NS_FILES`, `NS_INGRESS`, `NS_AUTH`, `NS_DB`, `NS_MONITORING`, `MATRIX_HOST`, `JITSI_HOST`, `FILES_HOST`, `AUTH_HOST`, `TENANT_DOMAIN`, `TENANT_ENV_DNS_LABEL`, `INFRA_DOMAIN`, `PG_HOST` (points to PgBouncer in-cluster, not the external PG VM directly), `S3_CLUSTER`, `RELEASE_VERSION`

## Build/Test Commands

- **Admin Portal**: `cd apps/admin-portal && npm install && npm start`
- **Terraform**: `cd phase1 && terraform init && terraform plan`
- **Helmfile lint**: `cd apps && helmfile -e dev lint`
- **Check pods**: `kubectl --kubeconfig=kubeconfig.<env>.yaml get pods -A`
- **Test email**: `./scripts/test-email-system -e dev -t example`
- **Check health**: `./scripts/check-health -e dev [-t example]`
- **Verify endpoints**: `./scripts/verify-endpoints -e dev -t example`

## Mandatory OSS Compliance Check on Commits

**IMPORTANT**: Before EVERY `git commit`, you MUST:

1. **Run the `oss-compliance` agent** via the Task tool to scan all staged changes
2. **If CRITICAL or HIGH findings exist**: Alert the user with the full findings list and ask whether to abort or continue. Use `AskUserQuestion` with options: "Abort and fix issues" / "Continue anyway"
3. **If clean**: Proceed with the commit

This ensures no real tenant domains, personal info, hardcoded credentials, or private registry references leak into git history. The main repo is **public** — only `config/` submodules contain private content. See `.claude/agents/oss-compliance.md` for the full compliance model.

Never skip this step, even if the changes seem trivial.

## Mandatory Security Review on PR Operations

**IMPORTANT**: Before EVERY PR creation (`gh pr create`) or PR update push (`git push` to an existing PR branch), you MUST:

1. **Run ALL THREE agents** via the Task tool: `oss-compliance`, `security-reviewer`, AND `version-bump`
2. **If CRITICAL or HIGH findings exist from either compliance/security agent**: Alert the user in the terminal with the full findings list and ask whether to abort or continue. Use `AskUserQuestion` with options: "Abort and fix issues" / "Continue anyway"
3. **The `version-bump` agent** will automatically bump portal versions and stage/commit if needed — no user prompt required
4. **For new PRs**: Include both the OSS compliance and security review output in the PR body under `## OSS Compliance Review` and `## Security Review` sections
5. **For PR updates**: Post both review outputs as a comment on the existing PR using `gh pr comment`
6. **If no issues found**: Include clean confirmations in the PR body/comment

Never skip this step, even if the changes seem trivial.

## Fail Fast — Never Silently Skip

**CRITICAL**: Scripts must fail immediately and loudly when a required value is missing. Never silently skip logic because an env var, secret, or parameter is empty/null/unset.

- Use `: "${VAR:?error message}"` for required env vars
- `set -euo pipefail` — the `u` flag catches unset variables
- When a guard check determines a feature should run, **validate its required inputs and fail if missing** — don't make the entire feature optional by wrapping it in an existence check
- Security-critical paths (locking, auth, encryption) must NEVER be optional
- The only exception is truly optional features (e.g., SES relay credentials). But if a feature is expected to run, its inputs are required.

## DNS Safety Rules

- **NEVER modify the base domain DNS record.** The base domain is a CNAME pointing to an external website. The `create_env` script must not create A/CNAME records for the bare domain.
- Records managed by `manage_infra --dns` (via `scripts/manage-dns.sh`) should not be duplicated or overridden by `create_env`. Managed records include: base domain CNAME, LB A record (`lb2.prod` / `lb1.<label>`), `mail` A record, MX, SPF, DKIM, DMARC, TURN SRV.
- The `create_env` script manages per-tenant CNAME records (subdomains like `matrix`, `element`, `docs`, etc.) and tenant-specific email DNS records only.

## Troubleshooting

- **Tailscale connectivity issues**: If K8s pods can't reach the PostgreSQL VM, check that the PgBouncer pod's Tailscale sidecar is connected to the Headscale mesh. Verify with `tailscale status` inside the sidecar. Ensure the pre-auth key hasn't expired.
- **PgBouncer SCRAM-SHA-256**: PgBouncer requires `auth_type = scram-sha-256` to match PostgreSQL's default. If auth fails, check that `userlist.txt` has the correct SCRAM hashes, not plaintext passwords.
- **Stale SSH host keys**: If Ansible fails with SSH errors against a VM that was rebuilt, remove the old key: `ssh-keygen -R <ip>`, then re-run `manage_infra --ansible`.

## Release Versioning

The platform has a root `VERSION` file (semver, e.g. `0.8.0`) and a deploy-time release string computed by `scripts/lib/release.sh`:

- **Format**: `<version>-<short-hash>[-M]` — e.g. `0.8.0-ab292eb` (clean) or `0.8.0-ab292eb-M` (dirty/modified)
- **Env var**: `RELEASE_VERSION` — exported by `_mt_load_release_version`, injected into portal containers
- **Endpoint**: `GET /version` on admin and account portals — returns `{ version, environment }` (public, no auth)
- **Changelog**: `CHANGELOG.md` in repo root, [Keep a Changelog](https://keepachangelog.com/) format

To cut a release: update `VERSION`, add a `CHANGELOG.md` entry, commit, tag `v<version>`.

## Important Notes

- Kubeconfig files: `kubeconfig.prod.yaml`, `kubeconfig.dev.yaml` (at repo root)
- Secrets files are gitignored — use `.example` files as templates
- Postfix image: `boky/postfix:v5.1.0`, OpenDKIM sidecar: `instrumentisto/opendkim:2.10`
- Keycloak image: `quay.io/keycloak/keycloak:26.5.1`
- DKIM selector: `default` (e.g., `default._domainkey.example.com`)
- Stalwart ports are unique per tenant (hostPort mapping): SMTPS 465xx, Submission 587xx, IMAPS 993x
- PostgreSQL runs on a dedicated external Linode VM per environment, connected to the K8s cluster via the Headscale/Tailscale WireGuard mesh. K8s pods connect through PgBouncer (in `infra-db` namespace) which has a Tailscale sidecar. `PG_HOST` points to `pgbouncer.infra-db.svc.cluster.local`.
