# Allow Internet Egress (HTTPS)
# Permits pods to reach external services over HTTPS (port 443).
# Needed for: S3 object storage, PyPI/npm package installs, OIDC discovery,
# external webhooks, etc.
#
# Required environment variables:
#   NAMESPACE - Target namespace (e.g., tn-example-docs)
#
# Applied per tenant namespace by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internet-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-internet
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: TCP
          port: 443
