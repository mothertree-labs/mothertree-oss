apiVersion: v1
kind: ServiceAccount
metadata:
  name: tailscale-router
  namespace: ${NS_INGRESS_INTERNAL}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tailscale-router
  namespace: ${NS_INGRESS_INTERNAL}
rules:
  # Tailscale state persistence (node identity across restarts)
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tailscale-router
  namespace: ${NS_INGRESS_INTERNAL}
subjects:
  - kind: ServiceAccount
    name: tailscale-router
roleRef:
  kind: Role
  name: tailscale-router
  apiGroup: rbac.authorization.k8s.io
