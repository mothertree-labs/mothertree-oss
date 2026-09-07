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
  # Tailscale state persistence (node identity across restarts). get/update/
  # patch are name-restricted to the fixed state Secret (containerboot touches
  # only TS_KUBE_SECRET; the auth key arrives via a secretKeyRef env), so the
  # router's ServiceAccount cannot read other Secrets in its namespace.
  # `create` cannot be name-restricted in RBAC and is needed on first start.
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["tailscale-router-state"]
    verbs: ["get", "update", "patch"]
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
