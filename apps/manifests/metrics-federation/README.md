# Cross-Cluster Metrics Federation

Lets **grafana.prod** query the **prod-eu** Prometheus over the existing Headscale
mesh, so every cluster's metrics show up in a single Grafana viewer (grafana.prod)
without moving any time-series data between clusters.

## Why a bridge (and not just a datasource URL)

`grafana.prod` runs in the prod LKE cluster; prod-eu's Prometheus is a plain
ClusterIP in a *different* cluster. You can't route cluster IPs across the two
clusters — prod and prod-eu both use Service CIDR `10.128.0.0/16`, so they
collide (this is also why the Tailscale subnet router only advertises the
internal-ingress `/32`). The only stable cross-cluster address is a **mesh IP**.

So we mirror the proven `pg-metrics-bridge` pattern (socat + native Tailscale
sidecar) on **both** sides:

```
grafana.prod ──ClusterIP──▶ prometheus-eu-bridge        (PROD, role: consumer)
                              │ socat :9090
                              │ Tailscale sidecar (tag:monitoring)
                              ▼ mesh 100.64.x.x:9090
                   ┌──── Headscale mesh ────┐
                              ▼
            prometheus-mesh-expose          (PROD-EU, role: exposer)
                              │ Tailscale sidecar (tag:monitoring, mesh IP X)
                              │ socat :9090
                              ▼ ClusterIP
            kube-prometheus-stack-prometheus:9090   (prod-eu)
```

Grafana itself never joins the mesh; only the two tiny bridge pods do.

## Resources

| File | Role | Notes |
|---|---|---|
| `deployment.yaml.tpl` | both | socat + native Tailscale sidecar, `Recreate`, 1 replica |
| `service.yaml.tpl` | both | ClusterIP `:9090` (consumer side is what Grafana hits) |
| `secret.yaml.tpl` | both | `${FED_NAME}-tailscale-auth` (bootstrap only; then key-rotator owns it) |
| `rbac.yaml.tpl` | both | SA + Role for the sidecar's state Secret |
| `grafana-datasource.configmap.yaml.tpl` | consumer | registers `Prometheus (prod-eu)` (uid `prometheus-eu`) |

Deployed by `apps/deploy-metrics-federation.sh`, wired into `scripts/deploy_infra`.
Feature-gated by `metrics_federation.role` in the infra config — **no-op when unset**
(so dev and any not-yet-enabled env are unaffected).

## Required config (private `config/platform` submodule)

`config/platform/infra/<env>.config.yaml`:

```yaml
# prod-eu
metrics_federation:
  role: exposer

# prod
metrics_federation:
  role: consumer
  source_mesh_ip: "100.64.x.x"   # the prod-eu exposer's assigned mesh IP (step 2 below)
```

`config/platform/infra/<env>.secrets.yaml` (both prod and prod-eu):

```yaml
tailscale:
  metrics_authkey: "<reusable tag:monitoring pre-auth key>"
```

prod already has `metrics_authkey` (pg-metrics-bridge). **prod-eu likely does not** —
mint one (see step 1).

## Operator bootstrap (run in order)

1. **prod-eu key**: mint a reusable `tag:monitoring` pre-auth key and set
   `tailscale.metrics_authkey` in the prod-eu infra secrets:
   ```bash
   ./scripts/rotate-tailscale-keys.sh -e prod-eu   # or mint manually on the Headscale VM:
   #   headscale preauthkeys create --user <infra-id> --reusable --expiration 8760h --tags tag:monitoring
   ```
   Set `metrics_federation.role: exposer` in the prod-eu infra config.

2. **Deploy the exposer + capture its mesh IP**:
   ```bash
   ./scripts/deploy_infra -e prod-eu
   # then read the assigned 100.64.x.x of node "prom-mesh-prod-eu":
   ssh root@<headscale-vm> 'headscale nodes list' | grep prom-mesh-prod-eu
   ```

3. **ACL**: this PR adds `{"src":["tag:monitoring"],"dst":["tag:monitoring:9090"]}`
   to `ansible/templates/headscale-acl-policy.json.j2`. Redeploy it:
   ```bash
   ./ci/scripts/provision-ci.sh --ansible-only   # or the headscale playbook tag that runs "Deploy ACL policy"
   ```

4. **prod config**: set `metrics_federation.role: consumer` **and**
   `metrics_federation.source_mesh_ip: <ip from step 2>` in the prod infra config.

5. **Deploy the consumer + datasource**:
   ```bash
   ./scripts/deploy_infra -e prod
   ```

## Verify

```bash
# prod-eu exposer healthy & on the mesh
kubectl --kubeconfig=kubeconfig.prod-eu.yaml -n infra-monitoring get pod -l app=prometheus-mesh-expose

# prod consumer healthy
kubectl --kubeconfig=kubeconfig.prod.yaml -n infra-monitoring get pod -l app=prometheus-eu-bridge

# from grafana.prod: Connections → Data sources → "Prometheus (prod-eu)" → Save & test  (should be green)
# or, in-cluster:
kubectl --kubeconfig=kubeconfig.prod.yaml -n infra-monitoring run q --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s 'http://prometheus-eu-bridge.infra-monitoring:9090/api/v1/query?query=up' | head -c 200
```

## Using it in dashboards

The datasource uid is **`prometheus-eu`**. To make an existing dashboard
switchable between clusters, add a `datasource` template variable (type
*Data source*, query `prometheus`) and replace each panel's hardcoded
`"uid": "prometheus"` with `"uid": "${datasource}"`. That retrofit is the
dashboard-revamp follow-up, tracked separately.

## Known follow-up

`scripts/rotate-tailscale-keys.sh` / `scripts/lib/tailscale-keys.sh` only rotate
the `pgbouncer` and `metrics` (pg-metrics-bridge) components today. The two bridge
pods here reuse the shared `tag:monitoring` key and — because tagged Headscale
nodes don't key-expire by default — run fine without per-component rotation. If you
later want their bootstrap auth-key Secrets refreshed on rotation, add
`prometheus-mesh-expose` / `prometheus-eu-bridge` entries to those scripts.
