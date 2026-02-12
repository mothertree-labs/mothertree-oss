apiVersion: apps/v1
kind: Deployment
metadata:
  name: account-portal
  namespace: ${NS_ADMIN}
  labels:
    app: account-portal
    tenant: ${TENANT_NAME}
spec:
  replicas: ${ACCOUNT_PORTAL_MIN_REPLICAS}
  selector:
    matchLabels:
      app: account-portal
  template:
    metadata:
      labels:
        app: account-portal
        tenant: ${TENANT_NAME}
    spec:
      containers:
        - name: account-portal
          image: ${ACCOUNT_PORTAL_IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: 3000
              protocol: TCP
          env:
            - name: NODE_ENV
              value: "production"
            - name: BASE_URL
              value: "https://${ACCOUNT_HOST}"
            - name: SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: account-portal-secrets
                  key: nextauth-secret
            - name: KEYCLOAK_CLIENT_ID
              value: "account-portal"
            - name: KEYCLOAK_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: account-portal-secrets
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
            # Used for guest registration domain validation
            - name: EMAIL_DOMAIN
              value: "${EMAIL_DOMAIN}"
            # Stalwart mail server API (for device passwords / app passwords)
            - name: STALWART_API_URL
              value: "http://stalwart.${NS_MAIL}.svc.cluster.local:8080"
            - name: STALWART_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: account-portal-secrets
                  key: stalwart-admin-password
            - name: MAIL_HOST
              value: "${MAIL_HOST}"
            - name: IMAP_HOST
              value: "${IMAP_HOST}"
            - name: SMTP_HOST
              value: "${SMTP_HOST}"
            - name: STALWART_IMAPS_PORT
              value: "${STALWART_IMAPS_PORT}"
            - name: STALWART_SUBMISSION_PORT
              value: "${STALWART_SUBMISSION_PORT}"
            - name: STALWART_IMAPS_APP_PORT
              value: "${STALWART_IMAPS_APP_PORT}"
            - name: STALWART_SUBMISSION_APP_PORT
              value: "${STALWART_SUBMISSION_APP_PORT}"
            - name: FILES_HOST
              value: "${FILES_HOST}"
            # Redis for session storage (enables HA with multiple replicas)
            - name: REDIS_HOST
              value: "redis"
            - name: REDIS_PORT
              value: "6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: account-portal-secrets
                  key: REDIS_PASSWORD
            # HMAC secret for beginSetup token generation and verification
            - name: BEGINSETUP_SECRET
              valueFrom:
                secretKeyRef:
                  name: account-portal-secrets
                  key: beginsetup-secret
          resources:
            requests:
              memory: "64Mi"
              cpu: "100m"
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
