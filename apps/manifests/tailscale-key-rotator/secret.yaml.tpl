apiVersion: v1
kind: Secret
metadata:
  name: tailscale-rotator-api-key
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
type: Opaque
stringData:
  HEADSCALE_API_KEY: "${TAILSCALE_ROTATOR_API_KEY}"
