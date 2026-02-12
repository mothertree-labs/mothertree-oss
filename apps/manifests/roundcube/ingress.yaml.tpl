# Roundcube Webmail - Public Ingress
# Exposes webmail at webmail.<tenant-domain>
#
# Required environment variables:
#   NS_WEBMAIL - Tenant webmail namespace (e.g., tn-example-webmail)
#   WEBMAIL_HOST - Webmail hostname (e.g., webmail.dev.example.com)
#   TENANT_NAME - Tenant name (e.g., example)

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: roundcube
  namespace: ${NS_WEBMAIL}
  labels:
    app: roundcube
    tenant: ${TENANT_NAME}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "25m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # Security headers
    nginx.ingress.kubernetes.io/server-snippet: |
      # Hide upstream headers (we set our own below; duplicates confuse browsers)
      proxy_hide_header X-Powered-By;
      proxy_hide_header Server;
      proxy_hide_header X-Frame-Options;
      proxy_hide_header Content-Security-Policy;
      # CSP - Roundcube needs unsafe-inline for its UI, and connects to auth for OIDC
      add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'self'; form-action 'self' https://*.${TENANT_DOMAIN}; base-uri 'self';" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
      add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/session-cookie-name: "ROUNDCUBE_ROUTE"
    nginx.ingress.kubernetes.io/session-cookie-expires: "3600"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"
    nginx.ingress.kubernetes.io/session-cookie-change-on-failure: "true"
    nginx.ingress.kubernetes.io/session-cookie-samesite: "Lax"
    nginx.ingress.kubernetes.io/session-cookie-conditional-samesite-none: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${WEBMAIL_HOST}
    secretName: roundcube-tls
  rules:
  - host: ${WEBMAIL_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: roundcube
            port:
              number: 80
