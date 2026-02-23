---
name: debug-pod
description: "Deep-dive debug a specific pod or component — logs, events, describe, config"
allowed-tools: ["Bash(kubectl *)", "Read", "Grep", "Glob"]
---

# Pod Debugger

## Instructions

Debug the specified pod or component. The user will provide a component name (e.g., "synapse", "stalwart", "postfix", "keycloak") or a full pod name.

### Component-to-Namespace Mapping

| Component | Namespace Pattern |
|-----------|------------------|
| synapse, element, synapse-admin | tn-<tenant>-matrix |
| docs-backend, docs-frontend, y-provider | tn-<tenant>-docs |
| nextcloud | tn-<tenant>-files |
| jitsi, prosody, jicofo, jvb | tn-<tenant>-jitsi |
| stalwart | tn-<tenant>-mail |
| roundcube | tn-<tenant>-webmail |
| admin-portal | tn-<tenant>-admin |
| postfix, opendkim | infra-mail |
| keycloak | infra-auth |
| postgresql, postgres | infra-db |
| prometheus, grafana, alertmanager, vector | infra-monitoring |
| ingress-nginx | infra-ingress or infra-ingress-internal |
| cert-manager | infra-cert-manager |

Default tenant: `example` (if not specified)

### Debugging Procedure

1. **Find the pod**
   ```bash
   kubectl get pods -n <namespace> -o wide
   ```

2. **Describe the pod** (shows events, conditions, volumes, env)
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   ```

3. **Check recent events**
   ```bash
   kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -15
   ```

4. **Get logs** (current and previous if restarting)
   ```bash
   kubectl logs <pod-name> -n <namespace> --tail=100
   kubectl logs <pod-name> -n <namespace> --previous --tail=50 2>/dev/null
   ```
   For multi-container pods (e.g., postfix with opendkim sidecar):
   ```bash
   kubectl logs <pod-name> -n <namespace> -c <container> --tail=100
   ```

5. **Check resource usage**
   ```bash
   kubectl top pod <pod-name> -n <namespace> 2>/dev/null
   ```

6. **Check related config** (if issue seems config-related)
   - Read relevant Helm values: `apps/values/<component>.yaml`
   - Read env overrides: `apps/environments/<env>/<component>.yaml.gotmpl`
   - Check manifests: `apps/manifests/<component>/`
   - Check tenant config: `tenants/<tenant>/<env>.config.yaml`

7. **Check related services**
   ```bash
   kubectl get svc -n <namespace>
   kubectl get endpoints -n <namespace>
   ```

### Common Issues

- **CrashLoopBackOff**: Check logs (current + previous), look for OOMKilled in describe
- **Pending**: Check events for scheduling failures, node resources, PVC binding
- **ImagePullBackOff**: Check image name/tag, registry access
- **Connection refused**: Check service endpoints, target pod readiness
- **OOMKilled**: Check memory limits vs actual usage, suggest increasing limits

## Output Format

```
## Debug Report: <component>

### Pod Status
- Name: <pod-name>
- Namespace: <namespace>
- Status: <status>
- Restarts: <count>
- Age: <age>
- Node: <node>

### Issue
<description of what's wrong>

### Evidence
<relevant log lines, events, or describe output>

### Root Cause
<identified or suspected cause>

### Suggested Fix
<specific steps to resolve>
```
