# HPA for Jitsi Video Bridge (JVB)
# Scales based on absolute CPU usage per pod (not % of request).
# CPU request is kept low (100m) for bin-packing; limit is 3200m for burst.
# Target 2800m means: scale up when JVBs approach their CPU limit.
# Note: JVB uses hostPort, so scaling beyond node count requires cluster autoscaler
# to provision new nodes. Pods will be Pending until nodes are available.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: jitsi-jvb-hpa
  namespace: ${NS_JITSI}
  labels:
    app: jitsi-jvb
    component: jvb
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: jitsi-jvb
  minReplicas: ${JVB_MIN_REPLICAS}
  maxReplicas: ${JVB_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: AverageValue
        averageValue: 2800m
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1
        periodSeconds: 120
