apiVersion: apps/v1
kind: Deployment
metadata:
  name: admin-portal
  namespace: ${NS_ADMIN}
  labels:
    app: admin-portal
    tenant: ${TENANT_NAME}
spec:
  replicas: ${ADMIN_PORTAL_MIN_REPLICAS}
  selector:
    matchLabels:
      app: admin-portal
  template:
    metadata:
      labels:
        app: admin-portal
        tenant: ${TENANT_NAME}
    spec:
      containers:
        - name: admin-portal
          image: ${ADMIN_PORTAL_IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: 3000
              protocol: TCP
          env:
            - name: NODE_ENV
              value: "production"
            - name: BASE_URL
              value: "https://${ADMIN_HOST}"
            - name: SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: admin-portal-secrets
                  key: nextauth-secret
            - name: KEYCLOAK_CLIENT_ID
              value: "admin-portal"
            - name: KEYCLOAK_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: admin-portal-secrets
                  key: keycloak-client-secret
            - name: KEYCLOAK_BOOTSTRAP_CLIENT_ID
              value: "admin-portal-bootstrap"
            - name: KEYCLOAK_BOOTSTRAP_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: admin-portal-secrets
                  key: keycloak-client-secret
            - name: KEYCLOAK_ISSUER
              value: "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}"
            - name: KEYCLOAK_URL
              value: "https://${AUTH_HOST}"
            - name: KEYCLOAK_REALM
              value: "${TENANT_KEYCLOAK_REALM}"
            - name: WEBMAIL_HOST
              value: "${WEBMAIL_HOST}"
            - name: TENANT_DOMAIN
              value: "${TENANT_DOMAIN}"
            # EMAIL_DOMAIN includes env prefix (e.g., dev.example.com for dev)
            # Used for creating user email addresses in the correct domain
            - name: EMAIL_DOMAIN
              value: "${EMAIL_DOMAIN}"
            # Account Portal URL for cross-portal invitation redirects
            - name: ACCOUNT_PORTAL_URL
              value: "https://${ACCOUNT_HOST}"
            - name: ACCOUNT_PORTAL_CLIENT_ID
              value: "account-portal"
            # Stalwart mail server API (for user provisioning during invite)
            - name: STALWART_API_URL
              value: "http://stalwart.${NS_MAIL}.svc.cluster.local:8080"
            - name: STALWART_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: admin-portal-secrets
                  key: stalwart-admin-password
            # Redis for session storage (enables HA with multiple replicas)
            - name: REDIS_HOST
              value: "redis"
            - name: REDIS_PORT
              value: "6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: admin-portal-secrets
                  key: REDIS_PASSWORD
            # HMAC secret for beginSetup token verification (shared with account portal)
            - name: BEGINSETUP_SECRET
              valueFrom:
                secretKeyRef:
                  name: admin-portal-secrets
                  key: beginsetup-secret
          resources:
            requests:
              memory: "64Mi"
              cpu: "100m"  # Minimum 100m to prevent HPA triggering on idle fluctuations
            limits:
              memory: "128Mi"
              cpu: "200m"
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 3
            periodSeconds: 10
