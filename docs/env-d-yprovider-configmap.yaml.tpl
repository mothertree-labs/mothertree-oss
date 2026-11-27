apiVersion: v1
data:
  # impress >= 6: the y-provider is the conversion service only. It verifies
  # the backend's tokens against <COLLABORATION_BACKEND_BASE_URL>/api/v1.0/jwks.
  # External HTTPS URL so the request goes through the ingress, which adds
  # X-Forwarded-Proto: https (Django's SECURE_SSL_REDIRECT would 301 otherwise).
  # This ConfigMap is also in the backend's envFrom (Y_PROVIDER_API_BASE_URL).
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

