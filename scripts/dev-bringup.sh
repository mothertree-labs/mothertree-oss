#!/usr/bin/env bash
# dev-bringup.sh — Ensure the dev LKE cluster exists. Called from the
# Woodpecker `ensure-dev-cluster` step on every PR. Idempotent:
#   - If the cluster already exists: noop apart from a heartbeat touch.
#   - If missing: run `manage_infra -e dev --phase1` (which dispatches to
#     phase1-dev/) and `deploy_infra -e dev`, then touch the heartbeat.
#
# Required env (set by ci/scripts/ci-deploy.sh after vault decrypt):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY — for phase1-dev's S3 backend
#   LINODE_CLI_TOKEN                         — for cluster-existence check
#   DEV_STATE_BUCKET, DEV_STATE_S3_ENDPOINT, DEV_STATE_S3_KEY,
#   DEV_STATE_S3_SECRET                      — for the final heartbeat touch
#
# Plus everything `manage_infra` / `deploy_infra` themselves need
# (secrets.tfvars.env, kubeconfig path defaults to $REPO_ROOT/kubeconfig.dev.yaml).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

: "${LINODE_CLI_TOKEN:?LINODE_CLI_TOKEN is required (set in Woodpecker secrets)}"

CLUSTER_LABEL="${CLUSTER_LABEL:-matrix-cluster-dev}"

print_status "dev-bringup: checking for existing LKE cluster '$CLUSTER_LABEL'..."

# linode-cli reads token from LINODE_CLI_TOKEN env var (no config file needed).
# `--json` output keeps the parse robust against UI string changes.
EXISTING_ID=$(linode-cli lke clusters-list --json 2>/dev/null \
    | jq -r --arg label "$CLUSTER_LABEL" '.[] | select(.label==$label) | .id' \
    | head -n1 || true)

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
    print_success "dev-bringup: cluster exists (id=$EXISTING_ID); reusing"
else
    print_status "dev-bringup: no cluster found; provisioning..."

    # phase1-dev's S3 backend needs these env vars. Fail fast if missing —
    # the alternative (silent local backend fallback) would diverge from
    # operator state and is exactly the failure mode we built phase1-dev to
    # avoid.
    : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required for phase1-dev backend (vault: tf-state-creds.env)}"
    : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required for phase1-dev backend (vault: tf-state-creds.env)}"

    print_status "dev-bringup: running manage_infra --phase1..."
    "$REPO_ROOT/scripts/manage_infra" -e dev --phase1

    print_status "dev-bringup: running deploy_infra..."
    "$REPO_ROOT/scripts/deploy_infra" -e dev

    print_success "dev-bringup: cluster + infra ready"
fi

# Always touch the heartbeat. The whole point of the on-demand-dev flow is
# that the reaper destroys the cluster when no CI step has touched it for
# IDLE_HOURS — so even on the "cluster already exists" path we want to push
# the timestamp forward.
print_status "dev-bringup: touching heartbeat"
"$REPO_ROOT/scripts/dev-heartbeat.sh"

print_success "dev-bringup: complete"
