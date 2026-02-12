# Separate ingress for Y-Provider (collaborative editing WebSocket)
# Uses consistent hashing based on document ID (in URI path) to ensure
# all users editing the same document connect to the same Y-Provider pod.
# This enables Y-Provider scaling without requiring Redis pub/sub.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: docs-yprovider
  namespace: docs
  labels:
    app.kubernetes.io/name: docs-yprovider
    app.kubernetes.io/part-of: mother-tree
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # WebSocket support
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    # Consistent hashing: route requests with same URI to same pod
    # The document ID is in the WebSocket URL path (e.g., /collaboration/ws/{doc-id})
    # This ensures all users editing the same document hit the same Y-Provider instance
    nginx.ingress.kubernetes.io/upstream-hash-by: "$request_uri"
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
      - path: /collaboration/ws/
        pathType: Prefix
        backend:
          service:
            name: y-provider
            port:
              number: 4444
