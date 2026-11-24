# Allow migration/config Jobs → Stalwart management API (#715)
# Applied to tn-<tenant>-mail namespace only.
#
# The Stalwart v1 config plan Job and the 0.15 → v1 dump Job talk to
# Stalwart's management API on 8080 from inside the mail namespace. The
# namespace's ingress allow-list (allow-mail-ingress) admits 8080 only from
# the admin namespace and calendar-automation, so those Jobs carry the label
# below and get exactly this port.
#
# Required environment variables:
#   NAMESPACE - Target namespace (e.g., tn-example-mail)

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-stalwart-mgmt-ingress
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: stalwart
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              stalwart.mothertree/mgmt-client: "true"
      ports:
        - port: 8080
          protocol: TCP
