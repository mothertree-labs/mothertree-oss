# Protect PostgreSQL in infra-db — Only Allow Known Client Namespaces
# PostgreSQL is shared infrastructure hosting databases for all tenants.
# This policy restricts access to port 5432 from only the namespaces that
# legitimately need database access, preventing unauthorized pods from
# connecting to the database.
#
# Allowed namespaces:
#   - tn-<tenant>-matrix  (Synapse)
#   - tn-<tenant>-docs    (Docs backend)
#   - tn-<tenant>-files   (Nextcloud)
#   - tn-<tenant>-mail    (Stalwart)
#   - tn-<tenant>-webmail (Roundcube)
#   - tn-<tenant>-admin   (Admin Portal db-init jobs)
#   - infra-auth          (Keycloak)
#   - infra-monitoring    (Grafana)
#
# Uses the built-in kubernetes.io/metadata.name label which Kubernetes automatically
# sets on all namespaces (no manual labeling required).
#
# Required environment variables:
#   TENANT_NAME - Tenant identifier (e.g., example)
#
# NOTE: This policy is applied to the infra-db namespace (not per-tenant).
# For multi-tenant setups, run this once per tenant to accumulate allow rules.
# Kubernetes NetworkPolicies are additive — multiple policies on the same pod
# combine their allow rules (union), so each tenant's policy adds its namespaces.

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-db-from-${TENANT_NAME}
  namespace: infra-db
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: protect-infra-db
    tenant: ${TENANT_NAME}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
  policyTypes:
    - Ingress
  ingress:
    # Tenant namespaces that need database access
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-matrix
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-docs
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-files
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-mail
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-webmail
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-admin
      ports:
        - protocol: TCP
          port: 5432

---
# Also allow infra services to reach PostgreSQL
# This is separate so it's always present regardless of tenant
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-db-from-infra
  namespace: infra-db
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: protect-infra-db
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
  policyTypes:
    - Ingress
  ingress:
    # Keycloak (infra-auth)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-auth
      ports:
        - protocol: TCP
          port: 5432
    # Grafana/Monitoring (infra-monitoring)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-monitoring
      ports:
        - protocol: TCP
          port: 5432
