#!/bin/bash

# Create/verify all S3 buckets for a tenant
# This script creates four buckets:
# 1. docs-media-[<env>-]<tenant> - Docs media
# 2. matrix-media-[<env>-]<tenant> - Matrix media (for future use)
# 3. files-media-[<env>-]<tenant> - Nextcloud files
# 4. mail-media-[<env>-]<tenant> - Stalwart mail blob storage
#
# Features:
# - Detects placeholder credentials and automatically creates new Linode Object Storage keys
# - Creates buckets using s3cmd (compatible with Linode Object Storage)
# - Sets up CORS for each bucket
# - Automatically updates the tenant secrets file with new credentials
#
# Usage:
#   TENANT=example MT_ENV=prod ./create-tenant-s3-buckets.sh
#   TENANT=example MT_ENV=dev ./create-tenant-s3-buckets.sh

set -e

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

# Check if a credential value is a placeholder
is_placeholder() {
    local value="$1"
    if [[ -z "$value" ]] || \
       [[ "$value" == "null" ]] || \
       [[ "$value" == *"PLEASE"* ]] || \
       [[ "$value" == *"PLACEHOLDER"* ]] || \
       [[ "$value" == *"YOUR_"* ]] || \
       [[ "$value" == *"your-"* ]] || \
       [[ "$value" == *"CHANGE_ME"* ]] || \
       [[ "$value" == *"TODO"* ]]; then
        return 0  # true - is placeholder
    fi
    return 1  # false - is real credential
}

# Check required tools
check_requirements() {
    local missing=0
    
    if ! command -v timeout &> /dev/null; then
        # On macOS, timeout is in coreutils
        if ! command -v gtimeout &> /dev/null; then
            print_error "timeout command not found. Install with: brew install coreutils"
            missing=1
        else
            # Create an alias for gtimeout
            timeout() { gtimeout "$@"; }
            export -f timeout
        fi
    fi
    
    if ! command -v linode-cli &> /dev/null; then
        print_error "linode-cli is not installed. Install with: pip install linode-cli"
        missing=1
    else
        # Verify linode-cli is configured
        if ! linode-cli --version &>/dev/null; then
            print_error "linode-cli is not properly configured. Run: linode-cli configure"
            missing=1
        fi
    fi
    
    if ! command -v s3cmd &> /dev/null; then
        print_error "s3cmd is not installed. Install with: brew install s3cmd"
        missing=1
    fi
    
    if ! command -v aws &> /dev/null; then
        print_error "aws cli is not installed. Install with: brew install awscli"
        missing=1
    fi
    
    if ! command -v yq &> /dev/null; then
        print_error "yq is not installed. Install with: brew install yq"
        missing=1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed. Install with: brew install jq"
        missing=1
    fi
    
    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# Create new Linode Object Storage access keys
create_linode_keys() {
    local label="$1"
    local timeout_seconds=60
    
    # Output to stderr so it doesn't get captured by command substitution
    echo -e "${BLUE}[INFO]${NC} Creating new Linode Object Storage keys: $label (timeout: ${timeout_seconds}s)" >&2
    
    local result
    local exit_code
    
    # Use timeout to prevent hanging, and --no-defaults to avoid interactive prompts
    # Also redirect stderr to capture any error messages
    result=$(timeout "$timeout_seconds" linode-cli object-storage keys-create \
        --label "$label" \
        --json \
        --no-defaults \
        2>&1)
    exit_code=$?
    
    if [ $exit_code -eq 124 ]; then
        print_error "Timeout waiting for Linode API response after ${timeout_seconds}s"
        print_error "Check your network connection and try again"
        return 1
    fi
    
    if [ $exit_code -ne 0 ]; then
        print_error "Failed to create Linode Object Storage keys (exit code: $exit_code)"
        print_error "Response: $result"
        return 1
    fi
    
    # Validate JSON response
    if ! echo "$result" | jq -e '.' >/dev/null 2>&1; then
        print_error "Invalid JSON response from Linode API"
        print_error "Response: $result"
        return 1
    fi
    
    # Extract access key and secret key from JSON response
    local access_key secret_key
    access_key=$(echo "$result" | jq -r '.[0].access_key // empty')
    secret_key=$(echo "$result" | jq -r '.[0].secret_key // empty')
    
    if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        print_error "Failed to parse access key or secret key from response"
        print_error "Response: $result"
        return 1
    fi
    
    # Return both keys space-separated
    echo "$access_key $secret_key"
}

# Create a bucket using s3cmd
create_bucket() {
    local bucket_name="$1"
    local access_key="$2"
    local secret_key="$3"
    local cluster="$4"
    local timeout_seconds=30
    
    print_status "Creating bucket: $bucket_name"
    
    if timeout "$timeout_seconds" s3cmd --access_key="$access_key" \
             --secret_key="$secret_key" \
             --host="${cluster}.linodeobjects.com" \
             --host-bucket="%(bucket)s.${cluster}.linodeobjects.com" \
             mb "s3://$bucket_name" 2>/dev/null; then
        print_success "Created bucket: $bucket_name"
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            print_error "Timeout creating bucket: $bucket_name (${timeout_seconds}s)"
            return 1
        fi
        
        # Check if bucket already exists
        if timeout "$timeout_seconds" s3cmd --access_key="$access_key" \
                 --secret_key="$secret_key" \
                 --host="${cluster}.linodeobjects.com" \
                 --host-bucket="%(bucket)s.${cluster}.linodeobjects.com" \
                 ls "s3://$bucket_name" >/dev/null 2>&1; then
            print_status "Bucket already exists: $bucket_name"
            return 0
        else
            print_error "Failed to create bucket: $bucket_name"
            return 1
        fi
    fi
}

# Set CORS on a bucket
set_cors() {
    local bucket_name="$1"
    local host="$2"
    local access_key="$3"
    local secret_key="$4"
    local cluster="$5"
    local timeout_seconds=30
    
    print_status "Setting CORS: $bucket_name -> https://$host"
    
    local cors_file="/tmp/cors-$$-${bucket_name}.json"
    cat > "$cors_file" << EOF
{
    "CORSRules": [
        {
            "AllowedOrigins": ["https://$host"],
            "AllowedMethods": ["GET", "PUT", "POST", "DELETE", "HEAD"],
            "AllowedHeaders": ["*"],
            "MaxAgeSeconds": 3000
        }
    ]
}
EOF
    
    if timeout "$timeout_seconds" env \
       AWS_ACCESS_KEY_ID="$access_key" \
       AWS_SECRET_ACCESS_KEY="$secret_key" \
       aws s3api put-bucket-cors \
           --bucket "$bucket_name" \
           --cors-configuration "file://$cors_file" \
           --endpoint-url="https://${cluster}.linodeobjects.com" 2>/dev/null; then
        print_success "CORS configured for $bucket_name"
        rm -f "$cors_file"
        return 0
    else
        local exit_code=$?
        rm -f "$cors_file"
        if [ $exit_code -eq 124 ]; then
            print_warning "Timeout setting CORS for $bucket_name (${timeout_seconds}s)"
        else
            print_warning "Could not set CORS for $bucket_name"
        fi
        return 1
    fi
}

# Update secrets file with new credentials
update_secrets_file() {
    local secrets_file="$1"
    local section="$2"
    local access_key="$3"
    local secret_key="$4"
    
    print_status "Updating $secrets_file with new $section credentials"
    
    # Use yq to update the YAML file in place
    yq -i ".${section}.access_key = \"$access_key\"" "$secrets_file"
    yq -i ".${section}.secret_key = \"$secret_key\"" "$secrets_file"
    
    print_success "Updated $section in $secrets_file"
}

# Main script
main() {
    check_requirements
    
    # Get tenant and environment from environment variables or defaults
    TENANT=${TENANT:-example}
    MT_ENV=${MT_ENV:-prod}
    
    # Determine paths
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TENANT_CONFIG="${SCRIPT_DIR}/tenants/${TENANT}/${MT_ENV}.config.yaml"
    TENANT_SECRETS="${SCRIPT_DIR}/tenants/${TENANT}/${MT_ENV}.secrets.yaml"
    
    # Validate files exist
    if [ ! -f "$TENANT_CONFIG" ]; then
        print_error "Tenant config not found: $TENANT_CONFIG"
        exit 1
    fi
    
    if [ ! -f "$TENANT_SECRETS" ]; then
        print_error "Tenant secrets not found: $TENANT_SECRETS"
        exit 1
    fi
    
    # Load configuration
    S3_CLUSTER=$(yq '.s3.cluster' "$TENANT_CONFIG")
    S3_DOCS_BUCKET=$(yq '.s3.docs_bucket' "$TENANT_CONFIG")
    S3_MATRIX_BUCKET=$(yq '.s3.matrix_bucket' "$TENANT_CONFIG")
    S3_FILES_BUCKET=$(yq '.s3.files_bucket' "$TENANT_CONFIG")
    S3_MAIL_BUCKET=$(yq '.s3.mail_bucket' "$TENANT_CONFIG")
    
    # Validate bucket names
    if [ -z "$S3_CLUSTER" ] || [ "$S3_CLUSTER" == "null" ]; then
        print_error "S3 cluster not found in config. Add s3.cluster to $TENANT_CONFIG"
        exit 1
    fi
    if [ -z "$S3_DOCS_BUCKET" ] || [ "$S3_DOCS_BUCKET" == "null" ]; then
        print_error "Docs bucket not found in config. Add s3.docs_bucket to $TENANT_CONFIG"
        exit 1
    fi
    if [ -z "$S3_MATRIX_BUCKET" ] || [ "$S3_MATRIX_BUCKET" == "null" ]; then
        print_error "Matrix bucket not found in config. Add s3.matrix_bucket to $TENANT_CONFIG"
        exit 1
    fi
    if [ -z "$S3_FILES_BUCKET" ] || [ "$S3_FILES_BUCKET" == "null" ]; then
        print_error "Files bucket not found in config. Add s3.files_bucket to $TENANT_CONFIG"
        exit 1
    fi
    if [ -z "$S3_MAIL_BUCKET" ] || [ "$S3_MAIL_BUCKET" == "null" ]; then
        print_error "Mail bucket not found in config. Add s3.mail_bucket to $TENANT_CONFIG"
        exit 1
    fi
    
    # Load hosts for CORS
    DOMAIN=$(yq '.dns.domain' "$TENANT_CONFIG")
    DOCS_SUBDOMAIN=$(yq '.dns.docs_subdomain' "$TENANT_CONFIG")
    MATRIX_SUBDOMAIN=$(yq '.dns.matrix_subdomain' "$TENANT_CONFIG")
    FILES_SUBDOMAIN=$(yq '.dns.files_subdomain' "$TENANT_CONFIG")
    MAIL_SUBDOMAIN=$(yq '.dns.mail_subdomain' "$TENANT_CONFIG")
    ENV_DNS_LABEL=$(yq '.dns.env_dns_label' "$TENANT_CONFIG")
    
    # Build full hostnames (dev environments have env label in subdomain)
    if [ -n "$ENV_DNS_LABEL" ] && [ "$ENV_DNS_LABEL" != "null" ] && [ "$ENV_DNS_LABEL" != '""' ]; then
        DOCS_HOST="${DOCS_SUBDOMAIN}.${ENV_DNS_LABEL}.${DOMAIN}"
        MATRIX_HOST="${MATRIX_SUBDOMAIN}.${ENV_DNS_LABEL}.${DOMAIN}"
        FILES_HOST="${FILES_SUBDOMAIN}.${ENV_DNS_LABEL}.${DOMAIN}"
        MAIL_HOST="${MAIL_SUBDOMAIN}.${ENV_DNS_LABEL}.${DOMAIN}"
    else
        DOCS_HOST="${DOCS_SUBDOMAIN}.${DOMAIN}"
        MATRIX_HOST="${MATRIX_SUBDOMAIN}.${DOMAIN}"
        FILES_HOST="${FILES_SUBDOMAIN}.${DOMAIN}"
        MAIL_HOST="${MAIL_SUBDOMAIN}.${DOMAIN}"
    fi
    
    # Load current credentials from secrets
    DOCS_ACCESS_KEY=$(yq '.s3_docs.access_key' "$TENANT_SECRETS")
    DOCS_SECRET_KEY=$(yq '.s3_docs.secret_key' "$TENANT_SECRETS")
    MATRIX_ACCESS_KEY=$(yq '.s3_matrix.access_key' "$TENANT_SECRETS")
    MATRIX_SECRET_KEY=$(yq '.s3_matrix.secret_key' "$TENANT_SECRETS")
    FILES_ACCESS_KEY=$(yq '.s3_files.access_key' "$TENANT_SECRETS")
    FILES_SECRET_KEY=$(yq '.s3_files.secret_key' "$TENANT_SECRETS")
    MAIL_ACCESS_KEY=$(yq '.s3_mail.access_key' "$TENANT_SECRETS")
    MAIL_SECRET_KEY=$(yq '.s3_mail.secret_key' "$TENANT_SECRETS")
    
    echo ""
    echo "=========================================="
    echo "S3 Bucket Setup for: $TENANT ($MT_ENV)"
    echo "=========================================="
    echo "Cluster:  $S3_CLUSTER"
    echo "Endpoint: https://${S3_CLUSTER}.linodeobjects.com"
    echo ""
    echo "Buckets:"
    echo "  Docs:   $S3_DOCS_BUCKET"
    echo "  Matrix: $S3_MATRIX_BUCKET"
    echo "  Files:  $S3_FILES_BUCKET"
    echo "  Mail:   $S3_MAIL_BUCKET"
    echo ""
    
    # Track if any credentials were created
    CREDS_CREATED=0
    FAILED=0
    
    # ========================================
    # DOCS BUCKET
    # ========================================
    echo ""
    echo "--- Docs Bucket ---"
    if is_placeholder "$DOCS_ACCESS_KEY" || is_placeholder "$DOCS_SECRET_KEY"; then
        print_warning "Docs credentials are placeholders - creating new keys..."
        keys=$(create_linode_keys "${TENANT}-${MT_ENV}-docs")
        if [ $? -eq 0 ]; then
            DOCS_ACCESS_KEY=$(echo "$keys" | cut -d' ' -f1)
            DOCS_SECRET_KEY=$(echo "$keys" | cut -d' ' -f2)
            update_secrets_file "$TENANT_SECRETS" "s3_docs" "$DOCS_ACCESS_KEY" "$DOCS_SECRET_KEY"
            CREDS_CREATED=1
        else
            print_error "Failed to create docs keys"
            FAILED=1
        fi
    else
        print_status "Using existing docs credentials"
    fi
    
    if [ $FAILED -eq 0 ]; then
        create_bucket "$S3_DOCS_BUCKET" "$DOCS_ACCESS_KEY" "$DOCS_SECRET_KEY" "$S3_CLUSTER" || FAILED=1
        set_cors "$S3_DOCS_BUCKET" "$DOCS_HOST" "$DOCS_ACCESS_KEY" "$DOCS_SECRET_KEY" "$S3_CLUSTER"
    fi
    
    # ========================================
    # MATRIX BUCKET
    # ========================================
    echo ""
    echo "--- Matrix Bucket (for future use) ---"
    if is_placeholder "$MATRIX_ACCESS_KEY" || is_placeholder "$MATRIX_SECRET_KEY"; then
        print_warning "Matrix credentials are placeholders - creating new keys..."
        keys=$(create_linode_keys "${TENANT}-${MT_ENV}-matrix")
        if [ $? -eq 0 ]; then
            MATRIX_ACCESS_KEY=$(echo "$keys" | cut -d' ' -f1)
            MATRIX_SECRET_KEY=$(echo "$keys" | cut -d' ' -f2)
            update_secrets_file "$TENANT_SECRETS" "s3_matrix" "$MATRIX_ACCESS_KEY" "$MATRIX_SECRET_KEY"
            CREDS_CREATED=1
        else
            print_error "Failed to create matrix keys"
            FAILED=1
        fi
    else
        print_status "Using existing matrix credentials"
    fi
    
    if [ $FAILED -eq 0 ]; then
        create_bucket "$S3_MATRIX_BUCKET" "$MATRIX_ACCESS_KEY" "$MATRIX_SECRET_KEY" "$S3_CLUSTER" || FAILED=1
        set_cors "$S3_MATRIX_BUCKET" "$MATRIX_HOST" "$MATRIX_ACCESS_KEY" "$MATRIX_SECRET_KEY" "$S3_CLUSTER"
    fi
    
    # ========================================
    # FILES BUCKET (Nextcloud)
    # ========================================
    echo ""
    echo "--- Files Bucket (Nextcloud) ---"
    if is_placeholder "$FILES_ACCESS_KEY" || is_placeholder "$FILES_SECRET_KEY"; then
        print_warning "Files credentials are placeholders - creating new keys..."
        keys=$(create_linode_keys "${TENANT}-${MT_ENV}-files")
        if [ $? -eq 0 ]; then
            FILES_ACCESS_KEY=$(echo "$keys" | cut -d' ' -f1)
            FILES_SECRET_KEY=$(echo "$keys" | cut -d' ' -f2)
            update_secrets_file "$TENANT_SECRETS" "s3_files" "$FILES_ACCESS_KEY" "$FILES_SECRET_KEY"
            CREDS_CREATED=1
        else
            print_error "Failed to create files keys"
            FAILED=1
        fi
    else
        print_status "Using existing files credentials"
    fi
    
    if [ $FAILED -eq 0 ]; then
        create_bucket "$S3_FILES_BUCKET" "$FILES_ACCESS_KEY" "$FILES_SECRET_KEY" "$S3_CLUSTER" || FAILED=1
        set_cors "$S3_FILES_BUCKET" "$FILES_HOST" "$FILES_ACCESS_KEY" "$FILES_SECRET_KEY" "$S3_CLUSTER"
    fi
    
    # ========================================
    # MAIL BUCKET (Stalwart)
    # ========================================
    echo ""
    echo "--- Mail Bucket (Stalwart) ---"
    if is_placeholder "$MAIL_ACCESS_KEY" || is_placeholder "$MAIL_SECRET_KEY"; then
        print_warning "Mail credentials are placeholders - creating new keys..."
        keys=$(create_linode_keys "${TENANT}-${MT_ENV}-mail")
        if [ $? -eq 0 ]; then
            MAIL_ACCESS_KEY=$(echo "$keys" | cut -d' ' -f1)
            MAIL_SECRET_KEY=$(echo "$keys" | cut -d' ' -f2)
            update_secrets_file "$TENANT_SECRETS" "s3_mail" "$MAIL_ACCESS_KEY" "$MAIL_SECRET_KEY"
            CREDS_CREATED=1
        else
            print_error "Failed to create mail keys"
            FAILED=1
        fi
    else
        print_status "Using existing mail credentials"
    fi
    
    if [ $FAILED -eq 0 ]; then
        create_bucket "$S3_MAIL_BUCKET" "$MAIL_ACCESS_KEY" "$MAIL_SECRET_KEY" "$S3_CLUSTER" || FAILED=1
        set_cors "$S3_MAIL_BUCKET" "$MAIL_HOST" "$MAIL_ACCESS_KEY" "$MAIL_SECRET_KEY" "$S3_CLUSTER"
    fi
    
    # ========================================
    # SUMMARY
    # ========================================
    echo ""
    echo "=========================================="
    echo "Summary"
    echo "=========================================="
    echo "Tenant:        $TENANT"
    echo "Environment:   $MT_ENV"
    echo "Cluster:       $S3_CLUSTER"
    echo ""
    echo "Buckets:"
    echo "  Docs:   $S3_DOCS_BUCKET"
    echo "  Matrix: $S3_MATRIX_BUCKET"
    echo "  Files:  $S3_FILES_BUCKET"
    echo "  Mail:   $S3_MAIL_BUCKET"
    echo ""
    echo "CORS configured for:"
    echo "  Docs:   https://$DOCS_HOST"
    echo "  Matrix: https://$MATRIX_HOST"
    echo "  Files:  https://$FILES_HOST"
    echo "  Mail:   https://$MAIL_HOST"
    echo ""
    
    if [ $CREDS_CREATED -eq 1 ]; then
        print_success "New credentials were created and saved to $TENANT_SECRETS"
    fi
    
    if [ $FAILED -eq 0 ]; then
        print_success "All S3 buckets configured successfully!"
        exit 0
    else
        print_error "Some operations failed. Check the output above."
        exit 1
    fi
}

# Run main function
main "$@"
