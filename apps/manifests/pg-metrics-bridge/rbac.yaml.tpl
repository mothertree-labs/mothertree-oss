---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pg-metrics-bridge
  namespace: ${NS_DB}
  labels:
    app: pg-metrics-bridge
---
# Role granting the Tailscale sidecar permission to manage its state Secret
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pg-metrics-bridge-tailscale
  namespace: ${NS_DB}
  labels:
    app: pg-metrics-bridge
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pg-metrics-bridge-tailscale
  namespace: ${NS_DB}
  labels:
    app: pg-metrics-bridge
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pg-metrics-bridge-tailscale
subjects:
  - kind: ServiceAccount
    name: pg-metrics-bridge
    namespace: ${NS_DB}
