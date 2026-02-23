# Allow Files → Office Egress (Collabora Internal)
# Applied to tn-<tenant>-files namespace only.
# Permits Nextcloud pods to reach Collabora Online in tn-<tenant>-office
# on port 9980 for the /hosting/discovery check and WOPI communication.
#
# Required environment variables:
#   NAMESPACE   - Source namespace (e.g., tn-example-files)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to files namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-files-to-office-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-files-office
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-office
      ports:
        - protocol: TCP
          port: 9980
