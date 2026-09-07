---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_DB}
  labels:
    app: tailscale-key-rotator
---
# Namespace-scoped Roles (not ClusterRole) — least privilege per namespace.
# Per namespace the rotator needs to: read + patch the named auth Secrets, read +
# patch the named Deployments (rollout restart, rollout polling), and list pods +
# read the tailscale sidecar's log to prove the new key authenticated. It never
# creates Secrets: bootstrap belongs to the deploy scripts (`create` cannot be
# name-restricted, so a missing Secret is a rotator error, not a silent create).
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
    verbs: ["get", "update", "patch"]
    resourceNames: ["pgbouncer-tailscale-auth", "pg-metrics-bridge-tailscale-auth"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
    resourceNames: ["pgbouncer", "pg-metrics-bridge"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
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
  namespace: ${NS_INGRESS_INTERNAL}
  labels:
    app: tailscale-key-rotator
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "update", "patch"]
    resourceNames: ["tailscale-router-auth"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
    resourceNames: ["tailscale-router"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
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
---
# Cross-cluster metrics federation sidecars (prometheus-eu-bridge on the
# consumer, prometheus-mesh-expose on the exposer). Their Secrets were seeded
# by hand in June and had no rotator coverage until #613.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_MONITORING}
  labels:
    app: tailscale-key-rotator
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "update", "patch"]
    resourceNames: ["prometheus-eu-bridge-tailscale-auth", "prometheus-mesh-expose-tailscale-auth"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
    resourceNames: ["prometheus-eu-bridge", "prometheus-mesh-expose"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tailscale-key-rotator
  namespace: ${NS_MONITORING}
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
