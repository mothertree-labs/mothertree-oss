# Per-tenant wildcard TLS certificate (DNS-01 via Cloudflare)
# Creates: Cloudflare token secret, ClusterIssuer, Certificate with reflector annotations
#
# The Certificate lives in NS_MATRIX (one per tenant) and reflector mirrors the
# resulting TLS secret to every other tenant namespace listed in TENANT_NAMESPACES.
#
# Required environment variables:
#   TENANT_NAME              - Tenant name (e.g., example)
#   WILDCARD_DOMAIN_EXTERNAL - External wildcard (e.g., *.example.com or *.dev.example.com)
#   WILDCARD_DOMAIN_INTERNAL - Internal wildcard (e.g., *.prod.example.com or *.internal.dev.example.com)
#   WILDCARD_DOMAIN_BARE     - Bare domain for .well-known (e.g., example.com or dev.example.com)
#   NS_MATRIX                - Namespace where the Certificate resource lives
#   TENANT_NAMESPACES        - Comma-separated target namespaces for reflector mirroring
#   CLOUDFLARE_API_TOKEN     - Cloudflare API token for DNS-01 challenge
#   TLS_EMAIL                - Email for Let's Encrypt registration
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token-${TENANT_NAME}
  namespace: infra-cert-manager
type: Opaque
stringData:
  api-token: "${CLOUDFLARE_API_TOKEN}"
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns01-${TENANT_NAME}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${TLS_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-dns01-${TENANT_NAME}
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-${TENANT_NAME}
              key: api-token
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls
  namespace: ${NS_MATRIX}
spec:
  secretName: wildcard-tls-${TENANT_NAME}
  issuerRef:
    name: letsencrypt-dns01-${TENANT_NAME}
    kind: ClusterIssuer
  dnsNames:
    - "${WILDCARD_DOMAIN_EXTERNAL}"
    - "${WILDCARD_DOMAIN_INTERNAL}"
    - "${WILDCARD_DOMAIN_BARE}"
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "${TENANT_NAMESPACES}"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "${TENANT_NAMESPACES}"
