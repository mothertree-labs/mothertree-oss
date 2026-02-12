#!/bin/bash

# Loki Manual Deployment Script
# This script deploys Loki in SingleBinary mode using kubectl manifests
# It's idempotent and safe to run multiple times

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="${KUBECONFIG:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/kubeconfig.yaml}"
LOKI_MANIFEST="${SCRIPT_DIR}/loki-manual.yaml"
NAMESPACE="monitoring"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check if kubeconfig exists
    if [[ ! -f "$KUBECONFIG_FILE" ]]; then
        log_error "Kubeconfig file not found: $KUBECONFIG_FILE"
        exit 1
    fi
    
    # Check if manifest file exists
    if [[ ! -f "$LOKI_MANIFEST" ]]; then
        log_error "Loki manifest file not found: $LOKI_MANIFEST"
        exit 1
    fi
    
    # Test kubectl connectivity
    if ! KUBECONFIG="$KUBECONFIG_FILE" kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

deploy_loki() {
    log_info "Deploying Loki..."
    
    # Apply the manifest
    if KUBECONFIG="$KUBECONFIG_FILE" kubectl apply -f "$LOKI_MANIFEST"; then
        log_success "Loki manifest applied successfully"
    else
        log_error "Failed to apply Loki manifest"
        exit 1
    fi
}

wait_for_loki() {
    log_info "Waiting for Loki pod to be ready..."
    
    # Wait for pod to be created
    local timeout=60
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if KUBECONFIG="$KUBECONFIG_FILE" kubectl get pods -n "$NAMESPACE" -l app=loki --no-headers 2>/dev/null | grep -q "Running\|Ready"; then
            break
        fi
        sleep 2
        ((count+=2))
    done
    
    if [[ $count -ge $timeout ]]; then
        log_error "Timeout waiting for Loki pod to be created"
        exit 1
    fi
    
    # Wait for pod to be ready
    if KUBECONFIG="$KUBECONFIG_FILE" kubectl wait --for=condition=ready pod -l app=loki -n "$NAMESPACE" --timeout=120s; then
        log_success "Loki pod is ready"
    else
        log_error "Loki pod failed to become ready"
        log_info "Checking pod status..."
        KUBECONFIG="$KUBECONFIG_FILE" kubectl get pods -n "$NAMESPACE" -l app=loki
        log_info "Checking pod logs..."
        KUBECONFIG="$KUBECONFIG_FILE" kubectl logs -n "$NAMESPACE" -l app=loki --tail=20
        exit 1
    fi
}

test_loki_health() {
    log_info "Testing Loki health..."
    
    # Test ready endpoint
    local pod_name
    pod_name=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl get pods -n "$NAMESPACE" -l app=loki -o jsonpath='{.items[0].metadata.name}')
    
    if KUBECONFIG="$KUBECONFIG_FILE" kubectl exec -n "$NAMESPACE" "$pod_name" -- wget -qO- http://localhost:3100/ready 2>/dev/null | grep -q "ready"; then
        log_success "Loki ready endpoint is responding"
    else
        log_error "Loki ready endpoint is not responding"
        return 1
    fi
    
    # Test metrics endpoint
    if KUBECONFIG="$KUBECONFIG_FILE" kubectl exec -n "$NAMESPACE" "$pod_name" -- wget -qO- http://localhost:3100/metrics 2>/dev/null | grep -q "loki_"; then
        log_success "Loki metrics endpoint is responding"
    else
        log_warning "Loki metrics endpoint is not responding (this may be normal)"
    fi
}

test_vector_connection() {
    log_info "Testing Vector connection to Loki..."
    
    # Check if Vector pods exist
    if ! KUBECONFIG="$KUBECONFIG_FILE" kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vector --no-headers 2>/dev/null | grep -q "Running"; then
        log_warning "No Vector pods found. Vector may not be deployed yet."
        return 0
    fi
    
    # Check Vector logs for connection errors
    local vector_pod
    vector_pod=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vector -o jsonpath='{.items[0].metadata.name}')
    
    if KUBECONFIG="$KUBECONFIG_FILE" kubectl logs -n "$NAMESPACE" "$vector_pod" --tail=10 2>/dev/null | grep -q "Connection refused\|500 Internal Server Error"; then
        log_warning "Vector may still be connecting to Loki. This is normal during startup."
    else
        log_success "Vector appears to be connecting to Loki successfully"
    fi
}

test_loki_api() {
    log_info "Testing Loki API..."
    
    local pod_name
    pod_name=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl get pods -n "$NAMESPACE" -l app=loki -o jsonpath='{.items[0].metadata.name}')
    
    # Test basic query
    if KUBECONFIG="$KUBECONFIG_FILE" kubectl exec -n "$NAMESPACE" "$pod_name" -- wget -qO- 'http://localhost:3100/loki/api/v1/query?query={job="kubernetes-pods"}&limit=1' 2>/dev/null | grep -q '"status":"success"'; then
        log_success "Loki API is responding to queries"
    else
        log_warning "Loki API query test failed (this may be normal if no logs are available yet)"
    fi
}

display_status() {
    log_info "Loki deployment status:"
    
    echo
    echo "Pods:"
    KUBECONFIG="$KUBECONFIG_FILE" kubectl get pods -n "$NAMESPACE" -l app=loki
    
    echo
    echo "Services:"
    KUBECONFIG="$KUBECONFIG_FILE" kubectl get svc -n "$NAMESPACE" -l app=loki
    
    echo
    echo "PersistentVolumeClaims:"
    KUBECONFIG="$KUBECONFIG_FILE" kubectl get pvc -n "$NAMESPACE" -l app=loki
    
    echo
    log_info "Next steps:"
    echo "1. Test Grafana datasource: https://grafana.${TENANT_ENV_DNS_LABEL:+$TENANT_ENV_DNS_LABEL.}${TENANT_DOMAIN:-example.org}"
    echo "2. Query logs in Grafana Explore with: {namespace=\"monitoring\"}"
    echo "3. Check Loki logs: kubectl logs -n ${NS_MONITORING:-infra-monitoring} -l app=loki"
    echo "4. Check Vector logs: kubectl logs -n ${NS_MONITORING:-infra-monitoring} -l app.kubernetes.io/name=vector"
}

cleanup_stray_components() {
    log_info "Cleaning up any stray Loki components..."
    
    # Remove any leftover cache pods
    KUBECONFIG="$KUBECONFIG_FILE" kubectl delete pod -n "$NAMESPACE" loki-chunks-cache-0 loki-results-cache-0 --ignore-not-found=true 2>/dev/null || true
    
    # Remove canary pods
    KUBECONFIG="$KUBECONFIG_FILE" kubectl delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=loki-canary --ignore-not-found=true 2>/dev/null || true
    
    # Remove any leftover services
    KUBECONFIG="$KUBECONFIG_FILE" kubectl delete service -n "$NAMESPACE" loki-gateway loki-memberlist loki-chunks-cache loki-results-cache loki-canary --ignore-not-found=true 2>/dev/null || true
    
    log_success "Cleanup completed"
}

# Main execution
main() {
    log_info "Starting Loki manual deployment..."
    
    check_prerequisites
    cleanup_stray_components
    deploy_loki
    wait_for_loki
    test_loki_health
    test_vector_connection
    test_loki_api
    display_status
    
    log_success "Loki deployment completed successfully!"
    log_info "Loki is now running in SingleBinary mode with filesystem storage"
    log_info "Log retention is set to 7 days (168 hours)"
}

# Run main function
main "$@"
