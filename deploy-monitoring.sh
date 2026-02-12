#!/bin/bash

# Matrix Monitoring Stack Deployment Script
# This script deploys Prometheus, Grafana, Loki, and related monitoring components

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
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check if terraform is available
    if ! command -v terraform &> /dev/null; then
        print_error "terraform is not installed or not in PATH"
        exit 1
    fi
    
    # Check if kubeconfig exists
    if [ ! -f "kubeconfig.yaml" ]; then
        print_error "kubeconfig.yaml not found in current directory"
        print_status "Please run the main deployment first: ./deploy.sh"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Function to source environment variables
source_environment() {
    print_status "Loading environment variables..."
    
    if [ -f "secrets.tfvars.env" ]; then
        source secrets.tfvars.env
        print_success "Environment variables loaded from secrets.tfvars.env"
    else
        print_warning "secrets.tfvars.env not found"
        print_status "Please create it from secrets.tfvars.env.example"
        exit 1
    fi
    
    # Check required variables for monitoring deployment
    local missing_vars=()
    
    if [[ -z "$TF_VAR_grafana_admin_password" ]]; then
        missing_vars+=("TF_VAR_grafana_admin_password")
    fi
    
    if [[ -z "$TF_VAR_cloudflare_api_token" ]]; then
        missing_vars+=("TF_VAR_cloudflare_api_token")
    fi
    

    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            print_error "  - $var"
        done
        print_status "Please add these variables to your secrets.tfvars.env file"
        exit 1
    fi
    
    print_success "All required environment variables are set"
}

# Function to deploy monitoring stack
deploy_monitoring() {
    print_status "Deploying monitoring stack..."
    
    cd phase2
    
    # Initialize Terraform
    print_status "Initializing Terraform..."
    terraform init
    
    # Plan deployment
    print_status "Planning deployment..."
    terraform plan -target=module.monitoring
    
    # Apply deployment
    print_status "Applying deployment..."
    terraform apply -target=module.monitoring -auto-approve
    
    cd ..
    
    print_success "Monitoring stack deployment completed"
}

# Function to verify monitoring deployment
verify_monitoring() {
    print_status "Verifying monitoring deployment..."
    
    # Set KUBECONFIG
    export KUBECONFIG="kubeconfig.yaml"
    
    # Wait for monitoring pods to be ready
    print_status "Waiting for monitoring pods to be ready..."
    kubectl -n infra-monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=grafana --timeout=300s
    kubectl -n infra-monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus --timeout=300s
    kubectl -n infra-monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=loki --timeout=300s
    
    # Check all monitoring pods
    print_status "Checking monitoring pods..."
    kubectl get pods -n infra-monitoring
    
    # Check ingress
    print_status "Checking ingress configuration..."
    kubectl get ingress -n infra-monitoring
    
    print_success "Monitoring deployment verification completed"
}

# Function to show monitoring access information
show_monitoring_info() {
    print_success "🎉 Matrix Monitoring Stack deployment completed!"
    
    # Read domain from terraform.tfvars
    DOMAIN=$(grep '^domain =' terraform.tfvars | cut -d'"' -f2)
    
    echo ""
    echo "📊 Monitoring Access Information:"
    echo "=================================="
    echo "Grafana Dashboard: https://grafana.${DOMAIN}"
    echo "Username: admin"
    echo "Password: [Your configured Grafana password]"
    echo ""
    echo "🔧 Useful Commands:"
    echo "kubectl get pods -n infra-monitoring"
    echo "kubectl logs -n infra-monitoring -l app=grafana -f"
    echo "kubectl get ingress -n infra-monitoring"
    echo ""
    echo "📚 Next Steps:"
    echo "1. Wait for SSL certificates to be issued (may take 5-10 minutes)"
    echo "2. Access Grafana and import recommended dashboards"
    echo "3. Configure Matrix-specific dashboards"
    echo "4. Set up alerting notifications"
    echo ""
    echo "📖 For detailed instructions, see MONITORING_GUIDE.md"
}

# Function to show usage
show_usage() {
    cat << EOF
Matrix Monitoring Stack Deployment Script

Usage: $0 [OPTIONS]

Options:
    -h, --help                   Show this help message
    --verify-only                Only verify existing deployment
    --destroy                    Destroy monitoring stack

Examples:
    $0                          # Deploy monitoring stack
    $0 --verify-only            # Verify existing deployment
    $0 --destroy                # Destroy monitoring stack

Environment Variables:
    TF_VAR_grafana_admin_password  - Required: Grafana admin password
    TF_VAR_cloudflare_api_token    - Required: Cloudflare API token

EOF
}

# Main script logic
main() {
    echo "📊 Matrix Monitoring Stack Deployment Script"
    echo "============================================"
    echo ""
    
    # Check if running in the correct directory
    if [ ! -d "phase2" ]; then
        print_error "Please run this script from the root directory of the project"
        exit 1
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Source environment variables
    source_environment
    
    # Deploy monitoring stack
    deploy_monitoring
    
    # Verify deployment
    verify_monitoring
    
    # Show monitoring information
    show_monitoring_info
}

# Handle script arguments
case "${1:-}" in
    "--verify-only")
        print_status "Running verification only..."
        check_prerequisites
        source_environment
        verify_monitoring
        show_monitoring_info
        ;;
    "--destroy")
        print_status "Destroying monitoring stack..."
        check_prerequisites
        source_environment
        cd phase2
        terraform destroy -target=module.monitoring -auto-approve
        cd ..
        print_success "Monitoring stack destroyed"
        ;;
    "help"|"-h"|"--help")
        show_usage
        ;;
    "")
        main
        ;;
    *)
        print_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
esac 