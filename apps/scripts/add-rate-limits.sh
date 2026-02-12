#!/bin/bash
# Script to safely add rate limit configuration to all Synapse environment files
# This ensures consistency across all environments to avoid deployment disasters

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APPS_DIR="$REPO_ROOT/apps"

print_status() {
    echo "ℹ️  $*"
}

print_success() {
    echo "✅ $*"
}

print_error() {
    echo "❌ $*" >&2
}

print_warning() {
    echo "⚠️  $*"
}

# Rate limit configuration to add
RATE_LIMIT_CONFIG='  # Rate limiting configuration
  rc_message:
    per_second: 2.0      # Allow 2 messages per second (default: 0.2)
    burst_count: 50      # Allow bursts of up to 50 messages (default: 10)
  
  rc_login:
    address:
      per_second: 1.0     # Allow 1 login per second per IP (default: 0.003)
      burst_count: 10    # Allow bursts of up to 10 logins (default: 5)
    account:
      per_second: 0.5    # Allow 0.5 logins per second per account (default: 0.003)
      burst_count: 5     # Allow bursts of up to 5 logins (default: 5)
    failed_attempts:
      per_second: 1.0     # Allow 1 failed login per second (default: 0.17)
      burst_count: 10    # Allow bursts of up to 10 failed logins (default: 3)
  
  rc_joins:
    local:
      per_second: 0.5     # Allow 0.5 joins per second (default: 0.1)
      burst_count: 20    # Allow bursts of up to 20 joins (default: 10)
    remote:
      per_second: 0.1     # Allow 0.1 remote joins per second (default: 0.01)
      burst_count: 10    # Allow bursts of up to 10 remote joins (default: 10)'

print_status "This script will add rate limit configuration to Synapse extraConfig"
print_warning "This will modify files in apps/environments/*/synapse.yaml"
echo ""
read -p "Continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    print_status "Aborted"
    exit 0
fi

# Process each environment file
ENVIRONMENTS=("dev" "prod")

for env in "${ENVIRONMENTS[@]}"; do
    ENV_FILE="$APPS_DIR/environments/$env/synapse.yaml"
    
    if [[ ! -f "$ENV_FILE" ]]; then
        print_error "File not found: $ENV_FILE"
        continue
    fi
    
    print_status "Processing: $ENV_FILE"
    
    # Check if rate limits already exist
    if grep -q "rc_message:" "$ENV_FILE"; then
        print_warning "  Rate limits already exist - skipping"
        continue
    fi
    
    # Create backup
    cp "$ENV_FILE" "$ENV_FILE.backup"
    print_success "  Created backup: $ENV_FILE.backup"
    
    # Find the line number where we should insert (after oidc_providers section ends)
    # We'll insert before the last closing of any nested structure
    
    # Use Python to safely insert the rate limit config
    python3 <<PYTHON_SCRIPT
import yaml
import sys

file_path = "$ENV_FILE"

# Read the file
with open(file_path, 'r') as f:
    content = f.read()
    data = yaml.safe_load(content)

# Add rate limit config to extraConfig
if 'extraConfig' not in data:
    data['extraConfig'] = {}

# Parse the rate limit config string
rate_limit_yaml = """$RATE_LIMIT_CONFIG"""
rate_limit_data = yaml.safe_load(rate_limit_yaml)

# Merge rate limits into extraConfig
for key, value in rate_limit_data.items():
    data['extraConfig'][key] = value

# Write back with original formatting preserved as much as possible
with open(file_path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True, width=1000)

print("✓ Added rate limit configuration")
PYTHON_SCRIPT
    
    if [[ $? -eq 0 ]]; then
        print_success "  ✓ Added rate limit configuration"
    else
        print_error "  ✗ Failed to add rate limit configuration"
        # Restore backup
        mv "$ENV_FILE.backup" "$ENV_FILE"
        exit 1
    fi
done

echo ""
print_success "Rate limit configuration added to all environment files!"
echo ""
print_status "Next steps:"
echo "  1. Review the changes:"
echo "     git diff apps/environments/"
echo ""
echo "  2. Validate the configuration:"
echo "     ./apps/scripts/validate-synapse-config.sh dev"
echo ""
echo "  3. If validation passes, deploy to dev first:"
echo "     cd apps && helmfile -e dev sync -l name=matrix-synapse"
echo ""
print_warning "Backups created with .backup extension - remove them after successful deployment"











