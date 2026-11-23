# One-time Synapse → MAS migration step (`mas-cli syn2mas`, #824).
# apps/deploy-mas.sh creates this Job three times, in order:
#   check            — read-only validation, Synapse still running
#   migrate --dry-run — full write path into the MAS DB, then truncated
#   migrate          — the real run; Synapse and MAS are scaled to 0 first
#
# Required environment variables:
#   NS_MATRIX         - Tenant matrix namespace
#   SYN2MAS_JOB_NAME  - Job name (one per step)
#   SYN2MAS_ARGS      - Quoted, comma-separated trailing args, e.g. "check"
apiVersion: batch/v1
kind: Job
metadata:
  name: ${SYN2MAS_JOB_NAME}
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: mas
    app.kubernetes.io/component: syn2mas
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mas
        app.kubernetes.io/component: syn2mas
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: syn2mas
          image: ghcr.io/element-hq/matrix-authentication-service:1.29.0
          imagePullPolicy: IfNotPresent
          args: ["syn2mas", "--config", "/config/config.yaml", "--synapse-config", "/synapse/homeserver.yaml", ${SYN2MAS_ARGS}]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
            - name: synapse
              mountPath: /synapse
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 1Gi
      volumes:
        - name: config
          secret:
            secretName: mas-config
            defaultMode: 0440
        - name: synapse
          secret:
            secretName: mas-syn2mas-synapse
            defaultMode: 0440
