apiVersion: batch/v1
kind: CronJob
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
spec:
  # Daily: a dead key must be repaired within a day, not a week (#613).
  schedule: "0 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  # Keep one failed Job so KubeJobFailed reflects the latest run, not a
  # months-old failure (a stale April Job kept prod-eu alerting for 5 months).
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      # No in-Job retry: a retry after "sidecar failed to authenticate" would
      # find the Secret already holding the freshly minted key, report OK and
      # mask the failure. The daily schedule is the retry.
      backoffLimit: 0
      # Up to 5 components × (rollout 180s + sidecar proof 120s) + API calls.
      activeDeadlineSeconds: 1800
      # Finished Jobs (and their KubeJobFailed signal) age out after 48h, so a
      # one-off failure does not alert forever once later runs succeed.
      ttlSecondsAfterFinished: 172800
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
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: rotator
              image: alpine/k8s:1.37.0
              command: ["bash", "/config/rotate.sh"]
              env:
                - name: HEADSCALE_URL
                  value: "${HEADSCALE_URL}"
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
