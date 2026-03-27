apiVersion: apps/v1
kind: Deployment
metadata:
  name: tailscale-router
  namespace: ${NS_INGRESS_INTERNAL}
  labels:
    app: tailscale-router
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tailscale-router
  template:
    metadata:
      labels:
        app: tailscale-router
      annotations:
        checksum/unbound-config: "${CHECKSUM_UNBOUND_CONFIG}"
    spec:
      serviceAccountName: tailscale-router
      # Tailscale subnet router — native sidecar, starts before Unbound.
      initContainers:
        - name: tailscale
          image: tailscale/tailscale:v1.94.2
          restartPolicy: Always
          env:
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: tailscale-router-auth
                  key: TS_AUTHKEY
            - name: TS_EXTRA_ARGS
              value: "--login-server=${HEADSCALE_URL} --advertise-routes=${SERVICE_CIDR} --hostname=router-${MT_ENV}"
            - name: TS_KUBE_SECRET
              value: "tailscale-router-state"
            - name: TS_ACCEPT_DNS
              value: "false"
            - name: TS_USERSPACE
              value: "true"
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
      containers:
        - name: unbound
          # NLnet Labs Unbound — lightweight recursive DNS resolver
          image: mvance/unbound:1.22.0
          ports:
            - containerPort: 5353
              name: dns
              protocol: UDP
            - containerPort: 5353
              name: dns-tcp
              protocol: TCP
          volumeMounts:
            - name: unbound-config
              mountPath: /opt/unbound/etc/unbound/unbound.conf
              subPath: unbound.conf
              readOnly: true
          livenessProbe:
            exec:
              command: ["drill", "@127.0.0.1", "-p", "5353", "localhost"]
            initialDelaySeconds: 5
            periodSeconds: 30
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
      volumes:
        - name: unbound-config
          configMap:
            name: tailscale-router-unbound
      terminationGracePeriodSeconds: 10
