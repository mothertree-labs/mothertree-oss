# Allow Mail Ingress
# Applied to tn-<tenant>-mail namespace only.
# Permits:
#   - Postfix (infra-mail) to deliver inbound email to Stalwart on port 25
#   - Roundcube (tn-<tenant>-webmail) to connect to Stalwart for IMAP/SMTP/Sieve
#
# Required environment variables:
#   NAMESPACE   - Target namespace (e.g., tn-example-mail)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to mail namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mail-ingress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-mail-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    # Postfix (infra-mail) delivering inbound email to Stalwart
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-mail
      ports:
        - protocol: TCP
          port: 25
    # Roundcube (webmail) connecting to Stalwart for IMAP, SMTP submission, Sieve
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-webmail
      ports:
        - protocol: TCP
          port: 993
        - protocol: TCP
          port: 587
        - protocol: TCP
          port: 4190
