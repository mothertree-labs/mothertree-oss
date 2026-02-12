apiVersion: v1
kind: ConfigMap
metadata:
  name: jitsi-web-config
  namespace: matrix
  labels:
    app: jitsi-web
    component: web
data:
  custom-config.js: |
    var config = {
      // Hosts configuration
      hosts: {
        domain: '${JITSI_HOST}',
        muc: 'muc.${JITSI_HOST}',
        // Guest domain for unauthenticated users (secure domain pattern)
        anonymousdomain: 'guest.${JITSI_HOST}'
      },
      // JWT Authentication - redirect to keycloak-adapter for login
      // Uses /oidc/auth (prompt=login) to show the Keycloak login page directly
      tokenAuthUrl: '/oidc/auth?path=/{room}&search=&hash=config.prejoinConfig.enabled%3Dfalse',
      // Don't auto-redirect - let guests join the waiting room first
      tokenAuthUrlAutoRedirect: false,
      // Enable moderator role detection from JWT token
      enableUserRolesBasedOnToken: true,
      // Use our TURN server for NAT traversal
      p2p: {
        enabled: true,
        stunServers: [
          { urls: 'stun:${TURN_SERVER_IP}:3478' }
        ],
        iceServers: [
          {
            urls: [
              'turn:${TURN_SERVER_IP}:3478?transport=udp',
              'turn:${TURN_SERVER_IP}:3478?transport=tcp',
              'turn:${TURN_SERVER_IP}:3479?transport=udp',
              'turn:${TURN_SERVER_IP}:3479?transport=tcp'
            ],
            username: 'matrix',
            credential: '${TF_VAR_turn_shared_secret}'
          }
        ]
      },
      // BOSH configuration
      bosh: 'https://${JITSI_HOST}/http-bind',
      // Disable some features for better performance
      enableWelcomePage: false,
      enableInsecureRoomNameWarning: false,
      // Allow iframe embedding for Matrix integration
      disableThirdPartyRequests: false
    };
