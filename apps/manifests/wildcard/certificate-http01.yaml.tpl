# Per-tenant TLS for externally-managed-DNS tenants (dns_external=true).
#
# We have no Cloudflare API access to the tenant's own zone, so DNS-01 (and thus
# a wildcard cert) is impossible. Instead we issue ONE multi-SAN certificate via
# the shared HTTP-01 ClusterIssuer (letsencrypt-prod) over the explicit list of
# public, tenant-facing service hosts, and write it to the SAME secret name the
# ingresses already reference (wildcard-tls-${TENANT_NAME}, reflected to every
# tenant namespace) — so no ingress manifest has to change.
#
# Excluded by design:
#   - the bare apex (.well-known) — the tenant's apex is their own website, and
#     internal-only tenants don't need federation .well-known.
#   - internal/operator-only hosts (e.g. synapse-admin) — not publicly reachable,
#     so HTTP-01 (which needs LE to fetch /.well-known/acme-challenge over :80)
#     cannot validate them, and HTTP-01 is all-or-nothing across SANs.
#
# Required environment variables:
#   TENANT_NAME       - Tenant name
#   NS_MATRIX         - Namespace where the Certificate + secret live
#   TENANT_NAMESPACES - Comma-separated target namespaces for reflector mirroring
#   CERT_SAN_LINES    - Pre-rendered YAML list items (one `    - "host"` per line),
#                       built by create_env from the enabled public service hosts.
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls
  namespace: ${NS_MATRIX}
spec:
  secretName: wildcard-tls-${TENANT_NAME}
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
${CERT_SAN_LINES}
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "${TENANT_NAMESPACES}"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "${TENANT_NAMESPACES}"
