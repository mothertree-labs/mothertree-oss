# Roundcube Webmail - Deployment, Service, ConfigMap, and Secrets
# Deployed per-tenant to namespace tn-<tenant>-webmail
#
# Required environment variables:
#   NS_WEBMAIL - Tenant webmail namespace (e.g., tn-example-webmail)
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   WEBMAIL_HOST - Webmail hostname (e.g., webmail.dev.example.com)
#   MAIL_HOST - Stalwart mail server hostname (e.g., mail.dev.example.com)
#   FILES_HOST - Nextcloud files hostname for CalDAV (e.g., files.dev.example.com)
#   TENANT_NAME - Tenant name (e.g., example)
#   TENANT_DOMAIN - Tenant domain (e.g., example.com)
#   AUTH_HOST - Keycloak auth hostname (e.g., auth.dev.example.com)
#   KEYCLOAK_REALM - Keycloak realm (e.g., docs)
#   ROUNDCUBE_OIDC_SECRET - OIDC client secret for Roundcube
#   ROUNDCUBE_DES_KEY - DES key for session encryption (24 chars)
#   ROUNDCUBE_DB_NAME - PostgreSQL database name
#   ROUNDCUBE_DB_USER - PostgreSQL username
#   ROUNDCUBE_DB_PASSWORD - PostgreSQL password
#   ROUNDCUBE_MEMORY_REQUEST, ROUNDCUBE_MEMORY_LIMIT, ROUNDCUBE_CPU_REQUEST, ROUNDCUBE_CPU_LIMIT

---
apiVersion: v1
kind: Secret
metadata:
  name: roundcube-secrets
  namespace: ${NS_WEBMAIL}
type: Opaque
stringData:
  ROUNDCUBE_OIDC_SECRET: "${ROUNDCUBE_OIDC_SECRET}"
  ROUNDCUBE_DB_PASSWORD: "${ROUNDCUBE_DB_PASSWORD}"
  ROUNDCUBEMAIL_DEFAULT_HOST: "ssl://stalwart.${NS_MAIL}.svc.cluster.local"
  ROUNDCUBEMAIL_SMTP_SERVER: "tls://stalwart.${NS_MAIL}.svc.cluster.local"

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: roundcube-config
  namespace: ${NS_WEBMAIL}
data:
  # Custom Roundcube config
  # Note: deploy-roundcube.sh uses explicit variable list with envsubst to preserve $config
  custom.config.php: |
    <?php
    // OAuth/OIDC Configuration for Keycloak
    $config['oauth_provider'] = 'custom';
    $config['oauth_provider_name'] = 'Keycloak';
    $config['oauth_client_id'] = 'roundcube';
    $config['oauth_client_secret'] = getenv('ROUNDCUBE_OIDC_SECRET');
    $config['oauth_auth_uri'] = 'https://${AUTH_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth';
    $config['oauth_token_uri'] = 'https://${AUTH_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token';
    $config['oauth_identity_uri'] = 'https://${AUTH_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/userinfo';
    $config['oauth_identity_fields'] = ['email'];
    $config['oauth_scope'] = 'openid email profile';
    
    // Use XOAUTH2 for IMAP/SMTP authentication
    $config['imap_auth_type'] = 'XOAUTH2';
    $config['smtp_auth_type'] = 'XOAUTH2';
    
    // IMAP/SMTP server configuration
    $config['imap_host'] = 'ssl://stalwart.${NS_MAIL}.svc.cluster.local:993';
    $config['smtp_host'] = 'tls://stalwart.${NS_MAIL}.svc.cluster.local:587';
    $config['smtp_port'] = 587;
    
    // SSL options for internal cluster connections (cert is for public hostname)
    $config['imap_conn_options'] = [
        'ssl' => [
            'verify_peer' => false,
            'verify_peer_name' => false,
        ],
    ];
    $config['smtp_conn_options'] = [
        'ssl' => [
            'verify_peer' => false,
            'verify_peer_name' => false,
        ],
    ];
    
    // Login page configuration - hide username/password, show OAuth button
    $config['oauth_login_redirect'] = true;
    
    // Session and encryption
    $config['des_key'] = '${ROUNDCUBE_DES_KEY}';
    $config['session_lifetime'] = 60;       // 60 minutes
    $config['cookie_secure'] = true;        // Only send cookies over HTTPS
    $config['cookie_samesite'] = 'Lax';     // Allow cookies on OAuth redirects from Keycloak

    // UI Configuration
    $config['product_name'] = '${TENANT_DISPLAY_NAME} Webmail';
    $config['support_url'] = '';
    $config['skin'] = 'elastic';
    $config['language'] = 'en_US';
    $config['date_format'] = 'Y-m-d';
    $config['time_format'] = 'H:i';
    
    // Security
    $config['ip_check'] = false;
    $config['referer_check'] = false;
    $config['x_frame_options'] = 'sameorigin';
    $config['use_https'] = true;  // Generate HTTPS URLs (don't redirect - ingress handles TLS)
    
    // Default folders
    $config['drafts_mbox'] = 'Drafts';
    $config['junk_mbox'] = 'Junk';
    $config['sent_mbox'] = 'Sent';
    $config['trash_mbox'] = 'Trash';
    
    // Enable plugins
    $config['plugins'] = [
        'archive',
        'zipdownload',
        'managesieve',
        'calendar',
        'libcalendaring',
        'libkolab',
        'mailvelope_client'
    ];
    
    // ManageSieve configuration (server-side mail filter rules via Stalwart)
    // Auth inherits imap_auth_type (XOAUTH2) - no explicit auth_type needed
    $config['managesieve_host'] = 'ssl://stalwart.${NS_MAIL}.svc.cluster.local';
    $config['managesieve_port'] = 4190;
    $config['managesieve_conn_options'] = [
        'ssl' => [
            'verify_peer' => false,
            'verify_peer_name' => false,
        ],
    ];

    // Calendar configuration (CalDAV to Nextcloud)
    // Uses OAuth bearer token authentication (patched in custom image)
    // Requires Keycloak audience mapper to include 'nextcloud-app' in Roundcube tokens
    $config['calendar_driver'] = 'caldav';
    $config['calendar_caldav_server'] = 'https://${FILES_HOST}/remote.php/dav/';
    $config['calendar_default_view'] = 'agendaWeek';
    $config['calendar_first_day'] = 1;  // Monday
    $config['calendar_crypt_key'] = '${ROUNDCUBE_DES_KEY}';
    
    // Mailvelope client plugin (no config needed - auto-detects browser extension)
    
    // Logging
    $config['log_driver'] = 'stdout';
    $config['log_logins'] = true;
    $config['log_session'] = false;
    
    // PostgreSQL database for contacts, preferences, and session storage
    $config['db_dsnw'] = 'pgsql://${ROUNDCUBE_DB_USER}:' . getenv('ROUNDCUBE_DB_PASSWORD') . '@${PG_HOST}/${ROUNDCUBE_DB_NAME}';
    
    // Use database for session storage (required for multi-replica deployments)
    $config['session_storage'] = 'db';
    ?>

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: roundcube
  namespace: ${NS_WEBMAIL}
  labels:
    app: roundcube
    tenant: ${TENANT_NAME}
spec:
  replicas: ${ROUNDCUBE_MIN_REPLICAS}
  selector:
    matchLabels:
      app: roundcube
  template:
    metadata:
      labels:
        app: roundcube
        tenant: ${TENANT_NAME}
      annotations:
        checksum/config: "${CONFIG_CHECKSUM}"
    spec:
      securityContext:
        runAsNonRoot: false  # Roundcube image requires root for Apache setup
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: roundcube
        # TODO: Pin to a specific version tag or sha256 digest
        image: ${CONTAINER_REGISTRY}/mothertree-roundcube:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add: ["SETUID", "SETGID"]
            drop: ["ALL"]
        ports:
        - containerPort: 80
          name: http
        env:
        - name: ROUNDCUBE_OIDC_SECRET
          valueFrom:
            secretKeyRef:
              name: roundcube-secrets
              key: ROUNDCUBE_OIDC_SECRET
        - name: ROUNDCUBE_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: roundcube-secrets
              key: ROUNDCUBE_DB_PASSWORD
        - name: ROUNDCUBEMAIL_DEFAULT_HOST
          valueFrom:
            secretKeyRef:
              name: roundcube-secrets
              key: ROUNDCUBEMAIL_DEFAULT_HOST
        - name: ROUNDCUBEMAIL_SMTP_SERVER
          valueFrom:
            secretKeyRef:
              name: roundcube-secrets
              key: ROUNDCUBEMAIL_SMTP_SERVER
        - name: ROUNDCUBEMAIL_SKIN
          value: "elastic"
        - name: ROUNDCUBEMAIL_UPLOAD_MAX_FILESIZE
          value: "25M"
        volumeMounts:
        - name: config
          mountPath: /var/roundcube/config/custom.config.php
          subPath: custom.config.php
        resources:
          requests:
            memory: "${ROUNDCUBE_MEMORY_REQUEST}"
            cpu: "${ROUNDCUBE_CPU_REQUEST}"
          limits:
            memory: "${ROUNDCUBE_MEMORY_LIMIT}"
            cpu: "${ROUNDCUBE_CPU_LIMIT}"
        livenessProbe:
          httpGet:
            path: /skins/elastic/images/logo.svg
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /skins/elastic/images/logo.svg
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
      volumes:
      - name: config
        configMap:
          name: roundcube-config

---
apiVersion: v1
kind: Service
metadata:
  name: roundcube
  namespace: ${NS_WEBMAIL}
  labels:
    app: roundcube
spec:
  selector:
    app: roundcube
  ports:
  - name: http
    port: 80
    targetPort: 80
  type: ClusterIP
  # Backup session affinity at Service level (primary affinity is cookie-based at Ingress)
  # Cookie affinity on the Ingress is what actually pins browser sessions to a pod;
  # ClientIP here is a fallback for any non-Ingress traffic
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600  # 1 hour - keep session sticky for compose duration