# Jitsi Keycloak Adapter - bridges Keycloak OIDC to Jitsi JWT authentication
# See: https://github.com/nordeck/jitsi-keycloak-adapter
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-keycloak-adapter
  namespace: matrix
  labels:
    app: jitsi-keycloak-adapter
    component: auth
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jitsi-keycloak-adapter
  template:
    metadata:
      labels:
        app: jitsi-keycloak-adapter
        component: auth
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: adapter
        image: ghcr.io/nordeck/jitsi-keycloak-adapter:v20260106
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true
        ports:
        - containerPort: 9000
          name: http
        env:
        - name: KEYCLOAK_ORIGIN
          value: "https://${AUTH_HOST}"
        - name: KEYCLOAK_REALM
          value: "${TENANT_KEYCLOAK_REALM}"
        - name: KEYCLOAK_CLIENT_ID
          value: "jitsi"
        # KEYCLOAK_CLIENT_SECRET is empty for public clients
        - name: KEYCLOAK_CLIENT_SECRET
          value: ""
        - name: JWT_APP_ID
          value: "jitsi-mother-tree"
        - name: JWT_APP_SECRET
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JWT_APP_SECRET
        # Allow self-signed certs in dev (set to false for production with proper certs)
        - name: ALLOW_UNSECURE_CERT
          value: "false"
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 9000
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 9000
          initialDelaySeconds: 5
          periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-keycloak-adapter
  namespace: matrix
  labels:
    app: jitsi-keycloak-adapter
    component: auth
spec:
  type: ClusterIP
  ports:
  - port: 9000
    name: http
    targetPort: 9000
  selector:
    app: jitsi-keycloak-adapter
