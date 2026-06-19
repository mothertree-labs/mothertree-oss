---
# Tailscale pre-authenticated key for mesh connectivity (tag:monitoring).
# Created only on first-time bootstrap; thereafter owned by the key-rotator CronJob.
apiVersion: v1
kind: Secret
metadata:
  name: ${FED_NAME}-tailscale-auth
  namespace: ${NS_MONITORING}
  labels:
    app: ${FED_NAME}
    component: metrics-federation
type: Opaque
stringData:
  TS_AUTHKEY: "${TAILSCALE_AUTHKEY}"
