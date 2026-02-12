# Stalwart Mail Server - StatefulSet, Service, ConfigMap, and Secrets
# Deployed per-tenant to namespace tn-<tenant>-mail
#
# Multi-tenant mail architecture:
# - Port 25 (SMTP inbound): Comes from shared Postfix via cluster-internal Service
# - Ports 465/587/993: Use hostPort for direct external access (unique per tenant)
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   MAIL_HOST - Mail server hostname (e.g., mail.example.com)
#   TENANT_NAME - Tenant name (e.g., example)
#   TENANT_DOMAIN - Tenant domain (e.g., example.com)
#   AUTH_HOST - Keycloak auth hostname (e.g., auth.example.com)
#   KEYCLOAK_REALM - Keycloak realm (e.g., docs)
#   S3_MAIL_BUCKET - S3 bucket name for mail blobs
#   S3_CLUSTER - S3 cluster (e.g., us-lax-1)
#   STALWART_DB_NAME - PostgreSQL database name
#   STALWART_DB_USER - PostgreSQL username
#   STALWART_SMTPS_PORT - Unique hostPort for SMTPS (465 equivalent)
#   STALWART_SUBMISSION_PORT - Unique hostPort for submission (587 equivalent)
#   STALWART_IMAPS_PORT - Unique hostPort for IMAPS (993 equivalent)
#   STALWART_* - Various secrets from tenant secrets file

---
apiVersion: v1
kind: Secret
metadata:
  name: stalwart-secrets
  namespace: ${NS_MAIL}
type: Opaque
stringData:
  STALWART_ADMIN_PASSWORD: "${STALWART_ADMIN_PASSWORD}"
  STALWART_DB_PASSWORD: "${STALWART_DB_PASSWORD}"
  STALWART_OIDC_SECRET: "${STALWART_OIDC_SECRET}"
  S3_ACCESS_KEY: "${S3_MAIL_ACCESS_KEY}"
  S3_SECRET_KEY: "${S3_MAIL_SECRET_KEY}"

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: stalwart-config
  namespace: ${NS_MAIL}
data:
  # Main Stalwart configuration
  config.toml: |
    [server]
    hostname = "${MAIL_HOST}"

    # Whitelist private IPs to prevent fail2ban from blocking cluster-internal traffic.
    # All connections to Stalwart are from internal pods (Roundcube, Postfix, nginx proxy),
    # so IP-based blocking only harms cluster services — real client IPs are never visible.
    [server.allowed-ip]
    "10.0.0.0/8" = ""
    "172.16.0.0/12" = ""
    "192.168.0.0/16" = ""

    # HTTP listener for JMAP/WebAdmin (TLS terminated by ingress)
    [server.listener.https]
    bind = ["[::]:443"]
    protocol = "http"
    tls.implicit = false
    
    # HTTP listener for health checks (no TLS)
    [server.listener.health]
    bind = ["[::]:8080"]
    protocol = "http"
    
    # SMTP listener for inbound mail
    [server.listener.smtp]
    bind = ["[::]:25"]
    protocol = "smtp"
    
    # SMTP submission with STARTTLS
    [server.listener.submission]
    bind = ["[::]:587"]
    protocol = "smtp"
    tls.implicit = false
    
    # SMTP submission with implicit TLS
    [server.listener.submissions]
    bind = ["[::]:465"]
    protocol = "smtp"
    tls.implicit = true
    
    # IMAP with implicit TLS (OAUTHBEARER via OIDC directory - used by Roundcube)
    [server.listener.imaps]
    bind = ["[::]:993"]
    protocol = "imap"
    tls.implicit = true

    # IMAP with implicit TLS (PLAIN/LOGIN via internal directory - used by iOS Mail, Thunderbird)
    # App passwords are stored as hashed secrets on user principals in PostgreSQL
    [server.listener.imaps-app]
    bind = ["[::]:994"]
    protocol = "imap"
    tls.implicit = true
    session.auth.directory = "'internal'"

    # SMTP submission with STARTTLS (PLAIN/LOGIN via internal directory - for email clients)
    [server.listener.submission-app]
    bind = ["[::]:588"]
    protocol = "smtp"
    tls.implicit = false
    session.auth.directory = "'internal'"

    # ManageSieve for mail filtering rules (cluster-internal, used by Roundcube)
    # Uses default OIDC directory for OAUTHBEARER auth (same as IMAP on port 993)
    [server.listener.sieve]
    bind = ["[::]:4190"]
    protocol = "managesieve"
    tls.implicit = true

    # Storage configuration
    [storage]
    data = "postgresql"
    blob = "s3"
    fts = "postgresql"
    lookup = "postgresql"
    # OIDC directory for auth (validates OAUTHBEARER tokens via Keycloak userinfo endpoint)
    # App passwords for PLAIN/LOGIN are handled via a separate IMAP listener using the internal directory
    directory = "oidc"
    
    # PostgreSQL data store
    [store."postgresql"]
    type = "postgresql"
    host = "${PG_HOST}"
    port = 5432
    database = "${STALWART_DB_NAME}"
    user = "${STALWART_DB_USER}"
    password = "%{env:STALWART_DB_PASSWORD}%"
    
    [store."postgresql".timeout]
    connect = "15s"
    
    [store."postgresql".tls]
    enable = false
    
    [store."postgresql".pool]
    max-connections = 10
    
    # S3 blob store for email content
    [store."s3"]
    type = "s3"
    bucket = "${S3_MAIL_BUCKET}"
    region = "${S3_CLUSTER}"
    endpoint = "https://${S3_CLUSTER}.linodeobjects.com"
    access-key = "%{env:S3_ACCESS_KEY}%"
    secret-key = "%{env:S3_SECRET_KEY}%"
    timeout = "30s"
    
    # Local domains - CRITICAL for preventing mail loops
    # Stalwart must know which domains are local to avoid relaying back to Postfix
    # EMAIL_DOMAIN is dev.example.com for dev, example.com for prod
    [session.rcpt]
    # Allow relay only for authenticated users (submission port)
    # Unauthenticated connections (port 25 inbound) cannot relay to external addresses
    relay = [{if = "!is_empty(authenticated_as)", then = true}, {else = false}]
    # Recipient validation: only validate local domain recipients against internal directory
    # External domains (gmail.com, etc.) skip validation and use relay if authenticated
    # This prevents "mailbox does not exist" errors when sending to external addresses
    # while preserving backscatter prevention for inbound mail to local domains
    directory = [{if = "is_local_domain('', rcpt_domain)", then = "'internal'"}, {else = false}]
    
    [session.rcpt.domain]
    "${EMAIL_DOMAIN}" = true
    
    # Internal directory for user accounts
    [directory."internal"]
    type = "internal"
    store = "postgresql"
    
    # OIDC directory for OAUTHBEARER token validation
    [directory."oidc"]
    type = "oidc"
    timeout = "5s"
    endpoint.url = "https://${AUTH_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/userinfo"
    endpoint.method = "userinfo"
    fields.email = "email"
    fields.username = "preferred_username"
    fields.full-name = "name"
    
    # Message routing strategy (v0.15+ format)
    # - Local domain recipients: deliver to local mailbox
    # - External recipients: relay through Postfix for DKIM signing
    [queue.strategy]
    route = [{if = "is_local_domain('', rcpt_domain)", then = "'local'"}, {else = "'relay'"}]
    
    # Local delivery route - deliver to internal mailbox
    [queue.route."local"]
    type = "local"
    
    # Relay route - send through Postfix for DKIM signing
    [queue.route."relay"]
    type = "relay"
    address = "postfix-internal.infra-mail.svc.cluster.local"
    port = 587
    protocol = "smtp"
    
    [queue.route."relay".tls]
    implicit = false
    allow-invalid-certs = true
    
    # Authentication
    [authentication]
    fallback-admin.user = "admin"
    fallback-admin.secret = "%{env:STALWART_ADMIN_PASSWORD}%"
    
    # OIDC authentication via Keycloak
    [oauth]
    oidc.enable = true
    oidc.issuer-url = "https://${AUTH_HOST}/realms/${KEYCLOAK_REALM}"
    oidc.client-id = "stalwart"
    oidc.client-secret = "%{env:STALWART_OIDC_SECRET}%"
    
    # TLS configuration - use cert-manager certificates
    [certificate.default]
    cert = "%{file:/opt/stalwart/tls/tls.crt}%"
    private-key = "%{file:/opt/stalwart/tls/tls.key}%"
    
    # Spam filtering
    [spam]
    enabled = true
    
    # Override spam scores for rules that are irrelevant for internal relay traffic
    # Stalwart always receives mail from K8s Postfix on internal IPs, so these checks
    # would always flag legitimate mail incorrectly. Setting score to 0.0 neutralizes them.
    # See: https://stalw.art/docs/spamfilter/settings/scores/
    [spam-filter.list]
    scores = { "FORGED_RCVD_TRAIL" = "0.0", "HELO_IPREV_MISMATCH" = "0.0", "HELO_NORES_A_OR_MX" = "0.0" }
    
    # Authentication verification for inbound mail
    # NOTE: Stalwart only receives mail from internal K8s Postfix relay or authenticated users
    # IPREV and SPF checks are disabled because:
    # 1. Internal relay IPs don't have proper reverse DNS or SPF records
    # 2. Authenticated users (submission ports) don't need client IP validation
    # 3. All spam filtering happens at VPN Postfix → K8s Postfix before reaching Stalwart
    # See: https://stalw.art/docs/mta/authentication/iprev
    # See: https://stalw.art/docs/smtp/authentication/spf/
    
    [auth.iprev]
    verify = "disable"
    
    [auth.spf.verify]
    ehlo = "disable"
    mail-from = "disable"
    
    [auth.dkim]
    verify = true
    
    [auth.dmarc]
    verify = true
    
    # Logging
    [tracing]
    level = "info"
    method = "stdout"
    
    # Force local configuration for session.rcpt and queue routing (not database)
    # Without this, these settings are stored in DB and local config is ignored
    # See: https://stalw.art/docs/configuration/overview/#local-and-database-settings
    [config]
    local-keys = ["store.*", "directory.*", "tracer.*", "!server.blocked-ip.*",
                  "server.*", "authentication.fallback-admin.*",
                  "cluster.*", "config.local-keys.*", "storage.data", "storage.blob",
                  "storage.lookup", "storage.fts", "storage.directory", "certificate.*",
                  "session.rcpt.*", "queue.strategy.*", "queue.route.*", "oauth.*"]

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stalwart
  namespace: ${NS_MAIL}
  labels:
    app: stalwart
    tenant: ${TENANT_NAME}
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
        checksum/config: "${CONFIG_CHECKSUM}"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: stalwart
        image: stalwartlabs/stalwart:v0.15.3
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        ports:
        # SMTP inbound (port 25) - receives mail from shared Postfix via ClusterIP
        - containerPort: 25
          name: smtp
        # User-facing ports - external access via nginx tcp-services proxy
        # (nginx proxies from unique external ports to these standard internal ports)
        - containerPort: 465
          name: smtps
        - containerPort: 587
          name: submission
        - containerPort: 993
          name: imaps
        # App password listeners (PLAIN/LOGIN via internal directory)
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
        - name: STALWART_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_DB_PASSWORD
        - name: STALWART_OIDC_SECRET
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_OIDC_SECRET
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
        volumeMounts:
        - name: config
          mountPath: /opt/stalwart/etc
        - name: data
          mountPath: /opt/stalwart/data
        - name: tls
          mountPath: /opt/stalwart/tls
          readOnly: true
        resources:
          requests:
            memory: "${STALWART_MEMORY_REQUEST}"
            cpu: "${STALWART_CPU_REQUEST}"
          limits:
            memory: "${STALWART_MEMORY_LIMIT}"
            cpu: "${STALWART_CPU_LIMIT}"
        livenessProbe:
          httpGet:
            path: /healthz/live
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /healthz/ready
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 10
      volumes:
      - name: config
        configMap:
          name: stalwart-config
      - name: tls
        secret:
          secretName: stalwart-tls
      - name: data
        emptyDir: {}

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
