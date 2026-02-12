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
      securityContext:
        runAsNonRoot: false  # Jicofo image requires root for s6-overlay init
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: jicofo
        image: jitsi/jicofo:stable-10710
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add: ["SETUID", "SETGID", "CHOWN", "FOWNER"]
            drop: ["ALL"]
        ports:
        - containerPort: 8888
          name: http
        env:
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
        resources:
          requests:
            cpu: 10m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 1Gi

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
