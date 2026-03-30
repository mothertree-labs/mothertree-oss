---
# Tailscale pre-authenticated key for mesh connectivity
apiVersion: v1
kind: Secret
metadata:
  name: pg-metrics-bridge-tailscale-auth
  namespace: ${NS_DB}
  labels:
    app: pg-metrics-bridge
type: Opaque
stringData:
  TS_AUTHKEY: "${TAILSCALE_AUTHKEY}"
