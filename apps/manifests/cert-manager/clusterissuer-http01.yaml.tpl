apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${TLS_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            # Must be ingressClassName, NOT the legacy `class:` field. cert-manager
            # >=1.12 maps `class:` to the deprecated kubernetes.io/ingress.class
            # annotation, which our ingress-nginx (watching ingressClassName) ignores
            # — the ACME solver Ingress then gets no backend and the self-check / LE
            # fetch returns 404, deadlocking every HTTP-01 challenge. Validated on
            # cert-manager v1.13.3 against the prod-eu ingress 2026-06-13.
            ingressClassName: nginx
