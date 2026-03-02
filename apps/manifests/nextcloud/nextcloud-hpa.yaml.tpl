# HPA for Nextcloud
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
# scaleDown stabilization window is configurable per-tenant:
#   - 300s (default): standard K8s behavior, scales down within 5 minutes
#   - 3600s: keeps scaled-up replicas for 1 hour (useful for bursty CI workloads)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nextcloud-hpa
  namespace: ${NS_FILES}
  labels:
    app: nextcloud
    tenant: ${TENANT_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nextcloud
  minReplicas: ${NEXTCLOUD_MIN_REPLICAS}
  maxReplicas: ${NEXTCLOUD_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
    scaleDown:
      stabilizationWindowSeconds: ${NEXTCLOUD_HPA_SCALEDOWN_WINDOW}
