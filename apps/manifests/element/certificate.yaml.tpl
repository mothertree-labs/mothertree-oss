# Synapse/Element shared TLS Certificate
# Both share MATRIX_HOST in the same namespace, so one cert covers both.
# Uses cert-manager to provision certificates from Let's Encrypt.
#
# Required environment variables:
#   NS_MATRIX - Tenant matrix namespace (e.g., tn-example-matrix)
#   MATRIX_HOST - Matrix hostname (e.g., matrix.dev.example.com)

apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: synapse-tls
  namespace: ${NS_MATRIX}
spec:
  secretName: synapse-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - ${MATRIX_HOST}
