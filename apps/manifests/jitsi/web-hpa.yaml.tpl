# HPA for Jitsi Web
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: jitsi-web-hpa
  namespace: ${NS_JITSI}
  labels:
    app: jitsi-web
    component: web
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: jitsi-web
  minReplicas: ${JITSI_WEB_MIN_REPLICAS}
  maxReplicas: ${JITSI_WEB_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
