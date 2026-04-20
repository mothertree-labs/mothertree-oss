# Allow SMTP Egress from Stalwart (to any destination)
# Permits tenant Stalwart pods to open outbound SMTP connections on 25/465/587.
# Needed by the outbound path introduced in step-2 PR-1 of the mail migration:
#   - Prod: Stalwart → AWS SES on 587 (SASL-authenticated submission)
#   - Dev:  Stalwart → destination MX on 25 (direct delivery)
#
# Scoped to pods with label `app: stalwart` so calendar-automation and any
# other pods in this namespace keep their original default-deny egress posture.
# Uses `podSelector` rather than broadening `allow-internet-egress` globally —
# that policy is shared across every tenant namespace and deliberately limited
# to port 443.
#
# Required environment variables:
#   NAMESPACE - Tenant mail namespace (e.g., tn-example-mail)
#
# Applied by deploy-network-policies.sh when the tenant mail namespace exists.

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mail-smtp-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-mail-smtp-egress
spec:
  podSelector:
    matchLabels:
      app: stalwart
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: TCP
          port: 25
        - protocol: TCP
          port: 465
        - protocol: TCP
          port: 587
