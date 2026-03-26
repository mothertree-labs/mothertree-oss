apiVersion: v1
kind: Service
metadata:
  name: pgbouncer
  namespace: ${NS_DB}
  labels:
    app: pgbouncer
spec:
  type: ClusterIP
  ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
      protocol: TCP
  selector:
    app: pgbouncer
