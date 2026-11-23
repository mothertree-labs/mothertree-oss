# Matrix Authentication Service (MAS) configuration — rendered by
# apps/deploy-mas.sh with an explicit envsubst variable list (so the Jinja
# `{{ }}` claim templates below are left alone) and stored in the `mas-config`
# Secret together with the secret files it references (/config/*).
#
# Reference: https://element-hq.github.io/matrix-authentication-service/reference/configuration.html
# Issue: #824 (Element X needs native OAuth 2.0 / QR login).

http:
  public_base: "https://${MAS_HOST}/"
  # MAS's only peer is the ingress-nginx pod (pod network); client IPs
  # arrive in X-Forwarded-For. Tailnet/CGNAT ranges are deliberately absent.
  trusted_proxies:
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16
    - 127.0.0.0/8
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
      binds:
        - address: "[::]:8080"
    # Cluster-internal only (not routed by the Ingress): health probes.
    - name: internal
      resources:
        - name: health
      binds:
        - address: "[::]:8081"

# Shared PostgreSQL VM through PgBouncer (session pooling — MAS uses advisory
# locks, which transaction pooling would break). Kept small: the PgBouncer
# connection budget is per database (pool × pods × DBs ≤ max_connections).
database:
  host: "${PG_HOST}"
  port: 5432
  username: "${MAS_DB_USER}"
  password: "${MAS_DB_PASSWORD}"
  database: "${MAS_DB_NAME}"
  ssl_mode: disable
  min_connections: 0
  max_connections: 5

matrix:
  # Synapse delegates auth to MAS (matrix_authentication_service in the
  # Synapse values); MAS provisions users and devices on Synapse.
  kind: synapse
  homeserver: "${MATRIX_HOST}"
  endpoint: "http://matrix-synapse.${NS_MATRIX}.svc.cluster.local:8008"
  secret_file: /config/synapse-shared-secret

secrets:
  # Never change after first start: it encrypts cookies and database fields.
  encryption_file: /config/encryption-key
  keys:
    - kid: rsa-1
      key_file: /config/signing-key-rsa
    - kid: ec-1
      key_file: /config/signing-key-ec

# Keycloak is the only way in: no local passwords, no self-registration.
passwords:
  enabled: false
  # Unused while passwords are disabled, but `mas-cli syn2mas` refuses to run
  # unless scheme version 1 is bcrypt (the Synapse hash format; Synapse has no
  # password pepper here). MAS's own default would be argon2id.
  schemes:
    - version: 1
      algorithm: bcrypt
      unicode_normalization: true

account:
  # Email and account lifecycle are owned by Keycloak and the admin portal.
  email_change_allowed: false
  account_deactivation_allowed: false
  password_registration_enabled: false

upstream_oauth2:
  providers:
    - id: "${MAS_UPSTREAM_PROVIDER_ID}"
      # Must equal Synapse's auth_provider in user_external_ids
      # ("oidc-" + idp_id) so `mas-cli syn2mas` carries existing links over.
      synapse_idp_id: oidc-keycloak
      human_name: "Sign in with MotherTree"
      # Same split as Synapse's oidc_providers: the browser goes to the public
      # auth host; server-to-server calls use the in-cluster Keycloak Service
      # (the public ingress speaks PROXY protocol, which breaks in-cluster calls).
      issuer: "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}"
      discovery_mode: disabled
      pkce_method: always
      authorization_endpoint: "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/auth"
      token_endpoint: "${KEYCLOAK_INTERNAL_URL}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/token"
      userinfo_endpoint: "${KEYCLOAK_INTERNAL_URL}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/userinfo"
      jwks_uri: "${KEYCLOAK_INTERNAL_URL}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/certs"
      fetch_userinfo: true
      client_id: matrix-mas
      client_secret_file: /config/keycloak-client-secret
      token_endpoint_auth_method: client_secret_post
      scope: "openid email profile"
      claims_imports:
        subject:
          template: "{{ user.sub }}"
        # First Keycloak login creates the Matrix account on the fly
        # (require + skip_confirmation); there is no pre-provisioning.
        skip_confirmation: true
        localpart:
          action: require
          # Reproduces Synapse's map_username_to_mxid_localpart() for the
          # characters that occur in email addresses, so new users keep the
          # `name=40domain` shape existing users already have. Any other
          # character outside [a-z0-9._/-] makes MAS reject the localpart and
          # the login fails loudly rather than minting a different ID.
          template: "{{ user.email | lower | replace('=', '=3d') | replace('@', '=40') | replace('+', '=2b') }}"
          # Never link a Keycloak identity to an existing account by a
          # matching email-derived localpart: existing users are linked by
          # `sub` (migrated from Synapse), anything else must fail.
          on_conflict: fail
        displayname:
          action: force
          template: "{{ user.name }}"
        email:
          action: force
          template: "{{ user.email }}"
