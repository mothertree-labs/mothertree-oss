# Allow Files → Admin Egress (Guest Bridge → Account Portal API)
# Applied to tn-<tenant>-files namespace only.
# Permits Nextcloud pods to reach the Account Portal in tn-<tenant>-admin
# on port 3000 for guest user provisioning via the guest_bridge app.
# Note: Calico evaluates egress after DNAT, so we use the pod port (3000)
# not the Service port (80).
#
# Required environment variables:
#   NAMESPACE   - Source namespace (e.g., tn-example-files)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to files namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-files-to-admin-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-files-admin
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-admin
      ports:
        - protocol: TCP
          port: 3000
