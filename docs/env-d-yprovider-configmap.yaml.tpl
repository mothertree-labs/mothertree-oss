apiVersion: v1
data:
  # External HTTPS URLs for y-provider → backend API calls
  # Must use external URL so requests go through ingress which adds X-Forwarded-Proto: https
  # This prevents Django's SECURE_SSL_REDIRECT from returning 301 redirects
  COLLABORATION_API_URL: https://${DOCS_HOST}/api/v1.0/
  COLLABORATION_BACKEND_BASE_URL: https://${DOCS_HOST}
  COLLABORATION_LOGGING: "true"
  # External URL for CORS (must match browser origin)
  COLLABORATION_SERVER_ORIGIN: https://${DOCS_HOST}
  Y_PROVIDER_API_BASE_URL: http://y-provider:4444/api/
kind: ConfigMap
metadata:
  name: env-d-yprovider
  namespace: docs
  labels:
    io.kompose.service: backend-env-d-yprovider

