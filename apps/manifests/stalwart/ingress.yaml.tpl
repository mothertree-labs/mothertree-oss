# Stalwart Mail Server - Public Ingress
# Exposes webmail/JMAP API at mail.<tenant-domain>
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   MAIL_HOST - Mail server hostname (e.g., mail.example.com)
#   TENANT_NAME - Tenant name (e.g., example)

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stalwart-webmail
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
    component: webmail
    tenant: ${TENANT_NAME}
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header Cache-Control "no-store" always;
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${MAIL_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
  rules:
  - host: ${MAIL_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: stalwart
            port:
              number: 443
