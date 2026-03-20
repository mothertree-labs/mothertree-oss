# Postfix Internal Service - for internal apps to send via submission port
# This service provides SMTP submission (port 587) without recipient verification
# for trusted internal apps (Keycloak, Alertmanager, Synapse, Stalwart)
apiVersion: v1
kind: Service
metadata:
  name: postfix-internal
  namespace: ${NS_MAIL}
  labels:
    app: postfix
spec:
  selector:
    app: postfix
  ports:
    - port: 587
      targetPort: 587
      name: submission
  type: ClusterIP
