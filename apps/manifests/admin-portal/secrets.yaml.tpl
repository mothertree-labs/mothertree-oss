apiVersion: v1
kind: Secret
metadata:
  name: admin-portal-secrets
  namespace: ${NS_ADMIN}
type: Opaque
stringData:
  nextauth-secret: "${ADMIN_PORTAL_NEXTAUTH_SECRET}"
  keycloak-client-secret: "${ADMIN_PORTAL_OIDC_SECRET}"
  stalwart-admin-password: "${STALWART_ADMIN_PASSWORD}"
  REDIS_PASSWORD: "${REDIS_SESSION_PASSWORD}"
  beginsetup-secret: "${BEGINSETUP_SECRET}"
