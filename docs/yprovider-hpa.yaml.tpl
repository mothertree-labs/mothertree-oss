# HPA for Y-Provider (Collaborative Editing)
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: yprovider-hpa
  namespace: ${NS_DOCS}
  labels:
    app.kubernetes.io/name: docs
    app.kubernetes.io/component: yProvider
    app.kubernetes.io/part-of: mother-tree
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: docs-y-provider
  minReplicas: ${YPROVIDER_MIN_REPLICAS}
  maxReplicas: ${YPROVIDER_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
