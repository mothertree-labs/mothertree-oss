# Stalwart Mail Server - TLS Certificate
# Uses cert-manager to provision certificates
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   MAIL_HOST - Mail server hostname (e.g., mail.example.com)

apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: stalwart-tls
  namespace: ${NS_MAIL}
spec:
  secretName: stalwart-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - ${MAIL_HOST}
  - ${IMAP_HOST}
  - ${SMTP_HOST}
