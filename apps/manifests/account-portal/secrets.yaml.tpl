apiVersion: v1
kind: Secret
metadata:
  name: account-portal-secrets
  namespace: ${NS_ADMIN}
type: Opaque
stringData:
  nextauth-secret: "${ACCOUNT_PORTAL_NEXTAUTH_SECRET}"
  keycloak-client-secret: "${ACCOUNT_PORTAL_OIDC_SECRET}"
  stalwart-admin-password: "${STALWART_ADMIN_PASSWORD}"
  REDIS_PASSWORD: "${REDIS_SESSION_PASSWORD}"
  beginsetup-secret: "${BEGINSETUP_SECRET}"
