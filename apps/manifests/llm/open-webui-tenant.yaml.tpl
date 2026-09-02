---
apiVersion: v1
kind: Secret
metadata:
  name: open-webui-oidc
  namespace: ${NS_LLM}
  labels:
    app.kubernetes.io/name: open-webui
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
type: Opaque
stringData:
  client-secret: "${LLM_OIDC_CLIENT_SECRET}"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: ${NS_LLM}
  labels:
    app.kubernetes.io/name: open-webui
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
spec:
  replicas: ${LLM_MIN_REPLICAS}
  selector:
    matchLabels:
      app: open-webui
  strategy:
    # Recreate (not RollingUpdate): prod mounts a RWO PVC for conversation history,
    # so a surge pod cannot mount the volume the old pod still holds — that deadlocks
    # restarts. Matches the ollama Deployment for the same reason.
    type: Recreate
  template:
    metadata:
      labels:
        app: open-webui
        mothertree/component: llm
    spec:
      containers:
        - name: open-webui
          image: openwebui/open-webui:0.11.3
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: OLLAMA_BASE_URL
              value: "http://ollama.infra-llm.svc.cluster.local:11434"
            - name: WEBUI_AUTH
              value: "true"
            - name: DEFAULT_MODELS
              value: "${LLM_MODEL}"
            # Open WebUI 0.11 defaults to native function calling, which
            # routes web search through the injected search_web tool. The
            # pinned single model (llama3.2:1b) cannot reliably emit native
            # tool calls when the full builtin tool suite (23 specs) is
            # injected — in testing it degraded to legacy <|python_tag|>
            # output and search silently never ran. Legacy FC instead forces
            # the deterministic SearXNG RAG path below. This env seeds the
            # PersistentConfig value; deploy-llm-webui.sh also upserts it into
            # webui.db so the setting survives on PVC-backed prod databases
            # (where a pre-existing "{}" row would otherwise shadow the env).
            - name: DEFAULT_MODEL_PARAMS
              value: '{"function_calling": "legacy"}'
            - name: OAUTH_CLIENT_ID
              value: "open-webui"
            - name: OAUTH_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: open-webui-oidc
                  key: client-secret
            - name: OPENID_PROVIDER_URL
              value: "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/.well-known/openid-configuration"
            - name: OAUTH_CODE_CHALLENGE_METHOD
              value: "S256"
            - name: ENABLE_OAUTH_SIGNUP
              value: "true"
            - name: DEFAULT_USER_ROLE
              value: "user"
            - name: ENABLE_LOGIN_FORM
              value: "false"
            - name: OAUTH_AUTO_REDIRECT
              value: "true"
            # Web search via the shared SearXNG service in infra-llm.
            # BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL is a narrow workaround
            # for the legacy-FC web-search collection RAG gap (page texts are
            # fed straight into the chat context instead of via the vector
            # store); it does not affect file/knowledge-base RAG. Requires
            # function_calling=legacy (see DEFAULT_MODEL_PARAMS above) — under
            # native FC the forced-RAG handler is skipped. See
            # docs/plans/llm/web-search.md.
            - name: ENABLE_WEB_SEARCH
              value: "true"
            - name: WEB_SEARCH_ENGINE
              value: "searxng"
            - name: SEARXNG_QUERY_URL
              value: "http://searxng.infra-llm.svc.cluster.local:8080/search"
            - name: BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL
              value: "true"
            # Open WebUI filters /api/models for role 'user' through per-model
            # access control, dropping every non-registered model (plain
            # Ollama models) unless granted — regular users see an empty model
            # list. This is the documented escape hatch; the shared LLM has a
            # single model and per-model grants are not used.
            - name: BYPASS_MODEL_ACCESS_CONTROL
              value: "true"
            # Open WebUI appends its built-in evaluation-arena entry
            # ("Arena Model", id: arena-model) to /api/models by default
            # (ENABLE_EVALUATION_ARENA_MODELS defaults to true). We don't use
            # the battle/vote feature, so keep it out of users' model lists.
            - name: ENABLE_EVALUATION_ARENA_MODELS
              value: "false"
          volumeMounts:
            - name: llm-data
              mountPath: /app/backend/data
          resources:
            requests:
              cpu: "${LLM_CPU_REQUEST}"
              memory: "${LLM_MEMORY_REQUEST}"
            limits:
              memory: "${LLM_MEMORY_LIMIT}"
          readinessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 120
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 120
            periodSeconds: 30
      volumes:
        - name: llm-data
          ${LLM_WEBUI_STORAGE_VALUE}

---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: ${NS_LLM}
  labels:
    app.kubernetes.io/name: open-webui
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
spec:
  selector:
    app: open-webui
  ports:
    - name: http
      port: 80
      targetPort: 8080
  type: ClusterIP

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: open-webui
  namespace: ${NS_LLM}
  labels:
    app.kubernetes.io/name: open-webui
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${LLM_HOST}
      secretName: wildcard-tls-${TENANT_NAME}
  rules:
    - host: ${LLM_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: open-webui
                port:
                  number: 80
