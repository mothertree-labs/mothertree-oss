---
name: project-conventions
description: "Mothertree project conventions — namespace naming, file organization, deployment patterns, multi-tenancy architecture. Apply when working on infrastructure, deployment scripts, or tenant configuration."
allowed-tools: ["Read", "Glob", "Grep"]
---

# Mothertree Project Conventions

## Architecture Overview

```
Internet -> Cloudflare DNS -> Linode LKE (3 nodes)
                              |-- infra-ingress (nginx, LoadBalancer)
                              |-- infra-ingress-internal (nginx, NodePort, Tailscale-restricted)
                              |-- infra-cert-manager (Let's Encrypt)
                              |-- infra-db (PostgreSQL, shared)
                              |-- infra-auth (Keycloak, OIDC)
                              |-- infra-mail (Postfix + OpenDKIM)
                              |-- infra-monitoring (Prometheus, Grafana, Vector)
                              |-- tn-<tenant>-matrix (Synapse + Element)
                              |-- tn-<tenant>-docs (LaSuite Docs backend/frontend/y-provider)
                              |-- tn-<tenant>-files (Nextcloud)
                              |-- tn-<tenant>-jitsi (Jitsi Meet)
                              |-- tn-<tenant>-mail (Stalwart)
                              |-- tn-<tenant>-webmail (Roundcube)
                              +-- tn-<tenant>-admin (Admin Portal)
```

## Service Dependencies

- **Synapse** -> PostgreSQL (infra-db), Redis (tn-*-matrix), Keycloak (infra-auth), Postfix (infra-mail)
- **Element** -> Synapse (tn-*-matrix), Jitsi (tn-*-jitsi)
- **Docs** -> PostgreSQL (infra-db), S3 (Linode Objects), Keycloak (infra-auth)
- **Nextcloud** -> PostgreSQL (infra-db), S3 (Linode Objects), Keycloak (infra-auth)
- **Jitsi** -> Keycloak (infra-auth), TURN server (external Linode)
- **Stalwart** -> PostgreSQL (infra-db), S3 (Linode Objects), Keycloak (infra-auth), Postfix (infra-mail)
- **Roundcube** -> Stalwart (tn-*-mail), Keycloak (infra-auth), PostgreSQL (infra-db)
- **Admin Portal** -> Keycloak (infra-auth), Redis (tn-*-admin), Synapse API

## Naming Conventions

- **Namespaces**: `infra-<service>` or `tn-<tenant>-<service>`
- **Databases**: `<service>_<tenant>` (e.g., `docs_example`, `nextcloud_example`)
- **S3 Buckets**: `<service>-media-<env_label>-<domain-dashed>` (e.g., `docs-media-dev-example-org`)
- **DNS subdomains**: `<service>.<env_label>.<domain>` (env_label empty for prod)
- **Keycloak realms**: Per-tenant (e.g., `docs`, `example`)
- **DKIM selector**: Always `default` -> `default._domainkey.<domain>`
- **Helm release names**: Match the component name (synapse, element-web, nextcloud, etc.)

## Deployment Patterns

### Script Variable Flow
1. Scripts source `secrets.tfvars.env` for credentials
2. Read tenant config via `yq` from `tenants/<name>/<env>.config.yaml`
3. Export as env vars (NS_MATRIX, MATRIX_HOST, etc.)
4. Pass to helmfile via `requiredEnv` / `env` Go template functions

### Helmfile Value Override Chain
```
apps/values/<component>.yaml           -> Base values (all environments)
apps/environments/<env>/<comp>.yaml.gotmpl -> Environment overrides (Go-templated)
```

### Selective Deployment
- Full tier: `helmfile -e <env> -l tier=system sync`
- Single release: `helmfile -e <env> -l name=<release> sync`
- Keycloak separate: `helmfile -e <env> -l name=keycloak sync` (tier=infra, not included in tier=apps)

## Common Gotchas

1. **Keycloak is tier=infra**, not tier=apps — won't deploy with `-l tier=apps`
2. **PostgreSQL deployed by deploy-docs.sh** via helmfile, not by deploy_infra directly
3. **DKIM keys mounted to Postfix pod** as volumes — adding a tenant requires Postfix pod restart
4. **Stalwart uses hostPort** — unique ports per tenant, uses DaemonSet-like scheduling
5. **Terraform workspaces** — always check you're in the right workspace before applying
6. **env_dns_label** — empty string for prod (not "prod"), "dev" for dev
7. **PG_HOST** points to `pgbouncer.infra-db.svc.cluster.local` — PgBouncer connects to external PG VM via Tailscale sidecar
8. **cert-manager uses DNS-01** for wildcard certs, HTTP-01 for standard certs
9. **Internal ingress** is Tailscale-restricted (whitelist 100.64.0.0/10) — accessible through Headscale/Tailscale mesh
10. **Admin Portal Docker image** only rebuilds if source files changed (hash-based check in create_env)
