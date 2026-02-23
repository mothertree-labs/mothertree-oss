apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: email-probe
  namespace: ${NS_MAIL}
  labels:
    app: email-probe
    component: monitoring
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: email-probe
  endpoints:
  - port: metrics
    path: /metrics
    interval: 60s
