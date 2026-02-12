# HPA for Docs Frontend
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: frontend-hpa
  namespace: ${NS_DOCS}
  labels:
    app.kubernetes.io/name: docs-frontend
    app.kubernetes.io/part-of: mother-tree
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: frontend
  minReplicas: ${DOCS_FRONTEND_MIN_REPLICAS}
  maxReplicas: ${DOCS_FRONTEND_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
