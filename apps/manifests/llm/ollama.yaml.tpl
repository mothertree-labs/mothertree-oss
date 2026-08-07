apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: infra-llm
  labels:
    app.kubernetes.io/name: ollama
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  strategy:
    # No PVC volume lock anymore (emptyDir) — RollingUpdate with zero downtime.
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: ollama
        mothertree/component: llm
    spec:
      initContainers:
        - name: restore-models
          # Restore model weights from the S3 model cache into the shared
          # emptyDir before Ollama starts. Idempotent (content-addressed blobs,
          # no --delete). No-op when the bucket is empty (first-ever deploy) —
          # Ollama then lazy-pulls on first request while the seed Job populates
          # the bucket in the background.
          image: amazon/aws-cli:2.22.35
          command:
            - /bin/sh
            - -c
            - |
              aws s3 sync --no-progress s3://${LLM_S3_BUCKET}/${LLM_S3_PREFIX}/ /root/.ollama/
          envFrom:
            - secretRef:
                name: ollama-s3
          volumeMounts:
            - name: ollama-models
              mountPath: /root/.ollama
      containers:
        - name: ollama
          image: ollama/ollama:0.5.7
          command:
            - ollama
            - serve
          ports:
            - name: http
              containerPort: 11434
              protocol: TCP
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0"
            - name: OLLAMA_KEEP_ALIVE
              value: "30m"
            - name: OLLAMA_NUM_PARALLEL
              value: "1"
          volumeMounts:
            - name: ollama-models
              mountPath: /root/.ollama
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2000m"
              memory: "3500Mi"
          readinessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 3

      volumes:
        - name: ollama-models
          # Disk-backed (NOT medium: Memory) — the multi-GB model must not
          # count against pod memory. Ephemeral cache; the source of truth is
          # the S3 model cache, restored by the initContainer above.
          emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: infra-llm
  labels:
    app.kubernetes.io/name: ollama
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
spec:
  selector:
    app: ollama
  ports:
    - name: http
      port: 11434
      targetPort: 11434
      protocol: TCP
  type: ClusterIP
