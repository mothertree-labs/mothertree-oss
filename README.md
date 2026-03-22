# Mothertree

_Build status:_

[![status-badge](https://ci.mother-tree.org/api/badges/1/status.svg)](https://ci.mother-tree.org/repos/1)

Multi-tenant collaboration platform on Kubernetes. Provides Matrix (chat), Element (web client), Docs (collaborative editing), Nextcloud (files), Jitsi (video conferencing), and email (Stalwart + Roundcube) per tenant — with shared infrastructure for auth (Keycloak), database (PostgreSQL), monitoring (Prometheus/Grafana), and ingress (NGINX).

## Architecture

```
                          Cloudflare DNS
                               |
                        NGINX Ingress (LKE)
                       /       |        \
              tenant-1/   tenant-2/   shared-infra/
              ┌──────────┐ ┌──────────┐ ┌──────────────┐
              │ Matrix   │ │ Matrix   │ │ Keycloak     │
              │ Element  │ │ Element  │ │ PostgreSQL   │
              │ Docs     │ │ Docs     │ │ Postfix+DKIM │
              │ Nextcloud│ │ Nextcloud│ │ Prometheus   │
              │ Jitsi    │ │ Jitsi    │ │ Grafana      │
              │ Stalwart │ │ Stalwart │ │ cert-manager │
              │ Roundcube│ │ Roundcube│ └──────────────┘
              └──────────┘ └──────────┘
```

### Tech Stack

- **Cloud**: Linode (LKE cluster, g6-standard-2 nodes)
- **IaC**: Terraform (workspaces per env) + Ansible (VPN/Postfix relay)
- **K8s Deployment**: Helmfile + Helm charts + raw manifests
- **DNS**: Cloudflare API
- **Auth**: Keycloak (OIDC, per-tenant realms, passkey support)
- **Email**: VPN Postfix -> K8s Postfix+OpenDKIM -> per-tenant Stalwart
- **Monitoring**: Prometheus + Grafana + AlertManager + Vector (logs)

## Quick Start

### Prerequisites

**Accounts:**
- Linode account with API token
- Cloudflare account with API token and zone ID
- A domain with DNS managed by Cloudflare

**Required CLI tools:**

| Tool | Min Version | Purpose |
|------|-------------|---------|
| `terraform` | >= 1.0 | Infrastructure provisioning (LKE, DNS, VPN) |
| `kubectl` | >= 1.27 | Kubernetes cluster management |
| `helm` | >= 3.0 | Kubernetes package management |
| `helmfile` | >= 1.0 | Multi-chart Helm orchestration (v0.x will **not** work) |
| `kustomize` | >= 5.0 | Kubernetes manifest customization (helmfile exec dependency) |
| `yq` | >= 4.0 | YAML parsing (tenant config files) |
| `jq` | any | JSON parsing (API responses, secrets) |
| `envsubst` | any | Template variable substitution (from `gettext` package) |
| `openssl` | any | TLS cert and secret generation |
| `curl` | any | HTTP API calls |
| `node` | >= 22 LTS | Admin and account portal development |

> **Note**: `kustomize` is not called directly by any deploy script, but helmfile invokes it internally. If missing, helmfile will fail with `exec: "kustomize": executable file not found in $PATH`.

**Optional tools** (auto-detected; scripts degrade gracefully if absent):

| Tool | When needed |
|------|-------------|
| `ansible-playbook` | VPN/Postfix relay setup (required by `deploy_infra` VPN section) |
| `docker` | Building container images |
| `gh` | GitHub CLI (PR workflows) |
| `dig` | DNS verification in `deploy_infra` and `verify-endpoints` (skipped if missing) |
| `swaks` | Email delivery testing in `test-email-system` (skipped if missing) |
| `psql` | Direct PostgreSQL administration |
| `linode-cli` | Linode resource management, S3 buckets, teardown (skipped if missing) |

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed installation instructions on macOS and Linux.

### 1. Configure

```bash
# Initialize submodules (if you have access to private config repos)
make setup

# OR create your own tenant config from the example template
cp -r tenants/.example tenants/my-org
# Edit tenants/my-org/dev.config.yaml with your domain and settings
# Copy and fill in secrets: cp tenants/my-org/dev.secrets.yaml.example tenants/my-org/dev.secrets.yaml

# Copy Terraform and infra secrets
cp terraform.tfvars.example terraform.tfvars
cp secrets.tfvars.env.example secrets.tfvars.env
```

### 2. Deploy Infrastructure

Deployment follows three phases:

```bash
# Phase 1: LKE cluster, VPN server, TURN server, base DNS
./scripts/manage_infra dev

# Phase 2: Shared infra (ingress, certs, PostgreSQL, Keycloak, Postfix, monitoring)
./scripts/deploy_infra dev

# Phase 3: Tenant apps (Matrix, Element, Docs, Nextcloud, Jitsi, Stalwart, Roundcube)
./scripts/create_env --tenant=my-org dev
```

### 3. Verify

```bash
kubectl get pods -A | grep -E 'infra-|tn-my-org'
```

## Directory Structure

```
config/          Private config submodules (optional, for operators with access)
  platform/      Container registry, infra sizing, theme overrides
  tenants/       Real tenant configs (domains, databases, S3 buckets)
phase1/          Terraform: LKE cluster, VPN server, TURN server, base DNS
modules/         Terraform modules: lke-cluster/, openvpn-server/, helm-bootstrap/
apps/            Application deployment layer
  helmfile.yaml.gotmpl   Main helmfile (Go-templated, env-aware)
  values/                Base Helm values
  environments/          Dev/prod-specific value overrides
  manifests/             Raw K8s manifests per component
  deploy-*.sh            Per-component deployment scripts
  themes/                Keycloak login/email themes
  admin-portal/          Node.js admin app (Express + EJS + OIDC)
  account-portal/        Node.js user self-service app
scripts/         Orchestration scripts (manage_infra, deploy_infra, create_env)
  lib/             Shared libraries (common.sh, config.sh, paths.sh, etc.)
tenants/         Tenant config template (.example/) or local configs
ansible/         VPN server config (OpenVPN, Postfix relay)
ci/              CI server (Woodpecker) — Terraform, Ansible, pipeline scripts
.woodpecker/     CI pipeline definitions
```

## Multi-Tenancy

Each tenant gets isolated Kubernetes namespaces:

| Namespace | Contents |
|-----------|----------|
| `tn-<tenant>-matrix` | Synapse + Element Web + Synapse Admin |
| `tn-<tenant>-docs` | Docs backend, frontend, y-provider, Redis |
| `tn-<tenant>-files` | Nextcloud |
| `tn-<tenant>-jitsi` | Jitsi (Prosody, Jicofo, JVB, Web) |
| `tn-<tenant>-mail` | Stalwart mail server |
| `tn-<tenant>-webmail` | Roundcube webmail |
| `tn-<tenant>-admin` | Admin portal |

Shared infrastructure lives in `infra-*` namespaces (db, auth, ingress, monitoring, mail, cert-manager).

See [tenants/README.md](tenants/README.md) for tenant configuration details.

## Deployment

### CI/CD (automatic)

Woodpecker CI deploys automatically:
- **Pull requests** deploy to dev (leased tenant slot), then run E2E tests
- **Merges to main** deploy to prod (all tenants) after the gate passes

Pipeline: validate → build-images → deploy-dev → E2E → gate → deploy-prod

### Manual deployment

```bash
# Deploy all tenant apps
./scripts/create_env -e <env> -t <tenant>

# Deploy individual components
./apps/deploy-docs.sh -e dev -t my-org
./apps/deploy-jitsi.sh -e dev -t my-org
./apps/deploy-stalwart.sh -e dev -t my-org
./apps/deploy-nextcloud.sh -e dev -t my-org

# Helmfile (Synapse, Element)
cd apps && helmfile -e dev -l tier=apps sync
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and contribution guidelines.

See [CLOUDFLARE_CACHING.md](CLOUDFLARE_CACHING.md) for CDN cache configuration (Cloudflare Cache Rules + origin headers).

## Security

If you discover a security vulnerability, please report it responsibly by opening a GitHub issue marked `[SECURITY]` or contacting the maintainers directly. Do not open a public issue with exploit details.

## License

This project is licensed under the GNU Affero General Public License v3.0 — see [LICENSE](LICENSE) for details.
