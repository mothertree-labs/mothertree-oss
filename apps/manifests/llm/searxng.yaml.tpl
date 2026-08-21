apiVersion: apps/v1
kind: Deployment
metadata:
  name: searxng
  namespace: infra-llm
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: searxng
  strategy:
    # Single replica — maxUnavailable 0 keeps an instance serving through
    # restarts (matches the ollama Deployment).
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: searxng
        mothertree/component: llm
    spec:
      securityContext:
        fsGroup: 977
      containers:
        - name: searxng
          # Date-stamped tag from Docker Hub (searxng/searxng). Bump by picking
          # the newest 2026.*-<sha> tag; verified working image from the dev
          # rollout (see docs/plans/llm/web-search.md).
          image: searxng/searxng:2026.8.5-1689cb1b5
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          volumeMounts:
            - name: settings
              mountPath: /etc/searxng
              readOnly: true
            - name: data
              mountPath: /var/cache/searxng
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
          readinessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: settings
          secret:
            secretName: searxng-settings
            defaultMode: 0444
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: searxng
  namespace: infra-llm
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
spec:
  selector:
    app: searxng
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
  type: ClusterIP
