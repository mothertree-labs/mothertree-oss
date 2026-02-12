{
  "realm": "${TENANT_KEYCLOAK_REALM}",
  "enabled": true,
  "displayName": "${TENANT_DISPLAY_NAME}",
  "sslRequired": "external",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": true,
  "editUsernameAllowed": false,
  "bruteForceProtected": true,
  "rememberMe": true,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000,
  "offlineSessionIdleTimeout": 2592000,
  "offlineSessionMaxLifespan": 2592000,
  "webAuthnPolicyPasswordlessRpEntityName": "${TENANT_DISPLAY_NAME}",
  "webAuthnPolicyPasswordlessSignatureAlgorithms": ["ES256", "RS256"],
  "webAuthnPolicyPasswordlessRpId": "${EMAIL_DOMAIN}",
  "webAuthnPolicyPasswordlessAttestationConveyancePreference": "not specified",
  "webAuthnPolicyPasswordlessAuthenticatorAttachment": "not specified",
  "webAuthnPolicyPasswordlessRequireResidentKey": "Yes",
  "webAuthnPolicyPasswordlessUserVerificationRequirement": "required",
  "webAuthnPolicyPasswordlessCreateTimeout": 0,
  "webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister": false,
  "webAuthnPolicyPasswordlessAcceptableAaguids": [],
  "smtpServer": {
    "host": "postfix.infra-mail.svc.cluster.local",
    "port": "25",
    "from": "noreply@${TENANT_DOMAIN}",
    "fromDisplayName": "${TENANT_DISPLAY_NAME}",
    "replyTo": "noreply@${TENANT_DOMAIN}",
    "replyToDisplayName": "${TENANT_DISPLAY_NAME}",
    "ssl": "false",
    "starttls": "false",
    "auth": "false"
  },
  "clients": [
    {
      "clientId": "docs-app",
      "name": "LaSuite Docs Application",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "${OIDC_RP_CLIENT_SECRET}",
      "redirectUris": [
        "https://${DOCS_HOST}/*"
      ],
      "webOrigins": [
        "https://${DOCS_HOST}"
      ],
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "fullScopeAllowed": true,
      "defaultClientScopes": [
        "web-origins",
        "role_list",
        "profile",
        "roles",
        "email",
        "offline_access"
      ],
      "optionalClientScopes": [
        "address",
        "phone",
        "microprofile-jwt"
      ]
    },
    {
      "clientId": "matrix-synapse",
      "name": "Matrix Synapse",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "${SYNAPSE_OIDC_CLIENT_SECRET}",
      "redirectUris": [
        "https://${MATRIX_HOST}/_synapse/client/oidc/callback"
      ],
      "webOrigins": [
        "https://${MATRIX_HOST}"
      ],
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "fullScopeAllowed": true,
      "defaultClientScopes": [
        "web-origins",
        "role_list",
        "profile",
        "roles",
        "email"
      ],
      "optionalClientScopes": [
        "address",
        "phone",
        "offline_access",
        "microprofile-jwt"
      ]
    },
    {
      "clientId": "stalwart",
      "name": "Stalwart Mail Server",
      "description": "OIDC client for Stalwart mail server authentication",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "${STALWART_OIDC_SECRET}",
      "redirectUris": [
        "https://${MAIL_HOST}/*"
      ],
      "webOrigins": [
        "https://${MAIL_HOST}"
      ],
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "fullScopeAllowed": true,
      "defaultClientScopes": [
        "web-origins",
        "role_list",
        "profile",
        "roles",
        "email"
      ],
      "optionalClientScopes": [
        "address",
        "phone",
        "offline_access",
        "microprofile-jwt"
      ]
    },
    {
      "clientId": "roundcube",
      "name": "Roundcube Webmail",
      "description": "OIDC client for Roundcube webmail OAuth authentication",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "${ROUNDCUBE_OIDC_SECRET}",
      "redirectUris": [
        "https://${WEBMAIL_HOST}/index.php/login/oauth"
      ],
      "webOrigins": [
        "https://${WEBMAIL_HOST}"
      ],
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "fullScopeAllowed": true,
      "defaultClientScopes": [
        "web-origins",
        "role_list",
        "profile",
        "roles",
        "email",
        "offline_access"
      ],
      "optionalClientScopes": [
        "address",
        "phone",
        "microprofile-jwt"
      ]
    },
    {
      "clientId": "admin-portal",
      "name": "Tenant Admin Portal",
      "description": "Admin portal for tenant user management and onboarding",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "${ADMIN_PORTAL_OIDC_SECRET}",
      "redirectUris": [
        "https://${ADMIN_HOST}/*"
      ],
      "webOrigins": [
        "https://${ADMIN_HOST}"
      ],
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": true,
      "authorizationServicesEnabled": false,
      "fullScopeAllowed": true,
      "defaultClientScopes": [
        "web-origins",
        "role_list",
        "profile",
        "roles",
        "email"
      ],
      "optionalClientScopes": [
        "address",
        "phone",
        "offline_access",
        "microprofile-jwt"
      ]
    }
  ],
  "identityProviders": [
    {
      "alias": "google",
      "displayName": "Google",
      "providerId": "google",
      "enabled": true,
      "updateProfileFirstLoginMode": "on",
      "trustEmail": true,
      "storeToken": false,
      "addReadTokenRoleOnCreate": false,
      "authenticateByDefault": false,
      "linkOnly": false,
      "firstBrokerLoginFlowAlias": "first broker login",
      "config": {
        "hideOnLoginPage": "false",
        "clientId": "${GOOGLE_CLIENT_ID}",
        "clientSecret": "${GOOGLE_CLIENT_SECRET}",
        "defaultScope": "openid email profile",
        "hostedDomain": "",
        "useJwksUrl": "true",
        "syncMode": "IMPORT"
      }
    }
  ],
  "roles": {
    "realm": [
      {
        "name": "docs-user",
        "description": "LaSuite Docs user role",
        "composite": false,
        "clientRole": false,
        "containerId": "${TENANT_KEYCLOAK_REALM}"
      },
      {
        "name": "guest-user",
        "description": "External guest collaborator - limited access to shared resources only",
        "composite": false,
        "clientRole": false,
        "containerId": "${TENANT_KEYCLOAK_REALM}"
      },
      {
        "name": "tenant-admin",
        "description": "Tenant administrator - can invite and manage users",
        "composite": false,
        "clientRole": false,
        "containerId": "${TENANT_KEYCLOAK_REALM}"
      }
    ]
  },
  "defaultRoles": [
    "docs-user"
  ],
  "requiredActions": [
    {
      "alias": "UPDATE_PASSWORD",
      "name": "Update Password",
      "providerId": "UPDATE_PASSWORD",
      "enabled": true,
      "defaultAction": false,
      "priority": 30,
      "config": {}
    },
    {
      "alias": "VERIFY_EMAIL",
      "name": "Verify Email",
      "providerId": "VERIFY_EMAIL",
      "enabled": true,
      "defaultAction": false,
      "priority": 50,
      "config": {}
    },
    {
      "alias": "WEBAUTHN_REGISTER_PASSWORDLESS",
      "name": "Webauthn Register Passwordless",
      "providerId": "webauthn-register-passwordless",
      "enabled": true,
      "defaultAction": false,
      "priority": 70,
      "config": {}
    },
    {
      "alias": "webauthn-register-passwordless",
      "name": "Webauthn Register Passwordless",
      "providerId": "webauthn-register-passwordless",
      "enabled": true,
      "defaultAction": false,
      "priority": 70,
      "config": {}
    }
  ],
  "users": [
    {
      "username": "admin",
      "email": "admin@${EMAIL_DOMAIN}",
      "firstName": "Admin",
      "lastName": "User",
      "enabled": true,
      "emailVerified": true,
      "credentials": [
        {
          "type": "password",
          "value": "${KEYCLOAK_ADMIN_PASSWORD}",
          "temporary": false
        }
      ],
      "realmRoles": [
        "docs-user"
      ]
    }
  ],
  "browserFlow": "browser",
  "registrationFlow": "registration",
  "directGrantFlow": "direct grant",
  "resetCredentialsFlow": "reset credentials",
  "clientAuthenticationFlow": "clients",
  "dockerAuthenticationFlow": "docker auth",
  "attributes": {
    "frontendUrl": "https://${AUTH_HOST}"
  },
  "browserSecurityHeaders": {
    "contentSecurityPolicy": "frame-ancestors 'self' https://${HOME_HOST} https://${DOCS_HOST}; frame-src 'self'; object-src 'none';",
    "xFrameOptions": ""
  },
  "loginTheme": "platform",
  "emailTheme": "platform"
}
