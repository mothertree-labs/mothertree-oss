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
| (deploy script) | both | `${FED_NAME}-tailscale-auth` — minted via the Headscale API by `scripts/lib/tailscale-keys.sh`, re-verified on every deploy and daily by the key rotator |
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
  source_env: "prod-eu"          # optional: only match the exposer of this env (prom-mesh-prod-eu)
  source_mesh_ip: "100.64.x.x"   # optional FALLBACK, used only when no exposer is online
```

The consumer does **not** need the exposer's IP in config: at deploy time it
looks up the online `tag:monitoring` node advertising hostname
`prom-mesh-<source_env>` (any `prom-mesh-*` node when `source_env` is unset)
through the Headscale API and renders that address into socat. A stale
`source_mesh_ip` only produces a warning; two online exposers or none (with no
fallback) fail the deploy.

## Node identity (why the mesh IP is stable)

Both pods run their Tailscale sidecar with a **fixed-name** state Secret
(`<name>-tailscale-state`, like the subnet router), so a pod recreation
re-registers the *same* Headscale node and keeps its mesh IP. Until 2026-09 the
Secret was per pod name, and every recreation of the exposer produced a new
node with a new IP that the consumer's static config never learned — the
federation silently died on 2026-09-02 (audit cause 7).

Migration is automatic: on the first deploy with this layout the script copies
the running pod's per-pod state Secret under the fixed name *before* rolling
the Deployment (only if that pod's sidecar is Running and online — a dead
registration is never adopted). The superseded per-pod Secrets are pruned once
their pod is gone, and the `headscale-cleanup` CronJob removes federation nodes
that have been offline for 48h+.

Infra tenant `<env>.secrets.yaml` (both prod and prod-eu):

```yaml
tailscale:
  rotator_api_key: "<Headscale API key>"   # headscale apikeys create --expiration 87600h
```

The deploy script mints the sidecar's reusable `tag:monitoring` pre-auth key
through the Headscale API on first deploy and re-verifies it on every deploy;
the `tailscale-key-rotator` CronJob does the same daily. No pre-auth key is
stored anywhere.

## Operator bootstrap (run in order)

1. **prod-eu config**: make sure `tailscale.rotator_api_key` is set in the
   prod-eu infra secrets (it already is if the key rotator runs there), then set
   `metrics_federation.role: exposer` in the prod-eu infra config.

2. **Deploy the exposer**:
   ```bash
   ./scripts/deploy_infra -e prod-eu
   # the script ends by printing the exposer's Headscale node and mesh IP —
   # informational only, the consumer discovers it itself.
   ```

3. **ACL**: `{"src":["tag:monitoring"],"dst":["tag:monitoring:9090"]}` in
   `ansible/templates/headscale-acl-policy.json.j2`. Redeploy it:
   ```bash
   ./ci/scripts/provision-ci.sh --ansible-only   # or the headscale playbook tag that runs "Deploy ACL policy"
   ```

4. **prod config**: set `metrics_federation.role: consumer` (and, recommended,
   `metrics_federation.source_env: prod-eu`) in the prod infra config.

5. **Deploy the consumer + datasource**:
   ```bash
   ./scripts/deploy_infra -e prod
   ```
   The deploy fails if the exposer's Prometheus does not answer through the
   tunnel (`/-/ready`), and `MetricsFederationDown` fires on the consumer
   cluster if the path breaks later (Prometheus scrapes the bridge, which is
   answered by the remote Prometheus through the tunnel; only one series is kept).

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

## Key rotation

Both sidecars are listed in `apps/manifests/tailscale-key-rotator/components.conf.tpl`
(`bridge` = prometheus-eu-bridge, `expose` = prometheus-mesh-expose), so the daily
`tailscale-key-rotator` CronJob and `./scripts/check-tailscale-keys -e <env>` verify
their auth Secrets like every other sidecar. Because the pods keep a fixed-name
state Secret, a restart re-registers the existing node and Headscale does not
re-validate the pre-auth key (same as the subnet router) — the key still has to
be live for the day the node identity is lost and a fresh registration happens.
