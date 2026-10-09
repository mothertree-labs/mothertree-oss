apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-jicofo
  namespace: matrix
  labels:
    app: jitsi-jicofo
    component: jicofo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jitsi-jicofo
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: jitsi-jicofo
        component: jicofo
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
      - name: jicofo
        image: ghcr.io/jitsi/jicofo:stable-11248
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        ports:
        - containerPort: 8888
          name: http
        env:
        # /run is an emptyDir, which Kubernetes creates root-owned and world-writable
        # without the sticky bit; the rootless s6-overlay refuses that unless told
        # otherwise (same setting as the jitsi-contrib/jitsi-helm chart).
        - name: S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES
          value: "1"
        - name: XMPP_SERVER
          value: "jitsi-prosody"
        - name: XMPP_DOMAIN
          value: "${JITSI_HOST}"
        - name: XMPP_MUC_DOMAIN
          value: "muc.${JITSI_HOST}"
        - name: XMPP_AUTH_DOMAIN
          value: "auth.${JITSI_HOST}"
        - name: XMPP_INTERNAL_MUC_DOMAIN
          value: "internal-muc.${JITSI_HOST}"
        - name: JVB_BREWERY_MUC
          value: "jvbbrewery"
        - name: JICOFO_ENABLE_REST
          value: "1"
        - name: JICOFO_AUTH_USER
          value: "focus"
        - name: JICOFO_AUTH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JICOFO_AUTH_PASSWORD
        - name: JICOFO_COMPONENT_SECRET
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JICOFO_COMPONENT_SECRET
        # Enable auth enforcement - guests cannot create rooms without moderator
        - name: ENABLE_AUTH
          value: "1"
        - name: AUTH_TYPE
          value: "jwt"
        - name: XMPP_GUEST_DOMAIN
          value: "guest.${JITSI_HOST}"
        # Auth settings for Keycloak adapter (per adapter docs)
        - name: JICOFO_AUTH_TYPE
          value: "internal"
        - name: JICOFO_AUTH_LIFETIME
          value: "100 milliseconds"
        livenessProbe:
          tcpSocket:
            port: 8888
        readinessProbe:
          tcpSocket:
            port: 8888
          periodSeconds: 10
        # Rendered jicofo.conf lives under /run/jicofo (non-root writable)
        volumeMounts:
        - name: run
          mountPath: /run
        resources:
          requests:
            cpu: 50m
            memory: 192Mi
          limits:
            memory: 1Gi
      volumes:
      - name: run
        emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jicofo
  namespace: matrix
  labels:
    app: jitsi-jicofo
    component: jicofo
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8888"
    prometheus.io/path: "/stats"
spec:
  type: ClusterIP
  ports:
  - port: 8888
    name: http
    targetPort: 8888
  selector:
    app: jitsi-jicofo
