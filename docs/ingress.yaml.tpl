apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: docs
  namespace: docs
  labels:
    app.kubernetes.io/name: docs
    app.kubernetes.io/part-of: mother-tree
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    # Allow iframe embedding from ${HOME_HOST}
    nginx.ingress.kubernetes.io/server-snippet: |
      more_clear_headers "X-Frame-Options";
      add_header X-Frame-Options "ALLOWALL" always;
      add_header Content-Security-Policy "frame-ancestors 'self' https://${HOME_HOST}" always;
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${DOCS_HOST}
    secretName: docs-tls
  rules:
  - host: ${DOCS_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 8080
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: backend
            port:
              number: 8000
      # /collaboration/ws/ is handled by separate yprovider-ingress.yaml.tpl
      # with consistent hashing for document ID-based routing
      - path: /collaboration/api/
        pathType: Prefix
        backend:
          service:
            name: backend
            port:
              number: 8000
      - path: /media
        pathType: Prefix
        backend:
          service:
            name: backend
            port:
              number: 8000

