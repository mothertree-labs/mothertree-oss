---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
---
# Namespace-scoped Roles (not ClusterRole) — least privilege per namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "update", "patch"]
    resourceNames: ["pgbouncer-tailscale-auth", "pg-metrics-bridge-tailscale-auth"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
    resourceNames: ["pgbouncer", "pg-metrics-bridge"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tailscale-key-rotator
subjects:
  - kind: ServiceAccount
    name: tailscale-key-rotator
    namespace: ${NS_DB}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_MAIL}
  labels:
    app: tailscale-key-rotator
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "update", "patch"]
    resourceNames: ["postfix-tailscale-auth"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
    resourceNames: ["postfix"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_MAIL}
  labels:
    app: tailscale-key-rotator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tailscale-key-rotator
subjects:
  - kind: ServiceAccount
    name: tailscale-key-rotator
    namespace: ${NS_DB}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_INGRESS_INTERNAL}
  labels:
    app: tailscale-key-rotator
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "update", "patch"]
    resourceNames: ["tailscale-router-auth"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
    resourceNames: ["tailscale-router"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_INGRESS_INTERNAL}
  labels:
    app: tailscale-key-rotator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tailscale-key-rotator
subjects:
  - kind: ServiceAccount
    name: tailscale-key-rotator
    namespace: ${NS_DB}
