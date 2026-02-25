# Allow Admin Portal → Synapse Admin API Egress
# Applied to tn-<tenant>-admin namespace only.
# Permits admin portal pods to reach Synapse's Admin API (port 8008)
# for user provisioning (ensureMatrixUser) during the invite flow.
#
# Required environment variables:
#   NAMESPACE   - Source namespace (e.g., tn-example-admin)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to admin namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-matrix
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # Synapse HTTP API (tn-<tenant>-matrix)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-matrix
      ports:
        - protocol: TCP
          port: 8008
