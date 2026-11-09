# NetworkPolicy: Restrict access to Postfix ports
# - Port 25: Allow all (NodePort traffic will reach this for inbound MX dispatch)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postfix-ingress
  namespace: ${NS_MAIL}
spec:
  podSelector:
    matchLabels:
      app: postfix
  policyTypes:
    - Ingress
  ingress:
    # Port 25: smtp - allow all (NodePort traffic will reach this)
    # We can't distinguish NodePort traffic at NetworkPolicy level
    # Security relies on recipient verification at port 25
    - ports:
        - port: 25
          protocol: TCP
    # Port 10025: smtp-proxy - ONLY from the public ingress-nginx controller
    # pods. This listener trusts the client address in the PROXY header, so
    # anyone else reaching it could forge a sender IP. Namespace AND pod
    # selector in one entry = both must match.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NS_INGRESS}
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
              app.kubernetes.io/instance: ingress-nginx
              app.kubernetes.io/component: controller
      ports:
        - port: 10025
          protocol: TCP
