#!/bin/bash
# Script to validate Synapse configuration before deployment
# This helps avoid deployment disasters by catching errors early

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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if helmfile is available
if ! command -v helmfile &> /dev/null; then
    print_error "helmfile is not installed"
    exit 1
fi

# Check if yq is available (for YAML validation)
if ! command -v yq &> /dev/null; then
    print_warning "yq not found - YAML validation will be limited"
    HAS_YQ=false
else
    HAS_YQ=true
fi

ENVIRONMENT="${1:-dev}"

print_status "Validating Synapse configuration for environment: $ENVIRONMENT"
echo ""

# Step 1: Validate YAML syntax of all synapse config files
print_status "Step 1: Validating YAML syntax..."

SYNAPSE_FILES=(
    "$APPS_DIR/values/synapse.yaml"
    "$APPS_DIR/environments/$ENVIRONMENT/synapse.yaml"
)

for file in "${SYNAPSE_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        exit 1
    fi
    
    print_status "  Checking: $(basename "$file")"
    
    # Basic YAML syntax check
    # Try Python yaml first, then yq, then basic syntax check
    if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
        print_success "    ✓ Valid YAML (Python)"
    elif command -v yq &> /dev/null && yq eval '.' "$file" > /dev/null 2>&1; then
        print_success "    ✓ Valid YAML (yq)"
    elif grep -q "^[a-zA-Z]" "$file" && ! grep -q "^\t" "$file"; then
        # Basic check: file exists and doesn't have tabs (common YAML error)
        print_warning "    ⚠ Basic check passed (full validation requires yaml module or yq)"
        print_status "    Install PyYAML: pip3 install pyyaml"
    else
        print_error "    ✗ YAML validation failed - install PyYAML (pip3 install pyyaml) or yq for full validation"
        exit 1
    fi
    
    # Check for extraConfig section
    if grep -q "extraConfig:" "$file"; then
        print_success "    ✓ Contains extraConfig section"
    else
        print_warning "    ⚠ No extraConfig section found"
    fi
done

echo ""

# Step 2: Check that environment file includes all required extraConfig keys
print_status "Step 2: Checking extraConfig consistency..."

BASE_CONFIG="$APPS_DIR/values/synapse.yaml"
ENV_CONFIG="$APPS_DIR/environments/$ENVIRONMENT/synapse.yaml"

# Extract extraConfig keys from base config (if it has them)
if grep -q "extraConfig:" "$BASE_CONFIG"; then
    print_status "  Base config has extraConfig - checking environment override..."
    
    # The environment file REPLACES the entire extraConfig, so it must have all keys
    # We'll check for critical ones
    CRITICAL_KEYS=(
        "turn_uris"
        "turn_shared_secret"
        "account_threepid_delegates"
        "email"
        "oidc_providers"
    )
    
    MISSING_KEYS=()
    for key in "${CRITICAL_KEYS[@]}"; do
        if ! grep -q "$key:" "$ENV_CONFIG"; then
            MISSING_KEYS+=("$key")
        fi
    done
    
    if [[ ${#MISSING_KEYS[@]} -gt 0 ]]; then
        print_error "  ✗ Missing critical keys in environment config:"
        for key in "${MISSING_KEYS[@]}"; do
            echo "      - $key"
        done
        print_error "  Remember: environment files REPLACE entire extraConfig section!"
        exit 1
    else
        print_success "  ✓ All critical keys present"
    fi
fi

echo ""

# Step 3: Use helmfile template to see what would be generated
print_status "Step 3: Generating Helm template (dry-run)..."

cd "$APPS_DIR"

# Set environment
export HELMFILE_ENVIRONMENT="$ENVIRONMENT"

# Try to template just the synapse release
if helmfile -e "$ENVIRONMENT" template -l name=matrix-synapse > /tmp/synapse-template.yaml 2>&1; then
    print_success "  ✓ Helm template generated successfully"
    
    # Check if the template contains rate limit config
    if grep -q "rc_" /tmp/synapse-template.yaml 2>/dev/null; then
        print_success "  ✓ Rate limit configuration found in template"
        echo ""
        print_status "  Rate limit config in template:"
        grep -A 10 "rc_" /tmp/synapse-template.yaml | head -20
    else
        print_warning "  ⚠ No rate limit (rc_*) configuration found in template"
    fi
else
    print_error "  ✗ Failed to generate Helm template"
    cat /tmp/synapse-template.yaml | tail -20
    exit 1
fi

echo ""

# Step 4: Validate Synapse config syntax if pod is available
print_status "Step 4: Checking if we can validate against running Synapse..."

export KUBECONFIG="$REPO_ROOT/kubeconfig.$ENVIRONMENT.yaml"

if [[ -f "$KUBECONFIG" ]] && kubectl --kubeconfig="$KUBECONFIG" get pods -n tn-${TENANT_NAME:-example}-matrix -l app.kubernetes.io/name=matrix-synapse --no-headers 2>/dev/null | grep -q Running; then
    SYNAPSE_POD=$(kubectl --kubeconfig="$KUBECONFIG" -n tn-${TENANT_NAME:-example}-matrix get pods -l app.kubernetes.io/name=matrix-synapse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -n "$SYNAPSE_POD" ]]; then
        print_status "  Found running Synapse pod: $SYNAPSE_POD"
        print_status "  (Config validation against running instance would require restart)"
        print_warning "  ⚠ This script cannot fully validate without deploying"
    fi
else
    print_warning "  ⚠ No running Synapse pod found - cannot validate against live instance"
fi

echo ""

# Step 5: Summary
print_success "Validation complete!"
echo ""
print_status "Next steps:"
echo "  1. Review the generated template: /tmp/synapse-template.yaml"
echo "  2. If everything looks good, deploy with:"
echo "     cd apps && helmfile -e $ENVIRONMENT sync -l name=matrix-synapse"
echo "  3. Monitor the pod after deployment:"
echo "     kubectl -n tn-${TENANT_NAME:-example}-matrix logs -l app.kubernetes.io/name=matrix-synapse -f"
echo ""
print_warning "Remember: Always test in dev environment first!"

