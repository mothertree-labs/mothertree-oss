#!/bin/bash
# Helper script to ensure Synapse rate limits are configured
# Called automatically by create_env before Synapse deployment
# This ensures rate limits are present without manual intervention

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APPS_DIR="$REPO_ROOT/apps"

ENVIRONMENT="${1:-}"

if [[ -z "$ENVIRONMENT" ]]; then
    echo "[ERROR] Environment not specified" >&2
    exit 1
fi

ENV_FILE="$APPS_DIR/environments/$ENVIRONMENT/synapse.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] Synapse config not found: $ENV_FILE" >&2
    exit 1
fi

# Rate limit configuration file - MUST exist
RATE_LIMIT_CONFIG_FILE="$REPO_ROOT/matrix.$ENVIRONMENT.config.yml"

if [[ ! -f "$RATE_LIMIT_CONFIG_FILE" ]]; then
    echo "[ERROR] Rate limit config file not found: $RATE_LIMIT_CONFIG_FILE" >&2
    echo "[ERROR] This file is required. Please create it with rate_limits section." >&2
    exit 1
fi

# Verify we can read the file
if [[ ! -r "$RATE_LIMIT_CONFIG_FILE" ]]; then
    echo "[ERROR] Cannot read rate limit config file: $RATE_LIMIT_CONFIG_FILE" >&2
    exit 1
fi

echo "[INFO] Reading rate limits from: $RATE_LIMIT_CONFIG_FILE"

# Check if rate limits already exist
if grep -q "rc_message:" "$ENV_FILE"; then
    echo "[INFO] Rate limits already configured in $ENV_FILE"
    echo "[INFO] Skipping rate limit application (already present)"
    # Still show what rate limits are configured
    echo "[INFO] Current rate limits in config:"
    grep -A 50 "rc_message:" "$ENV_FILE" | head -30 || true
    exit 0
fi

echo "[INFO] Adding rate limit configuration to $ENV_FILE..."

# Create backup
cp "$ENV_FILE" "$ENV_FILE.backup.$(date +%Y%m%d_%H%M%S)"
echo "[INFO] Created backup: $ENV_FILE.backup.*"

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo "[ERROR] yq is required but not installed" >&2
    echo "[ERROR] Install with: brew install yq" >&2
    exit 1
fi

# Read and validate rate limit config file
if ! yq eval '.rate_limits' "$RATE_LIMIT_CONFIG_FILE" >/dev/null 2>&1; then
    echo "[ERROR] Failed to read or parse rate limit config file: $RATE_LIMIT_CONFIG_FILE" >&2
    exit 1
fi

# Check if rate_limits section exists and is not empty
RATE_LIMITS_COUNT=$(yq eval '.rate_limits | length' "$RATE_LIMIT_CONFIG_FILE" 2>/dev/null || echo "0")
if [ "$RATE_LIMITS_COUNT" = "0" ] || [ -z "$RATE_LIMITS_COUNT" ]; then
    echo "[ERROR] 'rate_limits' section not found or is empty in config file" >&2
    echo "[ERROR] Config file: $RATE_LIMIT_CONFIG_FILE" >&2
    exit 1
fi

# Print rate limits that will be applied
echo ""
echo "[INFO] Rate limits loaded from config file:"
echo "======================================================================"
yq eval '.rate_limits' "$RATE_LIMIT_CONFIG_FILE" -P
echo "======================================================================"

# Create temporary file for the updated config
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Read the synapse config file
if ! yq eval '.' "$ENV_FILE" > "$TEMP_FILE" 2>/dev/null; then
    echo "[ERROR] Failed to read synapse config file: $ENV_FILE" >&2
    exit 1
fi

# Ensure extraConfig exists
if ! yq eval '.extraConfig' "$TEMP_FILE" >/dev/null 2>&1; then
    yq eval '.extraConfig = {}' -i "$TEMP_FILE"
fi

# Merge rate limits into extraConfig (only if not already present)
added_count=0
for key in $(yq eval '.rate_limits | keys | .[]' "$RATE_LIMIT_CONFIG_FILE" 2>/dev/null); do
    # Check if this rate limit already exists
    if yq eval ".extraConfig.$key" "$TEMP_FILE" >/dev/null 2>&1 && [ "$(yq eval ".extraConfig.$key" "$TEMP_FILE" 2>/dev/null)" != "null" ]; then
        echo "[INFO] Rate limit '$key' already exists in config, skipping"
    else
        # Add the rate limit
        RATE_LIMIT_VALUE=$(yq eval ".rate_limits.$key" "$RATE_LIMIT_CONFIG_FILE" -o json)
        yq eval ".extraConfig.$key = $RATE_LIMIT_VALUE" -i "$TEMP_FILE"
        added_count=$((added_count + 1))
    fi
done

# Write back to the original file
if ! yq eval '.' "$TEMP_FILE" > "$ENV_FILE" 2>/dev/null; then
    echo "[ERROR] Failed to write synapse config file: $ENV_FILE" >&2
    exit 1
fi

if [ $added_count -gt 0 ]; then
    echo ""
    echo "[SUCCESS] =========================================================="
    echo "[SUCCESS] Rate limits applied successfully!"
    echo "[SUCCESS] Added $added_count rate limit configuration(s)"
    echo "[SUCCESS] Configuration file: $ENV_FILE"
    echo "[SUCCESS] Rate limits will be active after Synapse pod restart"
    echo "[SUCCESS] =========================================================="
    echo ""
else
    echo ""
    echo "[INFO] All rate limits were already present in configuration"
    echo "[INFO] No changes needed"
fi

if [[ $? -ne 0 ]]; then
    echo "[ERROR] Failed to add rate limits" >&2
    exit 1
fi
