apiVersion: v1
kind: Service
metadata:
  name: pg-metrics-bridge
  namespace: ${NS_DB}
  labels:
    app: pg-metrics-bridge
spec:
  type: ClusterIP
  ports:
    - name: metrics
      port: 9187
      targetPort: 9187
      protocol: TCP
  selector:
    app: pg-metrics-bridge
