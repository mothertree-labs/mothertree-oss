#!/bin/bash

# Matrix Infrastructure Cost Estimation Script
# This script calculates the estimated monthly cost for the Matrix infrastructure

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_header() {
    echo -e "${BLUE}$1${NC}"
}

print_cost() {
    echo -e "${GREEN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# Function to calculate costs based on configuration
calculate_costs() {
    echo "💰 Matrix Infrastructure Cost Estimation"
    echo "========================================"
    echo ""
    
    # Read configuration from terraform.tfvars
    if [ -f "terraform.tfvars" ]; then
        # Extract node pool configuration
        NODE_TYPE=$(grep -A 3 'linode_node_pools' terraform.tfvars | grep 'type' | head -1 | cut -d'"' -f2)
        NODE_COUNT=$(grep -A 3 'linode_node_pools' terraform.tfvars | grep 'count' | head -1 | awk '{print $3}' | tr -d ',')
        STORAGE_SIZE=$(grep 'storage_size' terraform.tfvars | awk '{print $3}' | tr -d ',')
    else
        # Default values if terraform.tfvars doesn't exist
        NODE_TYPE="g6-standard-2"
        NODE_COUNT=3
        STORAGE_SIZE=20
    fi
    
    # Linode pricing (as of 2024 - check current prices)
    case $NODE_TYPE in
        "g6-standard-1")
            NODE_PRICE=5
            NODE_SPECS="1 vCPU, 1GB RAM"
            ;;
        "g6-standard-2")
            NODE_PRICE=12
            NODE_SPECS="2 vCPU, 4GB RAM"
            ;;
        "g6-standard-4")
            NODE_PRICE=24
            NODE_SPECS="4 vCPU, 8GB RAM"
            ;;
        "g6-standard-6")
            NODE_PRICE=36
            NODE_SPECS="6 vCPU, 16GB RAM"
            ;;
        *)
            NODE_PRICE=12
            NODE_SPECS="2 vCPU, 4GB RAM (default)"
            ;;
    esac
    
    # Calculate costs
    NODES_COST=$((NODE_COUNT * NODE_PRICE))
    STORAGE_COST=$((STORAGE_SIZE / 10))  # $1 per 10GB
    LOAD_BALANCER_COST=10  # Estimated cost for load balancer
    DATA_TRANSFER_COST=10  # Estimated cost for 100GB/month
    
    TOTAL_COST=$((NODES_COST + STORAGE_COST + LOAD_BALANCER_COST + DATA_TRANSFER_COST))
    
    # Display breakdown
    print_header "📊 Infrastructure Breakdown:"
    echo ""
    echo "🖥️  LKE Nodes:"
    echo "   - Type: $NODE_TYPE ($NODE_SPECS)"
    echo "   - Count: $NODE_COUNT nodes"
    echo "   - Cost: \$$NODE_PRICE/node/month"
    echo "   - Total: \$$NODES_COST/month"
    echo ""
    
    echo "💾 Storage:"
    echo "   - Size: ${STORAGE_SIZE}GB"
    echo "   - Cost: \$$STORAGE_COST/month"
    echo ""
    
    echo "🌐 Load Balancer:"
    echo "   - NGINX Ingress Controller"
    echo "   - Cost: \$$LOAD_BALANCER_COST/month"
    echo ""
    
    echo "📡 Data Transfer:"
    echo "   - Estimated: 100GB/month (100 users)"
    echo "   - Cost: \$$DATA_TRANSFER_COST/month"
    echo ""
    
    print_header "💰 Total Monthly Cost: \$$TOTAL_COST"
    echo ""
    
    # Cost optimization suggestions
    print_header "💡 Cost Optimization Tips:"
    echo ""
    
    if [ $NODE_COUNT -gt 3 ]; then
        print_warning "   - Consider reducing node count to 3 for cost savings"
    fi
    
    if [ "$NODE_TYPE" = "g6-standard-4" ] || [ "$NODE_TYPE" = "g6-standard-6" ]; then
        print_warning "   - Consider using g6-standard-2 nodes for better cost efficiency"
    fi
    
    if [ $STORAGE_SIZE -gt 50 ]; then
        print_warning "   - Consider reducing storage size if not needed"
    fi
    
    echo "   - Monitor actual usage and adjust resources accordingly"
    echo "   - Consider using Linode's volume snapshots for backups"
    echo "   - Use resource limits to prevent unexpected costs"
    echo ""
    
    # Usage recommendations
    print_header "📈 Usage Recommendations:"
    echo ""
    echo "   - 100 users: Current configuration is optimal"
    echo "   - 50 users: Consider reducing to 2 nodes"
    echo "   - 200+ users: Consider upgrading to g6-standard-4 nodes"
    echo "   - 500+ users: Consider multiple node pools for different workloads"
    echo ""
    
    # Budget comparison
    print_header "🎯 Budget Comparison:"
    echo ""
    echo "   - Target budget: \$70-80/month"
    echo "   - Current estimate: \$$TOTAL_COST/month"
    
    if [ $TOTAL_COST -le 80 ]; then
        print_cost "   ✅ Within budget!"
    else
        print_warning "   ⚠️  Over budget. Consider optimizations above."
    fi
    
    echo ""
    print_header "📝 Notes:"
    echo "   - Prices are estimates based on Linode's current pricing"
    echo "   - Actual costs may vary based on usage patterns"
    echo "   - Monitor your Linode dashboard for actual billing"
    echo "   - Consider setting up billing alerts"
    echo ""
}

# Function to show cost comparison with other providers
show_provider_comparison() {
    print_header "🏢 Provider Cost Comparison (Monthly):"
    echo ""
    echo "Linode LKE (Current):"
    echo "   - 3x g6-standard-2 nodes: \$36"
    echo "   - Storage + Load Balancer: \$13"
    echo "   - Data Transfer: \$10"
    echo "   - Total: ~\$59"
    echo ""
    
    echo "DigitalOcean Kubernetes:"
    echo "   - 3x Basic nodes (2 vCPU, 4GB): \$45"
    echo "   - Load Balancer: \$12"
    echo "   - Storage: \$10"
    echo "   - Total: ~\$67"
    echo ""
    
    echo "AWS EKS:"
    echo "   - 3x t3.medium instances: \$30"
    echo "   - EKS control plane: \$73"
    echo "   - Load Balancer: \$20"
    echo "   - Storage: \$10"
    echo "   - Total: ~\$133"
    echo ""
    
    echo "Google GKE:"
    echo "   - 3x e2-standard-2 instances: \$45"
    echo "   - GKE control plane: \$73"
    echo "   - Load Balancer: \$18"
    echo "   - Storage: \$10"
    echo "   - Total: ~\$146"
    echo ""
    
    print_cost "✅ Linode LKE offers the best cost-to-performance ratio for this use case!"
    echo ""
}

# Main function
main() {
    calculate_costs
    
    if [ "${1:-}" = "compare" ]; then
        show_provider_comparison
    fi
}

# Handle script arguments
case "${1:-}" in
    "compare")
        main compare
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [compare|help]"
        echo ""
        echo "Options:"
        echo "  compare   Show cost comparison with other providers"
        echo "  help      Show this help message"
        echo ""
        echo "If no argument is provided, only the cost estimation will be shown."
        ;;
    "")
        main
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac 