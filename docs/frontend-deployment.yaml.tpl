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
          image: lasuite/impress-frontend:v5.6.1
          # No command override: the image's own ENTRYPOINT/CMD
          # (/usr/local/bin/entrypoint -> nginx -g 'daemon off;') listens on 8080.
          ports:
            - containerPort: 8080
              name: http
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
              memory: 128Mi
          securityContext:
            runAsUser: 101
          # nginx's web root is /app since impress 4.8 (was /usr/share/nginx/html).
          # Neither /app/static nor /app/email-assets exists in the image, so
          # these directory mounts shadow nothing upstream serves.
          volumeMounts:
            - name: save-status-scripts
              mountPath: /app/static
              readOnly: true
            # Email logo served at /email-assets/logo-email.png (referenced by
            # DJANGO_EMAIL_LOGO_IMG in the backend's invitation emails).
            # Own directory mount — nesting a file mount inside the read-only
            # /static ConfigMap mount can fail pod start.
            - name: email-assets
              mountPath: /app/email-assets
              readOnly: true
      volumes:
        - name: save-status-scripts
          configMap:
            name: save-status-scripts
        - name: email-assets
          configMap:
            name: docs-email-assets
      restartPolicy: Always

