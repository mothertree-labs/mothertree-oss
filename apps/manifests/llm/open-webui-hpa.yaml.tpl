# HPA for Open WebUI
# Scales between min_replicas and max_replicas based on CPU utilization (80%)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: open-webui-hpa
  namespace: ${NS_LLM}
  labels:
    app: open-webui
    tenant: ${TENANT_NAME}
    mothertree/component: llm
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: open-webui
  minReplicas: ${LLM_MIN_REPLICAS}
  maxReplicas: ${LLM_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
