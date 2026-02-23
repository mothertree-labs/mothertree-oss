apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: home-page
  namespace: ${NS_HOME}
  labels:
    app.kubernetes.io/name: home
    app.kubernetes.io/part-of: ${TENANT_NAME}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${HOME_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
  rules:
  - host: ${HOME_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: home-page
            port:
              number: 80
