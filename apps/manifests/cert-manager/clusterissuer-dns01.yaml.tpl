apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${TLS_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-prod-dns01
    solvers:
      - dns01:
          cloudflare:
            email: "${TLS_EMAIL}"
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
