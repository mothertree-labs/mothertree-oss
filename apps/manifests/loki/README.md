# Loki Logging Stack

Centralized log aggregation: **Vector** (DaemonSet) collects logs from all pods and ships them to **Loki**, queryable via **Grafana**.

## Grafana Query Examples

### Basic queries

```logql
# All logs from a namespace
{namespace="tn-example-admin"}

# Clean message-only output (recommended)
{namespace="tn-example-admin"} | json | line_format "{{.message}}"

# With level prefix
{namespace="tn-example-admin"} | json | line_format "{{.level}} | {{.message}}"
```

### Filtering by label

```logql
# All errors across the cluster
{level="error"} | json | line_format "{{.namespace}} {{.pod_name}}: {{.message}}"

# All tenant logs
{tier="tenant"} | json | line_format "{{.message}}"

# Infrastructure errors only
{tier="infra", level="error"} | json | line_format "{{.pod_name}}: {{.message}}"

# Specific pod
{pod_name="matrix-synapse-abc123"} | json | line_format "{{.message}}"

# stderr only
{namespace="tn-example-matrix", stream="stderr"} | json | line_format "{{.message}}"
```

### Text search within messages

```logql
# Search for a keyword
{namespace="tn-example-matrix"} |= "federation" | json | line_format "{{.message}}"

# Regex search
{tier="tenant"} |~ "(?i)timeout|connection refused" | json | line_format "{{.pod_name}}: {{.message}}"

# Exclude noisy lines
{namespace="infra-monitoring"} != "healthcheck" | json | line_format "{{.message}}"
```

### Aggregation (for dashboards / alerting)

```logql
# Error rate by namespace (count per 5m)
sum by (namespace) (count_over_time({level="error"}[5m]))

# Log volume by tier
sum by (tier) (count_over_time({job="kubernetes-pods"}[5m]))

# Top 10 noisiest pods
topk(10, sum by (pod_name) (count_over_time({job="kubernetes-pods"}[1h])))
```

## Available Labels

| Label | Values | Description |
|-------|--------|-------------|
| `namespace` | `infra-monitoring`, `tn-example-matrix`, ... | Kubernetes namespace |
| `tier` | `infra`, `tenant`, `system` | Derived from namespace prefix |
| `level` | `error`, `warn`, `info`, `debug`, `unknown` | Extracted from log content |
| `stream` | `stdout`, `stderr` | Output stream |
| `pod_name` | | Pod name |
| `container_name` | | Container name |
| `node_name` | | Node the pod runs on |
| `app` | | From pod `app` label |

## Log Body Fields

Each log line is JSON with these fields (use `| json` to parse):

| Field | Description |
|-------|-------------|
| `message` | The original log message |
| `image` | Container image (e.g. `redis:8-alpine`) |
| `component` | From pod `component` label (if set) |
| `msg` | Clean message extracted from JSON-structured logs |

## Architecture

```
Pods (all namespaces)
  → Vector DaemonSet (4 pods, one per node)
    → Loki StatefulSet (infra-monitoring, 10Gi PVC)
      → Grafana (Explore / Dashboards)
```

- **Retention**: 7 days (`reject_old_samples_max_age: 168h`)
- **Storage**: Filesystem-backed with BoltDB index, 10Gi PVC
- **Alerts**: LokiDown, LokiRequestErrors, LokiStorageHigh, VectorDown, VectorSinkErrors, VectorNoLogsIngested
