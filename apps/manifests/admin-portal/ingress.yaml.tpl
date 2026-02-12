apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: admin-portal
  namespace: ${NS_ADMIN}
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${ADMIN_HOST}
      secretName: admin-portal-tls
  rules:
    - host: ${ADMIN_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: admin-portal
                port:
                  number: 80
