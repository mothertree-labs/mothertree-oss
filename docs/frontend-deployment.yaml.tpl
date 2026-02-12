apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    kompose.cmd: kompose convert
    kompose.version: 1.37.0 (HEAD)
  labels:
    io.kompose.service: frontend
    app.kubernetes.io/name: docs-frontend
    app.kubernetes.io/part-of: mother-tree
  name: frontend
  namespace: docs
spec:
  replicas: ${DOCS_FRONTEND_MIN_REPLICAS}
  selector:
    matchLabels:
      io.kompose.service: frontend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      annotations:
        kompose.cmd: kompose convert
        kompose.version: 1.37.0 (HEAD)
      labels:
        io.kompose.service: frontend
    spec:
      containers:
        - name: frontend
          image: lasuite/impress-frontend:v4.4.0
          ports:
            - containerPort: 8080
              name: http
          command:
            - /docker-entrypoint.sh
          args:
            - nginx
            - -g
            - daemon off;
          env:
          - name: NEXT_PUBLIC_API_URL
            value: "https://${DOCS_HOST}/api"
          - name: NEXT_PUBLIC_WS_URL
            value: "wss://${DOCS_HOST}/collaboration/ws/"
          # Memory tuned based on actual usage (~4Mi observed)
          resources:
            requests:
              cpu: 100m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            runAsUser: 101
          volumeMounts:
            - name: save-status-scripts
              mountPath: /usr/share/nginx/html/static
              readOnly: true
      volumes:
        - name: save-status-scripts
          configMap:
            name: save-status-scripts
      restartPolicy: Always

