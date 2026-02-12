# Allow Egress to Kubernetes API Server
# Permits pods to reach the Kubernetes API server (port 6443).
# Needed for: kubectl exec/wait in jobs (e.g., nextcloud-oidc-config),
# any pod using the downward API or service account tokens for API calls.
#
# Note: The K8s API server ClusterIP (kubernetes.default.svc) listens on 443,
# but traffic is DNAT'd to the control plane on port 6443. Calico evaluates
# egress policies against post-DNAT destinations, so we must allow port 6443.
#
# Required environment variables:
#   NAMESPACE - Target namespace (e.g., tn-example-files)
#
# Applied per tenant namespace by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kube-api-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-kube-api-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: TCP
          port: 6443
