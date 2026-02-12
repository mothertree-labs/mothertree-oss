apiVersion: v1
kind: ServiceAccount
metadata:
  name: jitsi-jvb
  namespace: matrix
  labels:
    app: jitsi-jvb
    component: jvb

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jitsi-jvb-node-reader
  labels:
    app: jitsi-jvb
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jitsi-jvb-node-reader
  labels:
    app: jitsi-jvb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jitsi-jvb-node-reader
subjects:
- kind: ServiceAccount
  name: jitsi-jvb
  namespace: matrix

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-jvb
  namespace: matrix
  labels:
    app: jitsi-jvb
    component: jvb
spec:
  replicas: ${JVB_MIN_REPLICAS}
  selector:
    matchLabels:
      app: jitsi-jvb
  strategy:
    # Recreate strategy required when using hostPort to avoid port conflicts during rollout
    type: Recreate
  template:
    metadata:
      labels:
        app: jitsi-jvb
        component: jvb
    spec:
      serviceAccountName: jitsi-jvb
      priorityClassName: critical-service  # Evicted last during resource pressure
      # Pod anti-affinity: one JVB per tenant per node (prevents hostPort conflicts)
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: jitsi-jvb
            topologyKey: "kubernetes.io/hostname"
      securityContext:
        runAsNonRoot: false  # JVB image requires root for s6-overlay init
        seccompProfile:
          type: RuntimeDefault
      # Init container to discover node's external IP (cloud K8s returns internal IP for status.hostIP)
      initContainers:
      - name: discover-external-ip
        image: alpine/kubectl:1.33.4
        imagePullPolicy: IfNotPresent
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        command:
        - /bin/sh
        - -c
        - |
          set -eu

          NODE_NAME="$(kubectl get pod "$POD_NAME" -n "$POD_NAMESPACE" -o jsonpath='{.spec.nodeName}')"
          if [ -z "$NODE_NAME" ]; then
            echo "ERROR: could not determine nodeName for pod $POD_NAMESPACE/$POD_NAME" >&2
            exit 1
          fi
          echo "Pod $POD_NAME is running on node: $NODE_NAME"

          EXTERNAL_IPS="$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' || true)"
          EXTERNAL_IP="$(echo "$EXTERNAL_IPS" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

          if [ -z "$EXTERNAL_IP" ]; then
            echo "ERROR: node $NODE_NAME has no IPv4 ExternalIP in .status.addresses[].type==ExternalIP" >&2
            echo "DEBUG: raw ExternalIP addresses: ${EXTERNAL_IPS:-<empty>}" >&2
            echo "DEBUG: node addresses:" >&2
            kubectl get node "$NODE_NAME" -o jsonpath='{range .status.addresses[*]}{.type}={.address}{"\n"}{end}' >&2 || true
            exit 1
          fi

          echo "Discovered node IPv4 ExternalIP: $EXTERNAL_IP"
          echo -n "$EXTERNAL_IP" > /shared/external-ip
        # Init container needs kubectl access; keep its current security settings
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true
        volumeMounts:
        - name: shared-data
          mountPath: /shared
      containers:
      - name: jvb
        image: jitsi/jvb:stable-10710
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add: ["SETUID", "SETGID", "CHOWN", "FOWNER"]
            drop: ["ALL"]
        # Read external IP from init container and set environment variables
        command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail

          PUBLIC_IP="$(cat /shared/external-ip)"
          if [ -z "$PUBLIC_IP" ]; then
            echo "ERROR: /shared/external-ip is empty; cannot start JVB" >&2
            exit 1
          fi

          if [ -z "${POD_IP:-}" ]; then
            echo "ERROR: POD_IP is not set; cannot start JVB" >&2
            exit 1
          fi

          # Ensure JVB advertises a reachable ICE candidate when running behind hostPort:
          # - local-address: pod IP (where JVB binds/harvests host candidates)
          # - public-address: node ExternalIP (where clients reach the hostPort)
          #
          # jvb.conf includes `include "custom-jvb.conf"` so we can safely override here.
          cat > /config/custom-jvb.conf <<EOF
          videobridge {
            ice {
              advertise-private-candidates = false
            }
          }

          ice4j {
            harvest {
              mapping {
                static-mappings = [
                  {
                    "local-address" = "${POD_IP}"
                    "public-address" = "${PUBLIC_IP}"
                  }
                ]
              }
            }
          }
          EOF

          echo "Configured ICE static mapping: ${POD_IP} -> ${PUBLIC_IP}"
          export DOCKER_HOST_ADDRESS="$PUBLIC_IP"
          export JVB_ADVERTISE_IPS="$PUBLIC_IP"
          exec /init
        volumeMounts:
        - name: shared-data
          mountPath: /shared
          readOnly: true
        ports:
        - containerPort: ${JVB_PORT}
          hostPort: ${JVB_PORT}  # Binds to node's port for direct UDP media access
          name: rtp-udp
          protocol: UDP
        - containerPort: 8080
          name: http
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: XMPP_SERVER
          value: "jitsi-prosody"
        - name: XMPP_DOMAIN
          value: "${JITSI_HOST}"
        - name: XMPP_MUC_DOMAIN
          value: "muc.${JITSI_HOST}"
        - name: XMPP_AUTH_DOMAIN
          value: "auth.${JITSI_HOST}"
        - name: XMPP_INTERNAL_MUC_DOMAIN
          value: "internal-muc.${JITSI_HOST}"
        - name: JVB_BREWERY_MUC
          value: "jvbbrewery"
        - name: JVB_PORT
          value: "${JVB_PORT}"
        - name: JVB_STUN_SERVERS
          value: "${TURN_SERVER_IP}:3478"
        - name: JVB_TCP_HARVESTER_DISABLED
          value: "1"
        - name: COLIBRI_REST_ENABLED
          value: "true"
        - name: JVB_AUTH_USER
          value: "jvb"
        - name: JVB_AUTH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: jitsi-secrets
              key: JVB_AUTH_PASSWORD
        livenessProbe:
          httpGet:
            path: /about/health
            port: 8080
        readinessProbe:
          httpGet:
            path: /about/health
            port: 8080
        # NOTE: If you change CPU request/limit values, update the threshold in
        # jitsi-dashboard-configmap.yaml gauge panel (id: 3). The green/yellow
        # threshold should be (request/limit * 100)%. Currently: 50m/3200m = 1.6%
        # Low request allows scheduling on smaller nodes; high limit allows burst for video
        # Memory tuned based on actual usage (~250Mi observed idle)
        resources:
          requests:
            cpu: 100m  # Minimum 100m to prevent HPA triggering on idle fluctuations
            memory: 300Mi
          limits:
            cpu: 3200m  # 80% of g6-standard-4 (4 cores)
            memory: 2Gi
      volumes:
      - name: shared-data
        emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jvb
  namespace: matrix
  labels:
    app: jitsi-jvb
    component: jvb
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/colibri/stats"
spec:
  # ClusterIP for internal access (metrics/health). External UDP uses hostPort directly.
  type: ClusterIP
  ports:
  - port: ${JVB_PORT}
    name: rtp-udp
    protocol: UDP
    targetPort: ${JVB_PORT}
  - port: 8080
    name: http
    targetPort: 8080
  selector:
    app: jitsi-jvb
