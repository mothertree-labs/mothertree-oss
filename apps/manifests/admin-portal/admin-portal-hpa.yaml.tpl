# HPA for Admin Portal
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: admin-portal-hpa
  namespace: ${NS_ADMIN}
  labels:
    app: admin-portal
    tenant: ${TENANT_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: admin-portal
  minReplicas: ${ADMIN_PORTAL_MIN_REPLICAS}
  maxReplicas: ${ADMIN_PORTAL_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
