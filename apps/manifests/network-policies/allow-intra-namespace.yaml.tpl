# Allow Intra-Namespace Egress Traffic
# Permits pods within the same namespace to communicate with each other (egress).
# Needed for: backend -> redis, backend -> y-provider, prosody -> jicofo, etc.
#
# Note: This policy only covers Egress. There is intentionally no Ingress
# policyType here — we rely on the absence of default-deny-ingress to allow
# all inbound traffic (including from the ingress controller in infra-ingress
# and kubelet health probes from node IPs). Targeted ingress restrictions are
# applied separately (protect-redis, protect-infra-db) for sensitive services.
#
# Required environment variables:
#   NAMESPACE - Target namespace (e.g., tn-example-docs)
#
# Applied per tenant namespace by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-intra-namespace
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector: {}
