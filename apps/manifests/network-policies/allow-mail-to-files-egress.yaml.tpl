# Allow Mail → Nextcloud CalDAV Egress
# Applied to tn-<tenant>-mail namespace only.
# Permits calendar-automation to reach Nextcloud's HTTP API in tn-<tenant>-files
# for CalDAV event creation/update/deletion.
#
# Required environment variables:
#   NAMESPACE   - Source namespace (e.g., tn-example-mail)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to mail namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mail-to-files-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-egress
spec:
  podSelector:
    matchLabels:
      app: calendar-automation
  policyTypes:
    - Egress
  egress:
    # Nextcloud HTTP API (tn-<tenant>-files)
    # Service port is 8080, but NetworkPolicy matches destination pod port (80)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-files
      ports:
        - protocol: TCP
          port: 80
