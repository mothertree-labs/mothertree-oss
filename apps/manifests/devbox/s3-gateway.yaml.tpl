# devbox only (scripts/devbox up): an in-cluster S3 for a developer box.
#
# versitygw serves a POSIX directory over the S3 API. Buckets are plain
# top-level directories, created by the init container, so no S3 client is
# needed to bootstrap them. One throwaway root key serves every bucket.
#
# Two ways in:
#   https://${DEVBOX_S3_HOST}       via ingress-nginx — what browsers follow
#                                   (Docs redirects /media/ to presigned URLs);
#                                   pods reach the same name through the
#                                   devbox CoreDNS rewrite.
#   http://versitygw.infra-s3.svc:7070  in-cluster, for Synapse (store-only).
#
# Variables: DEVBOX_S3_HOST, DEVBOX_S3_REGION, DEVBOX_S3_BUCKETS
# (space-separated), DEVBOX_S3_KEY_SHA (hash of the root key, never the key). The root key is the Secret s3-root, created by
# scripts/devbox from the generated tenant secrets.
apiVersion: v1
kind: Namespace
metadata:
  name: infra-s3
  labels:
    app.kubernetes.io/part-of: mothertree-devbox
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: versitygw-data
  namespace: infra-s3
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: versitygw
  namespace: infra-s3
  labels:
    app: versitygw
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: versitygw
  template:
    metadata:
      labels:
        app: versitygw
      annotations:
        # Restart when the root key changes (it is read from env at start).
        checksum/s3-root: "${DEVBOX_S3_KEY_SHA}"
    spec:
      initContainers:
        - name: buckets
          image: versity/versitygw:v1.10.0
          command: ["/bin/sh", "-c", "for b in ${DEVBOX_S3_BUCKETS}; do mkdir -p \"/data/$b\"; done; ls /data"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: data
              mountPath: /data
      containers:
        - name: versitygw
          image: versity/versitygw:v1.10.0
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          env:
            - name: VGW_BACKEND
              value: posix
            - name: VGW_BACKEND_ARG
              value: /data
            - name: VGW_REGION
              value: "${DEVBOX_S3_REGION}"
            - name: ROOT_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-root
                  key: access_key
            - name: ROOT_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-root
                  key: secret_key
          ports:
            - name: s3
              containerPort: 7070
          readinessProbe:
            tcpSocket:
              port: s3
            periodSeconds: 5
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: versitygw-data
---
apiVersion: v1
kind: Service
metadata:
  name: versitygw
  namespace: infra-s3
spec:
  selector:
    app: versitygw
  ports:
    - name: s3
      port: 7070
      targetPort: s3
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: versitygw
  namespace: infra-s3
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["${DEVBOX_S3_HOST}"]
      secretName: versitygw-tls
  rules:
    - host: ${DEVBOX_S3_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: versitygw
                port:
                  name: s3
