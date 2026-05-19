apiVersion: v1
kind: ServiceAccount
metadata:
  name: nextcloud-install
  namespace: ${NS_FILES}
  labels:
    app.kubernetes.io/name: nextcloud
    app.kubernetes.io/component: install
    app.kubernetes.io/part-of: mother-tree
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nextcloud-install
  namespace: ${NS_FILES}
  labels:
    app.kubernetes.io/name: nextcloud
    app.kubernetes.io/component: install
    app.kubernetes.io/part-of: mother-tree
rules:
  # Tight scope: only the nextcloud-identity Secret in this namespace.
  # create + get for first-run; update for the rare re-run path (409 PUT in
  # install-job.yaml.tpl).
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["nextcloud-identity"]
    verbs: ["create", "get", "update"]
  # Secret creation requires list scoped to the type without resourceNames
  # filtering at the API level (the K8s authorizer matches on POST without a
  # name), so allow create at the resource level. (resourceNames filtering
  # applies to verbs that target a specific named object.)
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nextcloud-install
  namespace: ${NS_FILES}
  labels:
    app.kubernetes.io/name: nextcloud
    app.kubernetes.io/component: install
    app.kubernetes.io/part-of: mother-tree
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: nextcloud-install
subjects:
  - kind: ServiceAccount
    name: nextcloud-install
    namespace: ${NS_FILES}
