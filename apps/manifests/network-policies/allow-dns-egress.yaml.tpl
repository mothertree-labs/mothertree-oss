# Allow DNS Egress
# Permits all pods in the namespace to reach kube-dns in kube-system.
# DNS resolution is essential — without this policy, pods cannot resolve
# service names or external hostnames after default-deny is applied.
#
# Uses the built-in kubernetes.io/metadata.name label which Kubernetes automatically
# sets on all namespaces (no manual labeling required).
#
# Required environment variables:
#   NAMESPACE - Target namespace (e.g., tn-example-matrix)
#
# Applied per tenant namespace by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-dns
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # DNS (kube-system) - UDP and TCP on port 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
