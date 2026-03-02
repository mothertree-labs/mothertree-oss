# Calendar Automation - Deployment, Service, ConfigMap, and Secrets
# Deployed per-tenant to namespace tn-<tenant>-mail (shares namespace with Stalwart)
#
# Processes iTIP email invitations (REQUEST/REPLY/CANCEL) and creates/updates/cancels
# events in Nextcloud CalDAV automatically.
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   TENANT_NAME - Tenant name (e.g., example)
#   FILES_HOST - Nextcloud files hostname for CalDAV (e.g., files.dev.example.com)
#   NEXTCLOUD_ADMIN_USER - Nextcloud admin username
#   NEXTCLOUD_ADMIN_PASSWORD - Nextcloud admin password
#   STALWART_ADMIN_PASSWORD - Stalwart admin password (for IMAP + API access)
#   CALENDAR_AUTOMATION_MEMORY_REQUEST, CALENDAR_AUTOMATION_MEMORY_LIMIT
#   CALENDAR_AUTOMATION_CPU_REQUEST, CALENDAR_AUTOMATION_CPU_LIMIT
#   POLL_INTERVAL_SECONDS - How often to scan inboxes (default: 60)
#   CONFIG_CHECKSUM - Checksum of config for pod restart on change

---
apiVersion: v1
kind: Secret
metadata:
  name: calendar-automation-secrets
  namespace: ${NS_MAIL}
type: Opaque
stringData:
  STALWART_ADMIN_PASSWORD: "${STALWART_ADMIN_PASSWORD}"
  CALDAV_ADMIN_USER: "${NEXTCLOUD_ADMIN_USER}"
  CALDAV_ADMIN_PASSWORD: "${NEXTCLOUD_ADMIN_PASSWORD}"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: calendar-automation
  namespace: ${NS_MAIL}
  labels:
    app: calendar-automation
    tenant: ${TENANT_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: calendar-automation
  template:
    metadata:
      labels:
        app: calendar-automation
        tenant: ${TENANT_NAME}
      annotations:
        checksum/config: "${CONFIG_CHECKSUM}"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: calendar-automation
        image: node:22-alpine
        command: ["node", "/app/server.js"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        ports:
        - containerPort: 8080
          name: health
        env:
        - name: IMAP_HOST
          value: "stalwart.${NS_MAIL}.svc.cluster.local"
        - name: IMAP_PORT
          value: "994"
        - name: STALWART_API_URL
          value: "http://stalwart.${NS_MAIL}.svc.cluster.local:443"
        - name: STALWART_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: calendar-automation-secrets
              key: STALWART_ADMIN_PASSWORD
        - name: CALDAV_BASE_URL
          value: "http://nextcloud.${NS_FILES}.svc.cluster.local:8080/remote.php/dav"
        - name: CALDAV_ADMIN_USER
          valueFrom:
            secretKeyRef:
              name: calendar-automation-secrets
              key: CALDAV_ADMIN_USER
        - name: CALDAV_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: calendar-automation-secrets
              key: CALDAV_ADMIN_PASSWORD
        - name: CALDAV_TOKEN_FILE
          value: "/config/caldav-tokens.json"
        - name: POLL_INTERVAL_SECONDS
          value: "${POLL_INTERVAL_SECONDS}"
        - name: HEALTH_PORT
          value: "8080"
        - name: LOG_LEVEL
          value: "info"
        - name: NODE_TLS_REJECT_UNAUTHORIZED
          value: "0"
        volumeMounts:
        - name: app
          mountPath: /app
          readOnly: true
        resources:
          requests:
            memory: "${CALENDAR_AUTOMATION_MEMORY_REQUEST}"
            cpu: "${CALENDAR_AUTOMATION_CPU_REQUEST}"
          limits:
            memory: "${CALENDAR_AUTOMATION_MEMORY_LIMIT}"
            cpu: "${CALENDAR_AUTOMATION_CPU_LIMIT}"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 20
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 10
      volumes:
      - name: app
        configMap:
          name: calendar-automation-app

---
apiVersion: v1
kind: Service
metadata:
  name: calendar-automation
  namespace: ${NS_MAIL}
  labels:
    app: calendar-automation
    tenant: ${TENANT_NAME}
spec:
  selector:
    app: calendar-automation
  ports:
  - name: health
    port: 8080
    targetPort: 8080
  type: ClusterIP
