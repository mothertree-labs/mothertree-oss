#!/bin/bash

# Matrix Applications Destruction Script
# This script removes all Matrix applications using Helmfile

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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
    
    # Check if Helmfile is installed
    if ! command -v helmfile &> /dev/null; then
        print_error "Helmfile is not installed. Please install Helmfile"
        print_status "Install with: brew install helmfile"
        exit 1
    fi
    
    # Check if kubeconfig exists
    if [ ! -f "../kubeconfig.yaml" ]; then
        print_error "kubeconfig.yaml not found in parent directory."
        exit 1
    fi
    
    print_success "Prerequisites check completed"
}

# Function to set up environment
setup_environment() {
    print_status "Setting up environment..."
    
    # Set KUBECONFIG
    export KUBECONFIG="../kubeconfig.yaml"
    
    print_success "Environment setup completed"
}

# Function to destroy applications
destroy_applications() {
    print_status "Destroying applications with Helmfile..."
    
    # Destroy all applications
    helmfile -f helmfile.yaml destroy
    
    print_success "Applications destroyed successfully!"
}

# Function to verify destruction
verify_destruction() {
    print_status "Verifying destruction..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        print_warning "kubectl not available, skipping verification"
        return
    fi
    
    # Set KUBECONFIG
    export KUBECONFIG="../kubeconfig.yaml"
    
    # Check if namespaces still exist
    print_status "Checking remaining namespaces..."
    kubectl get namespaces | grep -E "(infra-|tn-)" || print_success "All application namespaces removed"
    
    print_success "Destruction verification completed!"
}

# Function to show final status
show_final_status() {
    print_success "🎉 Matrix applications destruction completed!"
    
    echo ""
    echo "📋 Destruction Summary:"
    echo "======================="
    echo "All Matrix applications have been removed"
    echo "Infrastructure (PVCs, namespaces, DNS) remains intact"
    echo ""
    echo "🔧 Next Steps:"
    echo "1. Run 'cd ../infra && terraform destroy' to remove infrastructure"
    echo "2. Or run 'cd ../apps && ./deploy.sh' to redeploy applications"
    echo ""
    echo "📚 Useful Commands:"
    echo "kubectl get namespaces"
    echo "kubectl get pvc -A"
    echo ""
}

# Main destruction function
main() {
    echo "🗑️  Matrix Applications Destruction Script"
    echo "==========================================="
    echo ""
    
    # Check if running in the correct directory
    if [ ! -f "helmfile.yaml" ]; then
        print_error "Please run this script from the apps directory"
        exit 1
    fi
    
    # Confirmation prompt
    print_warning "This will destroy all Matrix applications!"
    print_warning "Infrastructure (PVCs, namespaces, DNS) will be preserved."
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Destruction cancelled"
        exit 0
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Setup environment
    setup_environment
    
    # Destroy applications
    destroy_applications
    
    # Verify destruction
    verify_destruction
    
    # Show final status
    show_final_status
}

# Handle script arguments
case "${1:-}" in
    "verify")
        print_status "Running verification only..."
        verify_destruction
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [verify|help]"
        echo ""
        echo "Options:"
        echo "  verify  Verify the destruction"
        echo "  help    Show this help message"
        echo ""
        echo "If no argument is provided, all applications will be destroyed."
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
