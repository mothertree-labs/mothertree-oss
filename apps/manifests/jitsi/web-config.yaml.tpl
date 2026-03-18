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
      // NAT traversal: STUN for P2P direct connections; TURN relay credentials
      // are provided by Prosody via external_services (time-limited HMAC auth)
      p2p: {
        enabled: true,
        stunServers: [
          { urls: 'stun:${TURN_SERVER_IP}:3478' }
        ]
      },
      // BOSH configuration
      bosh: 'https://${JITSI_HOST}/http-bind',

      // --- Camera capture: 1080p for users with capable hardware ---
      resolution: 1080,
      constraints: {
        video: {
          height: { ideal: 1080, max: 1080, min: 180 },
          width: { ideal: 1920, max: 1920, min: 320 },
          frameRate: { ideal: 30, max: 30 }
        }
      },

      // --- Video quality & codec bitrates ---
      videoQuality: {
        codecPreferenceOrder: ['AV1', 'VP9', 'VP8', 'H264'],
        mobileCodecPreferenceOrder: ['VP8', 'VP9', 'H264', 'AV1'],
        enableAdaptiveMode: true,
        // Simulcast bitrates per layer (low/standard/high) per codec
        // High layer targets 1080p; good connections will use it
        vp8: {
          maxBitratesVideo: {
            low: 200000,
            standard: 500000,
            high: 4000000
          }
        },
        vp9: {
          maxBitratesVideo: {
            low: 150000,
            standard: 400000,
            high: 3500000
          }
        },
        av1: {
          maxBitratesVideo: {
            low: 100000,
            standard: 350000,
            high: 3000000
          }
        },
        h264: {
          maxBitratesVideo: {
            low: 200000,
            standard: 500000,
            high: 4000000
          }
        }
      },

      // --- Screenshare: high resolution + fast frame rate ---
      // 30fps makes animated presentations smooth (matching Zoom behavior)
      screenshotCapture: { enabled: false },
      desktopSharingFrameRate: {
        min: 15,
        max: 30
      },

      // --- Limit received streams in large meetings to save bandwidth ---
      channelLastN: 25,

      // Auto-mute video for 11th+ participant
      startVideoMuted: 10,

      // Disable some features for better performance
      enableWelcomePage: false,
      enableInsecureRoomNameWarning: false,
      // Prevent Gravatar and CallStats.io requests (GDPR - no third-party IP leaks)
      disableThirdPartyRequests: true
    };
