#!/bin/bash

# Matrix Infrastructure Complete Destruction Script
# This script completely destroys all Matrix infrastructure

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if Terraform is installed
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform is not installed. Please install Terraform >= 1.0"
        exit 1
    fi
    
    # Check Terraform version
    TF_VERSION=$(terraform version -json | jq -r '.terraform_version')
    print_status "Terraform version: $TF_VERSION"
    
    print_success "Prerequisites check completed"
}

# Function to source environment variables
source_environment() {
    print_status "Sourcing environment variables..."
    
    if [ -f "secrets.tfvars.env" ]; then
        source secrets.tfvars.env
        print_success "Environment variables sourced"
    else
        print_error "secrets.tfvars.env not found"
        exit 1
    fi
}

# Function to cleanup Kubernetes resources
cleanup_kubernetes() {
    print_status "Cleaning up Kubernetes resources..."
    
    if [ -f "kubeconfig.yaml" ]; then
        export KUBECONFIG="kubeconfig.yaml"
        
        # Check if kubectl is available
        if command -v kubectl &> /dev/null; then
            print_status "Cleaning up tenant namespace resources..."
            
            # Delete all resources in tenant namespaces (tn-*)
            for ns in $(kubectl get ns -o name | grep "tn-" | cut -d/ -f2); do
                kubectl delete all --all -n "$ns" --ignore-not-found=true
                kubectl delete secret --all -n "$ns" --ignore-not-found=true
                kubectl delete configmap --all -n "$ns" --ignore-not-found=true
                kubectl delete pvc --all -n "$ns" --ignore-not-found=true
            done
            kubectl delete pv --all --ignore-not-found=true
            
            # Delete Helm releases from tenant namespaces
            for ns in $(kubectl get ns -o name | grep "tn-" | cut -d/ -f2); do
                for release in $(helm list -n "$ns" -q 2>/dev/null); do
                    helm uninstall "$release" -n "$ns" --ignore-not-found=true
                done
            done
            
            # Delete Helm releases from infra namespaces
            helm uninstall ingress-nginx -n infra-ingress --ignore-not-found=true
            helm uninstall ingress-nginx-internal -n infra-ingress-internal --ignore-not-found=true
            helm uninstall cert-manager -n infra-cert-manager --ignore-not-found=true
            helm uninstall kube-prometheus-stack -n infra-monitoring --ignore-not-found=true
            helm uninstall docs-postgresql -n infra-db --ignore-not-found=true
            helm uninstall keycloak -n infra-auth --ignore-not-found=true
            
            # Delete tenant namespaces
            for ns in $(kubectl get ns -o name | grep "tn-" | cut -d/ -f2); do
                kubectl delete namespace "$ns" --ignore-not-found=true
            done
            
            # Delete infra namespaces
            kubectl delete namespace infra-ingress --ignore-not-found=true
            kubectl delete namespace infra-ingress-internal --ignore-not-found=true
            kubectl delete namespace infra-cert-manager --ignore-not-found=true
            kubectl delete namespace infra-monitoring --ignore-not-found=true
            kubectl delete namespace infra-db --ignore-not-found=true
            kubectl delete namespace infra-auth --ignore-not-found=true
            kubectl delete namespace infra-mail --ignore-not-found=true
            
            print_success "Kubernetes resources cleaned up"
        else
            print_warning "kubectl not available, skipping Kubernetes cleanup"
        fi
    else
        print_warning "kubeconfig.yaml not found, skipping Kubernetes cleanup"
    fi
}

# Function to cleanup orphaned Linode resources
cleanup_linode_resources() {
    print_status "Cleaning up orphaned Linode resources..."
    
    # Check if linode-cli is available
    if ! command -v linode-cli &> /dev/null; then
        print_warning "linode-cli not available, skipping Linode resource cleanup"
        return
    fi
    
    # Clean up orphaned Linode instances
    print_status "Checking for orphaned Linode instances..."
    ORPHANED_LINODES=$(linode-cli linodes list --json | jq -r '.[] | select(.label | test("lke|matrix|mother-tree")) | .id' 2>/dev/null || echo "")
    
    if [[ -n "$ORPHANED_LINODES" ]]; then
        print_status "Found orphaned Linode instances: $ORPHANED_LINODES"
        for linode_id in $ORPHANED_LINODES; do
            print_status "Deleting orphaned Linode instance: $linode_id"
            linode-cli linodes delete "$linode_id"
        done
        print_success "Orphaned Linode instances cleaned up"
    else
        print_status "No orphaned Linode instances found"
    fi
    
    # Clean up orphaned volumes
    print_status "Checking for orphaned volumes..."
    ORPHANED_VOLUMES=$(linode-cli volumes list --json | jq -r '.[] | select(.label | test("pvc-|matrix|mother-tree")) | .id' 2>/dev/null || echo "")
    
    if [[ -n "$ORPHANED_VOLUMES" ]]; then
        print_status "Found orphaned volumes: $ORPHANED_VOLUMES"
        for volume_id in $ORPHANED_VOLUMES; do
            print_status "Deleting orphaned volume: $volume_id"
            linode-cli volumes delete "$volume_id"
        done
        print_success "Orphaned volumes cleaned up"
    else
        print_status "No orphaned volumes found"
    fi
    
    # Clean up orphaned node balancers
    print_status "Checking for orphaned node balancers..."
    ORPHANED_NODEBALANCERS=$(linode-cli nodebalancers list --json | jq -r '.[] | select(.label | test("ccm-|lke|matrix|mother-tree")) | .id' 2>/dev/null || echo "")
    
    if [[ -n "$ORPHANED_NODEBALANCERS" ]]; then
        print_status "Found orphaned node balancers: $ORPHANED_NODEBALANCERS"
        for nodebalancer_id in $ORPHANED_NODEBALANCERS; do
            print_status "Deleting orphaned node balancer: $nodebalancer_id"
            linode-cli nodebalancers delete "$nodebalancer_id"
        done
        print_success "Orphaned node balancers cleaned up"
    else
        print_status "No orphaned node balancers found"
    fi
    
    print_success "Linode resource cleanup completed"
}

# Function to destroy Phase 2
destroy_phase2() {
    print_status "Destroying Phase 2: Kubernetes Resources..."
    
    if [ -d "phase2" ]; then
        cd phase2
        
        if [ -f "terraform.tfstate" ]; then
            print_status "Destroying Phase 2 infrastructure..."
            terraform destroy -auto-approve
            print_success "Phase 2 destroyed"
        else
            print_warning "No Phase 2 Terraform state found"
        fi
        
        cd ..
    else
        print_warning "Phase 2 directory not found"
    fi
}

# Function to destroy Phase 1
destroy_phase1() {
    print_status "Destroying Phase 1: Infrastructure..."
    
    if [ -d "phase1" ]; then
        cd phase1
        
        if [ -f "terraform.tfstate" ]; then
            print_status "Destroying Phase 1 infrastructure..."
            terraform destroy -auto-approve
            print_success "Phase 1 destroyed"
        else
            print_warning "No Phase 1 Terraform state found"
        fi
        
        cd ..
    else
        print_warning "Phase 1 directory not found"
    fi
}

# Function to cleanup local files
cleanup_local_files() {
    print_status "Cleaning up local files..."
    
    # Remove kubeconfig
    if [ -f "kubeconfig.yaml" ]; then
        rm kubeconfig.yaml
        print_status "Removed kubeconfig.yaml"
    fi
    
    # Remove Terraform plan files
    if [ -f "phase1/phase1.tfplan" ]; then
        rm phase1/phase1.tfplan
        print_status "Removed phase1.tfplan"
    fi
    
    if [ -f "phase2/phase2.tfplan" ]; then
        rm phase2/phase2.tfplan
        print_status "Removed phase2.tfplan"
    fi
    
    # Remove .terraform directories (optional - uncomment if you want to remove them)
    # if [ -d "phase1/.terraform" ]; then
    #     rm -rf phase1/.terraform
    #     print_status "Removed phase1/.terraform"
    # fi
    # 
    # if [ -d "phase2/.terraform" ]; then
    #     rm -rf phase2/.terraform
    #     print_status "Removed phase2/.terraform"
    # fi
    
    print_success "Local files cleaned up"
}

# Function to show destruction summary
show_destruction_summary() {
    print_success "🗑️  Matrix infrastructure destruction completed!"
    
    echo ""
    echo "📋 Destruction Summary:"
    echo "======================"
    echo "✅ Kubernetes resources cleaned up"
    echo "✅ Phase 2 (Kubernetes resources) destroyed"
    echo "✅ Phase 1 (Infrastructure) destroyed"
    echo "✅ Orphaned Linode resources cleaned up"
    echo "✅ Local files cleaned up"
    echo ""
    echo "🔧 Next Steps:"
    echo "1. All infrastructure has been completely removed"
    echo "2. You can now run './deploy.sh' to redeploy from scratch"
    echo "3. Or run './deploy-clean.sh' for a complete rebuild with verification"
    echo ""
    echo "⚠️  Warning: All data has been permanently deleted!"
}

# Function to confirm destruction
confirm_destruction() {
    echo ""
    echo "⚠️  WARNING: This will completely destroy all Matrix infrastructure!"
    echo ""
            echo "This will delete:"
        echo "  - LKE cluster and all nodes"
        echo "  - All Kubernetes resources (pods, services, volumes)"
        echo "  - All persistent data"
        echo "  - DNS records"
        echo "  - SSL certificates"
        echo "  - Orphaned Linode resources (instances, volumes, node balancers)"
    echo ""
    echo "This action is IRREVERSIBLE!"
    echo ""
    
    read -p "Are you absolutely sure you want to continue? (type 'DESTROY' to confirm): " confirmation
    
    if [[ "$confirmation" != "DESTROY" ]]; then
        print_error "Destruction cancelled by user"
        exit 1
    fi
    
    echo ""
    print_warning "Proceeding with complete infrastructure destruction..."
    echo ""
}

# Main destruction function
main() {
    echo "🗑️  Matrix Infrastructure Complete Destruction Script"
    echo "===================================================="
    echo ""
    
    # Check if running in the correct directory
    if [ ! -d "phase1" ] || [ ! -d "phase2" ]; then
        print_error "Please run this script from the root directory of the project"
        exit 1
    fi
    
    # Confirm destruction
    confirm_destruction
    
    # Check prerequisites
    check_prerequisites
    
    # Source environment variables
    source_environment
    
    # Step 1: Cleanup Kubernetes resources
    cleanup_kubernetes
    
    # Step 2: Destroy Phase 2
    destroy_phase2
    
    # Step 3: Destroy Phase 1
    destroy_phase1
    
    # Step 4: Cleanup orphaned Linode resources
    cleanup_linode_resources
    
    # Step 5: Cleanup local files
    cleanup_local_files
    
    # Step 5: Show summary
    show_destruction_summary
}

# Handle script arguments
case "${1:-}" in
    "help"|"-h"|"--help")
        echo "Usage: $0 [help]"
        echo ""
        echo "This script completely destroys all Matrix infrastructure:"
        echo "  - LKE cluster and nodes"
        echo "  - All Kubernetes resources"
        echo "  - All persistent data"
        echo "  - DNS records"
        echo "  - SSL certificates"
        echo ""
        echo "⚠️  WARNING: This action is IRREVERSIBLE!"
        echo ""
        echo "Options:"
        echo "  help          Show this help message"
        echo ""
        echo "If no argument is provided, destruction will proceed after confirmation."
        ;;
    "")
        main
        ;;
    *)
        print_error "Unknown option: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac 