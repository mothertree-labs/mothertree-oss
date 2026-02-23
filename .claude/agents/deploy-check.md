---
name: deploy-check
description: "Pre-deployment validation — verify configs, secrets, namespaces, and readiness before deploying"
allowed-tools: ["Bash(kubectl *)", "Bash(helm *)", "Bash(terraform *)", "Read", "Glob"]
---

# Pre-Deployment Validation

## Instructions

Run a pre-deployment checklist for the specified environment and tenant. Parse arguments from the user input:
- Environment: `prod` or `dev` (required, first positional arg)
- Tenant: `--tenant=<name>` (optional, defaults to checking all tenants)

## Checklist

### 1. Kubeconfig
```bash
# Check kubeconfig exists
ls -la kubeconfig.prod.yaml kubeconfig.dev.yaml 2>/dev/null
```
- [ ] `kubeconfig.<env>.yaml` exists at repo root
- [ ] Cluster is reachable: `kubectl --kubeconfig=kubeconfig.<env>.yaml cluster-info`

### 2. Secrets File
```bash
# Check secrets env file
ls -la secrets.tfvars.env 2>/dev/null
```
- [ ] `secrets.tfvars.env` exists

### 3. Tenant Config (if tenant specified)
```bash
# Check tenant config and secrets
ls -la tenants/<tenant>/<env>.config.yaml tenants/<tenant>/<env>.secrets.yaml 2>/dev/null
```
- [ ] `tenants/<tenant>/<env>.config.yaml` exists
- [ ] `tenants/<tenant>/<env>.secrets.yaml` exists
- [ ] Config has required fields (tenant.name, dns.domain, database.*)

### 4. Infrastructure Namespaces
```bash
kubectl --kubeconfig=kubeconfig.<env>.yaml get namespaces | grep -E 'infra-|tn-'
```
- [ ] `infra-ingress` exists
- [ ] `infra-cert-manager` exists
- [ ] `infra-db` exists
- [ ] `infra-auth` exists
- [ ] `infra-mail` exists
- [ ] `infra-monitoring` exists

### 5. Core Services Running
```bash
kubectl --kubeconfig=kubeconfig.<env>.yaml get pods -n infra-db
kubectl --kubeconfig=kubeconfig.<env>.yaml get pods -n infra-auth
kubectl --kubeconfig=kubeconfig.<env>.yaml get pods -n infra-mail
```
- [ ] PostgreSQL is running in infra-db
- [ ] Keycloak is running in infra-auth
- [ ] Postfix is running in infra-mail

### 6. Cert-Manager
```bash
kubectl --kubeconfig=kubeconfig.<env>.yaml get clusterissuers
kubectl --kubeconfig=kubeconfig.<env>.yaml get certificates -A | head -10
```
- [ ] ClusterIssuers exist (letsencrypt-prod, letsencrypt-staging)
- [ ] No certificates in False/Unknown state

### 7. Ingress
```bash
kubectl --kubeconfig=kubeconfig.<env>.yaml get svc -n infra-ingress
```
- [ ] Ingress controller has external IP assigned

### 8. Helm Repos (if deploying apps)
```bash
helm repo list 2>/dev/null
```
- [ ] Required repos are configured

### 9. Tenant Namespaces (if tenant specified)
```bash
kubectl --kubeconfig=kubeconfig.<env>.yaml get namespaces | grep "tn-<tenant>"
```
- [ ] Required tenant namespaces exist (or will be created)

### 10. Terraform State (if deploying infra)
```bash
ls -la phase1/terraform.tfstate.d/<env>/terraform.tfstate 2>/dev/null
ls -la infra/terraform.tfstate 2>/dev/null
```
- [ ] Phase 1 state exists for environment
- [ ] Phase 2 state exists

## Output Format

```
## Pre-Deployment Check: <env> [tenant: <name>]

| Check | Status | Details |
|-------|--------|---------|
| Kubeconfig | PASS/FAIL | ... |
| Secrets | PASS/FAIL | ... |
| Tenant Config | PASS/FAIL/SKIP | ... |
| Namespaces | PASS/FAIL | ... |
| Core Services | PASS/FAIL | ... |
| Cert-Manager | PASS/FAIL | ... |
| Ingress | PASS/FAIL | ... |
| Helm Repos | PASS/FAIL | ... |

### Result: READY / NOT READY
<summary of any failures>
```
