apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${FED_NAME}
  namespace: ${NS_MONITORING}
  labels:
    app: ${FED_NAME}
    component: metrics-federation
spec:
  replicas: 1
  # Recreate: single-replica pod with a Tailscale sidecar — two pods cannot share
  # the same mesh identity during a rolling update, causing readiness failures.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ${FED_NAME}
  template:
    metadata:
      labels:
        app: ${FED_NAME}
        component: metrics-federation
    spec:
      serviceAccountName: ${FED_NAME}
      containers:
        # socat — TCP proxy. Two roles, selected by ${SOCAT_TARGET}:
        #   exposer  (prod-eu): forwards mesh -> in-cluster Prometheus ClusterIP:9090
        #   consumer (prod):    forwards in-cluster ClusterIP -> prod-eu bridge mesh IP:9090
        - name: socat
          image: alpine/socat:1.8.0.3
          args:
            - TCP-LISTEN:9090,fork,reuseaddr
            - TCP:${SOCAT_TARGET}
          ports:
            - containerPort: 9090
              name: http
          livenessProbe:
            tcpSocket:
              port: 9090
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            tcpSocket:
              port: 9090
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi

      # Native sidecar (K8s 1.28+): starts before main containers, terminated AFTER
      # them. This guarantees the WireGuard tunnel stays alive while socat drains
      # any in-flight requests on shutdown.
      initContainers:
        - name: tailscale
          # tailscale/tailscale:v1.94.2 — stable release, multi-arch
          # https://hub.docker.com/r/tailscale/tailscale
          image: tailscale/tailscale:v1.94.2
          restartPolicy: Always
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: ${FED_NAME}-tailscale-auth
                  key: TS_AUTHKEY
            - name: TS_HOSTNAME
              value: "${TS_HOSTNAME}"
            - name: TS_EXTRA_ARGS
              value: "--login-server=${HEADSCALE_URL}"
            - name: TS_KUBE_SECRET
              value: "${FED_NAME}-tailscale-state-$(POD_NAME)"
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

      terminationGracePeriodSeconds: 15
