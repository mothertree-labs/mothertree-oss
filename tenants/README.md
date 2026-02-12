# Tenant Configuration

This directory contains configuration files for each tenant in the Mothertree multi-tenant infrastructure.

## Directory Structure

```
tenants/
├── README.md                  # This file
└── <tenant-name>/             # One directory per tenant
    ├── prod.config.yaml       # Production environment config (non-secrets)
    ├── prod.secrets.yaml      # Production secrets (gitignored)
    ├── prod.secrets.yaml.example  # Template for prod secrets
    ├── dev.config.yaml        # Development environment config (non-secrets)
    ├── dev.secrets.yaml       # Development secrets (gitignored)
    └── dev.secrets.yaml.example   # Template for dev secrets
```

## File Types

### Config Files (`*.config.yaml`)

Non-secret configuration that can be safely committed to git:

- Tenant metadata (name, display name)
- DNS settings (domain, subdomains, env label)
- Keycloak realm name
- Resource allocation preferences
- Feature flags

### Secrets Files (`*.secrets.yaml`)

Sensitive configuration that is **gitignored**:

- API tokens (Cloudflare, Linode)
- Database passwords
- OIDC client secrets
- S3 storage credentials
- SSH keys

### Example Files (`*.secrets.yaml.example`)

Templates showing the structure of secrets files with placeholder values. Use these as a starting point when setting up a new tenant or environment.

## Adding a New Tenant

1. Create a directory for the tenant:
   ```bash
   mkdir tenants/new-tenant
   ```

2. Copy the example config files as templates:
   ```bash
   cp tenants/.example/prod.config.yaml tenants/new-tenant/prod.config.yaml
   cp tenants/.example/dev.config.yaml tenants/new-tenant/dev.config.yaml
   ```

3. Edit the config files with tenant-specific values

4. Copy the secrets example and fill in real values:
   ```bash
   cp tenants/.example/prod.secrets.yaml.example tenants/new-tenant/prod.secrets.yaml
   # Edit prod.secrets.yaml with real credentials
   ```

5. Deploy the tenant:
   ```bash
   ./scripts/create_env --tenant=new-tenant prod
   ```

## Configuration Reference

### Config File Structure

```yaml
tenant:
  name: tenant-name           # Lowercase identifier (used in namespaces)
  display_name: "Human Name"  # Display name for UI
  env: prod                   # Environment (prod/dev)

dns:
  domain: tenant-domain.org   # Primary domain
  matrix_subdomain: matrix    # -> matrix.tenant-domain.org
  element_subdomain: element  # -> element.tenant-domain.org
  docs_subdomain: docs        # -> docs.tenant-domain.org
  files_subdomain: files      # -> files.tenant-domain.org
  auth_subdomain: auth        # -> auth.tenant-domain.org
  jitsi_subdomain: jitsi      # -> jitsi.tenant-domain.org
  home_subdomain: home        # -> home.tenant-domain.org
  env_dns_label: ""           # Empty for prod, "dev" for dev environment

keycloak:
  realm: tenant-realm         # Keycloak realm name

resources:
  synapse:
    replicas: 1
    memory_limit: 2Gi
  nextcloud:
    replicas: 1
    storage_size: 10Gi

s3:
  bucket_prefix: "tenant-org"    # Bucket naming prefix
  docs_bucket: "docs-media-tenant-org"      # Docs media bucket
  matrix_bucket: "matrix-media-tenant-org"  # Matrix media bucket (future)
  files_bucket: "files-media-tenant-org"    # Nextcloud files bucket
  cluster: "us-lax-1"           # S3 cluster/region (Linode Los Angeles)

features:
  jitsi_enabled: true
  matrix_enabled: true
  docs_enabled: true
  files_enabled: true
  smtp_enabled: true
```

### Secrets File Structure

```yaml
linode:
  token: "..."                # Linode API token

cloudflare:
  api_token: "..."            # Cloudflare API token
  zone_id: "..."              # Cloudflare zone ID

tls:
  email: "..."                # Email for Let's Encrypt certificates

database:
  postgres_password: "..."    # PostgreSQL superuser password
  synapse_password: "..."     # Synapse database password
  docs_password: "..."        # Docs database password

oidc:
  matrix_client_secret: "..." # Matrix OIDC client secret
  docs_client_secret: "..."   # Docs OIDC client secret
  nextcloud_client_secret: "..." # Nextcloud OIDC client secret

matrix:
  registration_shared_secret: "..."  # Matrix registration secret
  synapse_password: "..."            # Synapse database password

turn:
  shared_secret: "..."        # TURN server shared secret

s3_matrix:
  access_key: "..."           # S3 access key for Matrix media
  secret_key: "..."           # S3 secret key for Matrix media

s3_docs:
  access_key: "..."           # S3 access key for Docs media
  secret_key: "..."           # S3 secret key for Docs media

s3_files:
  access_key: "..."           # S3 access key for Nextcloud files
  secret_key: "..."           # S3 secret key for Nextcloud files

ssh:
  public_key: "ssh-ed25519 ..."  # SSH public key for servers

grafana:
  admin_password: "..."       # Grafana admin password

jitsi:
  jwt_app_secret: "..."       # Jitsi JWT signing secret
```

**Note**: You can use the same S3 access key for all buckets if they're in the same Linode account.

## Usage with Scripts

### Deploy Tenant Environment

```bash
# Deploy example tenant to production
./scripts/create_env --tenant=example prod

# Deploy with alertbot user creation
./scripts/create_env --tenant=example prod --create-alert-user

# Deploy to dev environment
./scripts/create_env --tenant=example dev
```

### Infrastructure Management

Infrastructure (cluster, VPN, TURN) is managed separately and shared across tenants:

```bash
# Create/update shared infrastructure
./scripts/manage_infra prod

# Preview infrastructure changes
./scripts/manage_infra prod --plan
```

## Namespace Structure

The multi-tenant architecture uses a consistent namespace naming convention:

### Infrastructure Namespaces (`infra-*`)

Shared components that serve all tenants:

| Namespace | Contents |
|-----------|----------|
| `infra-db` | PostgreSQL (shared database) |
| `infra-auth` | Keycloak (shared SSO/authentication) |
| `infra-monitoring` | Prometheus, Grafana, Vector |
| `infra-ingress` | Public ingress controller |
| `infra-ingress-internal` | VPN-only internal ingress |
| `infra-cert-manager` | Certificate management |
| `infra-mail` | Postfix SMTP server |

### Tenant Namespaces (`tn-<tenant>-*`)

Isolated application instances per tenant:

| Namespace | Contents |
|-----------|----------|
| `tn-<tenant>-matrix` | Synapse, Element Web |
| `tn-<tenant>-jitsi` | Jitsi (prosody, jicofo, jvb, web) |
| `tn-<tenant>-docs` | Docs backend, frontend, y-provider, Redis |
| `tn-<tenant>-files` | Nextcloud |

**Example for a tenant named "example":**
- `tn-example-matrix`
- `tn-example-jitsi`
- `tn-example-docs`
- `tn-example-files`

### Benefits

- Easy filtering in kubectl: `kubectl get pods -n tn-example-*`
- Clear separation between infrastructure and tenant resources
- Supports multiple tenants with complete isolation

## Security Notes

- **Never commit `*.secrets.yaml` files** - they are gitignored
- Secrets files contain sensitive credentials
- Use strong, unique passwords for each tenant/environment
- Rotate credentials periodically
- Store backup copies of secrets securely (password manager, etc.)
