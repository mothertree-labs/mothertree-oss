apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer
  namespace: ${NS_DB}
  labels:
    app: pgbouncer
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pgbouncer
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
  template:
    metadata:
      labels:
        app: pgbouncer
      annotations:
        checksum/config: "${CHECKSUM_PGBOUNCER_CONFIG}"
        checksum/userlist: "${CHECKSUM_PGBOUNCER_USERLIST}"
    spec:
      serviceAccountName: pgbouncer
      priorityClassName: system-cluster-critical
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: pgbouncer
              topologyKey: kubernetes.io/hostname
      containers:
        # PgBouncer — connection pooler
        - name: pgbouncer
          # edoburu/pgbouncer:v1.25.1-p0 — actively maintained, multi-arch (amd64+arm64)
          # https://hub.docker.com/r/edoburu/pgbouncer
          image: edoburu/pgbouncer:v1.25.1-p0
          ports:
            - containerPort: 5432
              name: postgresql
          env:
            - name: DATABASES_HOST
              value: "${PG_VM_TAILSCALE_IP}"
            - name: DATABASES_PORT
              value: "5432"
          volumeMounts:
            - name: pgbouncer-config
              mountPath: /etc/pgbouncer/pgbouncer.ini
              subPath: pgbouncer.ini
              readOnly: true
            - name: pgbouncer-userlist
              mountPath: /etc/pgbouncer/userlist.txt
              subPath: userlist.txt
              readOnly: true
          livenessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi

        # Tailscale sidecar — WireGuard mesh connectivity to PG VM
        - name: tailscale
          # tailscale/tailscale:v1.94.2 — stable release, multi-arch
          # https://hub.docker.com/r/tailscale/tailscale
          image: tailscale/tailscale:v1.94.2
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: pgbouncer-tailscale-auth
                  key: TS_AUTHKEY
            - name: TS_EXTRA_ARGS
              value: "--login-server=${HEADSCALE_URL}"
            - name: TS_KUBE_SECRET
              value: "pgbouncer-tailscale-state-$(POD_NAME)"
            - name: TS_ACCEPT_DNS
              value: "true"
            - name: TS_USERSPACE
              value: "false"
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 128Mi

      volumes:
        - name: pgbouncer-config
          configMap:
            name: pgbouncer-config
        - name: pgbouncer-userlist
          secret:
            secretName: pgbouncer-userlist

      terminationGracePeriodSeconds: 30
