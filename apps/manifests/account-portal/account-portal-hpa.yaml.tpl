# HPA for Account Portal
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: account-portal-hpa
  namespace: ${NS_ADMIN}
  labels:
    app: account-portal
    tenant: ${TENANT_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: account-portal
  minReplicas: ${ACCOUNT_PORTAL_MIN_REPLICAS}
  maxReplicas: ${ACCOUNT_PORTAL_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
