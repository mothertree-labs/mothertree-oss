apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: account-portal
  namespace: ${NS_ADMIN}
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header Cache-Control "no-store" always;
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${ACCOUNT_HOST}
      secretName: wildcard-tls-${TENANT_NAME}
  rules:
    - host: ${ACCOUNT_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: account-portal
                port:
                  number: 80
