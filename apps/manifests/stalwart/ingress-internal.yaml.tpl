# Stalwart Mail Server - Internal Ingress (VPN-only)
# Exposes admin UI at webadmin.prod.example.com (prod)
# or webadmin.internal.dev.example.com (dev)
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   WEBADMIN_HOST - Admin UI hostname (e.g., webadmin.prod.example.com)
#   TENANT_NAME - Tenant name (e.g., example)

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stalwart-webadmin
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
    component: webadmin
    tenant: ${TENANT_NAME}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod-dns01
    kubernetes.io/ingress.class: nginx-internal
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  ingressClassName: nginx-internal
  tls:
  - hosts:
    - ${WEBADMIN_HOST}
    secretName: stalwart-webadmin-tls
  rules:
  - host: ${WEBADMIN_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: stalwart
            port:
              number: 443
