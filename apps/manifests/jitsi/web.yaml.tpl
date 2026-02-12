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
      securityContext:
        runAsNonRoot: false  # Jitsi web image requires root for s6-overlay init
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: web
        image: jitsi/web:stable-10710
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add: ["SETUID", "SETGID", "CHOWN", "FOWNER"]
            drop: ["ALL"]
        ports:
        - containerPort: 80
          name: http
        - containerPort: 443
          name: https
        env:
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
        # Keycloak adapter URL for OIDC proxy
        - name: ADAPTER_INTERNAL_URL
          value: "http://jitsi-keycloak-adapter:9000"
        - name: ENABLE_SCTP
          value: "true"
        - name: ENABLE_COLIBRI_WEBSOCKET
          value: "false"
        - name: JVB_PREFER_SCTP
          value: "true"
        - name: ENABLE_XMPP_WEBSOCKET
          value: "false"
        - name: TZ
          value: "UTC"
        - name: DISABLE_HTTPS
          value: "1"
        - name: ENABLE_HTTP_REDIRECT
          value: "0"
        - name: JICOFO_AUTH_USER
          value: "focus"
        - name: XMPP_BOSH_URL_BASE
          value: "http://jitsi-prosody:5280"
        volumeMounts:
        - name: web-config
          mountPath: /config
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
            port: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
        # Memory tuned based on actual usage (~17Mi observed)
        resources:
          requests:
            cpu: 100m  # Minimum 100m to prevent HPA triggering on idle fluctuations
            memory: 48Mi
          limits:
            cpu: 300m
            memory: 128Mi
      volumes:
      - name: web-config
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
  - port: 80
    name: http
    targetPort: 80
  - port: 443
    name: https
    targetPort: 443
  selector:
    app: jitsi-web
