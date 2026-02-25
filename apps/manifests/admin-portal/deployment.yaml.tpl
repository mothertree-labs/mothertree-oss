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
          imagePullPolicy: IfNotPresent
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
            - name: KEYCLOAK_INTERNAL_URL
              value: "http://keycloak-keycloakx-http.infra-auth.svc.cluster.local"
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
            # Default email quota per user in MB (0 = unlimited)
            - name: DEFAULT_EMAIL_QUOTA_MB
              value: "${DEFAULT_EMAIL_QUOTA_MB}"
            # Policy URLs (externally hosted legal documents)
            - name: PRIVACY_POLICY_URL
              value: "${PRIVACY_POLICY_URL}"
            - name: TERMS_OF_USE_URL
              value: "${TERMS_OF_USE_URL}"
            - name: ACCEPTABLE_USE_POLICY_URL
              value: "${ACCEPTABLE_USE_POLICY_URL}"
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
