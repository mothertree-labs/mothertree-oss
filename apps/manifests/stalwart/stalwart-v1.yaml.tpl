# Stalwart Mail Server v1 (#715)
#
# v1 has no TOML. config.json below names only the data store (the tenant's
# stalwart_<tenant>_v1 database, never the 0.15 one); every other setting is a
# JMAP object applied by deploy-stalwart.sh from scripts/lib/stalwart-v1-plan.sh
# through the stalwart-mgmt Service.
#
# The recovery admin (STALWART_RECOVERY_ADMIN=admin:<STALWART_ADMIN_PASSWORD>)
# is the management login for the portals and scripts, and the impersonation
# identity for calendar-automation (<email>%admin).
#
# Required environment variables:
#   NS_MAIL TENANT_NAME PG_HOST STALWART_V1_DB_NAME STALWART_DB_USER
#   STALWART_MIN_REPLICAS STALWART_MEMORY_REQUEST STALWART_CPU_REQUEST
#   STALWART_MEMORY_LIMIT STALWART_PLAN_CHECKSUM
#   AUTH_HOST INTERNAL_INGRESS_IP
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: stalwart-v1-config
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
data:
  config.json: |
    {"@type":"PostgreSql","host":"${PG_HOST}","port":5432,"database":"${STALWART_V1_DB_NAME}","authUsername":"${STALWART_DB_USER}","authSecret":{"@type":"EnvironmentVariable","variableName":"STALWART_DB_PASSWORD"},"useTls":false,"poolMaxConnections":10}

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stalwart
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
    tenant: ${TENANT_NAME}
    stalwart.mothertree/generation: "v1"
spec:
  replicas: ${STALWART_MIN_REPLICAS}
  selector:
    matchLabels:
      app: stalwart
  template:
    metadata:
      labels:
        app: stalwart
        tenant: ${TENANT_NAME}
      annotations:
        # Listener, store and coordinator changes only take effect on restart,
        # so any change to the applied plan rolls the pods.
        checksum/plan: "${STALWART_PLAN_CHECKSUM}"
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      # OIDC discovery goes to the PUBLIC issuer (it must match the token iss).
      # From inside the cluster the public ingress speaks PROXY protocol and
      # resets the connection, so resolve the auth host to the internal
      # ingress instead (same pattern as Nextcloud).
      hostAliases:
      - ip: "${INTERNAL_INGRESS_IP}"
        hostnames:
        - "${AUTH_HOST}"
      containers:
      - name: stalwart
        image: stalwartlabs/stalwart:v1.2.0
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        ports:
        - containerPort: 25
          name: smtp
        - containerPort: 465
          name: smtps
        - containerPort: 587
          name: submission
        - containerPort: 993
          name: imaps
        - containerPort: 994
          name: imaps-app
        - containerPort: 588
          name: submission-app
        - containerPort: 4190
          name: sieve
        - containerPort: 443
          name: https
        - containerPort: 8080
          name: health
        env:
        - name: STALWART_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_ADMIN_PASSWORD
        - name: STALWART_RECOVERY_ADMIN
          value: "admin:$(STALWART_ADMIN_PASSWORD)"
        - name: STALWART_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_DB_PASSWORD
        - name: S3_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: S3_ACCESS_KEY
        - name: S3_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: S3_SECRET_KEY
        # Only the SES route references it; absent elsewhere (optional).
        - name: SES_SMTP_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ses-credentials
              key: password
              optional: true
        volumeMounts:
        - name: config
          mountPath: /etc/stalwart
          readOnly: true
        - name: data
          mountPath: /var/lib/stalwart
        - name: tmp
          mountPath: /tmp
        - name: tls
          mountPath: /certs
          readOnly: true
        resources:
          requests:
            memory: "${STALWART_MEMORY_REQUEST}"
            cpu: "${STALWART_CPU_REQUEST}"
          limits:
            memory: "${STALWART_MEMORY_LIMIT}"
        startupProbe:
          httpGet:
            path: /healthz/live
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 30
        livenessProbe:
          httpGet:
            path: /healthz/live
            port: 8080
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
        # /healthz/ready only says the config loaded. Gate on the submission
        # listener the Keycloak realm SMTP and mailer@ use (588), as 0.15 did.
        # On a brand-new store 588 exists only after the plan is applied, so
        # the plan goes in through stalwart-mgmt (publishNotReadyAddresses).
        readinessProbe:
          tcpSocket:
            port: 588
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 3
      volumes:
      - name: config
        configMap:
          name: stalwart-v1-config
      - name: tls
        secret:
          secretName: wildcard-tls-${TENANT_NAME}
      - name: data
        emptyDir:
          sizeLimit: 1Gi
      - name: tmp
        emptyDir:
          sizeLimit: 256Mi

---
# Management endpoint for the plan Job and deploy gates. Unlike `stalwart`, it
# also routes to pods that are not Ready, so a fresh store (no listeners yet)
# can be configured. Cluster-internal only; the mail namespace's ingress
# allow-list admits 8080 only from the admin namespace and calendar-automation.
apiVersion: v1
kind: Service
metadata:
  name: stalwart-mgmt
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
spec:
  selector:
    app: stalwart
  publishNotReadyAddresses: true
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  type: ClusterIP

---
apiVersion: v1
kind: Service
metadata:
  name: stalwart
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
spec:
  selector:
    app: stalwart
  ports:
  - name: smtp
    port: 25
    targetPort: 25
  - name: smtps
    port: 465
    targetPort: 465
  - name: submission
    port: 587
    targetPort: 587
  - name: imaps
    port: 993
    targetPort: 993
  - name: imaps-app
    port: 994
    targetPort: 994
  - name: submission-app
    port: 588
    targetPort: 588
  - name: sieve
    port: 4190
    targetPort: 4190
  - name: https
    port: 443
    targetPort: 443
  - name: api
    port: 8080
    targetPort: 8080
  type: ClusterIP
