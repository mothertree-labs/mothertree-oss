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
      # IP forwarding must be enabled for subnet routing. LKE forbids pod-level
      # sysctls, so we use a privileged init container to set it at runtime.
      initContainers:
        - name: enable-ip-forward
          image: tailscale/tailscale:v1.94.2
          command:
            - sh
            - -c
            - |
              sysctl -w net.ipv4.ip_forward=1
              # NAT/masquerade traffic forwarded from tailscale0 to eth0.
              # Without this, the internal ingress sees the laptop's Tailscale IP
              # as the source and can't route the response back (no route for 100.64.0.0/10).
              iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
          securityContext:
            privileged: true
        # Tailscale subnet router — native sidecar, starts after ip_forward is set.
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
      containers:
        - name: unbound
          # NLnet Labs Unbound — lightweight recursive DNS resolver
          image: mvance/unbound:1.22.0
          ports:
            - containerPort: 53
              name: dns
              protocol: UDP
            - containerPort: 53
              name: dns-tcp
              protocol: TCP
          volumeMounts:
            - name: unbound-config
              mountPath: /opt/unbound/etc/unbound/unbound.conf
              subPath: unbound.conf
              readOnly: true
          livenessProbe:
            exec:
              command: ["drill", "@127.0.0.1", "-p", "53", "localhost"]
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
