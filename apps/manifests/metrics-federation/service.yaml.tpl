apiVersion: v1
kind: Service
metadata:
  name: ${FED_NAME}
  namespace: ${NS_MONITORING}
  labels:
    app: ${FED_NAME}
    component: metrics-federation
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 9090
      targetPort: 9090
      protocol: TCP
  selector:
    app: ${FED_NAME}
