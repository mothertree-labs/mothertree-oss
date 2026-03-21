# NetworkPolicy: Restrict access to Postfix ports
# - Port 587: Allow from all cluster pods (internal apps)
# - Port 25: Allow all (NodePort traffic will reach this)
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
    # Port 587: submission - allow from all cluster namespaces
    - from:
        - namespaceSelector: {}
      ports:
        - port: 587
          protocol: TCP
    # Port 25: smtp - allow all (NodePort traffic will reach this)
    # We can't distinguish NodePort traffic at NetworkPolicy level
    # Security relies on recipient verification at port 25
    - ports:
        - port: 25
          protocol: TCP
