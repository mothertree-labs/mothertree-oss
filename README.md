# Mothertree

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

- Linode account with API token
- Cloudflare account with API token and zone ID
- A domain with DNS managed by Cloudflare
- `terraform`, `kubectl`, `helm`, `helmfile`, `yq` installed

### 1. Configure

```bash
# Copy example configs
cp terraform.tfvars.example terraform.tfvars
cp secrets.tfvars.env.example secrets.tfvars.env

# Create your tenant config
cp -r tenants/example tenants/my-org
# Edit tenants/my-org/dev.config.yaml with your domain and settings
# Copy and fill in secrets: cp tenants/my-org/dev.secrets.yaml.example tenants/my-org/dev.secrets.yaml
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
phase1/          Terraform: LKE cluster, VPN server, TURN server, base DNS
infra/           Terraform: K8s infra (Postfix, cert-manager, DNS records, certs)
modules/         Terraform modules: lke-cluster/, dns/, openvpn-server/, helm-bootstrap/
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
tenants/         Per-tenant config: <name>/{env}.config.yaml + {env}.secrets.yaml
ansible/         VPN server config (OpenVPN, Postfix relay)
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

## Deployment Commands

```bash
# Deploy all tenant apps
./scripts/create_env --tenant=<name> <env>

# Deploy individual components
MT_ENV=dev apps/deploy-docs.sh
MT_ENV=dev apps/deploy-jitsi.sh
MT_ENV=dev apps/deploy-stalwart.sh
MT_ENV=dev apps/deploy-nextcloud.sh
MT_ENV=dev TENANT=<name> apps/deploy-roundcube.sh

# Helmfile (Synapse, Element)
cd apps && helmfile -e dev -l tier=apps sync
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and contribution guidelines.

## Security

If you discover a security vulnerability, please report it responsibly by opening a GitHub issue marked `[SECURITY]` or contacting the maintainers directly. Do not open a public issue with exploit details.

## License

This project is licensed under the GNU Affero General Public License v3.0 — see [LICENSE](LICENSE) for details.
