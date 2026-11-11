# devbox only (scripts/devbox up): let a tenant namespace reach the in-cluster
# S3 gateway (infra-s3, port 7070). Tenant namespaces are default-deny for
# egress; on real environments S3 is reached over the internet on :443
# (allow-internet-egress), which this gateway is not.
# Variables: NAMESPACE
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-devbox-s3-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: mothertree-devbox
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-s3
      ports:
        - protocol: TCP
          port: 7070
