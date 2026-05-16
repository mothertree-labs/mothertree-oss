# Per-tenant TLS certificates (DNS-01 via Cloudflare)
# Creates: Cloudflare token secret, ClusterIssuer, two Certificates with reflector annotations.
#
# The wildcard and bare-apex names are kept on SEPARATE Certificates because
# cert-manager's ACME scheduler deduplicates challenges by (DNSName, Type) only,
# without considering the Wildcard flag. A Certificate that mixes
# `*.example.com` and `example.com` produces two authorizations with the same
# `_acme-challenge.example.com` FQDN; the scheduler treats them as duplicates and
# only ever processes one. The first issuance can succeed by luck (cached
# authzs), but every fresh renewal deadlocks. Splitting puts each authz on its
# own Order, sidestepping the bug. See cert-manager#8643.
#
# Required environment variables:
#   TENANT_NAME              - Tenant name (e.g., example)
#   WILDCARD_DOMAIN_EXTERNAL - External wildcard (e.g., *.example.com or *.dev.example.com)
#   WILDCARD_DOMAIN_INTERNAL - Internal wildcard (e.g., *.prod.example.com or *.internal.dev.example.com)
#   WILDCARD_DOMAIN_BARE     - Bare domain for .well-known (e.g., example.com or dev.example.com)
#   NS_MATRIX                - Namespace where the Certificate resources live
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
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "${TENANT_NAMESPACES}"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "${TENANT_NAMESPACES}"
---
# Bare-apex Certificate (separate Order to avoid same-FQDN scheduler dedup with wildcard).
# Consumed by the Matrix .well-known ingress only — no reflector needed.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apex-tls
  namespace: ${NS_MATRIX}
spec:
  secretName: apex-tls-${TENANT_NAME}
  issuerRef:
    name: letsencrypt-dns01-${TENANT_NAME}
    kind: ClusterIssuer
  dnsNames:
    - "${WILDCARD_DOMAIN_BARE}"
