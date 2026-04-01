apiVersion: batch/v1
kind: CronJob
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
spec:
  schedule: "0 4 * * 0"  # Weekly, Sunday 04:00 UTC
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 300
      template:
        metadata:
          labels:
            app: tailscale-key-rotator
        spec:
          serviceAccountName: tailscale-key-rotator
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
          containers:
            - name: rotator
              image: alpine/k8s:1.34.0
              command: ["sh", "/config/rotate.sh"]
              env:
                - name: HEADSCALE_API_KEY
                  valueFrom:
                    secretKeyRef:
                      name: tailscale-rotator-api-key
                      key: HEADSCALE_API_KEY
              volumeMounts:
                - name: config
                  mountPath: /config
                  readOnly: true
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
          volumes:
            - name: config
              configMap:
                name: tailscale-rotator-config
                defaultMode: 0755
