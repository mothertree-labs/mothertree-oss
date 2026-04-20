# Allow Tenant Caller → Stalwart SMTP Submission Egress
# Applied to tn-<tenant>-{docs,matrix,files} namespaces.
# Permits Docs (Django), Synapse, and Nextcloud to reach Stalwart's
# submission-app listener (:588) for authenticated mail submission.
#
# The admin namespace has its own allow-admin-to-mail-egress policy that
# already covers port 588 (plus :8080 for the admin API).
#
# Required environment variables:
#   NAMESPACE   - Source namespace (e.g., tn-example-docs)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied per caller namespace by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-mail-smtp
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-egress
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
          port: 588
