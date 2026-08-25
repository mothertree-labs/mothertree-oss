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
    # Kill-before-create: with maxSurge, old + new pods need BOTH memory
    # requests simultaneously, which cannot schedule on the fixed-size,
    # tightly-packed dev pool (autoscaling disabled) — the rollout wedges
    # Pending forever. Brief downtime per rollout is fine: the web-search
    # gate waits for Ollama readiness, and rollouts only happen on manifest
    # changes.
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
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
          # no --delete). No-op when the bucket is empty (first-ever deploy);
          # the main container then pulls the model directly (see below) while
          # the seed Job populates the bucket in the background.
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
            - /bin/sh
            - -c
            - |
              # NOTE: this script is envsubst-templated at deploy time — do not
              # introduce shell variable references beyond the LLM_* ones
              # (envsubst blanks any it doesn't know). $! and awk's $1 are safe
              # (not valid envsubst identifiers).
              ollama serve &
              # Graceful drain: forward TERM to the backgrounded serve (sh
              # won't), so rolling updates let in-flight requests finish
              # instead of SIGKILLing ollama at container teardown.
              trap 'kill $! 2>/dev/null' TERM
              sleep 3
              until ollama list >/dev/null 2>&1; do sleep 1; done
              # Ollama's HTTP API does NOT auto-pull a missing model (it 404s),
              # so a first boot on an empty S3 cache would serve 404s until a
              # manual rollout restart. Pull it ourselves when the restore
              # initContainer had nothing to restore. `wait` is intentional:
              # it keeps serve alive as this container's long-running process.
              # LLM_MODEL_CANONICAL (bare names normalized to :latest by
              # deploy-llm.sh) matches how `ollama list` prints model names.
              if ! ollama list | awk -v m="${LLM_MODEL_CANONICAL}" '$1 == m { found = 1 } END { exit !found }'; then
                echo "Model ${LLM_MODEL_CANONICAL} missing locally — pulling from ollama.com (first boot on empty S3 cache)..."
                if ! ollama pull "${LLM_MODEL_CANONICAL}" > /tmp/pull.log 2>&1; then
                  tail -20 /tmp/pull.log >&2
                  exit 1
                fi
                tail -5 /tmp/pull.log
              fi
              wait
          ports:
            - name: http
              containerPort: 11434
              protocol: TCP
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0"
            - name: LLM_MODEL
              value: "${LLM_MODEL}"
            - name: OLLAMA_KEEP_ALIVE
              value: "30m"
            - name: OLLAMA_NUM_PARALLEL
              value: "1"
          volumeMounts:
            - name: ollama-models
              mountPath: /root/.ollama
          resources:
            requests:
              # Sized for the model loaded for inference (~1.7Gi for
              # llama3.2:1b), not the idle server. A 1Gi request made the
              # pod the prime memory-eviction victim whenever inference
              # ran (usage exceeded request by ~0.7Gi). 1536Mi is the
              # largest request that still fits current node packing
              # without forcing a scale-up; usage can still slightly
              # exceed it, so the web-search gate also tolerates a
              # transient Ollama restart.
              cpu: "500m"
              memory: "1536Mi"
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
