# Allow Stalwart → stalwart-redis (#715)
# Applied to tn-<tenant>-mail namespace only.
#
# The mail namespace's ingress is a per-port allow-list (allow-mail-ingress)
# with no rule for 6379, so stalwart-redis is reachable only through this
# policy: from Stalwart pods (cluster coordinator + in-memory store) and
# nothing else in or outside the namespace. calendar-automation and
# email-probe share the namespace but cannot connect.
#
# Required environment variables:
#   NAMESPACE - Target namespace (e.g., tn-example-mail)

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-stalwart-redis-ingress
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: stalwart-redis
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: stalwart
      ports:
        - port: 6379
          protocol: TCP
