---
# Synapse Admin ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-admin-config
  namespace: ${NS_MATRIX}
data:
  config.json: |
    {
      "server_name": "${MATRIX_SERVER_NAME}",
      "server_url": "https://${SYNAPSE_HOST}",
      "registration_shared_secret": "${MATRIX_REGISTRATION_SHARED_SECRET}"
    }
---
# Synapse Admin Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: synapse-admin
  namespace: ${NS_MATRIX}
  labels:
    app: synapse-admin
spec:
  replicas: ${SYNAPSE_ADMIN_MIN_REPLICAS}
  selector:
    matchLabels:
      app: synapse-admin
  template:
    metadata:
      labels:
        app: synapse-admin
    spec:
      securityContext:
        runAsNonRoot: false  # NGINX requires root to bind port 80
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: synapse-admin
          image: awesometechnologies/synapse-admin:0.11.1
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              add: ["SETUID", "SETGID", "CHOWN"]  # NGINX drops from root to nginx user
              drop: ["ALL"]
          ports:
            - containerPort: 80
              name: http
          resources:
            requests:
              cpu: 100m  # Minimum 100m to prevent HPA triggering on idle fluctuations
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: config
              mountPath: /app/config.json
              subPath: config.json
      volumes:
        - name: config
          configMap:
            name: synapse-admin-config
---
# Synapse Admin Service
apiVersion: v1
kind: Service
metadata:
  name: synapse-admin
  namespace: ${NS_MATRIX}
spec:
  selector:
    app: synapse-admin
  ports:
    - port: 80
      targetPort: 80
      name: http
  type: ClusterIP
---
# Synapse Admin Ingress
# SECURITY: This service MUST be VPN-only (nginx-internal ingress class).
# The config.json served to the browser contains the registration_shared_secret,
# which allows anyone with access to register admin accounts on the Matrix
# homeserver. Synapse Admin does not support prompting for this secret at login;
# it must be embedded in config.json. Restricting access to the VPN is the
# primary mitigation against unauthorized admin account creation.
# Uses DNS-01 challenge since internal ingress is not publicly reachable for HTTP-01.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: synapse-admin
  namespace: ${NS_MATRIX}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod-dns01
    kubernetes.io/ingress.class: nginx-internal
spec:
  ingressClassName: nginx-internal
  tls:
    - hosts:
        - ${SYNAPSE_ADMIN_HOST}
      secretName: synapse-admin-tls
  rules:
    - host: ${SYNAPSE_ADMIN_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: synapse-admin
                port:
                  number: 80
