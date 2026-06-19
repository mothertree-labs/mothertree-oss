---
# Registers the prod-eu Prometheus as a Grafana datasource in the PROD cluster,
# reached over the Headscale mesh via the prometheus-eu-bridge consumer pod.
# Picked up by the kube-prometheus-stack Grafana datasource sidecar
# (watches ConfigMaps labelled grafana_datasource: "1").
#
# Deployed ONLY in the consumer cluster (prod). The uid `prometheus-eu` is the
# stable handle dashboards use in a $datasource template variable to switch
# between the local cluster and prod-eu.
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-eu-datasource
  namespace: ${NS_MONITORING}
  labels:
    grafana_datasource: "1"
    component: metrics-federation
data:
  prometheus-eu.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus (prod-eu)
        type: prometheus
        uid: prometheus-eu
        access: proxy
        url: http://prometheus-eu-bridge.${NS_MONITORING}.svc.cluster.local:9090
        isDefault: false
        editable: false
        jsonData:
          httpMethod: POST
          # Cross-cluster hop over the mesh — allow a little extra headroom.
          timeout: 60
