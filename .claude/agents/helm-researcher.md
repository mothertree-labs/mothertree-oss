---
name: helm-researcher
description: "Research Helm chart configuration — find value files, trace override chains, understand helmfile structure. Use when modifying chart values, understanding how a component is configured, or debugging Helm releases."
allowed-tools: ["Read", "Glob", "Grep"]
---

# Helm/Helmfile Configuration Researcher

## Your Task

Research Helm chart configuration to answer the user's question. Trace where values are set and how they're overridden across environments.

## Helmfile Structure

**Main file**: `apps/helmfile.yaml.gotmpl` (Go-templated)

**Environments**: `dev`, `prod` — selected with `helmfile -e <env>`

**Tier labels**:
- `tier: system` — Infrastructure (ingress, cert-manager, monitoring, vector)
- `tier: infra` — Shared auth (Keycloak only — deployed separately, NOT included in tier=apps)
- `tier: apps` — Tenant applications (Synapse, Element, Nextcloud, Jitsi, Docs)

**Deployment**: `helmfile -e <env> -l name=<release> sync` or `-l tier=<tier>`

## Value Override Chain

```
apps/values/<component>.yaml                    <- Base values (all envs)
apps/environments/<env>/<component>.yaml.gotmpl  <- Env overrides (Go templates)
```

Go template functions:
- `{{ requiredEnv "VAR" }}` — Mandatory env var (fails if missing)
- `{{ env "VAR" }}` — Optional env var
- `{{ env "VAR" | default "fallback" }}` — With default
- `{{ .Environment.Name }}` — Current environment name

## Where to Look

### Finding where a value is set
1. Check base values: `apps/values/<component>.yaml`
2. Check env override: `apps/environments/{dev,prod}/<component>.yaml.gotmpl`
3. Check helmfile release definition: `apps/helmfile.yaml.gotmpl` (inline values)
4. Check deployment script for env var exports (scripts/create_env, scripts/deploy_infra)

### Chart Index

#### Helm Repositories

| Repository | URL |
|-----------|-----|
| ingress-nginx | https://kubernetes.github.io/ingress-nginx |
| jetstack | https://charts.jetstack.io |
| ananace | https://ananace.gitlab.io/charts/ |
| halkeye | https://halkeye.github.io/helm-charts |
| prometheus-community | https://prometheus-community.github.io/helm-charts |
| vector | https://helm.vector.dev |
| bitnami | https://charts.bitnami.com/bitnami |
| impress | https://suitenumerique.github.io/docs/ |
| jitsi | https://jitsi-contrib.github.io/jitsi-helm |
| nextcloud | https://nextcloud.github.io/helm/ |
| codecentric | https://codecentric.github.io/helm-charts |

#### Infrastructure (tier: system)

| Release | Chart | Version | Namespace | Base Values | Env Override |
|---------|-------|---------|-----------|-------------|--------------|
| ingress-nginx | ingress-nginx/ingress-nginx | 4.7.1 | infra-ingress | values/ingress-nginx.yaml | — |
| ingress-nginx-internal | ingress-nginx/ingress-nginx | 4.7.1 | infra-ingress-internal | values/ingress-nginx-internal.yaml | environments/{env}/ingress-nginx-internal.yaml.gotmpl |
| cert-manager | jetstack/cert-manager | v1.13.3 | infra-cert-manager | values/cert-manager.yaml | — |
| kube-prometheus-stack | prometheus-community/kube-prometheus-stack | 58.0.0 | infra-monitoring | values/prometheus.yaml | environments/{env}/prometheus.yaml.gotmpl |
| vector | vector/vector | 0.46.0 | infra-monitoring | values/vector.yaml | — |

#### Auth (tier: infra)

| Release | Chart | Version | Namespace | Base Values | Env Override |
|---------|-------|---------|-----------|-------------|--------------|
| keycloak | codecentric/keycloakx | 7.1.7 | infra-auth | values/keycloak-codecentric.yaml | environments/{env}/keycloak.yaml.gotmpl |

#### Tenant Apps (tier: apps)

| Release | Chart | Version | Namespace | Base Values | Env Override |
|---------|-------|---------|-----------|-------------|--------------|
| matrix-synapse | ananace/matrix-synapse | 3.12.18 | tn-*-matrix | values/synapse.yaml | environments/{env}/synapse.yaml.gotmpl |
| element-web | halkeye/element-web | 1.30.0 | tn-*-matrix | values/element.yaml | environments/{env}/element.yaml.gotmpl |
| nextcloud | nextcloud/nextcloud | 8.9.0 | tn-*-files | values/nextcloud.yaml | environments/{env}/nextcloud.yaml.gotmpl |

#### Deployed via Scripts (not in helmfile)

| Component | Deployed By | Namespace | Method |
|-----------|------------|-----------|--------|
| docs-postgresql | deploy-docs.sh | infra-db | helmfile -l name=docs-postgresql |
| docs-backend | deploy-docs.sh | tn-*-docs | kubectl apply (manifests) |
| docs-frontend | deploy-docs.sh | tn-*-docs | kubectl apply (manifests) |
| docs-y-provider | deploy-docs.sh | tn-*-docs | kubectl apply (manifests) |
| jitsi | deploy-jitsi.sh | tn-*-jitsi | kubectl apply (manifests) |
| stalwart | deploy-stalwart.sh | tn-*-mail | kubectl apply (manifests) |
| roundcube | deploy-roundcube.sh | tn-*-webmail | kubectl apply (manifests) |
| admin-portal | create_env | tn-*-admin | kubectl apply (manifests) |
| synapse-admin | create_env | tn-*-matrix | kubectl apply (manifests) |

## Response Format

Return:
1. **Where the value is set** — exact file path and line
2. **Override chain** — base -> env override -> inline -> env var source
3. **Current value** — what it resolves to
4. **How to change it** — which file to edit and any env vars involved
