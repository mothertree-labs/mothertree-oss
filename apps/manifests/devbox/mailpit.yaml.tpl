# devbox only (scripts/devbox up, mail feature on): a catch-all for outbound mail.
#
# The devbox infra config sets mail.smtp_relay to this Service, so Stalwart
# relays every message for a non-local domain (invitations to outside
# addresses, notifications, bounces) here instead of the internet. Mail
# between devbox users is still delivered by Stalwart itself.
#
#   https://${DEVBOX_MAILPIT_HOST}    the web UI (basic auth: Secret mailpit-ui)
#   mailpit.infra-mailpit.svc:1025    SMTP, plain, for Stalwart only
#
# The inbox holds password-reset and invitation links, so the UI and API need
# the generated login even though the ingress listens on loopback.
#
# Variables: DEVBOX_MAILPIT_HOST, DEVBOX_MAILPIT_AUTH_SHA (hash of the UI
# login, never the login itself).
apiVersion: v1
kind: Namespace
metadata:
  name: infra-mailpit
  labels:
    app.kubernetes.io/part-of: mothertree-devbox
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailpit
  namespace: infra-mailpit
  labels:
    app: mailpit
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: mailpit
  template:
    metadata:
      labels:
        app: mailpit
      annotations:
        # Restart when the UI login changes (it is read from env at start).
        checksum/mailpit-ui: "${DEVBOX_MAILPIT_AUTH_SHA}"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
      containers:
        - name: mailpit
          image: axllent/mailpit:v1.33.1
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: MP_SMTP_BIND_ADDR
              value: "0.0.0.0:1025"
            - name: MP_UI_BIND_ADDR
              value: "0.0.0.0:8025"
            - name: MP_DATABASE
              value: /data/mailpit.db
            - name: MP_MAX_MESSAGES
              value: "2000"
            - name: MP_UI_AUTH
              valueFrom:
                secretKeyRef:
                  name: mailpit-ui
                  key: auth
          ports:
            - name: smtp
              containerPort: 1025
            - name: http
              containerPort: 8025
          readinessProbe:
            exec:
              command: ["/mailpit", "readyz"]
            periodSeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: data
              mountPath: /data
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: data
          emptyDir: {}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mailpit
  namespace: infra-mailpit
spec:
  selector:
    app: mailpit
  ports:
    - name: smtp
      port: 1025
      targetPort: smtp
    - name: http
      port: 8025
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mailpit
  namespace: infra-mailpit
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["${DEVBOX_MAILPIT_HOST}"]
      secretName: mailpit-tls
  rules:
    - host: ${DEVBOX_MAILPIT_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mailpit
                port:
                  name: http
