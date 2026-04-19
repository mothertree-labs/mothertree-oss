# Stalwart Encrypted Mail Ingress
# Exposes JMAP API at encryptedmail.<tenant-domain> for encryption at rest management
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   ENCRYPTEDMAIL_HOST - Mail server hostname (e.g., encryptedmail.example.com)
#   TENANT_NAME - Tenant name (e.g., example)

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stalwart-encryptedmail
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
    component: encryptedmail
    tenant: ${TENANT_NAME}
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header Cache-Control "no-store" always;
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${ENCRYPTEDMAIL_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
  rules:
  - host: ${ENCRYPTEDMAIL_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: stalwart
            port:
              number: 8080