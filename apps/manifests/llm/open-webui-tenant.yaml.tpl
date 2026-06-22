apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: llm-data
  namespace: ${NS_LLM}
  labels:
    app.kubernetes.io/name: open-webui
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: linode-block-storage-retain
  resources:
    requests:
      storage: ${LLM_STORAGE_SIZE}

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
  replicas: 1
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
        mothertree/component: llm
    spec:
      containers:
        - name: open-webui
          image: ghcr.io/open-webui/open-webui:main
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: OLLAMA_BASE_URL
              value: "http://ollama.infra-llm.svc.cluster.local:11434"
            - name: WEBUI_AUTH
              value: "true"
            - name: OLLAMA_DEFAULT_MODELS
              value: "${LLM_MODEL}"
            - name: OAUTH_CLIENT_ID
              value: "open-webui"
            - name: OAUTH_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: open-webui-oidc
                  key: client-secret
            - name: OPENID_PROVIDER_URL
              value: "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/.well-known/openid-configuration"
            - name: ENABLE_OAUTH_SIGNUP
              value: "true"
          volumeMounts:
            - name: llm-data
              mountPath: /app/backend/data
          resources:
            requests:
              cpu: "200m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          readinessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: llm-data
          persistentVolumeClaim:
            claimName: llm-data

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
