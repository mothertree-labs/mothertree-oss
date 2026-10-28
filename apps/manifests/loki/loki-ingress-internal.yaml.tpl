---
# Loki internal ingress — allows VM-based Vector agents (Headscale, PG, etc.)
# to push logs to Loki via the Tailscale mesh and internal ingress.
# Only reachable from inside the cluster or via the mesh subnet router.
# Applied by deploy_infra; the host must match the loki_push_url manage_infra
# hands the VMs' Vector (loki.<env label, "prod" for prod>.<infra domain>).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: loki
  namespace: infra-monitoring
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    # Coarse per-controller-pod request cap only: it counts requests, not bytes,
    # and keys on the client IP. Loki's own ingestion_rate_mb is the real bound.
    nginx.ingress.kubernetes.io/limit-rps: "20"
spec:
  ingressClassName: nginx-internal
  rules:
  - host: ${LOKI_INTERNAL_HOST}
    http:
      paths:
      # Push only: Loki runs with auth_enabled: false, and every pod in the
      # cluster passes the internal ingress allowlist, so routing "/" would let
      # any tenant pod read all tenants' logs through the query API.
      - path: /loki/api/v1/push
        pathType: Exact
        backend:
          service:
            name: loki
            port:
              number: 3100
