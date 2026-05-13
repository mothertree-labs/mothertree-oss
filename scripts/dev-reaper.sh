#!/usr/bin/env bash
# dev-reaper.sh — idle reaper for the on-demand dev LKE cluster. Runs via cron
# on the CI VM. If the dev cluster has been idle longer than IDLE_HOURS AND no
# Woodpecker pool lease is currently held, destroy it via
# scripts/destroy-dev-cluster.sh (which only touches phase1-dev resources;
# always-up VMs are preserved).
#
# Reads config from /etc/mothertree-reaper.env (templated by Ansible).
# Required keys:
#   IDLE_HOURS                                — defaults to 2 if unset
#   DEV_STATE_BUCKET, DEV_STATE_S3_ENDPOINT,
#   DEV_STATE_S3_KEY, DEV_STATE_S3_SECRET     — heartbeat bucket read access
#   VALKEY_HOST, VALKEY_PORT, VALKEY_PASSWORD — for lease check
#   REPO_DIR                                  — checkout used by destroy script
#   LINODE_CLI_TOKEN                          — for cluster-existence check + destroy
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  — for phase1-dev terraform state
#
# Logs everything to stdout; cron redirects to /var/log/dev-reaper.log.

set -euo pipefail

REAPER_ENV="${REAPER_ENV:-/etc/mothertree-reaper.env}"
if [ ! -f "$REAPER_ENV" ]; then
    echo "[dev-reaper] ERROR: $REAPER_ENV not found"
    exit 1
fi
# shellcheck disable=SC1090
set -a; source "$REAPER_ENV"; set +a

log() {
    echo "[dev-reaper $(date -Iseconds)] $*"
}

: "${IDLE_HOURS:=2}"
: "${VALKEY_HOST:=127.0.0.1}"
: "${VALKEY_PORT:=6379}"
: "${CLUSTER_LABEL:=matrix-cluster-dev}"

# Sanity-check the inputs we actually need to reach a "destroy" decision.
# Cluster-presence check needs LINODE_CLI_TOKEN. Heartbeat read needs the S3
# bucket creds. Lease check needs Valkey password. Destroy needs AWS_*.
: "${LINODE_CLI_TOKEN:?LINODE_CLI_TOKEN required in $REAPER_ENV}"
: "${DEV_STATE_BUCKET:?DEV_STATE_BUCKET required in $REAPER_ENV}"
: "${DEV_STATE_S3_ENDPOINT:?DEV_STATE_S3_ENDPOINT required in $REAPER_ENV}"
: "${DEV_STATE_S3_KEY:?DEV_STATE_S3_KEY required in $REAPER_ENV}"
: "${DEV_STATE_S3_SECRET:?DEV_STATE_S3_SECRET required in $REAPER_ENV}"
: "${VALKEY_PASSWORD:?VALKEY_PASSWORD required in $REAPER_ENV}"
: "${REPO_DIR:?REPO_DIR required in $REAPER_ENV}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required in $REAPER_ENV}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required in $REAPER_ENV}"

# ── 1. Cluster existence ────────────────────────────────────────────────────
# If there's no cluster, there's nothing to do. Exit before checking anything
# else, so a missing heartbeat (e.g. first install) doesn't trigger destroy.
EXISTING_ID=$(linode-cli lke clusters-list --json 2>/dev/null \
    | jq -r --arg label "$CLUSTER_LABEL" '.[] | select(.label==$label) | .id' \
    | head -n1 || true)

if [ -z "$EXISTING_ID" ] || [ "$EXISTING_ID" = "null" ]; then
    log "no '$CLUSTER_LABEL' cluster; nothing to do"
    exit 0
fi
log "found cluster id=$EXISTING_ID; checking idle state"

# ── 2. Heartbeat age ────────────────────────────────────────────────────────
# A missing heartbeat is treated as infinitely-idle (we already know a cluster
# exists; if nothing has written a heartbeat ever, it's been up since before
# heartbeating started — definitely stale).
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Normalize the endpoint URL — DEV_STATE_S3_ENDPOINT is the bucket-style
# hostname (e.g. `mothertree-dev-state.us-lax-1.linodeobjects.com`); aws-cli
# wants the cluster endpoint. See scripts/dev-heartbeat.sh for the full
# rationale.
case "$DEV_STATE_S3_ENDPOINT" in
    https://*) ENDPOINT_URL="$DEV_STATE_S3_ENDPOINT" ;;
    *)         ENDPOINT_URL="https://${DEV_STATE_S3_ENDPOINT#*.}" ;;
esac

# Use the bucket-scoped key for the heartbeat read (read_write). The TF state
# key is separately scoped to mothertree-tf-state-dev.
HB_RAW=$(AWS_ACCESS_KEY_ID="$DEV_STATE_S3_KEY" \
         AWS_SECRET_ACCESS_KEY="$DEV_STATE_S3_SECRET" \
         aws s3 cp "s3://${DEV_STATE_BUCKET}/last-used.txt" - \
              --endpoint-url "$ENDPOINT_URL" \
              --no-progress 2>/dev/null || true)

NOW=$(date +%s)
if [ -z "$HB_RAW" ]; then
    log "heartbeat missing in s3://${DEV_STATE_BUCKET}/last-used.txt — treating as infinitely idle"
    IDLE_SECS=$((10**9))
else
    if ! [[ "$HB_RAW" =~ ^[0-9]+$ ]]; then
        log "heartbeat value is non-numeric ($HB_RAW) — refusing to destroy"
        exit 1
    fi
    IDLE_SECS=$((NOW - HB_RAW))
    log "heartbeat ts=$HB_RAW idle=${IDLE_SECS}s"
fi

# Allow fractional hours (e.g. IDLE_HOURS=0.05 during reaper testing).
IDLE_THRESHOLD_SECS=$(awk -v h="$IDLE_HOURS" 'BEGIN {printf "%d", h*3600}')
if [ "$IDLE_SECS" -lt "$IDLE_THRESHOLD_SECS" ]; then
    log "still active (idle ${IDLE_SECS}s < ${IDLE_THRESHOLD_SECS}s); skipping destroy"
    exit 0
fi

# ── 3. Lease check ──────────────────────────────────────────────────────────
# Dev uses two pool leases; CI scripts acquire one of `ci-lease-pool1` /
# `ci-lease-pool2` per pipeline. If EITHER is held, a pipeline is mid-flight
# (even if its heartbeat has stalled for some reason) — do not destroy.
VKEY=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
if [ -z "$VKEY" ]; then
    log "ERROR: neither valkey-cli nor redis-cli available"
    exit 1
fi

for pool in pool1 pool2; do
    if "$VKEY" -h "$VALKEY_HOST" -p "$VALKEY_PORT" -a "$VALKEY_PASSWORD" \
              --no-auth-warning EXISTS "ci-lease-${pool}" 2>/dev/null | grep -qx '1'; then
        log "ci-lease-${pool} is held — a pipeline is mid-flight; skipping destroy"
        exit 0
    fi
done
log "no pool leases held"

# ── 4. Destroy ──────────────────────────────────────────────────────────────
log "idle for ${IDLE_SECS}s ≥ ${IDLE_THRESHOLD_SECS}s and no lease — destroying"

if [ ! -d "$REPO_DIR" ]; then
    log "ERROR: REPO_DIR=$REPO_DIR not found"
    exit 1
fi

# Pull latest code so we run with whatever destroy logic is on main.
log "syncing $REPO_DIR to origin/master"
git -C "$REPO_DIR" fetch --quiet origin
git -C "$REPO_DIR" reset --hard --quiet origin/master
git -C "$REPO_DIR" submodule update --init --recursive --quiet 2>/dev/null || true

# Files we write into the repo dir that contain the Linode API token / kubeconfig.
# Mode 0600 root-owned, but still: scrub on exit so a compromise of the
# woodpecker user (which can't read root-mode-0600 files but might gain it
# later) doesn't find them between reaper runs.
SECRETS_FILE="$REPO_DIR/secrets.tfvars.env"
KCFG="$REPO_DIR/kubeconfig.dev.yaml"
cleanup() {
    rm -f "$SECRETS_FILE" "$KCFG"
}
trap cleanup EXIT

# Write the minimal tfvars secrets the destroy script will source.
# phase1-dev only needs linode_token at variable level (others have defaults).
cat > "$SECRETS_FILE" <<EOF
# Reaper-generated; do not edit by hand. Regenerated on every reaper run.
export TF_VAR_linode_token="$LINODE_CLI_TOKEN"
EOF
chmod 0600 "$SECRETS_FILE"

# Fetch a fresh kubeconfig so destroy-dev-cluster.sh's K8s pre-sweep can talk
# to the cluster. linode-cli returns base64-encoded yaml in JSON.
log "fetching kubeconfig for cluster $EXISTING_ID"
KCFG_B64=$(linode-cli lke kubeconfig-view --json "$EXISTING_ID" 2>/dev/null \
    | jq -r '.[0].kubeconfig // empty')
if [ -z "$KCFG_B64" ]; then
    log "WARNING: could not fetch kubeconfig; destroy will skip K8s pre-sweep"
else
    echo "$KCFG_B64" | base64 -d > "$KCFG"
    chmod 0600 "$KCFG"
fi

log "invoking destroy-dev-cluster.sh"
"$REPO_DIR/scripts/destroy-dev-cluster.sh" -e dev

log "destroy complete"
