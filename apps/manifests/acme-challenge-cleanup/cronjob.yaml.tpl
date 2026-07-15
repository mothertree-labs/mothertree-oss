apiVersion: batch/v1
kind: CronJob
metadata:
  name: acme-challenge-cleanup
  namespace: ${NS_CERTMANAGER}
  labels:
    app: acme-challenge-cleanup
spec:
  schedule: "40 * * * *"  # Hourly at :40 (offset from headscale-cleanup :15)
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
            app: acme-challenge-cleanup
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
          containers:
            - name: cleanup
              image: alpine/k8s:1.34.0
              command: ["sh", "/config/cleanup.sh"]
              env:
                - name: CF_API_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: cloudflare-api-token
                      key: api-token
                - name: CF_ZONE_NAME
                  value: "${INFRA_DOMAIN}"
                - name: MAX_AGE_MINUTES
                  value: "360"
              volumeMounts:
                - name: config
                  mountPath: /config
                  readOnly: true
                # Writable scratch for mktemp — the root fs is read-only.
                - name: tmp
                  mountPath: /tmp
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
                name: acme-challenge-cleanup-config
                defaultMode: 0755
            - name: tmp
              emptyDir: {}
