apiVersion: batch/v1
kind: CronJob
metadata:
  name: headscale-cleanup
  namespace: ${NS_DB}
  labels:
    app: headscale-cleanup
spec:
  schedule: "15 * * * *"  # Hourly at :15
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 600
      template:
        metadata:
          labels:
            app: headscale-cleanup
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
          containers:
            - name: cleanup
              image: alpine/k8s:1.34.0
              command: ["sh", "/config/cleanup.sh"]
              env:
                - name: HEADSCALE_API_KEY
                  valueFrom:
                    secretKeyRef:
                      name: tailscale-rotator-api-key
                      key: HEADSCALE_API_KEY
                - name: HEADSCALE_URL
                  value: "${HEADSCALE_URL}"
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
                name: headscale-cleanup-config
                defaultMode: 0755
