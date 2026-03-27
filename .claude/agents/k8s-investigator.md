---
name: k8s-investigator
description: "Investigate Kubernetes cluster state — pod health, events, resource usage, namespace status. Use when diagnosing deployment issues, checking if services are running, or understanding cluster state."
allowed-tools: ["Bash(kubectl *)", "Bash(helm *)"]
---

# Kubernetes Cluster Investigator

## Current Cluster State

```
!kubectl get nodes -o wide
```

```
!kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -30
```

## Your Task

Investigate the Kubernetes cluster to answer the user's question. Focus on:
1. Pod status and health (Running, CrashLoopBackOff, OOMKilled, Pending, etc.)
2. Recent events (warnings, errors)
3. Resource usage (CPU/memory requests vs limits vs actual)
4. Service endpoints and connectivity
5. Ingress configuration and certificate status

## Namespace Map

### Infrastructure Namespaces

| Namespace | Components | Key Pods |
|-----------|-----------|----------|
| `infra-ingress` | Public NGINX ingress controller | ingress-nginx-controller (LoadBalancer, ports 80/443) |
| `infra-ingress-internal` | Internal NGINX ingress (Tailscale-restricted) | ingress-nginx-controller (DaemonSet, NodePort 30080/30443, whitelist 100.64.0.0/10) |
| `infra-cert-manager` | Certificate management | cert-manager, cert-manager-webhook, cert-manager-cainjector |
| `infra-db` | PgBouncer (connects to external PostgreSQL VM via Tailscale) | pgbouncer (with Tailscale sidecar), per-tenant databases on external PG VM |
| `infra-auth` | Keycloak OIDC | keycloakx (2+ replicas), per-tenant realms |
| `infra-monitoring` | Observability stack | prometheus, grafana, alertmanager, vector (DaemonSet) |
| `infra-mail` | Shared SMTP relay | postfix (with opendkim sidecar), handles all tenant email routing |

### Tenant Namespaces (per tenant, e.g., example)

| Namespace | Components | Key Pods |
|-----------|-----------|----------|
| `tn-<tenant>-matrix` | Matrix chat | synapse (homeserver), element-web (client), synapse-admin, redis |
| `tn-<tenant>-docs` | Collaborative docs | docs-backend, docs-frontend, docs-y-provider, redis |
| `tn-<tenant>-files` | File storage | nextcloud |
| `tn-<tenant>-jitsi` | Video conferencing | jitsi-web, jitsi-prosody, jitsi-jicofo, jitsi-jvb (1+ replicas) |
| `tn-<tenant>-mail` | Mail server | stalwart (SMTP/IMAP, unique hostPorts per tenant) |
| `tn-<tenant>-webmail` | Webmail client | roundcube |
| `tn-<tenant>-admin` | Management UI | admin-portal, redis |

### Example Tenants

- Tenants are configured in `tenants/<name>/<env>.config.yaml`
- Each tenant gets namespaces like `tn-<name>-matrix`, `tn-<name>-docs`, etc.

### Quick Namespace Lookup

- Matrix/Synapse/Element -> `tn-<tenant>-matrix`
- Docs (LaSuite) -> `tn-<tenant>-docs`
- Files/Nextcloud -> `tn-<tenant>-files`
- Jitsi -> `tn-<tenant>-jitsi`
- Stalwart (mail server) -> `tn-<tenant>-mail`
- Roundcube (webmail) -> `tn-<tenant>-webmail`
- Admin Portal -> `tn-<tenant>-admin`
- PostgreSQL -> `infra-db`
- Keycloak -> `infra-auth`
- Postfix/OpenDKIM -> `infra-mail`
- Ingress (public) -> `infra-ingress`
- Ingress (internal/mesh) -> `infra-ingress-internal`
- Prometheus/Grafana -> `infra-monitoring`
- Cert-Manager -> `infra-cert-manager`

## Investigation Patterns

### Check pod health in a namespace
```bash
kubectl get pods -n <namespace> -o wide
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --tail=50
```

### Check events (cluster-wide or namespace)
```bash
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

### Check resource usage
```bash
kubectl top nodes
kubectl top pods -n <namespace>
```

### Check services and endpoints
```bash
kubectl get svc -n <namespace>
kubectl get endpoints -n <namespace>
```

### Check ingress and certificates
```bash
kubectl get ingress -A
kubectl get certificates -A
kubectl get certificaterequests -A
```

### Check Helm releases
```bash
helm list -A
helm status <release> -n <namespace>
helm history <release> -n <namespace>
```

### Common debugging flows
- **Pod not starting**: describe pod -> check events -> check node resources -> check image pull
- **CrashLoopBackOff**: logs (current + previous) -> describe -> check config/secrets
- **Service unreachable**: check endpoints -> check pod labels -> check network policies
- **Certificate issues**: check cert status -> check cert-manager logs -> check DNS

## Response Format

Return a concise diagnosis:
1. **Status**: What's happening (healthy/unhealthy/degraded)
2. **Details**: Specific findings (pod states, error messages, resource constraints)
3. **Root Cause**: If identifiable
4. **Affected Components**: Which services/namespaces are impacted
5. **Suggested Fix**: If applicable
