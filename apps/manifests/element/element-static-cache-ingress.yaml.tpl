# Separate ingress for Element Web /bundles/ path with long-lived cache headers.
# Webpack content-hashes all filenames, so these are safe to cache indefinitely.
# The chart's built-in nginx config handles index.html (no-cache) and config.json.
#
# Required environment variables:
#   MATRIX_HOST - The tenant's Matrix hostname (e.g., matrix.dev.example.com)
#   TENANT_NAME - Tenant name (e.g., example)
#   NS_MATRIX - Matrix namespace (e.g., tn-example-matrix)

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: element-static-cache
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: element-web
    app.kubernetes.io/component: static-cache
  annotations:
    nginx.ingress.kubernetes.io/priority: "15"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_hide_header Cache-Control;
      add_header Cache-Control "public, max-age=31536000, immutable" always;
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${MATRIX_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
  rules:
  - host: ${MATRIX_HOST}
    http:
      paths:
      - path: /bundles/
        pathType: Prefix
        backend:
          service:
            name: element-web
            port:
              name: http
