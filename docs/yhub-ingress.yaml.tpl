# Ingress for the Docs collaboration server (yhub, impress >= 6).
#
# Publishes ONLY the routes a browser needs (upstream's list, impress 6.0.0
# UPGRADE.md):
#   /collaboration/ws/        the editor websocket (/ws/v1/<org>/<document id>)
#   /collaboration/ydoc/      http fallback of the websocket
#   /collaboration/activity/  editing history
#   /collaboration/changeset/ editing history
#   /collaboration/rollback/  restore a document to a point in its history
#   /collaboration/jwks/      public keys, nothing else
# Everything else yhub serves (prune, create-ydoc, reset-connections, migrate,
# restore-ydoc, reset-ydoc) is backend-internal or granted to nobody and stays
# in-cluster: there is deliberately no /collaboration/ catch-all here, so those
# paths fall through to the frontend's "/" rule. Publishing them would put
# document deletion and the legacy migration one request away from the
# internet. The smoke spec docs-health.spec.ts checks both halves.
#
# No upstream-hash-by: the yhub replicas exchange updates through Redis, so a
# room needs no sticky upstream (the y-provider needed one).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: docs-yhub
  namespace: docs
  labels:
    app.kubernetes.io/name: docs-yhub
    app.kubernetes.io/part-of: mother-tree
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # Long-lived websockets (the y-provider ingress used the same window).
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    # The http fallback PATCHes Yjs updates to /collaboration/ydoc/.
    nginx.ingress.kubernetes.io/proxy-body-size: "20m"
    # nginx matches the location on the normalised path but proxies the RAW
    # request URI. A router that reads "\" as "/" or resolves ".." itself
    # (WHATWG URL parsing does both) could then see /collaboration/ws/..\migrate
    # as an admin route the allowlist above was meant to keep in-cluster. Refuse
    # any such URI outright (path only, before "?": query strings legitimately
    # carry %2F). "\\\\" is one literal backslash once nginx has unescaped the
    # string; verified against nginx with the URIs the smoke spec sends.
    # Document content is never cacheable (same header as the main ingress).
    nginx.ingress.kubernetes.io/configuration-snippet: |
      if ($request_uri ~* "^[^?]*(\.\.|\\\\|%2e|%5c|%2f)") {
        return 404;
      }
      add_header Cache-Control "no-store" always;
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${DOCS_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
  rules:
  - host: ${DOCS_HOST}
    http:
      paths:
      - path: /collaboration/ws/
        pathType: Prefix
        backend:
          service:
            name: yhub
            port:
              number: 3002
      - path: /collaboration/ydoc/
        pathType: Prefix
        backend:
          service:
            name: yhub
            port:
              number: 3002
      - path: /collaboration/activity/
        pathType: Prefix
        backend:
          service:
            name: yhub
            port:
              number: 3002
      - path: /collaboration/changeset/
        pathType: Prefix
        backend:
          service:
            name: yhub
            port:
              number: 3002
      - path: /collaboration/rollback/
        pathType: Prefix
        backend:
          service:
            name: yhub
            port:
              number: 3002
      - path: /collaboration/jwks/
        pathType: Prefix
        backend:
          service:
            name: yhub
            port:
              number: 3002
