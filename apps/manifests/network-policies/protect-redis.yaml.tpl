# Protect Redis — Only Allow Connections from Portal Pods
# Redis stores session data for admin-portal and account-portal.
# This policy restricts Redis access to only those pods within the same namespace,
# preventing cross-tenant or cross-service access to session data.
#
# Redis is deployed in the tn-<tenant>-admin namespace alongside admin-portal
# and account-portal. This policy allows only pods with app=admin-portal or
# app=account-portal to connect.
#
# Required environment variables:
#   NAMESPACE - Target admin namespace (e.g., tn-example-admin)
#
# Applied to admin namespaces by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: protect-redis
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: protect-redis
spec:
  podSelector:
    matchLabels:
      app: redis
  policyTypes:
    - Ingress
  ingress:
    # Allow from admin-portal pods in the same namespace
    - from:
        - podSelector:
            matchLabels:
              app: admin-portal
      ports:
        - protocol: TCP
          port: 6379
    # Allow from account-portal pods in the same namespace
    - from:
        - podSelector:
            matchLabels:
              app: account-portal
      ports:
        - protocol: TCP
          port: 6379
