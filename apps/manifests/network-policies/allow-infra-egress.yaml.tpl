# Allow Egress to Shared Infrastructure Services
# Permits tenant pods to reach:
#   - PostgreSQL in infra-db (port 5432)
#   - Keycloak in infra-auth (ports 8080, 8443)
#   - Postfix in infra-mail (port 25 for outbound email, port 587 for submission)
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
  name: allow-egress-to-infra
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # PostgreSQL (infra-db)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-db
      ports:
        - protocol: TCP
          port: 5432
    # Keycloak (infra-auth) - HTTP and HTTPS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-auth
      ports:
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 8443
    # Postfix (infra-mail) - SMTP and Submission
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-mail
      ports:
        - protocol: TCP
          port: 25
        - protocol: TCP
          port: 587
