# Apply the Stalwart v1 configuration plan (#715). Rendered by
# scripts/lib/stalwart-v1-plan.sh, stored in the Secret stalwart-v1-plan
# (it contains the Redis URL with its password), applied with stalwart-cli
# through stalwart-mgmt, which also reaches pods that are not Ready yet: a
# brand-new store has no listeners until this plan creates them.
#
# Idempotent: every line is an update, upsert or reconcile.
#
# Required environment variables:
#   NS_MAIL
apiVersion: batch/v1
kind: Job
metadata:
  name: stalwart-v1-plan
  namespace: ${NS_MAIL}
  labels:
    app.kubernetes.io/name: stalwart
    app.kubernetes.io/component: config-plan
spec:
  backoffLimit: 2
  activeDeadlineSeconds: 300
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stalwart
        app.kubernetes.io/component: config-plan
        # allow-stalwart-mgmt-ingress: may reach Stalwart :8080
        stalwart.mothertree/mgmt-client: "true"
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: apply
        image: stalwartlabs/cli:2.0.0
        args: ["apply", "--file", "/plan/plan.ndjson", "--quiet", "--no-color"]
        # Distroless, so no status file: --quiet prints the summary only, and
        # on failure the per-operation errors (object ids and properties,
        # never values).
        terminationMessagePolicy: FallbackToLogsOnError
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        env:
        - name: STALWART_URL
          value: "http://stalwart-mgmt.${NS_MAIL}.svc.cluster.local:8080"
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
        - name: plan
          mountPath: /plan
          readOnly: true
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: plan
        secret:
          secretName: stalwart-v1-plan
      - name: tmp
        emptyDir: {}
