# Allow Webmail to Mail Egress
# Applied to tn-<tenant>-webmail namespace only.
# Permits Roundcube to connect to Stalwart in tn-<tenant>-mail for
# IMAP (993), SMTP submission (587), and ManageSieve (4190).
#
# Required environment variables:
#   NAMESPACE   - Target namespace (e.g., tn-example-webmail)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to webmail namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-webmail-to-mail-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-webmail-mail
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-mail
      ports:
        - protocol: TCP
          port: 993
        - protocol: TCP
          port: 587
        - protocol: TCP
          port: 4190
