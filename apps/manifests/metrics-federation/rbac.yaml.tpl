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
# (${FED_NAME}-tailscale-state, fixed name) and nothing else in the namespace:
# get/update/patch are name-restricted to that one Secret (containerboot only
# ever touches TS_KUBE_SECRET — the auth key arrives via a secretKeyRef env),
# so the sidecar's ServiceAccount cannot read the Grafana / Alertmanager
# Secrets that share infra-monitoring. `create` cannot be name-restricted in
# RBAC (the request carries no name) and is needed on first start.
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
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["${FED_NAME}-tailscale-state"]
    verbs: ["get", "update", "patch"]
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
