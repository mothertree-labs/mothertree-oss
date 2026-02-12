# HPA for Roundcube Webmail
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: roundcube-hpa
  namespace: ${NS_WEBMAIL}
  labels:
    app: roundcube
    tenant: ${TENANT_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: roundcube
  minReplicas: ${ROUNDCUBE_MIN_REPLICAS}
  maxReplicas: ${ROUNDCUBE_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
