# One-time migration: split phase1 dev workspace → phase1-dev

This is an operator-run, one-time migration. Run it on your laptop with full
access to the dev workspace, the Linode account, and your password manager.
Until you complete it, the dev workspace's `terraform plan` against `phase1/`
will want to destroy the LKE cluster, the VPC, the VPC subnet, and
`local_file.kubeconfig` — those resources are now declared in `phase1-dev/`
and need to be re-homed.

CI cannot run this. `terraform state rm` / `terraform import` mutate state, so
they're operator-only.

## Why this split exists

The dev cluster is now on-demand: CI brings it up, an idle reaper destroys it.
Both code paths need to read/write durable state, but Terraform state for
`phase1/` lives on the operator's laptop. The fix is to give the dev cluster
its own Terraform root (`phase1-dev/`) with a Linode Object Storage backend.

Everything else — prod, prod-eu, the dev always-up VMs (postgres-dev,
headscale-dev, turn-server-dev) — keeps its state in `phase1/` and is
**not** touched by this migration.

## Prerequisites

- `terraform` >= 1.11 (`use_lockfile = true` in the S3 backend is a 1.11
  feature). Check with `terraform version`.
- `linode-cli` installed and authenticated against the same account that owns
  the dev cluster.
- `lpass` (LastPass CLI) logged in for storing the new credentials.
- Working directory: the repo root (`~/code/mothertree`).

## Step 1 — Create the Terraform-state bucket

Create the bucket Terraform's S3 backend will write to. Region `us-lax-1`
(matches the dev LKE cluster's region).

```bash
linode-cli obj mb mothertree-tf-state-dev --cluster us-lax-1
```

Verify it landed:

```bash
linode-cli obj la --cluster us-lax-1 | grep mothertree-tf-state-dev
```

## Step 2 — Create a scoped access key for the state bucket

This key only has access to `mothertree-tf-state-dev` — not the heartbeat
bucket (which Terraform manages separately), not any tenant S3 buckets.

```bash
linode-cli object-storage keys-create \
  --label "tf-state-dev" \
  --bucket_access '[{"region":"us-lax","bucket_name":"mothertree-tf-state-dev","permissions":"read_write"}]'
```

Capture the `access_key` and `secret_key` from the output.

## Step 3 — Store the credentials

Save them in LastPass as a new entry named `mothertree-tf-state-dev-s3-credentials`.

Then add to your gitignored secrets env (whichever one you currently source
when running `manage_infra` — typically `secrets.dev.tfvars.env` for dev work,
or `secrets.tfvars.env` if you've consolidated):

```bash
export AWS_ACCESS_KEY_ID="<access_key from step 2>"
export AWS_SECRET_ACCESS_KEY="<secret_key from step 2>"
```

Terraform's S3 backend uses `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for
authentication even against non-AWS S3 — these names are required.

## Step 4 — Back up the current dev state

```bash
cd phase1
terraform workspace select dev
terraform state pull > /tmp/dev-state-backup-pre-split.tfstate
```

Keep this backup until the next dev destroy/recreate cycle has succeeded
end-to-end. If anything goes wrong below, you can restore with:

```bash
terraform state push /tmp/dev-state-backup-pre-split.tfstate
```

## Step 5 — Capture the resource IDs you need for import

```bash
terraform state show 'module.lke_cluster.linode_lke_cluster.cluster' | grep '^id'
terraform state show 'module.lke_cluster.linode_vpc.cluster_vpc'     | grep '^id'
terraform state show 'module.lke_cluster.linode_vpc_subnet.cluster_subnet' | grep -E '^(id|vpc_id)'
```

You'll get three IDs. Write them down:

- `LKE_CLUSTER_ID` — e.g. `123456`
- `VPC_ID` — e.g. `78901`
- `VPC_SUBNET_ID` — e.g. `234567` (and remember its parent `vpc_id`)

If `terraform state show` is awkward, an equivalent lookup with `linode-cli`:

```bash
linode-cli lke clusters-list --json | jq '.[] | select(.label=="matrix-cluster-dev") | .id'
linode-cli vpcs list --json       | jq '.[] | select(.label=="matrix-cluster-dev-vpc") | {id, subnets: [.subnets[] | {id, label}]}'
```

## Step 6 — Remove the LKE resources from the phase1 dev workspace

This is the destructive-looking but actually safe step: `state rm` removes
the resources from Terraform's tracking, but the real Linode resources
continue to exist. You'll re-attach them to `phase1-dev`'s state in step 8.

```bash
# Still in phase1/, with the dev workspace selected.
terraform state rm \
  'module.lke_cluster.linode_lke_cluster.cluster' \
  'module.lke_cluster.linode_vpc.cluster_vpc' \
  'module.lke_cluster.linode_vpc_subnet.cluster_subnet' \
  'local_file.kubeconfig'
```

Confirm the LKE cluster, VPC, and subnet still exist in Linode (they should):

```bash
linode-cli lke clusters-list --json | jq '.[] | select(.label=="matrix-cluster-dev") | .id'
```

## Step 7 — Initialise the phase1-dev backend

```bash
cd ../phase1-dev
terraform init
```

Terraform will report that it's writing the initial state to the S3 bucket.
If it complains about credentials, double-check that step 3's env vars are
exported in the current shell.

## Step 8 — Import the LKE resources into phase1-dev

The subnet import takes a compound ID: `<vpc_id>,<subnet_id>`.

```bash
terraform import \
  -var-file="$(pwd)/../terraform.tfvars" \
  -var-file="$(pwd)/../terraform.dev.tfvars" \
  'module.lke_cluster.linode_lke_cluster.cluster' "$LKE_CLUSTER_ID"

terraform import \
  -var-file="$(pwd)/../terraform.tfvars" \
  -var-file="$(pwd)/../terraform.dev.tfvars" \
  'module.lke_cluster.linode_vpc.cluster_vpc' "$VPC_ID"

terraform import \
  -var-file="$(pwd)/../terraform.tfvars" \
  -var-file="$(pwd)/../terraform.dev.tfvars" \
  'module.lke_cluster.linode_vpc_subnet.cluster_subnet' "$VPC_ID,$VPC_SUBNET_ID"
```

`local_file.kubeconfig` is recreated from `module.lke_cluster.kubeconfig` on
the next apply — no manual import is needed (the file is at
`../kubeconfig.dev.yaml` and will be overwritten).

## Step 9 — Verify a zero-diff plan

```bash
terraform plan \
  -var-file="$(pwd)/../terraform.tfvars" \
  -var-file="$(pwd)/../terraform.dev.tfvars"
```

Expected outcome:

- No changes to `module.lke_cluster.linode_lke_cluster.cluster`.
- No changes to `module.lke_cluster.linode_vpc.cluster_vpc`.
- No changes to `module.lke_cluster.linode_vpc_subnet.cluster_subnet`.
- `local_file.kubeconfig` will create (writes the kubeconfig file from the
  cluster's output — this is fine; the file already exists with the same
  content from the prior phase1 apply).
- `linode_object_storage_bucket.dev_state` will create.
- `linode_object_storage_key.dev_state` will create.

If any of the first three resources show a `~ update` or `-/+ replace`, stop
and reconcile the diff against the on-Linode state before proceeding.

## Step 10 — Apply

```bash
terraform apply \
  -var-file="$(pwd)/../terraform.tfvars" \
  -var-file="$(pwd)/../terraform.dev.tfvars"
```

This creates the heartbeat bucket + scoped access key and re-writes
`../kubeconfig.dev.yaml`.

## Step 11 — Verify the phase1 dev workspace still applies cleanly

```bash
cd ../phase1
terraform workspace select dev
terraform plan -refresh=false \
  -var-file=../terraform.tfvars \
  -var-file=../terraform.dev.tfvars \
  -var env=dev \
  -var env_dns_label=dev \
  -var jitsi_tester_enabled=false
```

Expected: only the dev always-up VMs (postgres-dev, headscale-dev,
turn-server-dev) and their firewalls/SSH keys should be in the plan. No LKE,
no VPC, no kubeconfig.

## Step 12 — Final sanity: rerun manage_infra end-to-end

```bash
./scripts/manage_infra -e dev --phase1
```

This re-runs both Terraform roots (phase1 dev workspace + phase1-dev) back to
back. The resulting `terraform-outputs.dev.env` should include
`DEV_STATE_BUCKET`, `DEV_STATE_S3_KEY`, `DEV_STATE_S3_SECRET`, and a non-empty
`LKE_CLUSTER_ID`. CI will read these via the existing deploy-vault flow.

## Rollback

If something has gone catastrophically wrong:

1. `cd phase1 && terraform workspace select dev`
2. `terraform state push /tmp/dev-state-backup-pre-split.tfstate`
3. Drop the `phase1-dev/` directory from your local checkout (don't commit
   the revert) and re-run `manage_infra -e dev --phase1`. The dev workspace
   will look the way it did before the migration.
4. Delete the `mothertree-tf-state-dev` bucket and the scoped key.
