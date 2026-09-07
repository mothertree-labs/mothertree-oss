# Tailscale sidecar components whose pre-auth key Secret the rotator verifies.
# Format: name|acl_tag|k8s_secret|namespace|deployment/<name>|pod_selector
# Components whose namespace or Deployment is absent in a cluster are skipped
# (e.g. the federation pair exists only where metrics_federation.role is set).
pgbouncer|tag:pgbouncer|pgbouncer-tailscale-auth|${NS_DB}|deployment/pgbouncer|app=pgbouncer
metrics|tag:monitoring|pg-metrics-bridge-tailscale-auth|${NS_DB}|deployment/pg-metrics-bridge|app=pg-metrics-bridge
router|tag:router|tailscale-router-auth|${NS_INGRESS_INTERNAL}|deployment/tailscale-router|app=tailscale-router
bridge|tag:monitoring|prometheus-eu-bridge-tailscale-auth|${NS_MONITORING}|deployment/prometheus-eu-bridge|app=prometheus-eu-bridge
expose|tag:monitoring|prometheus-mesh-expose-tailscale-auth|${NS_MONITORING}|deployment/prometheus-mesh-expose|app=prometheus-mesh-expose
