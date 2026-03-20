apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: ${NS_CERTMANAGER}
type: Opaque
stringData:
  api-token: "${CLOUDFLARE_API_TOKEN}"
