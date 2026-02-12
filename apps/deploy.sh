#!/bin/bash

# Matrix Applications Deployment Script
# This script deploys all Matrix applications using Helmfile

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
    
    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        print_error "Helm is not installed. Please install Helm >= 3.0"
        exit 1
    fi
    
    # Check if Helmfile is installed
    if ! command -v helmfile &> /dev/null; then
        print_error "Helmfile is not installed. Please install Helmfile"
        print_status "Install with: brew install helmfile"
        exit 1
    fi
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        print_warning "kubectl is not installed. You won't be able to debug the cluster directly."
    fi
    
    # Check if kubeconfig exists
    if [ ! -f "../kubeconfig.yaml" ]; then
        print_error "kubeconfig.yaml not found in parent directory. Please run infrastructure deployment first."
        exit 1
    fi
    
    print_success "Prerequisites check completed"
}

# Function to set up environment
setup_environment() {
    print_status "Setting up environment..."
    
    # Set KUBECONFIG
    export KUBECONFIG="../kubeconfig.yaml"
    
    # Add Helm repositories
    print_status "Adding Helm repositories..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo add jetstack https://charts.jetstack.io
    helm repo add ananace https://ananace.gitlab.io/charts/
    helm repo add halkeye https://halkeye.github.io/helm-charts
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    
    print_status "Updating Helm repositories..."
    helm repo update
    
    print_success "Environment setup completed"
}

# Function to deploy applications
deploy_applications() {
    print_status "Deploying applications with Helmfile..."
    
    # Deploy all applications
    helmfile -f helmfile.yaml sync
    
    print_success "Applications deployed successfully!"
}

# Function to verify deployment
verify_deployment() {
    print_status "Verifying deployment..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        print_warning "kubectl not available, skipping verification"
        return
    fi
    
    # Set KUBECONFIG
    export KUBECONFIG="../kubeconfig.yaml"
    
    # Check all namespaces
    print_status "Checking namespaces..."
    kubectl get namespaces | grep -E "(infra-|tn-)"
    
    # Check Matrix pods
    print_status "Checking Matrix pods..."
    kubectl get pods -n tn-${TENANT_NAME:-example}-matrix
    
    # Check ingress controller
    print_status "Checking ingress controller..."
    kubectl get pods -n infra-ingress
    
    # Check cert-manager
    print_status "Checking cert-manager..."
    kubectl get pods -n infra-cert-manager
    
    # Check monitoring
    print_status "Checking monitoring..."
    kubectl get pods -n infra-monitoring
    
    # Check ingress resources
    print_status "Checking ingress resources..."
    kubectl get ingress -A
    
    print_success "Deployment verification completed!"
}

# Function to show final status
show_final_status() {
    print_success "🎉 Matrix applications deployment completed!"
    
    echo ""
    echo "📋 Deployment Summary:"
    echo "======================"
    echo "Matrix Server: https://${SYNAPSE_HOST:-synapse.\$TENANT_DOMAIN}"
    echo "Element Web:   https://${MATRIX_HOST:-matrix.\$TENANT_DOMAIN}"
    echo "Grafana:       https://grafana.${TENANT_ENV_DNS_LABEL:+$TENANT_ENV_DNS_LABEL.}${TENANT_DOMAIN:-example.org}"
    echo ""
    echo "🔧 Next Steps:"
    echo "1. Wait for SSL certificates to be issued (may take 5-10 minutes)"
    echo "2. Create your first admin user using the registration API"
    echo "3. Configure your Matrix client to connect to the server"
    echo ""
    echo "📚 Useful Commands:"
    echo "kubectl get pods -n ${NS_MATRIX:-tn-\$TENANT-matrix}"
    echo "kubectl logs -n ${NS_MATRIX:-tn-\$TENANT-matrix} -l app.kubernetes.io/name=matrix-synapse -f"
    echo "kubectl get ingress -A"
    echo ""
    echo "📖 For more information, see README.md"
}

# Main deployment function
main() {
    echo "🚀 Matrix Applications Deployment Script"
    echo "========================================"
    echo ""
    
    # Check if running in the correct directory
    if [ ! -f "helmfile.yaml" ]; then
        print_error "Please run this script from the apps directory"
        exit 1
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Setup environment
    setup_environment
    
    # Deploy applications
    deploy_applications
    
    # Verify deployment
    verify_deployment
    
    # Show final status
    show_final_status
}

# Handle script arguments
case "${1:-}" in
    "verify")
        print_status "Running verification only..."
        verify_deployment
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [verify|help]"
        echo ""
        echo "Options:"
        echo "  verify  Verify the deployment"
        echo "  help    Show this help message"
        echo ""
        echo "If no argument is provided, all applications will be deployed."
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
