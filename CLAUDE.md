# Mothertree Project

> **Private config override**: If `config/platform/CLAUDE.private.md` exists (from the private platform submodule), its instructions supplement and take precedence over this file.

Multi-tenant collaboration platform on Kubernetes. Provides Matrix (chat), Docs, Files, Jitsi (video), and Email per tenant.

## Tech Stack

- **Cloud**: Linode (LKE cluster, g6-standard-4, us-lax region, autoscaler min=1 max=5)
- **IaC**: Terraform (workspaces per env) + Ansible (VPN/Postfix on VPN server)
- **K8s Deployment**: Helmfile + Helm charts + raw manifests (apps/manifests/)
- **DNS**: Cloudflare API (A, CNAME, MX, TXT, SRV records)
- **Storage**: PostgreSQL (shared, per-tenant DBs), S3 (Linode Objects, us-lax-1), Redis (per-tenant)
- **Auth**: Keycloak (OIDC, per-tenant realms)
- **Email**: VPN Postfix -> K8s Postfix+OpenDKIM -> per-tenant Stalwart
- **Monitoring**: Prometheus + Grafana + AlertManager + Vector (logs)
- **Tools**: helmfile, yq, kubectl, terraform, ansible, gh (GitHub CLI)

## Directory Map

```
config/          Private config submodules (optional, for operators)
  platform/      Container registry, infra sizing, theme overrides, CLAUDE.private.md
  tenants/       Per-tenant configs (domains, databases, S3 buckets, resources)
phase1/          Terraform: LKE cluster, VPN server, TURN server, base DNS
infra/           Terraform: K8s infra (Postfix, cert-manager, DNS records, certs)
  templates/     Postfix main.cf, master.cf, aliases, opendkim.conf templates
modules/         Terraform modules: lke-cluster/, dns/, openvpn-server/, helm-bootstrap/
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
tenants/         Per-tenant config (or use config/tenants/ submodule)
  .example/      Template for new tenants
ansible/         VPN server config (OpenVPN, Postfix relay, Unbound DNS)
```

## Three-Phase Deployment

1. **`./scripts/manage_infra -e <env>`** — Terraform, DNS, LKE firewall, Ansible (runs locally, requires VPN)
2. **`./scripts/deploy_infra -e <env>`** — Shared K8s infra (ingress, certs, PostgreSQL, Keycloak, Postfix, monitoring) — CI-able
3. **`./scripts/create_env -e <env> -t <tenant> [--create-alert-user]`** — Tenant apps (Synapse, Element, Docs, Files, Jitsi, Stalwart, Roundcube, Admin Portal) — CI-able

`manage_infra` supports phase selectors: `--phase1`, `--dns`, `--firewall`, `--ansible` (default: all).
`--plan` and `--destroy` are phase1-only modifiers.

On initial setup of a new environment, DNS must run after deploy_infra creates the ingress:
```bash
manage_infra -e <env> --phase1          # Create cluster, VPN, TURN
deploy_infra -e <env>                   # Deploy K8s infra (creates ingress LB)
manage_infra -e <env> --dns             # Create DNS records (needs LB IP)
manage_infra -e <env> --firewall --ansible  # Firewall rules + VPN config
```

Sub-scripts are fully self-contained and independently runnable:
```bash
./apps/deploy-docs.sh -e dev -t example
./apps/deploy-stalwart.sh -e prod -t acme
```

## Namespace Conventions

- `infra-*` — Shared infrastructure: `infra-ingress`, `infra-ingress-internal`, `infra-cert-manager`, `infra-db`, `infra-auth`, `infra-monitoring`, `infra-mail`
- `tn-<tenant>-*` — Per-tenant: `tn-<tenant>-matrix`, `tn-<tenant>-docs`, `tn-<tenant>-files`, `tn-<tenant>-jitsi`, `tn-<tenant>-mail`, `tn-<tenant>-webmail`, `tn-<tenant>-admin`

## DNS Patterns

- **Prod**: `matrix.example.com`, `mail.example.com`, `lb1.prod.example.com`
- **Dev**: `matrix.dev.example.com`, `mail.dev.example.com`, `lb1.dev.example.com`
- **Prod VPN/internal**: `grafana.prod.example.com`, `prometheus.prod.example.com` (prefix is `prod`, NOT `internal`)
- **Dev VPN/internal**: `grafana.internal.dev.example.com`, `prometheus.internal.dev.example.com` (prefix is `internal.dev`)
- Tenant subdomains CNAME to `lb1.{env_label}.example.com`
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

## Key Env Vars (set by config.sh)

`MT_ENV`, `MT_TENANT`, `KUBECONFIG`, `NS_MATRIX`, `NS_FILES`, `NS_INGRESS`, `NS_AUTH`, `NS_DB`, `NS_MONITORING`, `MATRIX_HOST`, `JITSI_HOST`, `FILES_HOST`, `AUTH_HOST`, `TENANT_DOMAIN`, `TENANT_ENV_DNS_LABEL`, `INFRA_DOMAIN`, `PG_HOST`, `S3_CLUSTER`, `RELEASE_VERSION`

## Build/Test Commands

- **Admin Portal**: `cd apps/admin-portal && npm install && npm start`
- **Terraform**: `cd phase1 && terraform init && terraform plan` (or `cd infra`)
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

## DNS Safety Rules

- **NEVER modify the base domain DNS record.** The base domain is a CNAME managed by Terraform (`modules/dns/main.tf` `base_domain_cname`) pointing to an external website. The `create_env` script must not create A/CNAME records for the bare domain.
- Records managed by Terraform (in `modules/dns/` and `infra/main.tf`) should not be duplicated or overridden by `create_env`. Terraform-managed records include: base domain CNAME, `lb1` A record, `mail` A record, MX, SPF, DKIM, DMARC, TURN SRV.
- The `create_env` script manages per-tenant CNAME records (subdomains like `matrix`, `element`, `docs`, etc.) and tenant-specific email DNS records only.

## Troubleshooting

- **`deploy_infra` fails with "Connection closed by UNKNOWN port 65535" for turn-server**: This means the SSH host key for the VPN tunnel IP in `~/.ssh/known_hosts` is stale (e.g., VPN server was rebuilt). The ProxyJump through the VPN fails host key verification, producing the misleading port 65535 error. **Fix**: `ssh-keygen -R <tunnel-ip>` (prod: `10.8.0.1`, dev: `10.9.0.1`), then re-run `deploy_infra`.

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
- PostgreSQL supports standalone and replication modes (PG_HOST switches between them)
