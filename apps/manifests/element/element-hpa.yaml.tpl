# HPA for Element Web (Matrix client)
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: element-hpa
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: element-web
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: element-web
  minReplicas: ${ELEMENT_MIN_REPLICAS}
  maxReplicas: ${ELEMENT_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
