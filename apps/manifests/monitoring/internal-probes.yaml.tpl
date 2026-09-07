# Per-tenant INTERNAL Probe CRD — K8s ClusterIP services, no public DNS or
# ingress in the path, so these work in every environment and create_env
# deploys them unconditionally. The PUBLIC-endpoint probes live in
# endpoint-probes.yaml.tpl and are only deployed where a pod can actually
# reach the tenant's public hosts (see the endpoint-probes section of create_env).
#
# Variables substituted by envsubst:
#   TENANT, NS_MONITORING, NS_MATRIX
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
