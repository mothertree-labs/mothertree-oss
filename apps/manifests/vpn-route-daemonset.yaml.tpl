---
# VPN Route DaemonSet
# Adds a static route on each node to reach the VPN server's private IP
# This enables pods to connect to the VPN server for mail relay, etc.
#
# The VPN_SERVER_PRIVATE_IP is substituted by deploy_infra from Terraform outputs
apiVersion: v1
kind: ConfigMap
metadata:
  name: vpn-route-config
  namespace: kube-system
  labels:
    app: vpn-route-manager
data:
  VPN_SERVER_PRIVATE_IP: "${VPN_SERVER_PRIVATE_IP}"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vpn-route-manager
  namespace: kube-system
  labels:
    app: vpn-route-manager
spec:
  selector:
    matchLabels:
      app: vpn-route-manager
  template:
    metadata:
      labels:
        app: vpn-route-manager
    spec:
      hostNetwork: true
      tolerations:
        # Run on all nodes including control plane
        - operator: Exists
      containers:
        - name: route-manager
          image: alpine:3.18
          command:
            - /bin/sh
            - -c
            - |
              set -e
              apk add --no-cache iproute2 >/dev/null 2>&1
              
              VPN_IP="$VPN_SERVER_PRIVATE_IP"
              if [ -z "$VPN_IP" ]; then
                echo "ERROR: VPN_SERVER_PRIVATE_IP not set"
                exit 1
              fi
              
              echo "VPN Route Manager starting for VPN server: $VPN_IP"
              
              # Add route for VPN server private IP (direct via eth0)
              # Linode legacy private network is layer 2, so direct routing works
              add_route() {
                if ! ip route show | grep -q "$VPN_IP"; then
                  echo "Adding route to $VPN_IP via eth0..."
                  ip route add "$VPN_IP/32" dev eth0 || echo "Route may already exist"
                fi
              }
              
              # Initial route add
              add_route
              
              # Keep running and periodically ensure route exists
              # (in case of network reconfiguration)
              while true; do
                sleep 60
                add_route
              done
          env:
            - name: VPN_SERVER_PRIVATE_IP
              valueFrom:
                configMapKeyRef:
                  name: vpn-route-config
                  key: VPN_SERVER_PRIVATE_IP
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              add: ["NET_ADMIN"]
              drop: ["ALL"]
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
      terminationGracePeriodSeconds: 5
