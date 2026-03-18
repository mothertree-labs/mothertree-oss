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
    // Custom overrides — appended after the image-generated config.js
    // Use property assignment to override specific values without wiping the base config

    // Hosts configuration
    config.hosts = {
      domain: '${JITSI_HOST}',
      muc: 'muc.${JITSI_HOST}',
      anonymousdomain: 'guest.${JITSI_HOST}'
    };

    // JWT Authentication - redirect to keycloak-adapter for login
    // Uses /oidc/auth (prompt=login) to show the Keycloak login page directly
    config.tokenAuthUrl = '/oidc/auth?path=/{room}&search=&hash=config.prejoinConfig.enabled%3Dfalse';
    // Don't auto-redirect - let guests join the waiting room first
    config.tokenAuthUrlAutoRedirect = false;
    // Enable moderator role detection from JWT token
    config.enableUserRolesBasedOnToken = true;

    // NAT traversal: STUN for P2P direct connections; TURN relay credentials
    // are provided by Prosody via external_services (time-limited HMAC auth)
    config.p2p = Object.assign(config.p2p || {}, {
      enabled: true,
      stunServers: [
        { urls: 'stun:${TURN_SERVER_IP}:3478' }
      ]
    });

    // BOSH configuration
    config.bosh = 'https://${JITSI_HOST}/http-bind';

    // --- Camera capture: 1080p for users with capable hardware ---
    config.resolution = 1080;
    config.constraints = {
      video: {
        height: { ideal: 1080, max: 1080, min: 180 },
        width: { ideal: 1920, max: 1920, min: 320 },
        frameRate: { ideal: 30, max: 30 }
      }
    };

    // --- Video quality & codec bitrates ---
    // Request high-res layer when pinning a participant
    config.videoQuality = {
      codecPreferenceOrder: ['AV1', 'VP9', 'VP8', 'H264'],
      mobileCodecPreferenceOrder: ['VP8', 'VP9', 'H264', 'AV1'],
      enableAdaptiveMode: true,
      maxBitratesVideo: {
        low: 200000,
        standard: 500000,
        high: 4000000
      },
      // Per-codec overrides
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
    };

    // --- Screenshare: high resolution + fast frame rate ---
    // 30fps makes animated presentations smooth (matching Zoom behavior)
    config.screenshotCapture = { enabled: false };
    config.desktopSharingFrameRate = {
      min: 15,
      max: 30
    };

    // Tell the client to request full resolution for pinned/large video
    config.maxReceiverVideoHeight = 1080;

    // --- Limit received streams in large meetings to save bandwidth ---
    config.channelLastN = 25;

    // Auto-mute video for 11th+ participant
    config.startVideoMuted = 10;

    // Disable some features for better performance
    config.enableWelcomePage = false;
    config.enableInsecureRoomNameWarning = false;
    // Prevent Gravatar and CallStats.io requests (GDPR - no third-party IP leaks)
    config.disableThirdPartyRequests = true;
