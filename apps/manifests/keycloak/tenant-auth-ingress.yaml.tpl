# Tenant-specific Keycloak auth ingress
# This ingress routes auth traffic for a specific tenant to the shared Keycloak instance
#
# Required environment variables:
#   AUTH_HOST - The tenant's auth hostname (e.g., auth.dev.example.com)
#   TENANT - The tenant name (e.g., example)
#   NS_AUTH - The namespace where Keycloak runs (e.g., infra-auth)
#
# This approach avoids helm conflicts by having each tenant own their own ingress resource

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak-${TENANT}
  namespace: ${NS_AUTH}
  labels:
    app: keycloak
    tenant: ${TENANT}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
    nginx.ingress.kubernetes.io/server-snippet: |
      # Override Keycloak's minimal CSP with a more complete one
      proxy_hide_header Content-Security-Policy;
      add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'self' https://*.${TENANT_DOMAIN}; frame-src 'self'; object-src 'none'; form-action 'self' https://*.${TENANT_DOMAIN}; base-uri 'self';" always;
spec:
  ingressClassName: nginx
  rules:
    - host: ${AUTH_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak-keycloakx-http
                port:
                  name: http
  tls:
    - hosts:
        - ${AUTH_HOST}
      secretName: ${AUTH_HOST}-tls
