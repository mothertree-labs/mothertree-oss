# Allow Admin Portal → Stalwart Mail API Egress
# Applied to tn-<tenant>-admin namespace only.
# Permits admin portal and account portal pods to reach Stalwart's HTTP API
# for user provisioning (ensureUserExists) and quota management.
#
# Required environment variables:
#   NAMESPACE   - Source namespace (e.g., tn-example-admin)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to admin namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-mail
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # Stalwart HTTP API (tn-<tenant>-mail)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-mail
      ports:
        - protocol: TCP
          port: 8080
