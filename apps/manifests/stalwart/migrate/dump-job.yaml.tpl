# Stalwart 0.15 → v1 migration, Job 1 of 2 (#715): export the LIVE 0.15
# server through its management API (dump.sh). Created by deploy-stalwart.sh
# while 0.15 still runs; 0.15 is stopped right after this Job succeeds.
#
# Writes only to the stalwart-migration PVC. Its files hold the OAuth signing
# key and possibly DKIM/TLS private keys: deploy-stalwart.sh prints only the
# termination message (a one-line status), never `kubectl logs`.
#
# Required environment variables:
#   NS_MAIL TENANT_NAME STALWART_DB_NAME STALWART_SCRATCH_DB_NAME
#   MIGRATE_V016_URL MIGRATE_V016_SHA256
apiVersion: batch/v1
kind: Job
metadata:
  name: stalwart-migrate-dump
  namespace: ${NS_MAIL}
  labels:
    app.kubernetes.io/name: stalwart
    app.kubernetes.io/component: migrate
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        # Keep this pod's output out of Loki: it handles the converted
        # export (OAuth signing key, DKIM/TLS keys) and the admin password.
        vector.dev/exclude: "true"
        app.kubernetes.io/name: stalwart
        app.kubernetes.io/component: migrate
        # allow-stalwart-mgmt-ingress: may reach stalwart:8080
        stalwart.mothertree/mgmt-client: "true"
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
      containers:
      - name: dump
        image: python:3.13.18-slim
        command: ["sh", "/scripts/dump.sh"]
        terminationMessagePolicy: File
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        env:
        - name: HOME
          value: /tmp
        - name: SW_URL
          value: "http://stalwart.${NS_MAIL}.svc.cluster.local:8080"
        - name: SW_USER
          value: admin
        - name: SW_PASSWORD
          valueFrom:
            secretKeyRef:
              name: stalwart-secrets
              key: STALWART_ADMIN_PASSWORD
        - name: SRC_DB
          value: "${STALWART_DB_NAME}"
        - name: SCRATCH_DB
          value: "${STALWART_SCRATCH_DB_NAME}"
        - name: MIGRATE_V016_URL
          value: "${MIGRATE_V016_URL}"
        - name: MIGRATE_V016_SHA256
          value: "${MIGRATE_V016_SHA256}"
        volumeMounts:
        - name: work
          mountPath: /work
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: tls
          mountPath: /opt/stalwart/tls
          readOnly: true
        - name: tmp
          mountPath: /tmp
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            memory: 512Mi
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
      - name: tmp
        emptyDir: {}
