apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jitsi-web
  namespace: matrix
  labels:
    app: jitsi-web
    component: web
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/priority: "50"
    # Allow iframe embedding for Matrix integration
    nginx.ingress.kubernetes.io/server-snippet: |
      more_clear_headers "X-Frame-Options";
      add_header Content-Security-Policy "frame-ancestors 'self' https://${MATRIX_HOST} https://${HOME_HOST}" always;
      add_header Permissions-Policy "camera=(self), microphone=(self), geolocation=()" always;
spec:
  tls:
  - hosts:
    - ${JITSI_HOST}
    secretName: jitsi-tls
  rules:
  - host: ${JITSI_HOST}
    http:
      paths:
      - path: /http-bind
        pathType: Prefix
        backend:
          service:
            name: jitsi-prosody
            port:
              number: 5280
      - path: /
        pathType: Prefix
        backend:
          service:
            name: jitsi-web
            port:
              number: 80
