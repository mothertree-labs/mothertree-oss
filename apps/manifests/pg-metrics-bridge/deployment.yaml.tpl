apiVersion: apps/v1
kind: Deployment
metadata:
  name: pg-metrics-bridge
  namespace: ${NS_DB}
  labels:
    app: pg-metrics-bridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pg-metrics-bridge
  template:
    metadata:
      labels:
        app: pg-metrics-bridge
    spec:
      serviceAccountName: pg-metrics-bridge
      containers:
        # socat — TCP proxy forwarding metrics requests to PG VM's postgres_exporter
        - name: socat
          image: alpine/socat:1.8.0.3
          args:
            - TCP-LISTEN:9187,fork,reuseaddr
            - TCP:${PG_VM_TAILSCALE_IP}:9187
          ports:
            - containerPort: 9187
              name: metrics
          livenessProbe:
            tcpSocket:
              port: 9187
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            tcpSocket:
              port: 9187
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi

        # Tailscale sidecar — WireGuard mesh connectivity to PG VM
        - name: tailscale
          image: tailscale/tailscale:v1.94.2
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: pg-metrics-bridge-tailscale-auth
                  key: TS_AUTHKEY
            - name: TS_EXTRA_ARGS
              value: "--login-server=${HEADSCALE_URL}"
            - name: TS_KUBE_SECRET
              value: "pg-metrics-bridge-tailscale-state-$(POD_NAME)"
            - name: TS_ACCEPT_DNS
              value: "false"
            - name: TS_USERSPACE
              value: "false"
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 128Mi

      terminationGracePeriodSeconds: 10
