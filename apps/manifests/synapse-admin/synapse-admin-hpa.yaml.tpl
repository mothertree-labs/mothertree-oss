# HPA for Synapse Admin
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: synapse-admin-hpa
  namespace: ${NS_MATRIX}
  labels:
    app: synapse-admin
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: synapse-admin
  minReplicas: ${SYNAPSE_ADMIN_MIN_REPLICAS}
  maxReplicas: ${SYNAPSE_ADMIN_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
