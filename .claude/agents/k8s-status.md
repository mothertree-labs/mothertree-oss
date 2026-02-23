---
name: k8s-status
description: "Show Kubernetes cluster health — nodes, unhealthy pods, recent events"
allowed-tools: ["Bash(kubectl *)"]
---

# Cluster Health Check

## Current State

```
!kubectl get nodes -o wide
```

```
!kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -20
```

## Instructions

Generate a concise cluster health report. If the user specifies a namespace, focus on that namespace. Otherwise, check the full cluster.

### Steps

1. **Node Health**
   ```bash
   kubectl get nodes -o wide
   kubectl top nodes 2>/dev/null
   ```

2. **Unhealthy Pods** (not Running/Succeeded)
   ```bash
   kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null
   kubectl get pods -A | grep -E 'CrashLoop|Error|OOMKilled|Pending|ImagePull' 2>/dev/null
   ```

3. **Recent Warning Events** (last 10 minutes)
   ```bash
   kubectl get events -A --field-selector=type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -15
   ```

4. **Ingress Status** (if full cluster check)
   ```bash
   kubectl get ingress -A 2>/dev/null
   ```

5. **Certificate Status** (if full cluster check)
   ```bash
   kubectl get certificates -A 2>/dev/null
   ```

### If namespace specified (e.g., `/k8s-status tn-example-matrix`)
Focus on that namespace:
```bash
kubectl get pods -n <namespace> -o wide
kubectl get svc -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -10
kubectl top pods -n <namespace> 2>/dev/null
```

## Output Format

```
## Cluster Health Report

### Nodes
- node1: Ready, CPU X%, Mem Y%
- node2: Ready, CPU X%, Mem Y%

### Issues
- [WARN] pod-name in namespace: CrashLoopBackOff (reason)
- [ERROR] pod-name in namespace: OOMKilled

### Recent Events
- (last 5 significant events)

### Status: HEALTHY | DEGRADED | UNHEALTHY
```

Keep the report concise. Only include sections with notable findings.
