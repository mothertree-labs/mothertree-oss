---
name: terraform-researcher
description: "Research Terraform infrastructure — modules, variables, state, provisioning logic. Use when understanding or modifying infrastructure-as-code, DNS configuration, or cloud resource provisioning."
allowed-tools: ["Read", "Glob", "Grep"]
---

# Terraform Infrastructure Researcher

## Your Task

Research Terraform infrastructure code to answer the user's question. Understand module structure, variable flow, and resource provisioning.

## Two-Phase Terraform Structure

### Phase 1: Cloud Infrastructure (`phase1/`)

**Files**: `phase1/main.tf`, `phase1/variables.tf`, `phase1/outputs.tf`

**Providers**: linode (~>2.0), cloudflare (~>4.0), kubernetes (~>2.0), null (~>3.0)

**Resources provisioned**:
- LKE Kubernetes cluster (via `modules/lke-cluster/`)
- Headscale VM (via `modules/headscale/`) — self-hosted Tailscale control plane
- PostgreSQL VM (via `modules/postgres-server/`) — dedicated external DB per env
- TURN server (for Matrix/Jitsi video calls)
- Jitsi tester VM (optional, `--jitsi_tester=yes`)
- Base DNS records (via `modules/dns/`)
- Kubeconfig file generation

**Workspaces**: One per environment — `terraform workspace select prod` or `dev`

**State**: `phase1/terraform.tfstate.d/<env>/terraform.tfstate`

**Key variables** (from `terraform.tfvars` + `terraform.dev.tfvars` + `secrets.tfvars.env`):
- `linode_token`, `linode_region` (us-lax), `linode_k8s_version`
- `linode_node_pools` (list of {type, count, tags, autoscaler})
- `cloudflare_api_token`, `cloudflare_zone_id`
- `domain`, `env`, `cluster_label`
- `ssh_public_key`

**Key outputs**: `kubeconfig`, `turn_server_ip`, `headscale_ip`, `postgres_server_ip`

### Phase 2: Kubernetes Infrastructure (`infra/`)

**Files**: `infra/main.tf`, `infra/variables.tf`, `infra/outputs.tf`

**Reads Phase 1 state via**:
```hcl
data "terraform_remote_state" "phase1" {
  backend = "local"
  config = { path = "../phase1/terraform.tfstate.d/${var.env}/terraform.tfstate" }
}
```

**Resources provisioned**:
- cert-manager ClusterIssuers (HTTP-01 and DNS-01)
- Postfix Deployment + Service (with OpenDKIM sidecar)
- ConfigMaps: postfix-config, opendkim-config, postfix-init-scripts
- DNS records via `modules/dns/` (LB A record: `lb2.prod`/`lb1.<label>`, mail, turn A records; tenant CNAMEs)

**Templates** (in `infra/templates/`):
- `postfix-main.cf.tpl` — Postfix configuration
- `postfix-master.cf` — Postfix process config
- `postfix-aliases.tpl` — Mail aliases
- `opendkim.conf.tpl` — DKIM signing config

## Terraform Modules

| Module | Path | Purpose |
|--------|------|---------|
| lke-cluster | `modules/lke-cluster/` | LKE cluster provisioning (node pools, HA control plane) |
| dns | `modules/dns/` | Cloudflare DNS records (A, CNAME, SRV, MX) |
| headscale | `modules/headscale/` | Headscale VM (self-hosted Tailscale control plane) |
| postgres-server | `modules/postgres-server/` | Dedicated PostgreSQL VM per environment |
| helm-bootstrap | `modules/helm-bootstrap/` | Helm provider initialization |

## Variable Flow

```
secrets.tfvars.env (credentials)
    | sourced by scripts
terraform.tfvars (common config)
terraform.dev.tfvars (dev overrides)
    | passed via -var-file
phase1/variables.tf -> phase1/main.tf -> phase1/outputs.tf
                                              | remote state
                                    infra/main.tf (reads phase1 outputs)
```

## Where to Look

- **Cloud resources**: `phase1/main.tf`
- **K8s infrastructure resources**: `infra/main.tf`
- **DNS records**: `modules/dns/main.tf`
- **Variable definitions**: `*/variables.tf`
- **Variable values**: `terraform.tfvars`, `terraform.dev.tfvars`
- **Secrets**: `secrets.tfvars.env` (env file, gitignored)
- **Postfix templates**: `infra/templates/`

## Response Format

Return:
1. **Where the resource/variable is defined** — exact file path
2. **What it does** — resource purpose and configuration
3. **Dependencies** — what depends on it, what it depends on
4. **How to modify** — which files to change and any workspace considerations
