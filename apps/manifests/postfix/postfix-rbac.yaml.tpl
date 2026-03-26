---
# ServiceAccount for Postfix pods (Tailscale sidecar needs Secret access)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postfix
  namespace: ${NS_MAIL}
  labels:
    app: postfix
---
# Role granting the Tailscale sidecar permission to manage its state Secret
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: postfix-tailscale
  namespace: ${NS_MAIL}
  labels:
    app: postfix
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: postfix-tailscale
  namespace: ${NS_MAIL}
  labels:
    app: postfix
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: postfix-tailscale
subjects:
  - kind: ServiceAccount
    name: postfix
    namespace: ${NS_MAIL}
