# Tenant Creation Guide

This guide explains how to create and deploy a new tenant on the Mother Tree multi-tenant infrastructure.

## Overview

The Mother Tree platform is a multi-tenant Kubernetes deployment that provides:
- **Matrix/Synapse** - Secure chat and communication
- **Element Web** - Matrix web client
- **Jitsi** - Video conferencing with guest/moderator mode
- **LaSuite Docs** - Collaborative document editing
- **Nextcloud** - File storage and sharing
- **Stalwart Mail** - Full-featured email server (IMAP/SMTP) with webmail

Each tenant gets isolated namespaces while sharing common infrastructure (database, auth, monitoring, ingress).

## Prerequisites

Before creating a new tenant, ensure:

1. **Infrastructure exists** - Run `./scripts/manage_infra <env>` at least once
2. **Shared infrastructure deployed** - Run `./scripts/deploy_infra <env>` at least once
3. **Required tools installed**:
   - `kubectl`
   - `helm` (v3+)
   - `helmfile`
   - `yq` (YAML processor)
   - `terraform`
4. **DNS Zone access** - Cloudflare API token with Zone:Edit permissions
5. **S3 buckets** - Linode Object Storage buckets for docs, files (Nextcloud), and matrix media

## Step-by-Step: Creating a New Tenant

### Step 1: Create Tenant Directory

```bash
# Replace 'newtenant' with your tenant name (lowercase, alphanumeric, no spaces)
TENANT_NAME="newtenant"
mkdir -p tenants/$TENANT_NAME
```

### Step 2: Create Configuration Files

#### 2a. Add tenant domain to infrastructure configuration

Before creating the tenant, add the tenant's email domain to the allowed sender domains list in `infra/variables.tf`:

```terraform
variable "smtp_allowed_sender_domains" {
  description = "Domains allowed to send email through Postfix (space-separated). Must include all tenant domains."
  type        = string
  default     = "example.com newtenant.com"  # Add your domain here (space-separated)
}
```

**Note**: The `create_env` script will automatically add the domain at runtime if it's missing, so deployments will work immediately. However, adding it to `variables.tf` ensures the configuration is preserved when `deploy_infra` is run again.

#### 2b. Create the config file (`<env>.config.yaml`)

Copy an existing config file and customize it:

```bash
cp tenants/example/prod.config.yaml tenants/$TENANT_NAME/prod.config.yaml
```

Edit the file with your tenant's values:

```yaml
# Tenant metadata
tenant:
  name: newtenant              # Lowercase identifier (used in namespace names)
  display_name: "New Tenant"   # Display name for UI
  env: prod                    # Environment: prod or dev

# DNS Configuration
dns:
  domain: newtenant.com        # Primary domain (must have Cloudflare zone)
  
  # Subdomains (relative to domain)
  matrix_subdomain: matrix     # -> matrix.newtenant.com
  element_subdomain: element   # -> element.newtenant.com
  synapse_subdomain: synapse   # -> synapse.newtenant.com (admin API)
  docs_subdomain: docs         # -> docs.newtenant.com
  files_subdomain: files       # -> files.newtenant.com
  auth_subdomain: auth         # -> auth.newtenant.com
  jitsi_subdomain: jitsi       # -> jitsi.newtenant.com
  home_subdomain: home         # -> home.newtenant.com
  mail_subdomain: mail         # -> mail.newtenant.com (webmail, IMAP, SMTP)
  
  # Environment DNS label
  # For prod: leave empty or "null" (matrix.newtenant.com)
  # For dev: set to "dev" (matrix.dev.newtenant.com)
  env_dns_label: ""
  
  # Cookie domain for shared authentication
  cookie_domain: .newtenant.com

# Keycloak configuration
keycloak:
  realm: newtenant             # Realm name in shared Keycloak

# SMTP configuration
smtp:
  domain: newtenant.com        # From address domain

# Database names (tenant-specific)
database:
  docs_db: docs_newtenant
  nextcloud_db: nextcloud_newtenant
  stalwart_db: stalwart_newtenant              # Mail server metadata

# S3 bucket configuration
s3:
  bucket_prefix: newtenant-com
  docs_bucket: docs-media-newtenant-com
  matrix_bucket: matrix-media-newtenant-com    # For future use (Matrix uses PVC currently)
  files_bucket: files-media-newtenant-com      # Nextcloud primary storage
  mail_bucket: mail-media-newtenant-com        # Email blob storage
  cluster: us-lax-1            # Linode Object Storage region (Los Angeles)

# Resource allocation
resources:
  synapse:
    replicas: 1
    memory_request: 512Mi
    memory_limit: 2Gi
    cpu_request: 250m
    cpu_limit: 1000m
  nextcloud:
    replicas: 1
    memory_request: 256Mi
    memory_limit: 1Gi
    storage_size: 10Gi
  docs:
    backend_replicas: 2
    frontend_replicas: 2
  jitsi:
    jvb_replicas: 1
  stalwart:
    memory_request: 256Mi
    memory_limit: 1Gi
    cpu_request: 100m
    cpu_limit: 500m
    storage_size: 1Gi          # Local storage for config/cache

# Feature flags
features:
  jitsi_enabled: true
  matrix_enabled: true
  docs_enabled: true
  files_enabled: true
  smtp_enabled: true           # Outbound email via shared Postfix
  turn_enabled: true
  mail_enabled: true           # Stalwart mail server (IMAP/SMTP/webmail)
```

#### 2c. Create the secrets example file

```bash
cp tenants/example/prod.secrets.yaml.example tenants/$TENANT_NAME/prod.secrets.yaml.example
```

#### 2d. Create the actual secrets file

```bash
cp tenants/$TENANT_NAME/prod.secrets.yaml.example tenants/$TENANT_NAME/prod.secrets.yaml
```

**IMPORTANT**: Never commit `*.secrets.yaml` files. They are automatically gitignored.

### Step 3: Gather Required Secrets

You need to obtain/generate the following secrets:

#### Infrastructure Tokens

| Secret | How to Obtain |
|--------|---------------|
| `linode.token` | [Linode API Tokens](https://cloud.linode.com/profile/tokens) - Create with Read/Write access |
| `cloudflare.api_token` | [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) - Zone:Edit for your domain |
| `cloudflare.zone_id` | Cloudflare Dashboard → Your Domain → Overview → Zone ID (right sidebar) |

#### Generate Random Passwords

For passwords, generate secure random strings. You can use:

```bash
# Generate a 24-character random password
openssl rand -base64 18

# Generate a 32-character hex string (for JWT secrets)
openssl rand -hex 32
```

| Secret | Type | Notes |
|--------|------|-------|
| `database.postgres_password` | Random password | Main PostgreSQL password |
| `database.redis_password` | Random password | Redis password |
| `database.docs_password` | Random password | Docs app DB password |
| `database.stalwart_password` | Random password | Stalwart mail DB password |
| `matrix.registration_shared_secret` | Random password | Matrix user registration |
| `matrix.synapse_password` | Random password | Synapse DB user password |
| `oidc.docs_client_secret` | Random password | Docs OIDC client secret |
| `oidc.nextcloud_client_secret` | Random password | Nextcloud OIDC secret |
| `oidc.stalwart_client_secret` | Random password | Stalwart mail OIDC secret |
| `turn.shared_secret` | Random password | TURN server auth |
| `grafana.admin_password` | Random password | Grafana admin login |
| `jitsi.jwt_app_secret` | Hex string (64 chars) | Jitsi JWT signing key |

#### S3 Object Storage

Three S3 buckets are needed per tenant/environment, using the naming pattern `<app>-media-[<env>-]<tenant>`:

| Bucket | Purpose | Example (prod) |
|--------|---------|----------------|
| Docs media | Document attachments and media | `docs-media-newtenant-com` |
| Matrix media | Matrix/Synapse media (future) | `matrix-media-newtenant-com` |
| Files (Nextcloud) | Primary file storage | `files-media-newtenant-com` |
| Mail (Stalwart) | Email blob storage | `mail-media-newtenant-com` |

**Note**: Matrix currently uses PVC block storage; the bucket is created for future S3 migration.

**⚠️ Important**: You can leave the S3 credentials as placeholders in your secrets file. The bucket creation script will automatically detect placeholders, create Linode Object Storage access keys, create the buckets, configure CORS, and update your secrets file.

| Secret | Value |
|--------|-------|
| `s3_matrix.access_key` | Access key for matrix media bucket (or placeholder) |
| `s3_matrix.secret_key` | Secret key for matrix media bucket (or placeholder) |
| `s3_docs.access_key` | Access key for docs media bucket (or placeholder) |
| `s3_docs.secret_key` | Secret key for docs media bucket (or placeholder) |
| `s3_files.access_key` | Access key for Nextcloud files bucket (or placeholder) |
| `s3_files.secret_key` | Secret key for Nextcloud files bucket (or placeholder) |
| `s3_mail.access_key` | Access key for Stalwart mail bucket (or placeholder) |
| `s3_mail.secret_key` | Secret key for Stalwart mail bucket (or placeholder) |

**Tip**: If you already have Linode Object Storage keys, you can enter them directly. Otherwise, use placeholders like `"PLACEHOLDER_S3_ACCESS_KEY"` and let the script create them.

#### SSH Key

Generate or use an existing SSH key for server access:

```bash
# Generate new key (if needed)
ssh-keygen -t ed25519 -C "admin@newtenant.com"
cat ~/.ssh/id_ed25519.pub
```

| Secret | Value |
|--------|-------|
| `ssh.public_key` | Full public key string (starts with `ssh-ed25519`) |

#### DKIM Email Signing Key

Each tenant needs a DKIM key pair for email authentication. Generate a 2048-bit RSA key:

```bash
# Generate private key
openssl genrsa 2048 > dkim.private

# Extract public key (single line, base64, for DNS TXT record)
openssl rsa -in dkim.private -pubout 2>/dev/null | grep -v "^-" | tr -d '\n'

# View private key (copy entire content including BEGIN/END lines)
cat dkim.private
```

Add to your secrets file:

```yaml
# DKIM key for email signing (SPF/DKIM/DMARC records created automatically)
dkim:
  private_key: |
    -----BEGIN PRIVATE KEY-----
    MIIEvgIBADANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
    ...paste full private key here...
    -----END PRIVATE KEY-----
  public_key: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA..."
```

| Secret | Value |
|--------|-------|
| `dkim.private_key` | Full RSA private key in PEM format (including BEGIN/END lines) |
| `dkim.public_key` | Base64 public key (single line, no headers) |

**Note**: The `create_env` script will automatically create SPF, DKIM, and DMARC DNS records using the Cloudflare API.

#### Other Settings

| Secret | Value |
|--------|-------|
| `tls.email` | Email for Let's Encrypt certificates (e.g., `admin@newtenant.com`) |
| `alertbot.access_token` | Leave as placeholder - auto-generated when you run with `--create-alert-user` |
| `github.pat` | Optional - for performance testing |

### Step 4: Complete the Secrets File

Edit `tenants/$TENANT_NAME/prod.secrets.yaml` with all the gathered values:

```yaml
# Example completed secrets file
linode:
  token: "abc123def456..."

cloudflare:
  api_token: "xyz789..."
  zone_id: "a1b2c3d4e5..."

tls:
  email: "admin@newtenant.com"

database:
  postgres_password: "SecurePass123!"
  redis_password: "AnotherSecure456!"
  docs_password: "DocsDBPass789!"
  stalwart_password: "StalwartDBPass789!"

oidc:
  docs_client_secret: "OIDCDocsSecret!"
  nextcloud_client_secret: "NextcloudSecret!"
  stalwart_client_secret: "StalwartOIDCSecret!"

matrix:
  registration_shared_secret: "MatrixRegSecret!"
  synapse_password: "SynapseDBPass!"

turn:
  shared_secret: "TurnServerSecret!"

s3_matrix:
  access_key: "ABCD1234..."
  secret_key: "abcdef123456..."

s3_docs:
  access_key: "EFGH5678..."
  secret_key: "ghijkl789012..."

s3_files:
  access_key: "IJKL9012..."
  secret_key: "mnopqr345678..."

s3_mail:
  access_key: "MNOP3456..."
  secret_key: "stuvwx901234..."

ssh:
  public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... admin@newtenant.com"

grafana:
  admin_password: "GrafanaAdmin123!"

jitsi:
  jwt_app_secret: "64characterhexstringhere..."

alertbot:
  access_token: "placeholder"

github:
  pat: ""

# Stalwart mail server admin password
stalwart:
  admin_password: "StalwartAdmin123!"

# DKIM key for email signing
dkim:
  private_key: |
    -----BEGIN PRIVATE KEY-----
    ...your generated private key...
    -----END PRIVATE KEY-----
  public_key: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA..."
```

### Step 5: Create S3 Buckets

Run the bucket creation script to set up all S3 buckets for your tenant:

```bash
# Create S3 buckets for production
TENANT=newtenant MT_ENV=prod ./create-tenant-s3-buckets.sh

# For development environment (if using)
TENANT=newtenant MT_ENV=dev ./create-tenant-s3-buckets.sh
```

**What this script does:**
1. Reads bucket names from your tenant config (`s3.docs_bucket`, `s3.matrix_bucket`, `s3.files_bucket`, `s3.mail_bucket`)
2. Checks credentials in your secrets file
3. If credentials are placeholders:
   - Creates new Linode Object Storage access keys via `linode-cli`
   - **Automatically updates your secrets file** with the new credentials
4. Creates the buckets using `s3cmd`
5. Configures CORS for each bucket (using domains from your config)

**Requirements:**
- `linode-cli` configured with your Linode API token
- `s3cmd`, `aws` CLI, `yq`, and `jq` installed

**Example output:**
```
==========================================
S3 Bucket Setup for: newtenant (prod)
==========================================
Cluster:  us-lax-1
Endpoint: https://us-lax-1.linodeobjects.com

--- Docs Bucket ---
[WARNING] Docs credentials are placeholders - creating new keys...
[SUCCESS] Created new Linode Object Storage keys: newtenant-prod-docs
[SUCCESS] Updated s3_docs in tenants/newtenant/prod.secrets.yaml
[SUCCESS] Created bucket: docs-media-newtenant-com
[SUCCESS] CORS configured for docs-media-newtenant-com
...
```

### Step 6: Create Dev Environment (Optional)

If you want a dev environment for testing:

```bash
# Create dev config (adjust dns.env_dns_label to "dev")
cp tenants/$TENANT_NAME/prod.config.yaml tenants/$TENANT_NAME/dev.config.yaml

# Edit to set:
# - tenant.env: dev
# - dns.env_dns_label: dev
# - dns.cookie_domain: .dev.newtenant.com
# - Reduce resource allocations

# Create dev secrets
cp tenants/$TENANT_NAME/prod.secrets.yaml tenants/$TENANT_NAME/dev.secrets.yaml

# Edit dev secrets if needed (can use same values or different for isolation)

# Create S3 buckets for dev (will auto-create new keys)
TENANT=$TENANT_NAME MT_ENV=dev ./create-tenant-s3-buckets.sh
```

### Step 7: Deploy the Tenant

```bash
# For production
./scripts/create_env --tenant=newtenant prod

# For development
./scripts/create_env --tenant=newtenant dev

# With alertbot user creation
./scripts/create_env --tenant=newtenant prod --create-alert-user
```

## Verification Checklist

After deployment, verify each component:

### 1. Check Namespaces

```bash
kubectl get namespaces | grep tn-newtenant
# Should see:
# tn-newtenant-matrix
# tn-newtenant-jitsi
# tn-newtenant-docs
# tn-newtenant-files
# tn-newtenant-mail (if mail_enabled)
```

### 2. Check Pods

```bash
# All tenant pods
kubectl get pods -n tn-newtenant-matrix
kubectl get pods -n tn-newtenant-jitsi
kubectl get pods -n tn-newtenant-docs
kubectl get pods -n tn-newtenant-files
kubectl get pods -n tn-newtenant-mail  # if mail_enabled
```

### 3. Check Ingresses

```bash
kubectl get ingress -A | grep newtenant
```

### 4. Test URLs

Open in browser:
- Matrix: `https://matrix.newtenant.com` (or `matrix.dev.newtenant.com`)
- Docs: `https://docs.newtenant.com`
- Files: `https://files.newtenant.com`
- Jitsi: `https://jitsi.newtenant.com`
- Mail/Webmail: `https://mail.newtenant.com` (if mail_enabled)
- Keycloak: `https://auth.newtenant.com`

### 5. Test Authentication

1. Go to any app (e.g., Docs)
2. Click "Sign in"
3. Should redirect to Keycloak
4. Create account or sign in
5. Should redirect back authenticated

### 6. Test Jitsi Guest/Moderator Mode

1. Open `https://jitsi.newtenant.com` (not logged in)
2. Create a room
3. Should see "Waiting for moderator" message
4. In another browser (logged in), join the same room
5. Conference should start

## Troubleshooting

### Common Issues

#### "Tenant secrets not found"
```
[ERROR] Tenant secrets not found: tenants/newtenant/prod.secrets.yaml
```
**Fix**: Create the secrets file from the example template.

#### "Kubeconfig not found"
```
[ERROR] Kubeconfig not found: kubeconfig.prod.yaml
```
**Fix**: Run `./scripts/manage_infra prod` first to create the cluster.

#### "Infrastructure namespace not found"
```
[ERROR] Infrastructure namespace infra-db not found.
```
**Fix**: Run `./scripts/deploy_infra prod` first to deploy shared infrastructure.

#### Pod stuck in Pending
```bash
kubectl describe pod <pod-name> -n tn-newtenant-matrix
# Look for events at the bottom
```
Common causes:
- PVC not binding (check storage class)
- Resource limits too high

#### TLS Certificate not issued
```bash
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>
```
Check:
- Cloudflare API token permissions
- DNS propagation (`dig matrix.newtenant.com`)

### Viewing Logs

```bash
# Synapse logs
kubectl logs -n tn-newtenant-matrix -l app.kubernetes.io/name=matrix-synapse

# Jitsi web logs
kubectl logs -n tn-newtenant-jitsi -l app=jitsi-web

# Docs backend logs
kubectl logs -n tn-newtenant-docs -l app=docs-backend
```

## Namespace Reference

### Infrastructure Namespaces (Shared)

| Namespace | Contents |
|-----------|----------|
| `infra-db` | PostgreSQL (shared database) |
| `infra-auth` | Keycloak (shared SSO) |
| `infra-monitoring` | Prometheus, Grafana, Vector |
| `infra-ingress` | Public nginx ingress controller |
| `infra-ingress-internal` | VPN-only internal ingress |
| `infra-cert-manager` | Certificate management |
| `infra-mail` | Postfix SMTP server |

### Tenant Namespaces

| Namespace Pattern | Contents |
|-------------------|----------|
| `tn-<tenant>-matrix` | Synapse, Element Web, Synapse Admin |
| `tn-<tenant>-jitsi` | Prosody, Jicofo, JVB, Jitsi Web |
| `tn-<tenant>-docs` | Docs backend, frontend, y-provider, Redis |
| `tn-<tenant>-files` | Nextcloud |
| `tn-<tenant>-mail` | Stalwart Mail (IMAP/SMTP/webmail) |

## Updating a Tenant

To update an existing tenant's configuration:

1. Edit the config or secrets file
2. Re-run the deployment:
   ```bash
   ./scripts/create_env --tenant=newtenant prod
   ```

Most changes are applied incrementally via Helm and kubectl.

## Removing a Tenant

To remove a tenant:

```bash
# Delete tenant namespaces
kubectl delete namespace tn-newtenant-matrix
kubectl delete namespace tn-newtenant-jitsi
kubectl delete namespace tn-newtenant-docs
kubectl delete namespace tn-newtenant-files
kubectl delete namespace tn-newtenant-mail  # if mail_enabled

# Optional: Clean up DNS records in Cloudflare
# Optional: Delete S3 buckets (data loss!)
# Optional: Remove tenant directory
rm -rf tenants/newtenant
```

**Warning**: Deleting namespaces will delete all data (PVCs) for that tenant!

## Related Documentation

- [tenants/README.md](tenants/README.md) - Tenant directory structure
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Full deployment guide
- [VPN_ACCESS_GUIDE.md](VPN_ACCESS_GUIDE.md) - VPN setup for internal access
- [MONITORING_GUIDE.md](MONITORING_GUIDE.md) - Monitoring and alerting
