---
# Matrix .well-known ingress for federation
# This serves the /.well-known/matrix/* endpoints on the bare domain
# Only deployed for production (no env label)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: matrix-wellknown
  namespace: ${NS_MATRIX}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    kubernetes.io/ingress.class: nginx
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${TENANT_DOMAIN}
      secretName: matrix-wellknown-tls
  rules:
    - host: ${TENANT_DOMAIN}
      http:
        paths:
          - path: /.well-known/matrix/server
            pathType: Exact
            backend:
              service:
                name: matrix-synapse
                port:
                  number: 8008
          - path: /.well-known/matrix/client
            pathType: Exact
            backend:
              service:
                name: matrix-synapse
                port:
                  number: 8008
