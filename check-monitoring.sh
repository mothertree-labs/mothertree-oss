#!/bin/bash

# Matrix Monitoring Stack Status Check Script

set -e

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

echo "📊 Matrix Monitoring Stack Status Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if kubeconfig exists
if [ ! -f "kubeconfig.yaml" ]; then
    print_error "kubeconfig.yaml not found in current directory"
    exit 1
fi

# Set KUBECONFIG
export KUBECONFIG="kubeconfig.yaml"

# Check if monitoring namespace exists
if ! kubectl get namespace monitoring &> /dev/null; then
    print_warning "Monitoring namespace not found"
    print_status "Monitoring stack may not be deployed yet"
    print_status "Run: ./deploy-monitoring.sh"
    exit 1
fi

print_status "Checking monitoring pods..."

# Check all monitoring pods
echo ""
echo "📦 Pod Status:"
echo "=============="
kubectl get pods -n infra-monitoring

echo ""
echo "🌐 Ingress Status:"
echo "=================="
kubectl get ingress -n infra-monitoring

echo ""
echo "📊 Service Status:"
echo "=================="
kubectl get services -n infra-monitoring

echo ""
echo "🔍 Detailed Pod Status:"
echo "======================"

# Check specific components
components=("grafana" "prometheus" "loki" "alertmanager")

for component in "${components[@]}"; do
    print_status "Checking $component..."
    
    # Get pod status
    pod_status=$(kubectl get pods -n infra-monitoring -l app.kubernetes.io/name=$component --no-headers 2>/dev/null | head -1 | awk '{print $3}')
    
    if [[ -n "$pod_status" ]]; then
        if [[ "$pod_status" == "Running" ]]; then
            print_success "$component: $pod_status"
        else
            print_warning "$component: $pod_status"
        fi
    else
        print_error "$component: Not found"
    fi
done

echo ""
echo "🔗 Access Information:"
echo "====================="

# Read domain from terraform.tfvars
if [ -f "terraform.tfvars" ]; then
    DOMAIN=$(grep '^domain =' terraform.tfvars | cut -d'"' -f2)
    echo "Grafana Dashboard: https://grafana.${DOMAIN}"
    echo "Username: admin"
    echo "Password: [Your configured Grafana password]"
else
    print_warning "terraform.tfvars not found, cannot determine domain"
fi

echo ""
echo "📚 Useful Commands:"
echo "=================="
echo "kubectl logs -n infra-monitoring -l app=grafana -f"
echo "kubectl logs -n infra-monitoring -l app=prometheus -f"
echo "kubectl logs -n infra-monitoring -l app=loki -f"
echo "kubectl port-forward -n infra-monitoring svc/prometheus-operated 9090:9090"
echo "kubectl port-forward -n infra-monitoring svc/loki 3100:3100"

echo ""
print_success "Status check completed!" 