apiVersion: v1
kind: ConfigMap
metadata:
  name: docs-config
  namespace: docs
  labels:
    app.kubernetes.io/name: docs
    app.kubernetes.io/part-of: mother-tree
data:
  # Django settings
  DJANGO_ALLOWED_HOSTS: "${DOCS_HOST},*.${BASE_DOMAIN},backend"
  DJANGO_SETTINGS_MODULE: "impress.settings"
  DJANGO_CONFIGURATION: "Production"
  DJANGO_DEBUG: "False"
  
  # Database settings (cross-namespace: PgBouncer in infra-db routes to external PG VM)
  # Database name and user are tenant-specific to avoid conflicts
  DB_HOST: "${PG_HOST}"
  DB_PORT: "5432"
  DB_NAME: "${DOCS_DB_NAME}"
  DB_USER: "${TENANT_DB_USER}"
  # Keep DB connections alive for 10 minutes to reduce connection churn
  # during rolling deploys (Django default is 0 = close after each request)
  CONN_MAX_AGE: "600"
  
  # Redis settings
  REDIS_HOST: "redis"
  REDIS_PORT: "6379"
  
  # S3 Storage settings (S3_CLUSTER from tenant config)
  AWS_S3_ENDPOINT_URL: "https://${S3_CLUSTER}.linodeobjects.com"
  AWS_S3_REGION_NAME: "${S3_CLUSTER}"
  AWS_STORAGE_BUCKET_NAME: "${BUCKET_NAME}"
  AWS_S3_SIGNATURE_VERSION: "s3v4"
  AWS_S3_ADDRESSING_STYLE: "virtual"
  AWS_S3_USE_SSL: "True"
  AWS_ENDPOINT_URL_S3: "https://${S3_CLUSTER}.linodeobjects.com"
  # AWS_S3_CUSTOM_DOMAIN intentionally unset when using bucket endpoint
  AWS_S3_URL_PROTOCOL: "https:"
  MEDIA_BASE_URL: "https://${DOCS_HOST}"
  
  # Linode Object Storage compatibility settings
  # Override STORAGES backend using the specific environment variable name Impress expects
  STORAGES_DEFAULT_BACKEND: "storage_backends.LinodeS3Boto3Storage"
  AWS_S3_DEFAULT_ACL: "private"
  AWS_S3_VERIFY: "False"
  AWS_S3_FILE_OVERWRITE: "False"
  
  # CORS settings
  CORS_ALLOWED_ORIGINS: "https://${DOCS_HOST}"
  
  # SSL settings
  SECURE_SSL_REDIRECT: "True"
  SECURE_PROXY_SSL_HEADER: "HTTP_X_FORWARDED_PROTO,https"
  
  # Session/Cookie settings for OIDC across subdomains
  SESSION_COOKIE_SECURE: "True"
  SESSION_COOKIE_SAMESITE: "None"
  SESSION_COOKIE_DOMAIN: "${COOKIE_DOMAIN}"
  # Session duration - 30 days to match offline token and Remember Me lifespan
  # Offline tokens (30-day lifetime) keep OIDC refresh working beyond SSO session expiry
  SESSION_COOKIE_AGE: "2592000"
  CSRF_COOKIE_SECURE: "True"
  CSRF_TRUSTED_ORIGINS: "https://${DOCS_HOST},https://${AUTH_HOST}"
  
  # Email backend - SMTP via Postfix submission port (587)
  # Uses postfix-internal service which allows relay to external domains
  EMAIL_BACKEND: "django.core.mail.backends.smtp.EmailBackend"
  EMAIL_HOST: "postfix-internal.infra-mail.svc.cluster.local"
  EMAIL_PORT: "587"
  EMAIL_USE_TLS: "False"
  EMAIL_USE_SSL: "False"
  DEFAULT_FROM_EMAIL: "MotherTree Docs <noreply@${SMTP_DOMAIN}>"

  # Impress/LaSuite Docs specific email settings
  DJANGO_EMAIL_HOST: "postfix-internal.infra-mail.svc.cluster.local"
  DJANGO_EMAIL_PORT: "587"
  DJANGO_EMAIL_USE_TLS: "False"
  DJANGO_EMAIL_FROM: "MotherTree Docs <noreply@${SMTP_DOMAIN}>"
  DJANGO_EMAIL_BRAND_NAME: "Mother Tree Docs"
  
  # Logging
  LOG_LEVEL: "INFO"
  
  # Admin user
  DJANGO_SUPERUSER_EMAIL: "admin@${BASE_DOMAIN}"
  DJANGO_SUPERUSER_PASSWORD: "${DJANGO_SUPERUSER_PASSWORD}"
  
  # OIDC settings for Keycloak (realm name is tenant-specific)
  # Browser-facing endpoints use external AUTH_HOST (user's browser redirects here)
  OIDC_OP_AUTHORIZATION_ENDPOINT: "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/auth"
  OIDC_OP_LOGOUT_ENDPOINT: "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/logout"
  # Server-side endpoints use internal Keycloak URL to avoid PROXY protocol issue
  # (in-cluster traffic to external URL bypasses NodeBalancer → ECONNRESET)
  OIDC_OP_TOKEN_ENDPOINT: "${KEYCLOAK_INTERNAL_URL}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/token"
  OIDC_OP_USER_ENDPOINT: "${KEYCLOAK_INTERNAL_URL}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/userinfo"
  OIDC_OP_JWKS_ENDPOINT: "${KEYCLOAK_INTERNAL_URL}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/certs"
  OIDC_RP_CLIENT_ID: "docs-app"
  OIDC_RP_SIGN_ALGO: "RS256"
  OIDC_RP_SCOPES: "openid email profile"
  OIDC_RP_REDIRECT_URI: "https://${DOCS_HOST}/api/v1.0/callback/"
  LOGIN_REDIRECT_URL: "https://${DOCS_HOST}"
  LOGOUT_REDIRECT_URL: "https://${DOCS_HOST}"

  # Admin portal URL (for guest invitation email links)
  ADMIN_PORTAL_URL: "https://${ADMIN_HOST}"

  # Collaboration/Y-Provider settings
  COLLABORATION_WS_URL: "wss://${DOCS_HOST}/collaboration/ws/"  # Frontend customization
  # Custom JavaScript for save status indicator (served from ConfigMap mount)
  FRONTEND_JS_URL: "https://${DOCS_HOST}/static/save-status.js"
  # Skip the "Start Writing" splash page — go straight to Keycloak login
  FRONTEND_HOMEPAGE_FEATURE_ENABLED: "false"
