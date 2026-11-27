# Docs collaboration server (lasuite/impress-yhub, impress >= 6.0).
#
# Replaces the y-provider on everything under /collaboration/: it holds the
# editor websockets, keeps the live state of a document in Redis (yhub-redis)
# and persists it to a PostgreSQL database of its own (the tenant docs database name + "_yhub",
# created by docs-db-init, schema by docs-yhub-init-db). The y-provider is now
# the conversion service only.
#
# Authentication, both directions, is RS256 JWTs — no shared secret:
#   - yhub verifies the backend's admin tokens against
#     <COLLABORATION_BACKEND_BASE_URL>/api/v1.0/jwks
#   - yhub signs its own calls to the backend (content-updated) with the key in
#     Secret docs-yhub (yhub-jwt.pem), whose public half it publishes on
#     /collaboration/jwks/v1, which the backend reads over YHUB_API_BASE_URL.
#
# SOFT_MIGRATION seeds a document from its legacy S3 snapshot
# ({document-id}/file in the media bucket) the first time it is opened; the
# docs-migrate-documents Job backfills the rest. It must stay on until that
# backfill has covered every document (deploy-docs.sh checks the ledger), and
# needs read access to the media bucket — it currently reuses the backend's
# keys (see the deploy script for the follow-up).
#
# Image is distroless: no shell, so no `sh -c` command overrides anywhere here.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: docs-yhub
  namespace: docs
  labels:
    app.kubernetes.io/name: docs
    app.kubernetes.io/instance: docs
    app.kubernetes.io/component: yhub
    app.kubernetes.io/part-of: mother-tree
spec:
  replicas: ${YPROVIDER_MIN_REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: docs
      app.kubernetes.io/instance: docs
      app.kubernetes.io/component: yhub
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: docs
        app.kubernetes.io/instance: docs
        app.kubernetes.io/component: yhub
    spec:
      priorityClassName: critical-service
      # Needs no Kubernetes API access.
      automountServiceAccountToken: false
      # A websocket is dropped when its pod goes away and the client reconnects
      # to another replica; the embedded worker gets this long to persist what
      # is still only on the Redis stream (upstream chart default).
      terminationGracePeriodSeconds: 60
      containers:
        - name: yhub
          image: lasuite/impress-yhub:v6.1.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3002
          env:
            - name: REDIS
              value: "redis://yhub-redis:6379/0"
            - name: REDIS_PREFIX
              value: "yhub"
            # Must match the backend's YHUB_ORG (docs-config) and the last
            # segment of COLLABORATION_WS_URL.
            - name: YHUB_ORG
              value: "docs"
            - name: POSTGRES
              valueFrom:
                secretKeyRef:
                  name: docs-yhub
                  key: POSTGRES
            # External URL, like the y-provider always used: the request goes
            # through the ingress, which sets X-Forwarded-Proto: https, so
            # Django's SECURE_SSL_REDIRECT does not 301 it.
            - name: COLLABORATION_BACKEND_BASE_URL
              value: "https://${DOCS_HOST}"
            - name: COLLABORATION_SERVER_ORIGIN
              value: "https://${DOCS_HOST}"
            # Same value as the backend's: exempts yhub's per-connection calls
            # from the backend's API throttling.
            - name: Y_PROVIDER_API_KEY
              valueFrom:
                secretKeyRef:
                  name: docs-secrets
                  key: Y_PROVIDER_API_KEY
            - name: YHUB_JWT_PRIVATE_KEY_FILE
              value: /etc/yhub-jwt/yhub-jwt.pem
            # One compute thread: the default is the NODE's cpu count minus one,
            # each thread with a heap of its own, sized for a far larger corpus.
            - name: YHUB_COMPUTE_THREADS
              value: "1"
            # Legacy (impress < 6) document store, read on first open and by the
            # full migration. Path-style addressing is chosen automatically for
            # any endpoint other than amazonaws.com.
            - name: SOFT_MIGRATION
              value: "true"
            - name: LEGACY_S3_ENDPOINT_URL
              value: "${YHUB_LEGACY_S3_ENDPOINT}"
            - name: LEGACY_S3_REGION_NAME
              value: "${S3_CLUSTER}"
            - name: LEGACY_S3_BUCKET_NAME
              value: "${BUCKET_NAME}"
            - name: LEGACY_S3_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: docs-secrets
                  key: AWS_S3_ACCESS_KEY_ID
            - name: LEGACY_S3_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: docs-secrets
                  key: AWS_S3_SECRET_ACCESS_KEY
          # ping touches nothing (liveness must not restart a server over a
          # store it cannot reach: that drops healthy websockets); ready asks
          # PostgreSQL and Redis and takes the pod out of the endpoints.
          startupProbe:
            httpGet:
              path: /collaboration/ping/v1
              port: 3002
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 24
          livenessProbe:
            httpGet:
              path: /collaboration/ping/v1
              port: 3002
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /collaboration/ready/v1
              port: 3002
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: yhub-jwt
              mountPath: /etc/yhub-jwt
              readOnly: true
      # The distroless image has no passwd entry; uid and gid are both named
      # (upstream chart does the same).
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: yhub-jwt
          secret:
            secretName: docs-yhub
            items:
              - key: YHUB_JWT_PRIVATE_KEY
                path: yhub-jwt.pem
            defaultMode: 0440
---
apiVersion: v1
kind: Service
metadata:
  name: yhub
  namespace: docs
  labels:
    app.kubernetes.io/name: docs
    app.kubernetes.io/component: yhub
    app.kubernetes.io/part-of: mother-tree
spec:
  selector:
    app.kubernetes.io/name: docs
    app.kubernetes.io/instance: docs
    app.kubernetes.io/component: yhub
  ports:
    - name: http
      port: 3002
      targetPort: 3002
