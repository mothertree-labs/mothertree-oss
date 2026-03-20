# Postfix ClusterIP Service - internal SMTP access only
apiVersion: v1
kind: Service
metadata:
  name: postfix
  namespace: ${NS_MAIL}
  labels:
    app: postfix
spec:
  selector:
    app: postfix
  ports:
    - port: 25
      targetPort: 25
      name: smtp
  type: ClusterIP
