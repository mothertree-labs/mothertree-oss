# Postfix NodePort Service - for VPN server to reach K8s Postfix via VPC
# This allows the VPN Postfix to route inbound mail to K8s without going through internet
apiVersion: v1
kind: Service
metadata:
  name: postfix-nodeport
  namespace: ${NS_MAIL}
  labels:
    app: postfix
spec:
  selector:
    app: postfix
  ports:
    - port: 25
      targetPort: 25
      nodePort: 30025
      name: smtp
  type: NodePort
  # Use Cluster policy so NodePort works on any node (pod may move)
  # Source IP will be SNAT'd but that's OK - K8s Postfix trusts 10.0.0.0/8 (pod network)
  # Security is enforced at VPN Postfix level (specific VPN IP in mynetworks)
  externalTrafficPolicy: Cluster
