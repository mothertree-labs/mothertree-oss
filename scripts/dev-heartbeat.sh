#!/usr/bin/env bash
# dev-heartbeat.sh — write a Unix timestamp to the dev-state Object Storage
# bucket. Called from every CI step that uses the dev cluster, so the idle
# reaper has a fresh "last used" signal.
#
# Required env (set by ci/scripts/ci-deploy.sh from the deploy vault's
# terraform-outputs.dev.env after Phase 2/3 phase1-dev migration):
#   DEV_STATE_BUCKET       — bucket name (e.g. mothertree-dev-state)
#   DEV_STATE_S3_ENDPOINT  — endpoint URL (e.g. https://us-lax-1.linodeobjects.com)
#   DEV_STATE_S3_KEY       — access key
#   DEV_STATE_S3_SECRET    — secret key
#
# Fails loud on missing creds per CLAUDE.md fail-fast rule. Caller is expected
# to `|| true` if heartbeat failure shouldn't fail the parent step (typical
# pattern in CI exit traps — the heartbeat going stale is non-fatal for a
# single pipeline run).
set -euo pipefail

: "${DEV_STATE_BUCKET:?DEV_STATE_BUCKET is required (set by ci-deploy.sh from terraform-outputs.dev.env)}"
: "${DEV_STATE_S3_ENDPOINT:?DEV_STATE_S3_ENDPOINT is required}"
: "${DEV_STATE_S3_KEY:?DEV_STATE_S3_KEY is required}"
: "${DEV_STATE_S3_SECRET:?DEV_STATE_S3_SECRET is required}"

# Use AWS_* env vars for the aws CLI; the dev-state access key is bucket-scoped
# (read_write on $DEV_STATE_BUCKET only) per phase1-dev/main.tf.
export AWS_ACCESS_KEY_ID="$DEV_STATE_S3_KEY"
export AWS_SECRET_ACCESS_KEY="$DEV_STATE_S3_SECRET"
# AWS_DEFAULT_REGION is required by the v2 CLI even though Linode ignores it.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

TS=$(date +%s)
echo "[dev-heartbeat] writing ts=$TS to s3://$DEV_STATE_BUCKET/last-used.txt"

# Normalize the endpoint URL. `linode_object_storage_bucket.hostname` (which
# manage_infra writes into terraform-outputs.dev.env as DEV_STATE_S3_ENDPOINT)
# returns a bucket-style hostname like
# `mothertree-dev-state.us-lax-1.linodeobjects.com`. aws-cli's --endpoint-url
# wants the cluster endpoint without the bucket prefix; otherwise the SDK
# constructs `https://<bucket>.<endpoint>/<key>` and ends up with a doubled
# bucket name. Strip everything up to the first dot to get the cluster host.
case "$DEV_STATE_S3_ENDPOINT" in
    https://*) ENDPOINT_URL="$DEV_STATE_S3_ENDPOINT" ;;
    *)         ENDPOINT_URL="https://${DEV_STATE_S3_ENDPOINT#*.}" ;;
esac

# Use stdin to avoid creating a temp file. `aws s3 cp - s3://...` reads stdin.
printf '%s' "$TS" | aws s3 cp - "s3://${DEV_STATE_BUCKET}/last-used.txt" \
    --endpoint-url "$ENDPOINT_URL" \
    --content-type "text/plain" \
    --no-progress

echo "[dev-heartbeat] ok"
