#!/bin/bash

# Deploy Nextcloud to Kubernetes
# This script handles the complete deployment of Nextcloud for file management
#
# Namespace structure:
#   - PostgreSQL in NS_DB (shared 'db' namespace)
#   - Nextcloud in NS_FILES (tenant-prefixed namespace, e.g., 'tn-example-files')

set -euo pipefail

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

dump_pod_diagnostics() {
    local namespace="$1"
    local selector="$2"
    print_status "Diagnostics: pods matching selector '$selector' in namespace '$namespace'"
    kubectl get pods -n "$namespace" -l "$selector" -o wide || true
    local pod_name
    pod_name=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    if [ -n "$pod_name" ]; then
        echo ""
        print_status "Diagnostics: describe pod $namespace/$pod_name"
        kubectl describe pod -n "$namespace" "$pod_name" || true
    fi
    echo ""
    print_status "Diagnostics: recent events in namespace '$namespace'"
    kubectl get events -n "$namespace" --sort-by=.lastTimestamp | tail -n 80 || true
}

# Poll for a condition with timeout - replaces 'kubectl wait' which hangs on failures
# Usage: poll_condition <check_command> <success_pattern> <timeout_seconds> <poll_interval> <description>
poll_condition() {
    local check_cmd="$1"
    local success_pattern="$2"
    local timeout="${3:-300}"
    local interval="${4:-5}"
    local description="${5:-condition}"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local result
        result=$(eval "$check_cmd" 2>&1) || true
        
        if echo "$result" | grep -qE "$success_pattern"; then
            return 0
        fi
        
        # Check for failure conditions
        if echo "$result" | grep -qiE "CrashLoopBackOff|Error|Failed|ImagePullBackOff"; then
            print_error "Detected failure while waiting for $description: $result"
            return 1
        fi
        
        echo "  Waiting for $description... (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for $description after ${timeout}s"
    return 1
}

# Poll for job completion with failure detection
poll_job_complete() {
    local namespace="$1"
    local job_name="$2"
    local timeout="${3:-180}"
    local interval="${4:-5}"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local job_status
        job_status=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.conditions[*].type}' 2>&1) || true
        
        if echo "$job_status" | grep -q "Complete"; then
            return 0
        fi
        
        if echo "$job_status" | grep -q "Failed"; then
            print_error "Job $job_name failed"
            kubectl logs -n "$namespace" "job/$job_name" --tail=50 || true
            return 1
        fi
        
        # Check pod status for early failure detection
        local pod_phase
        pod_phase=$(kubectl get pods -n "$namespace" -l "job-name=$job_name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || true
        if [ "$pod_phase" = "Failed" ]; then
            print_error "Job pod failed"
            kubectl logs -n "$namespace" "job/$job_name" --tail=50 || true
            return 1
        fi
        
        # Show current status in wait message
        local display_status="${pod_phase:-pending}"
        [ -n "$job_status" ] && display_status="$job_status"
        echo "  Waiting for job $job_name... status=$display_status (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for job $job_name after ${timeout}s"
    kubectl logs -n "$namespace" "job/$job_name" --tail=50 || true
    return 1
}

# Poll for pod ready with failure detection
poll_pod_ready() {
    local namespace="$1"
    local selector="$2"
    local timeout="${3:-300}"
    local interval="${4:-5}"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        # Check if pod is ready using simple JSONPath (nested filters don't work in kubectl)
        local ready_status
        ready_status=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true
        
        if [ "$ready_status" = "True" ]; then
            local pod_name
            pod_name=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
            print_success "Pod ready: $pod_name"
            return 0
        fi
        
        # Get current pod phase and any waiting reason for status display
        local pod_phase
        pod_phase=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || true
        local waiting_reason
        waiting_reason=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null) || true
        local scheduled_status
        scheduled_status=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null) || true
        local pod_node
        pod_node=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null) || true
        
        # Check for failure conditions
        if echo "$waiting_reason" | grep -qE "CrashLoopBackOff|ImagePullBackOff|ErrImagePull"; then
            print_error "Pod failed with: $waiting_reason"
            kubectl logs -n "$namespace" -l "$selector" --tail=30 || true
            return 1
        fi

        # Fail fast if the pod exists but is unschedulable (no node assigned) for a while
        # (Common on single-node Linode when exceeding max attached volume count.)
        if [ "$pod_phase" = "Pending" ] && [ "${scheduled_status:-}" = "False" ] && [ -z "${pod_node:-}" ]; then
            # Keep waiting, but once we're past 60s, dump diagnostics and stop.
            if [ $elapsed -ge 60 ]; then
                print_error "Pod is Pending and unscheduled (no node assigned). This is not a readiness issue; it's a scheduling constraint."
                dump_pod_diagnostics "$namespace" "$selector"
                return 1
            fi
        fi
        
        # Build status display
        local display_status="${pod_phase:-no-pod}"
        [ -n "$waiting_reason" ] && display_status="$pod_phase/$waiting_reason"
        
        echo "  Waiting for pod ($selector)... status=$display_status (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for pod ($selector) after ${timeout}s"
    dump_pod_diagnostics "$namespace" "$selector"
    return 1
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    print_error "helm is not installed or not in PATH"
    exit 1
fi

# Require MT_ENV and set kubeconfig statelessly
REPO_ROOT="${REPO_ROOT:-/workspace}"

# Parse nesting level for deploy notifications
NESTING_LEVEL=0
for arg in "$@"; do
  case "$arg" in
    --nesting-level=*) NESTING_LEVEL="${arg#*=}" ;;
  esac
done
_MT_NOTIFY_NESTING_LEVEL=$NESTING_LEVEL

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-nextcloud"

if [ -z "${MT_ENV:-}" ]; then
  print_error "MT_ENV is not set. Usage: MT_ENV=dev ./apps/deploy-nextcloud.sh"
  exit 1
fi
export KUBECONFIG="$REPO_ROOT/kubeconfig.$MT_ENV.yaml"

# Namespace configuration
NS_DB="${NS_DB:-infra-db}"
NS_FILES="${NS_FILES:-tn-${TENANT_NAME:-example}-files}"
NS_DOCS="${NS_DOCS:-tn-${TENANT_NAME:-example}-docs}"  # For docs-secrets reference

print_status "Starting Nextcloud deployment for environment: $MT_ENV"
print_status "Database namespace: $NS_DB"
print_status "Files namespace: $NS_FILES"

# Validate required environment variables (set by create_env from tenant config)
required_vars=("FILES_HOST" "AUTH_HOST" "TENANT_DOMAIN" "NEXTCLOUD_DB_NAME" "TENANT_KEYCLOAK_REALM" "TENANT_NAME")
missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    print_error "Required environment variables not set: ${missing_vars[*]}"
    print_error "This script should be called from create_env which sets these from tenant config."
    exit 1
fi

# Derive per-tenant database user from tenant name (e.g., docs_example)
export TENANT_DB_USER="${TENANT_DB_USER:-docs_${TENANT_NAME}}"
print_status "Using environment: FILES_HOST=$FILES_HOST, AUTH_HOST=$AUTH_HOST"
print_status "Database user: $TENANT_DB_USER, Database: $NEXTCLOUD_DB_NAME"

# Derive PG_HOST if not passed in from the environment
if [ -z "${PG_HOST:-}" ]; then
    if kubectl get service docs-postgresql-primary -n "$NS_DB" >/dev/null 2>&1; then
        export PG_HOST="docs-postgresql-primary.${NS_DB}.svc.cluster.local"
        print_status "PostgreSQL: detected replication mode (docs-postgresql-primary)"
    elif kubectl get service docs-postgresql -n "$NS_DB" >/dev/null 2>&1; then
        export PG_HOST="docs-postgresql.${NS_DB}.svc.cluster.local"
        print_status "PostgreSQL: detected standalone mode (docs-postgresql)"
    else
        print_error "PostgreSQL not found in $NS_DB namespace and PG_HOST not set."
        print_error "Either set PG_HOST or run 'deploy_infra $MT_ENV' first."
        exit 1
    fi
else
    print_status "Using PG_HOST from environment: $PG_HOST"
fi

# Load secrets for OIDC configuration
# When called from create_env, tenant-specific secrets are already exported.
# Only source the shared secrets file as a fallback for standalone runs,
# to avoid overwriting tenant-specific values with another tenant's secrets.
if [ -z "${TF_VAR_nextcloud_oidc_client_secret:-}" ]; then
    if [ -f "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env" ]; then
        # shellcheck disable=SC1091
        source "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env"
        print_status "Loaded secrets from secrets.${MT_ENV}.tfvars.env"
    else
        print_error "Secrets file secrets.${MT_ENV}.tfvars.env not found"
        exit 1
    fi
else
    print_status "Using secrets from environment (set by create_env)"
fi

# Get OIDC client secret
NEXTCLOUD_OIDC_SECRET="${TF_VAR_nextcloud_oidc_client_secret:-}"
if [ -z "$NEXTCLOUD_OIDC_SECRET" ]; then
    print_error "NEXTCLOUD_OIDC_CLIENT_SECRET not set. Add TF_VAR_nextcloud_oidc_client_secret to secrets.${MT_ENV}.tfvars.env"
    exit 1
fi
print_success "OIDC client secret retrieved"

# Step 1: Create files namespace if it doesn't exist
print_status "Ensuring files namespace exists..."
if ! kubectl get namespace "$NS_FILES" >/dev/null 2>&1; then
    kubectl create namespace "$NS_FILES"
    print_success "Created files namespace: $NS_FILES"
else
    print_status "Files namespace $NS_FILES already exists"
fi

# Step 2: Wait for PostgreSQL to be ready (shared database in db namespace)
print_status "Waiting for PostgreSQL to be ready in namespace $NS_DB..."
if ! poll_pod_ready "$NS_DB" "app.kubernetes.io/name=postgresql" 300 5; then
    print_error "PostgreSQL is not ready"
    exit 1
fi

# Step 3: Create Nextcloud database secret using the CORRECT password source
# IMPORTANT: The authoritative password for the tenant's DB user is in docs-secrets.DATABASE_PASSWORD
print_status "Creating Nextcloud database secret..."
DB_PASSWORD=$(kubectl get secret docs-secrets -n "$NS_DOCS" -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d 2>/dev/null || echo "")
if [ -z "$DB_PASSWORD" ]; then
    print_error "Failed to retrieve PostgreSQL password from docs-secrets secret in namespace $NS_DOCS"
    exit 1
fi

kubectl create secret generic nextcloud-db \
    --namespace "$NS_FILES" \
    --from-literal=db-username="$TENANT_DB_USER" \
    --from-literal=db-password="$DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "Nextcloud database secret created/updated (user: $TENANT_DB_USER)"

# Step 4: Create Nextcloud OIDC secret
print_status "Creating Nextcloud OIDC secret..."
kubectl create secret generic nextcloud-oidc \
    --namespace "$NS_FILES" \
    --from-literal=oidc-client-id=nextcloud-app \
    --from-literal=oidc-client-secret="$NEXTCLOUD_OIDC_SECRET" \
    --from-literal=oidc-provider-url="https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "Nextcloud OIDC secret created/updated"

# Step 4b: Create Nextcloud S3 secret for object storage
print_status "Creating Nextcloud S3 secret..."
S3_ACCESS_KEY="${TF_VAR_files_s3_access_key:-}"
S3_SECRET_KEY="${TF_VAR_files_s3_secret_key:-}"

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    print_warning "S3 credentials not set (TF_VAR_files_s3_access_key/TF_VAR_files_s3_secret_key)"
    print_warning "Nextcloud will not be able to use S3 object storage"
else
    kubectl create secret generic nextcloud-s3-credentials \
        --namespace "$NS_FILES" \
        --from-literal=access_key="$S3_ACCESS_KEY" \
        --from-literal=secret_key="$S3_SECRET_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "Nextcloud S3 secret created/updated"
fi

# Step 5: Run Nextcloud database initialization job (in files namespace where secrets are accessible)
print_status "Running Nextcloud database initialization..."

# Copy postgres-password from NS_DB to NS_FILES so the job can access it
print_status "Copying PostgreSQL credentials to files namespace for db-init job..."
POSTGRES_PASSWORD=$(kubectl get secret docs-postgresql -n "$NS_DB" -o jsonpath='{.data.postgres-password}' | base64 -d 2>/dev/null || echo "")
if [ -z "$POSTGRES_PASSWORD" ]; then
    print_error "Could not get postgres-password from docs-postgresql secret in $NS_DB"
    exit 1
fi
kubectl create secret generic docs-postgresql \
    --from-literal=postgres-password="$POSTGRES_PASSWORD" \
    -n "$NS_FILES" \
    --dry-run=client -o yaml | kubectl apply -f -

# Copy docs-secrets from NS_DOCS to NS_FILES for the DATABASE_PASSWORD
print_status "Copying docs-secrets to files namespace..."
DOCS_DB_PASSWORD=$(kubectl get secret docs-secrets -n "$NS_DOCS" -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d 2>/dev/null || echo "")
if [ -z "$DOCS_DB_PASSWORD" ]; then
    print_error "Could not get DATABASE_PASSWORD from docs-secrets in $NS_DOCS"
    exit 1
fi
kubectl create secret generic docs-secrets \
    --from-literal=DATABASE_PASSWORD="$DOCS_DB_PASSWORD" \
    -n "$NS_FILES" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS_FILES" delete job/nextcloud-db-init --ignore-not-found=true || true
envsubst '${NEXTCLOUD_DB_NAME} ${TENANT_DB_USER} ${PG_HOST}' < "$REPO_ROOT/docs/nextcloud-db-init-job.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_FILES/g" | kubectl apply -f -
if ! poll_job_complete "$NS_FILES" "nextcloud-db-init" 180 5; then
    print_error "Nextcloud database initialization failed"
    exit 1
fi
print_success "Nextcloud database initialized"

# Step 5c: Pre-deployment credential reconciliation (fix config.php BEFORE pod starts)
# This handles the case where PVC has stale credentials from a previous installation
print_status "Checking for existing Nextcloud installation that needs credential update..."
PVC_EXISTS=$(kubectl get pvc nextcloud-nextcloud -n "$NS_FILES" -o name 2>/dev/null || true)
if [ -n "$PVC_EXISTS" ]; then
    # Scale down Nextcloud to safely access PVC
    print_status "Scaling down Nextcloud to check/fix config..."
    kubectl scale deployment nextcloud -n "$NS_FILES" --replicas=0 2>/dev/null || true
    
    # Wait for all Nextcloud pods to fully terminate (RWO volume can only attach to one pod)
    print_status "Waiting for Nextcloud pods to terminate..."
    for i in $(seq 1 30); do
        PODS=$(kubectl get pods -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud --no-headers 2>/dev/null | wc -l)
        if [ "$PODS" -eq 0 ]; then
            print_success "All Nextcloud pods terminated"
            break
        fi
        echo "  Waiting for $PODS pod(s) to terminate... (${i}s/30s)"
        sleep 1
    done
    sleep 2  # Extra buffer for volume detachment
    
    # Create a temporary pod to access the PVC
    kubectl delete pod fix-nextcloud-config -n "$NS_FILES" --ignore-not-found=true 2>/dev/null || true
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fix-nextcloud-config
  namespace: $NS_FILES
  labels:
    app: fix-nextcloud-config
spec:
  containers:
  - name: fix
    image: alpine
    command: ["sleep", "120"]
    volumeMounts:
    - name: nc
      mountPath: /mnt
      subPath: config
  volumes:
  - name: nc
    persistentVolumeClaim:
      claimName: nextcloud-nextcloud
  restartPolicy: Never
EOF
    
    # Wait for fix pod to be ready (use label selector)
    if poll_pod_ready "$NS_FILES" "app=fix-nextcloud-config" 60 3 2>/dev/null; then
        # Check if config.php exists
        if kubectl exec -n "$NS_FILES" fix-nextcloud-config -- test -f /mnt/config.php 2>/dev/null; then
            print_status "Found existing config.php, checking database settings..."
            
            # Get current values from config.php
            CONFIG_DB_NAME=$(kubectl exec -n "$NS_FILES" fix-nextcloud-config -- \
                grep dbname /mnt/config.php 2>/dev/null | grep -o "'[^']*'" | tail -1 | tr -d "'" || true)
            CONFIG_DB_USER=$(kubectl exec -n "$NS_FILES" fix-nextcloud-config -- \
                grep dbuser /mnt/config.php 2>/dev/null | grep -o "'[^']*'" | tail -1 | tr -d "'" || true)
            CONFIG_DB_PASSWORD=$(kubectl exec -n "$NS_FILES" fix-nextcloud-config -- \
                grep dbpassword /mnt/config.php 2>/dev/null | grep -o "'[^']*'" | tail -1 | tr -d "'" || true)
            
            # Get authoritative values (NEXTCLOUD_DB_NAME is set by create_env from tenant config)
            EXPECTED_DB_NAME="$NEXTCLOUD_DB_NAME"
            SECRET_DB_USER=$(kubectl get secret nextcloud-db -n "$NS_FILES" -o jsonpath='{.data.db-username}' | base64 -d)
            SECRET_DB_PASSWORD=$(kubectl get secret nextcloud-db -n "$NS_FILES" -o jsonpath='{.data.db-password}' | base64 -d)
            
            print_status "Config values: dbname='$CONFIG_DB_NAME', dbuser='$CONFIG_DB_USER'"
            print_status "Expected values: dbname='$EXPECTED_DB_NAME', dbuser='$SECRET_DB_USER'"
            
            NEEDS_FIX=false
            
            # Check and fix database name
            if [ -n "$CONFIG_DB_NAME" ] && [ "$CONFIG_DB_NAME" != "$EXPECTED_DB_NAME" ]; then
                print_warning "Updating dbname: $CONFIG_DB_NAME -> $EXPECTED_DB_NAME"
                kubectl exec -n "$NS_FILES" fix-nextcloud-config -- \
                    sed -i "s|'dbname' => '$CONFIG_DB_NAME'|'dbname' => '$EXPECTED_DB_NAME'|" /mnt/config.php
                NEEDS_FIX=true
            fi
            
            # Check and fix username
            if [ -n "$CONFIG_DB_USER" ] && [ "$CONFIG_DB_USER" != "$SECRET_DB_USER" ]; then
                print_warning "Updating dbuser: $CONFIG_DB_USER -> $SECRET_DB_USER"
                kubectl exec -n "$NS_FILES" fix-nextcloud-config -- \
                    sed -i "s|'dbuser' => '$CONFIG_DB_USER'|'dbuser' => '$SECRET_DB_USER'|" /mnt/config.php
                NEEDS_FIX=true
            fi
            
            # Check and fix password
            if [ -n "$CONFIG_DB_PASSWORD" ] && [ "$CONFIG_DB_PASSWORD" != "$SECRET_DB_PASSWORD" ]; then
                print_warning "Updating dbpassword: ${CONFIG_DB_PASSWORD:0:8}... -> ${SECRET_DB_PASSWORD:0:8}..."
                # Escape special regex characters in passwords for sed
                # Pattern side: escape $ ^ * . [ ] \ /
                # Replacement side: escape & \ /
                ESCAPED_OLD_PW=$(printf '%s\n' "$CONFIG_DB_PASSWORD" | sed 's/[[\.*^$()+?{|\/&]/\\&/g')
                ESCAPED_NEW_PW=$(printf '%s\n' "$SECRET_DB_PASSWORD" | sed 's/[[\.*^$()+?{|\/&]/\\&/g')
                kubectl exec -n "$NS_FILES" fix-nextcloud-config -- \
                    sed -i "s|$ESCAPED_OLD_PW|$ESCAPED_NEW_PW|g" /mnt/config.php
                NEEDS_FIX=true
            fi
            
            if [ "$NEEDS_FIX" = true ]; then
                print_success "config.php database settings updated"
            else
                print_success "config.php database settings already correct"
            fi
        else
            print_status "No existing config.php found (new installation)"
        fi
    else
        print_warning "Could not start fix pod, will try post-deployment reconciliation"
    fi
    
    # Cleanup fix pod
    kubectl delete pod fix-nextcloud-config -n "$NS_FILES" --ignore-not-found=true 2>/dev/null || true
    
    # Scale Nextcloud back up (will be done by helmfile anyway)
    kubectl scale deployment nextcloud -n "$NS_FILES" --replicas=1 2>/dev/null || true
fi

# Step 6: Deploy Nextcloud via helmfile
print_status "Deploying Nextcloud via helmfile..."
pushd "$REPO_ROOT/apps" >/dev/null
  # Use sync instead of apply to skip slow diff operation
  # Use --skip-deps if repos already updated by create_env
  SKIP_DEPS_FLAG=""
  if [ "${SKIP_HELM_REPO_UPDATE:-}" = "true" ]; then
    SKIP_DEPS_FLAG="--skip-deps"
  fi
  if helmfile -e "$MT_ENV" -l name=nextcloud sync $SKIP_DEPS_FLAG; then
    print_success "Nextcloud deployed successfully"
  else
    print_error "Nextcloud deployment failed"
    exit 1
  fi
popd >/dev/null

# Step 7: Wait for Nextcloud to be ready
print_status "Waiting for Nextcloud pod to be ready (this may take a few minutes)..."
if ! poll_pod_ready "$NS_FILES" "app.kubernetes.io/instance=nextcloud" 600 5; then
    print_error "Nextcloud pod did not become ready."
    print_error "Refusing to continue (OIDC job / kubectl exec / kubectl cp require a scheduled, running pod)."
    exit 1
fi

# Step 5b: Check for stale installation and clean up if needed
print_status "Checking for incomplete Nextcloud installation..."
NEXTCLOUD_POD=$(kubectl get pod -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$NEXTCLOUD_POD" ]; then
    CONFIG_EXISTS=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null && echo "yes" || echo "no")
    if [ "$CONFIG_EXISTS" = "yes" ]; then
        INSTALLED=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- cat /var/www/html/config/config.php 2>/dev/null | grep "'installed'" | grep "true" || true)
        if [ -z "$INSTALLED" ]; then
            print_warning "Found incomplete Nextcloud installation (config.php exists but not installed)"
            print_warning "Deleting Nextcloud release and PVC to force clean reinstallation..."
            helm uninstall nextcloud -n "$NS_FILES" || true
            kubectl delete job nextcloud-oidc-config -n "$NS_FILES" --ignore-not-found=true || true
            kubectl delete pvc -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud --wait=true || true
            print_success "Stale installation cleaned up"
            sleep 5
        else
            print_status "Nextcloud installation is complete"
        fi
    fi
fi

# Step 7b: Reconcile database credentials in config.php with K8s secret
# This fixes drift when upgrading to per-tenant users or when secrets change
print_status "Checking database credentials consistency..."
NEXTCLOUD_POD=$(kubectl get pod -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
NEEDS_RESTART=false

if [ -n "$NEXTCLOUD_POD" ]; then
    # Check if config.php exists and is accessible
    if ! timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null; then
        print_warning "config.php not found yet (new installation), skipping reconciliation"
    else
        # Get current values from config.php
        CONFIG_DB_USER=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            grep -oP "'dbuser'\s*=>\s*'\K[^']*" /var/www/html/config/config.php 2>/dev/null || true)
        CONFIG_DB_PASSWORD=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            grep -oP "'dbpassword'\s*=>\s*'\K[^']*" /var/www/html/config/config.php 2>/dev/null || true)
        
        # Get authoritative values from K8s secret
        SECRET_DB_USER=$(kubectl get secret nextcloud-db -n "$NS_FILES" -o jsonpath='{.data.db-username}' 2>/dev/null | base64 -d || true)
        SECRET_DB_PASSWORD=$(kubectl get secret nextcloud-db -n "$NS_FILES" -o jsonpath='{.data.db-password}' 2>/dev/null | base64 -d || true)
        
        # Reconcile username (e.g., upgrading from 'docs' to 'docs_example')
        if [ -n "$CONFIG_DB_USER" ] && [ -n "$SECRET_DB_USER" ] && [ "$CONFIG_DB_USER" != "$SECRET_DB_USER" ]; then
            print_warning "Database user mismatch detected!"
            print_warning "  config.php user: $CONFIG_DB_USER"
            print_warning "  K8s secret user: $SECRET_DB_USER"
            print_status "Updating config.php with correct database user..."
            
            if kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                sed -i "s/'dbuser' => '$CONFIG_DB_USER'/'dbuser' => '$SECRET_DB_USER'/" \
                /var/www/html/config/config.php 2>/dev/null; then
                print_success "config.php updated with correct user: $SECRET_DB_USER"
                NEEDS_RESTART=true
            else
                print_error "Failed to update dbuser in config.php"
            fi
        else
            print_success "Database user is consistent: ${SECRET_DB_USER:-unknown}"
        fi
        
        # Reconcile password
        if [ -n "$CONFIG_DB_PASSWORD" ] && [ -n "$SECRET_DB_PASSWORD" ] && [ "$CONFIG_DB_PASSWORD" != "$SECRET_DB_PASSWORD" ]; then
            print_warning "Database password mismatch detected!"
            print_warning "  config.php password: ${CONFIG_DB_PASSWORD:0:8}..."
            print_warning "  K8s secret password: ${SECRET_DB_PASSWORD:0:8}..."
            print_status "Updating config.php with correct database password..."
            
            # Use pipe delimiter to avoid issues with special chars in passwords
            if kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                sed -i "s|'dbpassword' => '$CONFIG_DB_PASSWORD'|'dbpassword' => '$SECRET_DB_PASSWORD'|" \
                /var/www/html/config/config.php 2>/dev/null; then
                print_success "config.php updated with correct password"
                NEEDS_RESTART=true
            else
                print_error "Failed to update dbpassword in config.php"
            fi
        else
            print_success "Database password is consistent"
        fi
        
        # Restart pod if any changes were made
        if [ "$NEEDS_RESTART" = true ]; then
            print_status "Restarting Nextcloud pod to apply credential changes..."
            kubectl delete pod -n "$NS_FILES" "$NEXTCLOUD_POD"
            sleep 5
            
            if ! poll_pod_ready "$NS_FILES" "app.kubernetes.io/instance=nextcloud" 300 5; then
                print_warning "Pod may still be starting. Continuing..."
            fi
            NEXTCLOUD_POD=$(kubectl get pod -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            print_success "Nextcloud pod restarted with updated credentials"
        fi
    fi
else
    print_warning "Nextcloud pod not found, skipping credential reconciliation"
fi

# Step 7c: Reconcile trusted_domains (ensure calendar host is included)
print_status "Checking trusted_domains configuration..."
NEXTCLOUD_POD=$(kubectl get pod -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$NEXTCLOUD_POD" ]; then
    if timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null; then
        # Get current trusted_domains list
        CURRENT_DOMAINS=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            php /var/www/html/occ config:system:get trusted_domains 2>/dev/null || true)

        # Ensure FILES_HOST is in trusted_domains
        if [ -n "${FILES_HOST:-}" ] && ! echo "$CURRENT_DOMAINS" | grep -qF "$FILES_HOST"; then
            NEXT_INDEX=$(echo "$CURRENT_DOMAINS" | grep -c '.' || echo "0")
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                php /var/www/html/occ config:system:set trusted_domains "$NEXT_INDEX" --value="$FILES_HOST"
            print_success "Added $FILES_HOST to trusted_domains"
        fi

        # Ensure CALENDAR_HOST is in trusted_domains (when calendar is enabled)
        if [ "${CALENDAR_ENABLED:-false}" = "true" ] && [ -n "${CALENDAR_HOST:-}" ]; then
            if ! echo "$CURRENT_DOMAINS" | grep -qF "$CALENDAR_HOST"; then
                # Re-read in case we just added FILES_HOST
                CURRENT_DOMAINS=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                    php /var/www/html/occ config:system:get trusted_domains 2>/dev/null || true)
                NEXT_INDEX=$(echo "$CURRENT_DOMAINS" | grep -c '.' || echo "0")
                kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                    php /var/www/html/occ config:system:set trusted_domains "$NEXT_INDEX" --value="$CALENDAR_HOST"
                print_success "Added $CALENDAR_HOST to trusted_domains"
            else
                print_success "trusted_domains already includes $CALENDAR_HOST"
            fi
        fi
    else
        print_status "No config.php yet (new installation), trusted_domains will be set at install time"
    fi
else
    print_warning "Nextcloud pod not found, skipping trusted_domains check"
fi

# Step 8: Generate and apply OIDC configuration job from template
print_status "Configuring OIDC authentication via Job..."

# First, wait for Nextcloud installation to complete
print_status "Waiting for Nextcloud installation to complete..."
NEXTCLOUD_POD=$(kubectl get pod -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$NEXTCLOUD_POD" ]; then
    for attempt in $(seq 1 30); do
        INSTALLED=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- cat /var/www/html/config/config.php 2>/dev/null | grep "'installed'" | grep "true" || true)
        if [ -n "$INSTALLED" ]; then
            print_success "Nextcloud installation confirmed"
            break
        fi
        if [ $attempt -eq 30 ]; then
            print_error "Nextcloud installation check timed out after 30 attempts."
            print_error "Refusing to run OIDC configuration job until installation completes (it will just fail/retry noisily)."
            exit 1
        fi
        echo "Waiting for Nextcloud installation... (attempt $attempt/30)"
        sleep 10
    done
else
    print_error "Nextcloud pod not found. Refusing to run OIDC configuration job."
    dump_pod_diagnostics "$NS_FILES" "app.kubernetes.io/instance=nextcloud"
    exit 1
fi

if [ -f "$REPO_ROOT/docs/nextcloud-oidc-config-job.yaml.tpl" ]; then
    # Apply RBAC resources first (with namespace substitution)
    if [ -f "$REPO_ROOT/docs/nextcloud-oidc-rbac.yaml" ]; then
        cat "$REPO_ROOT/docs/nextcloud-oidc-rbac.yaml" | sed "s/namespace: files/namespace: $NS_FILES/g" | kubectl apply -f -
        print_status "OIDC RBAC resources applied"
        sleep 2
    fi
    
    # Generate the job manifest from template
    envsubst '${FILES_HOST} ${AUTH_HOST} ${TENANT_KEYCLOAK_REALM} ${CALENDAR_ENABLED} ${SMTP_DOMAIN}' < "$REPO_ROOT/docs/nextcloud-oidc-config-job.yaml.tpl" | \
      sed "s/namespace: files/namespace: $NS_FILES/g" > /tmp/nextcloud-oidc-config-job.yaml
    
    # Delete previous job if exists
    kubectl -n "$NS_FILES" delete job/nextcloud-oidc-config --ignore-not-found=true || true
    
    # Apply the job
    kubectl apply -f /tmp/nextcloud-oidc-config-job.yaml
    
    # Wait for job to complete
    if poll_job_complete "$NS_FILES" "nextcloud-oidc-config" 600 5; then
        print_success "OIDC configuration completed"
    else
        print_warning "OIDC configuration job may still be running or failed"
    fi
else
    print_warning "OIDC config job template not found, skipping OIDC configuration"
fi

# Step 9: Deploy custom files_linkeditor app (pre-built by deploy_infra)
print_status "Deploying custom files_linkeditor app..."
if [ -d "$REPO_ROOT/submodules/files_linkeditor" ]; then
    # Check if the app has been built (by deploy_infra)
    if [ ! -d "$REPO_ROOT/submodules/files_linkeditor/js" ] && [ ! -f "$REPO_ROOT/submodules/files_linkeditor/js/files_linkeditor-main.js" ]; then
        print_warning "files_linkeditor not built yet. Run './scripts/deploy_infra $MT_ENV' first, or build manually with './scripts/build-linkeditor.sh'"
    fi
    
    NEXTCLOUD_POD=$(kubectl get pod -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$NEXTCLOUD_POD" ]; then
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- rm -rf /var/www/html/custom_apps/files_linkeditor 2>/dev/null || true
        
        rm -rf /tmp/files_linkeditor_deploy
        mkdir -p /tmp/files_linkeditor_deploy
        rsync -a --exclude='node_modules' --exclude='.git' --exclude='dev' \
            "$REPO_ROOT/submodules/files_linkeditor/" /tmp/files_linkeditor_deploy/
        
        kubectl cp /tmp/files_linkeditor_deploy "$NS_FILES/$NEXTCLOUD_POD:/var/www/html/custom_apps/files_linkeditor"
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- chown -R www-data:www-data /var/www/html/custom_apps/files_linkeditor
        rm -rf /tmp/files_linkeditor_deploy
        
        print_success "Custom files_linkeditor app deployed"
        
        # Register .mtd MIME type
        print_status "Registering .mtd MIME type..."
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- sh -c 'cat > /var/www/html/config/mimetypemapping.json << EOF
{
    "mtd": ["application/x-mothertree-document"]
}
EOF'
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- chown www-data:www-data /var/www/html/config/mimetypemapping.json
        
        print_status "Updating MIME type mappings..."
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ maintenance:mimetype:update-js" 2>/dev/null || true
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ maintenance:mimetype:update-db --repair-filecache" 2>/dev/null || true
        print_success "MIME type mappings updated"
        
        # Configure files_linkeditor app settings for DOCX conversion
        print_status "Configuring files_linkeditor app settings..."
        DOCS_HOST="${DOCS_HOST:-docs.${TENANT_ENV_DNS_LABEL:+$TENANT_ENV_DNS_LABEL.}${TENANT_DOMAIN}}"
        
        # Get Y-Provider API key from docs secrets
        YPROVIDER_API_KEY=$(kubectl get secret -n "$NS_DOCS" docs-secrets -o jsonpath='{.data.Y_PROVIDER_API_KEY}' 2>/dev/null | base64 -d) || true
        
        if [ -n "$YPROVIDER_API_KEY" ]; then
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ config:app:set files_linkeditor docs_url --value='https://$DOCS_HOST'"
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ config:app:set files_linkeditor yprovider_url --value='http://y-provider.$NS_DOCS.svc.cluster.local:4444/api'"
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ config:app:set files_linkeditor yprovider_api_key --value='$YPROVIDER_API_KEY'"
            print_success "files_linkeditor app configured with Y-Provider settings"
        else
            print_warning "Could not retrieve Y-Provider API key from docs-secrets, skipping Y-Provider configuration"
        fi
    else
        print_warning "Nextcloud pod not found, skipping custom app deployment"
    fi
else
    print_warning "files_linkeditor submodule not found at $REPO_ROOT/submodules/files_linkeditor"
fi

# Step 10: Deploy Grafana dashboard
print_status "Deploying Nextcloud Grafana dashboard..."
NS_MONITORING="${NS_MONITORING:-infra-monitoring}"
if [ -f "$REPO_ROOT/apps/manifests/nextcloud/nextcloud-dashboard-configmap.yaml" ]; then
    cat "$REPO_ROOT/apps/manifests/nextcloud/nextcloud-dashboard-configmap.yaml" | sed "s/namespace: monitoring/namespace: $NS_MONITORING/g" | kubectl apply -f -
    print_success "Nextcloud Grafana dashboard deployed"
else
    print_warning "Grafana dashboard configmap not found, skipping"
fi

print_success "Nextcloud deployment completed!"
echo ""
echo "Access Information:"
echo "  URL: https://$FILES_HOST"
echo "  OIDC Provider: https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}"
echo ""
echo "Namespace Information:"
echo "  Database namespace: $NS_DB"
echo "  Files namespace: $NS_FILES"
echo ""
echo "To check the status:"
echo "  kubectl get pods -n $NS_FILES"
echo "  kubectl get ingress -n $NS_FILES"
echo "  kubectl logs -f deployment/nextcloud -n $NS_FILES"
