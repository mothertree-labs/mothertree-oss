# Email Probe - End-to-end email delivery monitoring
# Deployed per-tenant to namespace tn-<tenant>-mail
#
# Sends probe emails through the full mail chain every 15 minutes,
# waits for auto-reply, and exposes Prometheus metrics.
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   TENANT_NAME - Tenant name (e.g., example)
#   BOT_EMAIL - Probe bot email address (e.g., email-probe@dev.example.com)
#   BOT_PASSWORD - Probe bot app password
#   OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_USER_PASSWORD, OIDC_TOKEN_URL -
#     the synthetic Keycloak login (apps/scripts/ensure-email-probe-oidc.py)
#   EMAIL_PROBE_CHECKSUM - hash of the script and secrets (rolls the pod)
#   TARGET_EMAIL - External auto-reply address
#   EMAIL_PROBE_MEMORY_REQUEST, EMAIL_PROBE_MEMORY_LIMIT
#   EMAIL_PROBE_CPU_REQUEST

---
apiVersion: v1
kind: Secret
metadata:
  name: email-probe-secrets
  namespace: ${NS_MAIL}
type: Opaque
stringData:
  BOT_PASSWORD: "${BOT_PASSWORD}"
  OIDC_CLIENT_SECRET: "${OIDC_CLIENT_SECRET}"
  OIDC_USER_PASSWORD: "${OIDC_USER_PASSWORD}"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: email-probe
  namespace: ${NS_MAIL}
  labels:
    app: email-probe
    tenant: ${TENANT_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: email-probe
  template:
    metadata:
      labels:
        app: email-probe
        tenant: ${TENANT_NAME}
      annotations:
        checksum/config: "${EMAIL_PROBE_CHECKSUM}"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: email-probe
        image: python:3.14.1-alpine3.21
        command: ["python3", "/app/email-probe.py"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        ports:
        - containerPort: 9090
          name: metrics
        env:
        - name: SMTP_HOST
          value: "stalwart.${NS_MAIL}.svc.cluster.local"
        - name: SMTP_PORT
          value: "588"
        - name: IMAP_HOST
          value: "stalwart.${NS_MAIL}.svc.cluster.local"
        - name: IMAP_PORT
          value: "994"
        - name: BOT_EMAIL
          value: "${BOT_EMAIL}"
        - name: BOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: email-probe-secrets
              key: BOT_PASSWORD
        # Synthetic OIDC login: Keycloak token (aud=stalwart), then IMAP
        # XOAUTH2 on 993, as Roundcube does.
        - name: OIDC_IMAP_PORT
          value: "993"
        - name: OIDC_TOKEN_URL
          value: "${OIDC_TOKEN_URL}"
        - name: OIDC_CLIENT_ID
          value: "${OIDC_CLIENT_ID}"
        - name: OIDC_USERNAME
          value: "email-probe"
        - name: OIDC_CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: email-probe-secrets
              key: OIDC_CLIENT_SECRET
        - name: OIDC_USER_PASSWORD
          valueFrom:
            secretKeyRef:
              name: email-probe-secrets
              key: OIDC_USER_PASSWORD
        - name: OIDC_LOGIN_INTERVAL
          value: "300"
        - name: TARGET_EMAIL
          value: "${TARGET_EMAIL}"
        - name: PROBE_INTERVAL
          value: "900"
        - name: PROBE_TIMEOUT
          value: "240"
        - name: TENANT_NAME
          value: "${TENANT_NAME}"
        - name: INFRA_DOMAIN
          value: "${INFRA_DOMAIN}"
        - name: METRICS_PORT
          value: "9090"
        volumeMounts:
        - name: script
          mountPath: /app
          readOnly: true
        resources:
          requests:
            memory: "${EMAIL_PROBE_MEMORY_REQUEST}"
            cpu: "${EMAIL_PROBE_CPU_REQUEST}"
          limits:
            memory: "${EMAIL_PROBE_MEMORY_LIMIT}"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 9090
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /healthz
            port: 9090
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: script
        configMap:
          name: email-probe-script

---
apiVersion: v1
kind: Service
metadata:
  name: email-probe
  namespace: ${NS_MAIL}
  labels:
    app: email-probe
    tenant: ${TENANT_NAME}
spec:
  selector:
    app: email-probe
  ports:
  - name: metrics
    port: 9090
    targetPort: 9090
  type: ClusterIP
