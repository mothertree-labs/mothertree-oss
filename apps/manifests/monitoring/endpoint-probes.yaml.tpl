# Per-tenant PUBLIC endpoint Probe CRDs — the tenant's external FQDNs, fetched
# from inside the cluster over the full client path (DNS -> [Cloudflare] ->
# NodeBalancer -> ingress). Deployed per tenant by create_env ONLY where that
# path works from a pod: PROXY protocol off on this env's ingress, or
# Cloudflare-proxied tenant DNS. Where neither holds (dev), kube-proxy
# short-circuits the LB IP straight to ingress-nginx, which then rejects the
# PROXY-header-less connection — see the endpoint-probes section of create_env.
# Internal ClusterIP probes live in internal-probes.yaml.tpl (unconditional).
#
# Variables substituted by envsubst:
#   TENANT, NS_MONITORING, MATRIX_HOST
#   PROBE_MODULE_HTTP, PROBE_MODULE_SYNAPSE — must exist in
#     apps/values/blackbox-exporter.yaml (create_env guards this: an unknown
#     module is an HTTP 400 from blackbox, i.e. TargetDown forever)
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
