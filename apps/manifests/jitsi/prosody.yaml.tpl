apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: jitsi-prosody
  namespace: matrix
  labels:
    app: jitsi-prosody
    component: prosody
spec:
  serviceName: jitsi-prosody
  replicas: 1
  selector:
    matchLabels:
      app: jitsi-prosody
  template:
    metadata:
      labels:
        app: jitsi-prosody
        component: prosody
    spec:
      securityContext:
        runAsNonRoot: false  # Prosody image requires root for s6-overlay init
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: prosody
        image: jitsi/prosody:stable-10710
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add: ["SETUID", "SETGID", "CHOWN", "FOWNER", "DAC_OVERRIDE"]
            drop: ["ALL"]
        ports:
        - containerPort: 5222
          name: xmpp-c2s
        - containerPort: 5269
          name: xmpp-s2s
        - containerPort: 5347
          name: xmpp-component
        - containerPort: 5280
          name: bosh-insecure
        - containerPort: 5281
          name: bosh-secure
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
        - name: JVB_AUTH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JVB_AUTH_PASSWORD
        - name: JIGASI_AUTH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JIGASI_AUTH_PASSWORD
        - name: JIGASI_COMPONENT_SECRET
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JIGASI_COMPONENT_SECRET
        - name: JIBRI_AUTH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JIBRI_AUTH_PASSWORD
        - name: JIBRI_RECORDER_PASSWORD
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JIBRI_RECORDER_PASSWORD
        - name: TURN_CREDENTIALS
          value: "matrix:${TURN_SHARED_SECRET}"
        - name: TURN_HOST
          value: "${TURN_SERVER_IP}"
        - name: TURN_PORT
          value: "3478"
        - name: TURN_PORT_TLS
          value: "5349"
        - name: TURN_TRANSPORT
          value: "udp,tcp"
        volumeMounts:
        - name: prosody-config
          mountPath: /config
        - name: prosody-data
          mountPath: /config/data
        livenessProbe:
          httpGet:
            path: /http-bind
            port: 5280
        readinessProbe:
          httpGet:
            path: /http-bind
            port: 5280
        # Memory tuned based on actual usage (~33Mi observed)
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 300m
            memory: 256Mi
      volumes:
      - name: prosody-config
        emptyDir: {}
      - name: prosody-data
        emptyDir: {}  # Changed from PVC to reduce volume count - XMPP state rebuilds on restart

---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-prosody
  namespace: matrix
  labels:
    app: jitsi-prosody
    component: prosody
spec:
  type: ClusterIP
  ports:
  - port: 5222
    name: xmpp-c2s
    targetPort: 5222
  - port: 5269
    name: xmpp-s2s
    targetPort: 5269
  - port: 5347
    name: xmpp-component
    targetPort: 5347
  - port: 5280
    name: bosh-insecure
    targetPort: 5280
  - port: 5281
    name: bosh-secure
    targetPort: 5281
  selector:
    app: jitsi-prosody
