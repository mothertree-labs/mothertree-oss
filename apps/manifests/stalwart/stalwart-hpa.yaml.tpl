# HPA for Stalwart Mail Server
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
# Note: Stalwart uses hostPort, so scaling beyond node count requires cluster autoscaler
# to provision new nodes. Pods will be Pending until nodes are available.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: stalwart-hpa
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
    tenant: ${TENANT_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: stalwart
  minReplicas: ${STALWART_MIN_REPLICAS}
  maxReplicas: ${STALWART_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
