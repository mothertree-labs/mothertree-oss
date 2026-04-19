---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postfix
  namespace: ${NS_MAIL}
  labels:
    app: postfix
