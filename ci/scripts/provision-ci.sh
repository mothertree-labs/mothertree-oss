#!/usr/bin/env bash
# Provision CI server: run terraform, generate inventory, run ansible
#
# Usage: ./ci/scripts/provision-ci.sh [--plan|--apply|--ansible-only]
#
# Prerequisites:
#   - VPN connection active
#   - config/platform/ci/terraform.tfvars exists
#   - config/platform/ci/ansible-vars.yml exists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/ci/terraform"
ANSIBLE_DIR="$REPO_ROOT/ci/ansible"

ACTION="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[ci]${NC} $1"; }
print_success() { echo -e "${GREEN}[ci]${NC} $1"; }
print_error() { echo -e "${RED}[ci]${NC} $1" >&2; }

# Resolve ansible vars
ANSIBLE_VARS=""
if [ -f "$REPO_ROOT/config/platform/ci/ansible-vars.yml" ]; then
  ANSIBLE_VARS="$REPO_ROOT/config/platform/ci/ansible-vars.yml"
elif [ -f "$ANSIBLE_DIR/ansible-vars.yml" ]; then
  ANSIBLE_VARS="$ANSIBLE_DIR/ansible-vars.yml"
fi

resolve_tfvars() {
  if [ -f "$REPO_ROOT/config/platform/ci/terraform.tfvars" ]; then
    TFVARS="-var-file=$REPO_ROOT/config/platform/ci/terraform.tfvars"
  elif [ -f "$TF_DIR/terraform.tfvars" ]; then
    TFVARS="-var-file=$TF_DIR/terraform.tfvars"
  else
    print_error "No terraform.tfvars found. Copy ci/terraform/terraform.tfvars.example to config/platform/ci/terraform.tfvars"
    exit 1
  fi
}

run_terraform() {
  resolve_tfvars
  print_status "Running terraform $1..."
  cd "$TF_DIR"
  terraform init -input=false
  terraform "$1" $TFVARS
}

generate_inventory() {
  cd "$TF_DIR"
  local ci_public_ip
  ci_public_ip=$(terraform output -raw ci_server_ip 2>/dev/null || echo "<ci-server-public-ip>")

  # Use VPN tunnel IP for ProxyJump (requires active VPN connection)
  local vpn_tunnel_ip
  vpn_tunnel_ip=$(cd "$REPO_ROOT/phase1" && terraform output -raw vpn_server_tunnel_ip 2>/dev/null || echo "10.8.0.1")

  cat > "$ANSIBLE_DIR/inventory.yml" <<EOF
all:
  children:
    ci_servers:
      hosts:
        ci:
          ansible_host: ${ci_public_ip}
          ansible_user: root
          ansible_ssh_common_args: "-o ProxyJump=root@${vpn_tunnel_ip} -o StrictHostKeyChecking=accept-new"
EOF
  print_status "Generated ansible inventory at ci/ansible/inventory.yml"
}

run_ansible() {
  if [ ! -f "$ANSIBLE_DIR/inventory.yml" ]; then
    print_error "No inventory.yml found. Run terraform first, or create manually from inventory.yml.example"
    exit 1
  fi

  local extra_vars=""
  if [ -n "$ANSIBLE_VARS" ]; then
    extra_vars="-e @$ANSIBLE_VARS"
  else
    print_error "No ansible-vars.yml found. Copy example and fill in credentials."
    exit 1
  fi

  print_status "Running ansible playbook..."
  cd "$ANSIBLE_DIR"
  ansible-playbook -i inventory.yml playbook.yml $extra_vars
}

case "${ACTION}" in
  --plan)
    run_terraform plan
    ;;
  --apply)
    run_terraform apply
    generate_inventory
    print_success "Terraform apply complete. Run with --ansible-only to configure the server."
    ;;
  --ansible-only)
    run_ansible
    print_success "Ansible playbook complete."
    ;;
  "")
    run_terraform apply
    generate_inventory
    print_status "Waiting 60s for cloud-init to complete..."
    sleep 60
    run_ansible
    print_success "CI server provisioned and configured."
    ;;
  *)
    echo "Usage: $0 [--plan|--apply|--ansible-only]"
    exit 1
    ;;
esac
