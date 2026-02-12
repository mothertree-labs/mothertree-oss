apiVersion: apps/v1
kind: Deployment
metadata:
  name: matrix-alertmanager
  namespace: infra-monitoring
  labels:
    app: matrix-alertmanager
spec:
  replicas: 1
  selector:
    matchLabels:
      app: matrix-alertmanager
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: matrix-alertmanager
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: matrix-alertmanager
          # Using metio/matrix-alertmanager-receiver from Docker Hub
          # See: https://hub.docker.com/r/metio/matrix-alertmanager-receiver
          image: metio/matrix-alertmanager-receiver:2025.12.24
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
          args:
            - --config-path=/config/config.yaml
            - --log-level=info
          ports:
            - containerPort: 3000
              name: http
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 50m
              memory: 64Mi
          livenessProbe:
            httpGet:
              path: /metrics
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /metrics
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: config
          secret:
            secretName: matrix-alertmanager-config
