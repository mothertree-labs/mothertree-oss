# Stalwart 0.15 → v1 migration, Job 2 of 2 (#715). Created by
# deploy-stalwart.sh after Job 1 succeeded and every 0.15 pod is gone.
#
# Steps, in order (init containers run one after another; the v0.16.27
# recovery server is a native sidecar, so it keeps running across the steps
# after it and is stopped explicitly before the final copy):
#   1. copy          live 0.15 DB → scratch DB (pg_dump | pg_restore); checks
#                    the v1 DB is empty (dev: RESET_V1=yes recreates it)
#   2. v016          sidecar: v0.16.27 recovery mode on the scratch DB, 8080 only
#   3. apply-export  stalwart-cli 1.0.14 applies the converted 0.15 export
#   4. stop-v016     stops the sidecar for good and waits for 8080 to close
#   5. migrate       stalwart-migrate 0.16.27 store → empty v1 DB, then verify
#
# The live 0.15 database is only ever READ (step 1). Nothing here prints the
# export, settings or logs; each step leaves a one-line termination message.
#
# Required environment variables:
#   NS_MAIL TENANT_NAME PG_HOST STALWART_DB_NAME STALWART_SCRATCH_DB_NAME
#   STALWART_V1_DB_NAME STALWART_DB_USER STALWART_RESET_V1
apiVersion: batch/v1
kind: Job
metadata:
  name: stalwart-migrate
  namespace: ${NS_MAIL}
  labels:
    app.kubernetes.io/name: stalwart
    app.kubernetes.io/component: migrate
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 2700
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        # Keep this pod's output out of Loki: it handles the converted
        # export (OAuth signing key, DKIM/TLS keys) and the admin password.
        vector.dev/exclude: "true"
        app.kubernetes.io/name: stalwart
        app.kubernetes.io/component: migrate
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
      - name: copy
        image: postgres:18.7
        command: ["bash", "/scripts/copy.sh"]
        securityContext:
          runAsUser: 999
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        env:
        - name: PGHOST
          value: "${PG_HOST}"
        - name: PGPORT
          value: "5432"
        - name: PGUSER
          value: postgres
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: postgres-password
        - name: SRC_DB
          value: "${STALWART_DB_NAME}"
        - name: SCRATCH_DB
          value: "${STALWART_SCRATCH_DB_NAME}"
        - name: V1_DB
          value: "${STALWART_V1_DB_NAME}"
        - name: DB_OWNER
          value: "${STALWART_DB_USER}"
        - name: RESET_V1
          value: "${STALWART_RESET_V1}"
        volumeMounts:
        - name: work
          mountPath: /work
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: tmp
          mountPath: /tmp
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            memory: 512Mi

      # Native sidecar (restartPolicy: Always). No liveness probe: a restart
      # must not resurrect recovery mode once stop-v016 has run (the script
      # checks the stop file itself).
      - name: v016
        image: stalwartlabs/stalwart:v0.16.27
        restartPolicy: Always
        command: ["sh", "/scripts/v016-recovery.sh"]
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        env:
        - name: STALWART_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_ADMIN_PASSWORD
        - name: STALWART_RECOVERY_ADMIN
          value: "admin:$(STALWART_ADMIN_PASSWORD)"
        - name: STALWART_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_DB_PASSWORD
        - name: STALWART_OIDC_SECRET
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_OIDC_SECRET
        - name: S3_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: S3_ACCESS_KEY
        - name: S3_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: S3_SECRET_KEY
        # The converted 0.15 export references these (relay route).
        - name: SES_SMTP_ENDPOINT
          valueFrom:
            secretKeyRef:
              name: ses-credentials
              key: endpoint
              optional: true
        - name: SES_SMTP_USER
          valueFrom:
            secretKeyRef:
              name: ses-credentials
              key: username
              optional: true
        - name: SES_SMTP_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ses-credentials
              key: password
              optional: true
        startupProbe:
          httpGet:
            path: /healthz/live
            port: 8080
          periodSeconds: 2
          failureThreshold: 150
        volumeMounts:
        - name: work
          mountPath: /work
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: tls
          mountPath: /opt/stalwart/tls
          readOnly: true
        - name: data
          mountPath: /opt/stalwart/data
        - name: tmp
          mountPath: /tmp
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 1Gi

      - name: apply-export
        image: stalwartlabs/cli:1.0.14
        args: ["apply", "--file", "/work/hop1/export.patched.ndjson", "--quiet", "--no-color"]
        # Distroless, no shell: the termination message stays empty and only
        # the exit code is reported (copying log lines into pod status could
        # carry values from the export). Logs are excluded from Loki.
        terminationMessagePolicy: File
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        env:
        - name: STALWART_URL
          value: "http://127.0.0.1:8080"
        - name: STALWART_USER
          value: admin
        - name: STALWART_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_ADMIN_PASSWORD
        - name: HOME
          value: /tmp
        volumeMounts:
        - name: work
          mountPath: /work
          readOnly: true
        - name: tmp
          mountPath: /tmp

      - name: stop-v016
        image: stalwartlabs/stalwart:v0.16.27
        command: ["sh", "/scripts/stop-v016.sh"]
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: work
          mountPath: /work
        - name: scripts
          mountPath: /scripts
          readOnly: true

      containers:
      - name: migrate
        image: stalwartlabs/stalwart-migrate:1.0.8
        command: ["sh", "/scripts/migrate.sh"]
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        env:
        - name: PG_HOST
          value: "${PG_HOST}"
        - name: V1_DB
          value: "${STALWART_V1_DB_NAME}"
        - name: DB_OWNER
          value: "${STALWART_DB_USER}"
        - name: HOME
          value: /tmp
        - name: STALWART_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_DB_PASSWORD
        - name: S3_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: S3_ACCESS_KEY
        - name: S3_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: S3_SECRET_KEY
        volumeMounts:
        - name: work
          mountPath: /work
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: tmp
          mountPath: /tmp
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            memory: 2Gi

      volumes:
      - name: work
        persistentVolumeClaim:
          claimName: stalwart-migration
      - name: scripts
        configMap:
          name: stalwart-migrate-scripts
      - name: tls
        secret:
          secretName: wildcard-tls-${TENANT_NAME}
      - name: data
        emptyDir: {}
      - name: tmp
        emptyDir: {}
