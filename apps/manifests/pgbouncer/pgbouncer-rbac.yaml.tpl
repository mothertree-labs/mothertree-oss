---
# ServiceAccount for PgBouncer pods (Tailscale sidecar needs Secret access)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pgbouncer
  namespace: ${NS_DB}
  labels:
    app: pgbouncer
---
# Role granting the Tailscale sidecar permission to manage its state Secret
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pgbouncer-tailscale
  namespace: ${NS_DB}
  labels:
    app: pgbouncer
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pgbouncer-tailscale
  namespace: ${NS_DB}
  labels:
    app: pgbouncer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pgbouncer-tailscale
subjects:
  - kind: ServiceAccount
    name: pgbouncer
    namespace: ${NS_DB}
