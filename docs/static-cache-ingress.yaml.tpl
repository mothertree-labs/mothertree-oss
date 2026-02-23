# Separate ingress for Docs /_next/static/ assets with long-lived cache headers.
# Next.js content-hashes all filenames so these are safe to cache indefinitely.
#
# Required environment variables:
#   DOCS_HOST - The tenant's docs hostname (e.g., docs.dev.example.com)
#   TENANT_NAME - Tenant name (e.g., example)
#   NS_DOCS - Docs namespace (set by sed in deploy-docs.sh)

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: docs-static-cache
  namespace: docs
  labels:
    app.kubernetes.io/name: docs
    app.kubernetes.io/component: static-cache
    app.kubernetes.io/part-of: mother-tree
  annotations:
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_hide_header Cache-Control;
      add_header Cache-Control "public, max-age=31536000, immutable" always;
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${DOCS_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
  rules:
  - host: ${DOCS_HOST}
    http:
      paths:
      - path: /_next/static/
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 8080
