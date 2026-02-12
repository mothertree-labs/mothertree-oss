# HPA for Docs Backend
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend-hpa
  namespace: ${NS_DOCS}
  labels:
    app.kubernetes.io/name: docs-backend
    app.kubernetes.io/part-of: mother-tree
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend
  minReplicas: ${DOCS_BACKEND_MIN_REPLICAS}
  maxReplicas: ${DOCS_BACKEND_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
