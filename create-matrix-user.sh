#!/bin/bash

# Matrix User Creation Script
# Uses the shared secret from environment variables to create users via the admin API

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - use environment variable if set, otherwise derive from SYNAPSE_HOST
SYNAPSE_HOST="${SYNAPSE_HOST:-${MATRIX_HOST:-synapse.${TENANT_DOMAIN:-example.org}}}"
MATRIX_SERVER="https://${SYNAPSE_HOST}"
REGISTRATION_API_BASE="${MATRIX_SERVER}/_matrix/client/r0"
ENVIRONMENT="dev" # default; can be overridden via --env dev|prod
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Function to show usage
show_usage() {
    cat << EOF
Matrix User Creation Script

Usage: $0 [--env dev|prod] [OPTIONS] <username>

Options:
    --env dev|prod              Target environment (default: dev). Refuses prod.
    -p, --password <password>   Set user password (will prompt if not provided)
    -a, --admin                 Create user as admin
    -d, --display-name <name>   Set display name
    -e, --email <email>         Set email address
    -h, --help                  Show this help message

Examples:
    $0 --env dev john.doe
    $0 --env dev -p "securepassword123" -a john.doe
    $0 --env dev -p "mypass" -d "John Doe" -e "john@example.com" jane.smith

Environment Variables:
    TF_VAR_matrix_registration_shared_secret  - Required: Shared secret for admin API
    TENANT_DOMAIN or TF_VAR_domain           - Domain for user ID (from tenant config)
    SYNAPSE_HOST or MATRIX_HOST              - Matrix server hostname

EOF
}

# Function to validate username
validate_username() {
    local username="$1"
    
    # Check if username is provided
    if [[ -z "$username" ]]; then
        print_error "Username is required"
        exit 1
    fi
    
    # Check username format (alphanumeric, dots, hyphens, underscores)
    if [[ ! "$username" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "Username can only contain letters, numbers, dots, hyphens, and underscores"
        exit 1
    fi
    
    # Check length
    if [[ ${#username} -lt 3 ]]; then
        print_error "Username must be at least 3 characters long"
        exit 1
    fi
    
    if [[ ${#username} -gt 50 ]]; then
        print_error "Username must be less than 50 characters long"
        exit 1
    fi
}

# Function to generate secure password
generate_password() {
    openssl rand -base64 16 | tr -d "=+/" | cut -c1-16
}

# Function to create user
create_user() {
    local username="$1"
    local password="$2"
    local is_admin="$3"
    local display_name="$4"
    local email="$5"
    
    # Get domain from environment (tenant config or TF_VAR)
    local domain="${TENANT_DOMAIN:-${TF_VAR_domain:-example.org}}"
    local user_id="@${username}:${domain}"
    
    print_status "Creating user: $user_id"
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is required for user creation"
        exit 1
    fi
    
    # Set KUBECONFIG by environment (absolute path)
    if [[ -z "${KUBECONFIG:-}" ]]; then
        export KUBECONFIG="${SCRIPT_DIR}/kubeconfig.${ENVIRONMENT}.yaml"
    fi
    if [[ ! -f "${KUBECONFIG}" ]]; then
        print_error "Kubeconfig not found: ${KUBECONFIG}"
        exit 1
    fi
    
    # Get Synapse pod name
    SYNAPSE_POD=$(kubectl -n tn-${TENANT_NAME:-example}-matrix get pods -l app.kubernetes.io/name=matrix-synapse -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$SYNAPSE_POD" ]]; then
        print_error "Synapse pod not found"
        exit 1
    fi
    
    # Build the register_new_matrix_user command
    local cmd="kubectl -n tn-${TENANT_NAME:-example}-matrix exec $SYNAPSE_POD -- register_new_matrix_user"
    cmd="$cmd -c /synapse/config/homeserver.yaml"
    cmd="$cmd -c /synapse/config/conf.d/secrets.yaml"
    cmd="$cmd -u $username"
    cmd="$cmd -p $password"
    
    if [[ "$is_admin" == "true" ]]; then
        cmd="$cmd --admin"
    else
        cmd="$cmd --no-admin"
    fi
    
    cmd="$cmd http://localhost:8008"
    
    print_status "Executing: $cmd"
    
    # Execute the command
    local result=$(eval $cmd 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        print_success "User created successfully!"
        echo "User ID: $user_id"
        echo "Password: $password"
        if [[ -n "$display_name" ]]; then
            echo "Display Name: $display_name"
            print_warning "Note: Display name will need to be set separately via Matrix client"
        fi
        if [[ -n "$email" ]]; then
            echo "Email: $email"
            print_warning "Note: Email will need to be set separately via Matrix client"
        fi
        if [[ "$is_admin" == "true" ]]; then
            echo "Admin: Yes"
        fi
    else
        print_error "Failed to create user"
        echo "Command output: $result"
        exit 1
    fi
}

# Main script logic
main() {
    # Parse early global args (env/help)
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
            show_usage
            exit 0
        fi
    done

    # Check for shared secret file
    if [[ -f "matrix-registration-shared-secret.txt" ]]; then
        TF_VAR_matrix_registration_shared_secret=$(cat matrix-registration-shared-secret.txt)
    fi

    # Check if shared secret is available
    if [[ -z "$TF_VAR_matrix_registration_shared_secret" ]]; then
        print_error "TF_VAR_matrix_registration_shared_secret environment variable is not set and matrix-registration-shared-secret.txt not found!"
        print_status "Please source your secrets.tfvars.env file or run the extract step:"
        echo "  source secrets.tfvars.env"
        echo "  ./deploy.sh (to extract the shared secret)"
        exit 1
    fi
    
    # Parse command line arguments
    local username=""
    local password=""
    local is_admin="false"
    local display_name=""
    local email=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -p|--password)
                password="$2"
                shift 2
                ;;
            -a|--admin)
                is_admin="true"
                shift
                ;;
            -d|--display-name)
                display_name="$2"
                shift 2
                ;;
            -e|--email)
                email="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$username" ]]; then
                    username="$1"
                else
                    print_error "Multiple usernames provided"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Refuse to run against prod
    if [[ "${ENVIRONMENT}" == "prod" ]]; then
        print_error "Refusing to create Matrix users on prod environment"
        exit 1
    fi
    
    # Validate username
    validate_username "$username"
    
    # Generate password if not provided
    if [[ -z "$password" ]]; then
        print_status "No password provided, generating secure password..."
        password=$(generate_password)
        print_warning "Generated password: $password"
        print_warning "Please save this password securely!"
    fi
    
    # Create the user
    create_user "$username" "$password" "$is_admin" "$display_name" "$email"
    
    print_success "User creation completed!"
    print_status "The user can now log in to your Matrix server"
}

# Run main function with all arguments
main "$@" 