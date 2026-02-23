---
name: tenant-researcher
description: "Research tenant configuration — config structure, required fields, existing tenant setups, secrets layout. Use when creating new tenants, modifying tenant config, or understanding multi-tenancy patterns."
allowed-tools: ["Read", "Glob", "Grep"]
---

# Tenant Configuration Researcher

## Current Tenants

```
!ls -la tenants/*/
```

```
!ls tenants/.example/
```

## Your Task

Research tenant configuration to answer the user's question. Understand the config schema, compare tenants, and identify required fields.

## Tenant File Layout

```
tenants/<name>/
  dev.config.yaml          # Dev environment configuration
  dev.secrets.yaml          # Dev secrets (gitignored)
  dev.secrets.yaml.example  # Secrets template
  prod.config.yaml          # Prod environment configuration
  prod.secrets.yaml         # Prod secrets (gitignored)
  prod.secrets.yaml.example # Secrets template
```

## Config Schema

### config.yaml

```yaml
# Tenant identity
tenant:
  name: <tenant-slug>            # Lowercase, no spaces (used in namespace names: tn-<name>-*)
  display_name: "<Display Name>"  # Human-readable name
  env: <dev|prod>                 # Environment

# DNS configuration
dns:
  domain: <tenant-domain.org>     # Base domain for this tenant
  matrix_subdomain: matrix
  element_subdomain: element
  synapse_subdomain: synapse
  docs_subdomain: docs
  files_subdomain: files
  auth_subdomain: auth
  jitsi_subdomain: jitsi
  home_subdomain: home
  mail_subdomain: mail
  webmail_subdomain: webmail
  admin_subdomain: admin
  calendar_subdomain: calendar
  env_dns_label: ""               # Empty for prod, "dev" for dev
  cookie_domain: .<domain>        # With leading dot, includes env label for dev

# Authentication
keycloak:
  realm: <realm-name>             # Unique per tenant (not per env)

# Email
smtp:
  domain: <email-domain>          # Usually same as dns.domain with env prefix

# Databases (shared PostgreSQL, per-tenant DBs)
database:
  docs_db: docs_<tenant>
  nextcloud_db: nextcloud_<tenant>
  stalwart_db: stalwart_<tenant>
  roundcube_db: roundcube_<tenant>

# Object Storage (Linode S3)
s3:
  bucket_prefix: <env>-<domain-dashed>
  docs_bucket: docs-media-<prefix>
  matrix_bucket: matrix-media-<prefix>
  files_bucket: files-media-<prefix>
  mail_bucket: mail-media-<prefix>
  cluster: us-lax-1

# Resource scaling (HPA at 80% CPU)
resources:
  docs:
    backend:   { min_replicas: 1, max_replicas: 5, memory_request: 256Mi, memory_limit: 512Mi }
    frontend:  { min_replicas: 1, max_replicas: 5, memory_request: 64Mi,  memory_limit: 128Mi }
    y_provider: { min_replicas: 1, max_replicas: 5, memory_request: 64Mi, memory_limit: 128Mi }
  element:     { min_replicas: 1, max_replicas: 5, memory_request: 64Mi,  memory_limit: 128Mi }
  jitsi:
    web:       { min_replicas: 1, max_replicas: 5, memory_request: 32Mi,  memory_limit: 64Mi }
    jvb:       { min_replicas: 1, max_replicas: 5, memory_request: 256Mi, memory_limit: 1Gi, jvb_port: 31000 }
  roundcube:   { min_replicas: 1, max_replicas: 5, memory_request: 128Mi, memory_limit: 256Mi }
  admin_portal: { min_replicas: 1, max_replicas: 5, memory_request: 64Mi, memory_limit: 128Mi }
  synapse_admin: { min_replicas: 1, max_replicas: 5, memory_request: 32Mi, memory_limit: 64Mi }
  stalwart:    { min_replicas: 1, max_replicas: 5, memory_request: 128Mi, memory_limit: 512Mi, storage_size: 1Gi }
  stalwart_ports:
    smtps_port: 46500           # Must be unique across all tenants!
    submission_port: 58700      # Must be unique across all tenants!
    imaps_port: 9930            # Must be unique across all tenants!
  keycloak:    { replicas: 2 }
  synapse:     { replicas: 1, memory_request: 512Mi, memory_limit: 1Gi }
  nextcloud:   { replicas: 1, memory_request: 256Mi, memory_limit: 512Mi, storage_size: 5Gi }
  redis:       { replicas: 0 }  # 0 = standalone, 1 = sentinel HA

# Feature flags
features:
  jitsi_enabled: true
  matrix_enabled: true
  docs_enabled: true
  files_enabled: true
  smtp_enabled: true
  turn_enabled: true
  mail_enabled: true
  webmail_enabled: true
  admin_portal_enabled: true
  calendar_enabled: true
```

### secrets.yaml fields

- `linode.token`, `cloudflare.{api_token, zone_id}`
- `database.*` — PostgreSQL passwords per service
- `oidc.*` — Keycloak client secrets per service
- `s3_*.*` — S3 access keys per bucket
- `dkim.{private_key, public_key}` — RSA 2048-bit DKIM keys
- `matrix.*`, `turn.*`, `jitsi.*` — Service-specific secrets
- `google.*` — OAuth credentials
- `grafana.*`, `alertbot.*`, `stalwart.*`

## Where Config Is Used

The `create_env` script (`scripts/create_env`) reads tenant config via `yq`:
```bash
yq '.tenant.name' tenants/<name>/<env>.config.yaml
```
And exports values as environment variables consumed by helmfile and deployment scripts.

## New Tenant Checklist

1. Create directory: `tenants/<name>/`
2. Copy config from existing tenant, update all fields
3. Create secrets file from `.example` template
4. Generate DKIM keys: `openssl genrsa -out dkim.private 2048` -> extract public key
5. Create S3 buckets in Linode (4 buckets per tenant per env)
6. Create databases in PostgreSQL (4 DBs per tenant)
7. Register Keycloak realm and OIDC clients
8. Assign unique Stalwart ports (check existing tenants for conflicts)
9. Run `./scripts/create_env --tenant=<name> <env>`

## Response Format

Return:
1. **Config details** — relevant field values from the tenant config
2. **Comparison** — if comparing tenants, show differences
3. **Required fields** — what must be set for the operation
4. **Template** — if creating a new tenant, provide the config template
