# Roundcube Webmail - TLS Certificate
# Uses cert-manager to provision certificates
#
# Required environment variables:
#   NS_WEBMAIL - Tenant webmail namespace (e.g., tn-example-webmail)
#   WEBMAIL_HOST - Webmail hostname (e.g., webmail.dev.example.com)

apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: roundcube-tls
  namespace: ${NS_WEBMAIL}
spec:
  secretName: roundcube-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - ${WEBMAIL_HOST}
