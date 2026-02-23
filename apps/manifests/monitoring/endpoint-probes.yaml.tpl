# Per-tenant endpoint Probe CRD — monitors external and internal tenant services
# External endpoints are probed via external FQDNs (full path: DNS -> Cloudflare -> LB -> ingress)
# Internal endpoints are probed via K8s ClusterIP services
# Deployed per tenant by create_env. Feature-flag targets are injected by the deploy script.
#
# Variables substituted by envsubst:
#   TENANT, NS_MONITORING, TENANT_KEYCLOAK_REALM, AUTH_HOST, NS_MATRIX
#   PROBE_MODULE_HTTP, PROBE_MODULE_SYNAPSE (env-specific: _ext for dev SOCKS proxy)
#   ENDPOINT_PROBE_TARGETS (built dynamically by create_env based on feature flags)
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: ${TENANT}-endpoints
  namespace: ${NS_MONITORING}
  labels:
    release: kube-prometheus-stack
    tenant: ${TENANT}
spec:
  jobName: ${TENANT}-endpoints
  interval: 60s
  module: ${PROBE_MODULE_HTTP}
  prober:
    url: prometheus-blackbox-exporter.${NS_MONITORING}.svc.cluster.local:9115
  targets:
    staticConfig:
      labels:
        probe_type: tenant
        tenant: ${TENANT}
      static:
${ENDPOINT_PROBE_TARGETS}
---
# Synapse API probe — validates Matrix federation endpoint returns version JSON
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: ${TENANT}-synapse-api
  namespace: ${NS_MONITORING}
  labels:
    release: kube-prometheus-stack
    tenant: ${TENANT}
spec:
  jobName: ${TENANT}-synapse-api
  interval: 60s
  module: ${PROBE_MODULE_SYNAPSE}
  prober:
    url: prometheus-blackbox-exporter.${NS_MONITORING}.svc.cluster.local:9115
  targets:
    staticConfig:
      labels:
        probe_type: tenant
        tenant: ${TENANT}
      static:
        - https://${MATRIX_HOST}/_matrix/client/versions
---
# Internal service probes (K8s ClusterIP, no external DNS needed)
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: ${TENANT}-internal
  namespace: ${NS_MONITORING}
  labels:
    release: kube-prometheus-stack
    tenant: ${TENANT}
spec:
  jobName: ${TENANT}-internal
  interval: 60s
  module: http_2xx_internal
  prober:
    url: prometheus-blackbox-exporter.${NS_MONITORING}.svc.cluster.local:9115
  targets:
    staticConfig:
      labels:
        probe_type: tenant-internal
        tenant: ${TENANT}
      static:
        - http://synapse-admin.${NS_MATRIX}.svc.cluster.local/
