apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-web
  namespace: matrix
  labels:
    app: jitsi-web
    component: web
spec:
  replicas: ${JITSI_WEB_MIN_REPLICAS}
  selector:
    matchLabels:
      app: jitsi-web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: jitsi-web
        component: web
    spec:
      # Rootless since stable-11146: the images run as user s6 (uid/gid 1000).
      # Numeric ids are required, runAsNonRoot cannot verify a named USER.
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: web
        image: ghcr.io/jitsi/web:stable-11248
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        # Unprivileged port since stable-11146 (was 80). HTTPS is terminated at
        # the ingress (DISABLE_HTTPS=1), so the image's 8443 is not exposed.
        ports:
        - containerPort: 8000
          name: http
        env:
        # /run is an emptyDir, which Kubernetes creates root-owned and world-writable
        # without the sticky bit; the rootless s6-overlay refuses that unless told
        # otherwise (same setting as the jitsi-contrib/jitsi-helm chart).
        - name: S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES
          value: "1"
        - name: PUBLIC_URL
          value: "https://${JITSI_HOST}"
        - name: XMPP_DOMAIN
          value: "${JITSI_HOST}"
        - name: XMPP_MUC_DOMAIN
          value: "muc.${JITSI_HOST}"
        - name: XMPP_AUTH_DOMAIN
          value: "auth.${JITSI_HOST}"
        - name: XMPP_GUEST_DOMAIN
          value: "guest.${JITSI_HOST}"
        - name: XMPP_HIDDEN_DOMAIN
          value: "hidden.${JITSI_HOST}"
        - name: XMPP_INTERNAL_MUC_DOMAIN
          value: "internal-muc.${JITSI_HOST}"
        # JWT Authentication for Keycloak adapter
        - name: ENABLE_AUTH
          value: "1"
        - name: AUTH_TYPE
          value: "jwt"
        - name: JWT_APP_ID
          value: "jitsi-mother-tree"
        - name: JWT_APP_SECRET
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JWT_APP_SECRET
        - name: JWT_ALLOW_EMPTY
          value: "1"
        - name: ENABLE_GUESTS
          value: "1"
        - name: ENABLE_AUTO_LOGIN
          value: "0"
        # ADAPTER_INTERNAL_URL moved below POD_NAMESPACE (uses FQDN for nginx resolver)
        - name: ENABLE_SCTP
          value: "true"
        - name: JVB_PREFER_SCTP
          value: "true"
        - name: ENABLE_XMPP_WEBSOCKET
          value: "false"
        - name: TZ
          value: "UTC"
        # In-place ICE restart (make-before-break) instead of a full session
        # restart when a client's media connection fails, e.g. on a Wi-Fi <->
        # cellular switch. The second flag lets the native apps restart ICE
        # proactively on an OS network-change event. Jicofo (enable-ice-restart)
        # and JVB (ice.restart.enabled) default to on.
        - name: ENABLE_ICE_RESTART
          value: "true"
        - name: ENABLE_ICE_RESTART_ON_NETWORK_CHANGE
          value: "true"
        - name: DISABLE_HTTPS
          value: "1"
        - name: ENABLE_HTTP_REDIRECT
          value: "0"
        - name: JICOFO_AUTH_USER
          value: "focus"
        # Pod namespace via downward API — used to construct FQDNs for nginx resolver
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: XMPP_BOSH_URL_BASE
          value: "http://jitsi-prosody.$(POD_NAMESPACE).svc.cluster.local:5280"
        # Keycloak adapter URL (FQDN for nginx resolver compatibility)
        - name: ADAPTER_INTERNAL_URL
          value: "http://jitsi-keycloak-adapter.$(POD_NAMESPACE).svc.cluster.local:9000"
        # DNS resolver IP for nginx (kube-dns ClusterIP) — prevents stale DNS on pod restarts
        - name: NGINX_RESOLVER
          value: "10.128.0.10"
        volumeMounts:
        - name: web-config
          mountPath: /config
        # Rendered config.js and nginx config live under /run/web (non-root writable)
        - name: run
          mountPath: /run
        - name: custom-config
          mountPath: /config/custom-config.js
          subPath: custom-config.js
        # OIDC adapter static files
        - name: adapter-body
          mountPath: /usr/share/jitsi-meet/body.html
          subPath: body.html
        - name: adapter-oidc-adapter
          mountPath: /usr/share/jitsi-meet/static/oidc-adapter.html
          subPath: oidc-adapter.html
        - name: adapter-oidc-redirect
          mountPath: /usr/share/jitsi-meet/static/oidc-redirect.html
          subPath: oidc-redirect.html
        # Custom meet.conf template with OIDC adapter support
        - name: meet-conf-template
          mountPath: /defaults/meet.conf
          subPath: meet.conf
        livenessProbe:
          httpGet:
            path: /
            port: http
        readinessProbe:
          httpGet:
            path: /
            port: http
        # Memory tuned based on actual usage (~17Mi observed)
        resources:
          requests:
            cpu: 100m  # Minimum 100m to prevent HPA triggering on idle fluctuations
            memory: 48Mi
          limits:
            memory: 128Mi
      volumes:
      - name: web-config
        emptyDir: {}
      - name: run
        emptyDir: {}
      - name: custom-config
        configMap:
          name: jitsi-web-config
      # OIDC adapter static files
      - name: adapter-body
        configMap:
          name: jitsi-adapter-static-files
          items:
          - key: body.html
            path: body.html
      - name: adapter-oidc-adapter
        configMap:
          name: jitsi-adapter-static-files
          items:
          - key: oidc-adapter.html
            path: oidc-adapter.html
      - name: adapter-oidc-redirect
        configMap:
          name: jitsi-adapter-static-files
          items:
          - key: oidc-redirect.html
            path: oidc-redirect.html
      # Custom meet.conf template with OIDC adapter support
      - name: meet-conf-template
        configMap:
          name: jitsi-meet-conf-template
          items:
          - key: meet.conf
            path: meet.conf

---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-web
  namespace: matrix
  labels:
    app: jitsi-web
    component: web
spec:
  type: ClusterIP
  ports:
  # Named targetPort: old pods (80) and new pods (8000) both stay reachable
  # during the rollout.
  - port: 80
    name: http
    targetPort: http
  selector:
    app: jitsi-web
