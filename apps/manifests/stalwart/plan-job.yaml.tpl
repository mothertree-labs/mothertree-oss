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
        # Keep this pod's output out of Loki: it handles the converted
        # export (OAuth signing key, DKIM/TLS keys) and the admin password.
        vector.dev/exclude: "true"
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
      initContainers:
      # A new pod's first connections are refused until the k3s/kube-router
      # NetworkPolicy controller has added its IP (about a second; pipeline
      # 139: all three cli attempts failed instantly). The cli is distroless
      # and connects at once, so wait here until the management API answers.
      - name: wait-mgmt
        image: python:3.15.2-slim
        command: ["python", "-I", "-c"]
        args:
        - |
          import time, urllib.request, urllib.error
          url = "http://stalwart-mgmt.${NS_MAIL}.svc.cluster.local:8080/healthz/live"
          for i in range(90):
              try:
                  urllib.request.urlopen(url, timeout=3)
                  print("mgmt API reachable after %ds" % (i * 2))
                  raise SystemExit(0)
              except (urllib.error.URLError, OSError):
                  time.sleep(2)
          raise SystemExit("stalwart-mgmt not reachable after 180s")
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 64Mi
      containers:
      - name: apply
        image: stalwartlabs/cli:2.0.0
        args: ["apply", "--file", "/plan/plan.ndjson", "--quiet", "--no-color"]
        # Distroless, so no status file: only the exit code is reported. The
        # plan holds the Redis ACL password; nothing from the logs is copied
        # into pod status, and the logs are excluded from Loki.
        terminationMessagePolicy: File
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
