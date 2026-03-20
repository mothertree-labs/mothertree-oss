# Ingress for Element Web static assets and custom CSS injection.
#
# - /bundles/ gets immutable cache headers (webpack content-hashed filenames)
# - /themes/ serves custom CSS mounted from the branding ConfigMap
# - HTML responses get a <link> tag injected via sub_filter to load custom.css
#
# The ananace/element-web Helm chart has no native custom CSS support,
# so nginx sub_filter is used to inject the stylesheet reference.
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
    nginx.ingress.kubernetes.io/server-snippet: |
      location ~* ^/themes/ {
        proxy_pass http://element-web.${NS_MATRIX}.svc.cluster.local;
        proxy_hide_header Cache-Control;
        add_header Cache-Control "public, max-age=3600" always;
      }
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
