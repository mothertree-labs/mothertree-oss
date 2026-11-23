# Matrix Authentication Service (MAS) — per tenant, in the Matrix namespace.
# Applied by apps/deploy-mas.sh (envsubst with an explicit variable list).
# Config + secret files come from the `mas-config` Secret (see config.yaml.tpl).
#
# Required environment variables:
#   NS_MATRIX     - Tenant matrix namespace (e.g., tn-example-matrix)
#   TENANT_NAME   - Tenant name (wildcard TLS secret name)
#   MAS_HOST      - Public MAS hostname (e.g., mas.example.com)
apiVersion: v1
kind: Service
metadata:
  name: mas
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: mas
    tenant: ${TENANT_NAME}
spec:
  selector:
    app.kubernetes.io/name: mas
    app.kubernetes.io/component: server
  ports:
    - name: web
      port: 8080
      targetPort: web
      protocol: TCP
    - name: internal
      port: 8081
      targetPort: internal
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mas
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: mas
    tenant: ${TENANT_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: mas
      app.kubernetes.io/component: server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mas
        app.kubernetes.io/component: server
        tenant: ${TENANT_NAME}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        # Secret files are mounted 0440; fsGroup makes them group-readable by MAS.
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mas
          image: ghcr.io/element-hq/matrix-authentication-service:1.29.0
          imagePullPolicy: IfNotPresent
          # `server` applies pending DB migrations and syncs the upstream
          # provider from the config on every start.
          args: ["server", "--config", "/config/config.yaml"]
          ports:
            - name: web
              containerPort: 8080
              protocol: TCP
            - name: internal
              containerPort: 8081
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          startupProbe:
            httpGet:
              path: /health
              port: internal
            periodSeconds: 5
            failureThreshold: 36
          readinessProbe:
            httpGet:
              path: /health
              port: internal
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: internal
            periodSeconds: 30
            failureThreshold: 3
      volumes:
        - name: config
          secret:
            secretName: mas-config
            defaultMode: 0440
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mas
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: mas
    tenant: ${TENANT_NAME}
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${MAS_HOST}
      secretName: wildcard-tls-${TENANT_NAME}
  rules:
    - host: ${MAS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mas
                port:
                  name: web
