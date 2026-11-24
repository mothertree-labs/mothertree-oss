# Redis for Stalwart v1 clustering (#715): the Coordinator (pub/sub between
# replicas) and the shared in-memory store (rate limits, fail2ban counters,
# OAuth codes, queue/task locks). Stalwart keeps only short-lived keys here
# (TTL 5 s to ~10 min, a few MB); bans and all mail data live in PostgreSQL/S3,
# so no persistence is needed and a restart loses nothing that matters.
#
# Deliberately NOT the admin-portal Redis: Stalwart stores this Redis URL,
# password included, in clear in its settings registry (readable over JMAP by
# Stalwart admins), so a shared password would expose the portal sessions.
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stalwart-redis
  namespace: ${NS_MAIL}
  labels:
    app: stalwart-redis
    app.kubernetes.io/name: stalwart
    app.kubernetes.io/component: redis
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: stalwart-redis
  template:
    metadata:
      labels:
        app: stalwart-redis
        app.kubernetes.io/name: stalwart
        app.kubernetes.io/component: redis
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: redis
          image: redis:8.12.0-alpine
          # maxmemory below the container limit, so Redis refuses writes
          # (noeviction) instead of being OOM-killed. No RDB/AOF.
          command:
            - redis-server
            - --requirepass
            - $(REDIS_PASSWORD)
            - --maxmemory
            - 96mb
            - --save
            - ""
            - --appendonly
            - "no"
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: stalwart-redis
                  key: REDIS_PASSWORD
            # redis-cli in the probes reads this instead of -a (no password in argv)
            - name: REDISCLI_AUTH
              valueFrom:
                secretKeyRef:
                  name: stalwart-redis
                  key: REDIS_PASSWORD
          ports:
            - containerPort: 6379
              name: redis
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              memory: 128Mi
          livenessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 2
            periodSeconds: 5
      volumes:
        - name: data
          emptyDir:
            sizeLimit: 16Mi
---
apiVersion: v1
kind: Service
metadata:
  name: stalwart-redis
  namespace: ${NS_MAIL}
  labels:
    app: stalwart-redis
    app.kubernetes.io/name: stalwart
    app.kubernetes.io/component: redis
spec:
  selector:
    app: stalwart-redis
  ports:
    - port: 6379
      targetPort: 6379
      name: redis
  type: ClusterIP
