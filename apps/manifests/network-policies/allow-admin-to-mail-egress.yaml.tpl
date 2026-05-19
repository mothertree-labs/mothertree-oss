# Allow Admin Portal → Stalwart Mail Egress
# Applied to tn-<tenant>-admin namespace only.
# Permits admin portal and account portal pods to reach Stalwart:
#   - HTTP API (:8080) for user provisioning and quota management
#   - SMTP submission-app (:588) for authenticated mail relay (Keycloak
#     notifications, share invites, account portal magic links)
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
    # Stalwart HTTP API (tn-<tenant>-mail:8080) + SMTP submission-app (:588)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-mail
      ports:
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 588
