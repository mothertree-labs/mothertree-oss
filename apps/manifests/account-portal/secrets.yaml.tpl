apiVersion: v1
kind: Secret
metadata:
  name: account-portal-secrets
  namespace: ${NS_ADMIN}
type: Opaque
stringData:
  nextauth-secret: "${ACCOUNT_PORTAL_NEXTAUTH_SECRET}"
  keycloak-client-secret: "${ACCOUNT_PORTAL_OIDC_SECRET}"
  guest-provisioning-api-key: "${GUEST_PROVISIONING_API_KEY}"
