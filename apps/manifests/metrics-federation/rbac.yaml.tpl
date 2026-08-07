---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${FED_NAME}
  namespace: ${NS_MONITORING}
  labels:
    app: ${FED_NAME}
    component: metrics-federation
---
# Role granting the Tailscale sidecar permission to manage its state Secret
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${FED_NAME}-tailscale
  namespace: ${NS_MONITORING}
  labels:
    app: ${FED_NAME}
    component: metrics-federation
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${FED_NAME}-tailscale
  namespace: ${NS_MONITORING}
  labels:
    app: ${FED_NAME}
    component: metrics-federation
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${FED_NAME}-tailscale
subjects:
  - kind: ServiceAccount
    name: ${FED_NAME}
    namespace: ${NS_MONITORING}
