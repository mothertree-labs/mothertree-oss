#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source project config if available (provides GITHUB_ORG)
[[ -f "$REPO_DIR/project.conf" ]] && source "$REPO_DIR/project.conf"
IMAGE_NAME="mothertree-dev"
BASE_DIR="$HOME/.mothertree-dev"

usage() {
    cat <<'EOF'
Usage: ./dev-env/start.sh <instance-name> <tenant> [branch-name]

  instance-name   Unique name for this instance (e.g., agent1)
  tenant          Tenant to deploy as (e.g., example)
  branch-name     Git branch (default: claude/<instance-name>)

Examples:
  ./dev-env/start.sh agent1 example
  ./dev-env/start.sh agent2 example fix/email

Environment variables:
  GITHUB_TOKEN        Required for push/PR, optional otherwise
EOF
    exit 1
}

# --- Parse args ---
[[ $# -lt 2 ]] && usage
INSTANCE="$1"
TENANT="$2"
BRANCH="${3:-claude/$INSTANCE}"

# --- Validate tenant ---
if [[ ! -f "$REPO_DIR/tenants/$TENANT/dev.config.yaml" ]]; then
    echo "Error: Unknown tenant '$TENANT'. Expected tenants/\$TENANT/dev.config.yaml to exist."
    echo "Available tenants:"
    ls -1 "$REPO_DIR/tenants/"
    exit 1
fi

# --- Check prereqs ---
if ! docker info &>/dev/null; then
    echo "Error: Docker is not running."
    exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "Warning: GITHUB_TOKEN is not set. Push and PR operations will not work."
fi

# --- Build image if needed ---
DOCKERFILE_HASH=$(md5sum "$SCRIPT_DIR/Dockerfile" 2>/dev/null || md5 -q "$SCRIPT_DIR/Dockerfile")
CURRENT_LABEL=$(docker inspect --format='{{index .Config.Labels "dockerfile.hash"}}' "$IMAGE_NAME" 2>/dev/null || echo "")

NEEDS_BUILD=false
if [[ "$CURRENT_LABEL" != "$DOCKERFILE_HASH" ]]; then
    NEEDS_BUILD=true
else
    # Rebuild if image is older than 24 hours (picks up new package versions)
    IMAGE_CREATED=$(docker inspect --format='{{.Created}}' "$IMAGE_NAME" 2>/dev/null || echo "")
    if [[ -n "$IMAGE_CREATED" ]]; then
        IMAGE_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%S" "${IMAGE_CREATED%%.*}" +%s 2>/dev/null \
            || date -d "${IMAGE_CREATED%%.*}" +%s 2>/dev/null \
            || echo 0)
        NOW_EPOCH=$(date +%s)
        AGE_HOURS=$(( (NOW_EPOCH - IMAGE_EPOCH) / 3600 ))
        if [[ $AGE_HOURS -ge 24 ]]; then
            echo "Image is ${AGE_HOURS}h old, rebuilding to pick up updates..."
            NEEDS_BUILD=true
        fi
    fi
fi

if [[ "$NEEDS_BUILD" == "true" ]]; then
    echo "Building $IMAGE_NAME image..."
    docker build --label "dockerfile.hash=$DOCKERFILE_HASH" -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# --- Check for existing container ---
CONTAINER_NAME="mt-dev-$INSTANCE"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '$CONTAINER_NAME' is already running."
    echo "To attach: docker exec -it $CONTAINER_NAME bash"
    exit 1
fi

# --- Clone or update repo ---
INSTANCE_DIR="$BASE_DIR/$INSTANCE"
CLONE_DIR="$INSTANCE_DIR/repo"

if [[ ! -d "$CLONE_DIR/.git" ]]; then
    echo "Cloning repo for instance '$INSTANCE'..."
    mkdir -p "$INSTANCE_DIR"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        git clone --recurse-submodules "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG:-YOUR_ORG}/mothertree.git" "$CLONE_DIR"
    else
        git clone --recurse-submodules "https://github.com/${GITHUB_ORG:-YOUR_ORG}/mothertree.git" "$CLONE_DIR"
    fi
else
    echo "Updating repo for instance '$INSTANCE'..."
    # Update remote URL in case token changed
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        git -C "$CLONE_DIR" remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG:-YOUR_ORG}/mothertree.git"
    fi
    git -C "$CLONE_DIR" fetch origin
fi

# Ensure submodules are initialized (clone may skip SSH-url submodules)
git -C "$CLONE_DIR" submodule sync
git -C "$CLONE_DIR" submodule update --init --force --recursive

# --- Clean up modified CLAUDE.md from previous run before branch switch ---
git -C "$CLONE_DIR" update-index --no-skip-worktree CLAUDE.md 2>/dev/null || true
git -C "$CLONE_DIR" checkout -- CLAUDE.md 2>/dev/null || true

# --- Branch management ---
cd "$CLONE_DIR"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "Checking out existing branch '$BRANCH'..."
    git checkout "$BRANCH"
    git rebase origin/main || { echo "Error: Rebase failed. Aborting."; git rebase --abort; exit 1; }
else
    echo "Creating new branch '$BRANCH' from origin/main..."
    git checkout -b "$BRANCH" origin/main
fi
cd - >/dev/null

# --- Copy secrets ---
echo "Copying secrets into clone..."

# kubeconfig
cp -f "$REPO_DIR/kubeconfig.dev.yaml" "$CLONE_DIR/kubeconfig.dev.yaml" 2>/dev/null || echo "Warning: kubeconfig.dev.yaml not found"

# Tenant secrets (only the assigned tenant)
mkdir -p "$CLONE_DIR/tenants/$TENANT"
cp -f "$REPO_DIR/tenants/$TENANT/dev.secrets.yaml" "$CLONE_DIR/tenants/$TENANT/dev.secrets.yaml" 2>/dev/null || echo "Warning: tenants/$TENANT/dev.secrets.yaml not found"

# Terraform secrets
cp -f "$REPO_DIR/secrets.dev.tfvars.env" "$CLONE_DIR/secrets.dev.tfvars.env" 2>/dev/null || echo "Warning: secrets.dev.tfvars.env not found"
cp -f "$REPO_DIR/terraform.tfvars" "$CLONE_DIR/terraform.tfvars" 2>/dev/null || echo "Warning: terraform.tfvars not found"
cp -f "$REPO_DIR/terraform.dev.tfvars" "$CLONE_DIR/terraform.dev.tfvars" 2>/dev/null || echo "Warning: terraform.dev.tfvars not found"

# Keycloak Google OAuth secret
mkdir -p "$CLONE_DIR/docs"
cp -f "$REPO_DIR/docs/keycloak-google-oauth-secret.yaml" "$CLONE_DIR/docs/keycloak-google-oauth-secret.yaml" 2>/dev/null || echo "Warning: docs/keycloak-google-oauth-secret.yaml not found"

# --- Prepend agent instructions to CLAUDE.md ---
AGENT_INSTRUCTIONS="$SCRIPT_DIR/agent-instructions.md"
CLONE_CLAUDE_MD="$CLONE_DIR/CLAUDE.md"
if [[ -f "$AGENT_INSTRUCTIONS" ]]; then
    ORIGINAL_CLAUDE_MD="$REPO_DIR/CLAUDE.md"
    if [[ -f "$ORIGINAL_CLAUDE_MD" ]]; then
        cat "$AGENT_INSTRUCTIONS" <(echo "") "$ORIGINAL_CLAUDE_MD" > "$CLONE_CLAUDE_MD"
    else
        cp "$AGENT_INSTRUCTIONS" "$CLONE_CLAUDE_MD"
    fi
    # Tell git to ignore local modifications to CLAUDE.md (it's already tracked,
    # so .gitignore won't help — skip-worktree prevents it from showing as changed)
    git -C "$CLONE_DIR" update-index --skip-worktree CLAUDE.md
fi

# --- Git identity ---
GIT_NAME="${GIT_AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo "Claude Dev")}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo "claude@dev")}"

# --- Start container ---
echo "Starting container '$CONTAINER_NAME' (tenant=$TENANT, branch=$BRANCH)..."
exec docker run \
    --name "$CONTAINER_NAME" \
    --rm -it \
    -v "$CLONE_DIR:/workspace" \
    -v "mt-dev-claude-config:/home/devuser/.claude" \
    -v "mt-dev-terraform-cache:/home/devuser/.terraform.d/plugin-cache" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -e "GITHUB_TOKEN=${GITHUB_TOKEN:-}" \
    -e "GH_TOKEN=${GITHUB_TOKEN:-}" \
    -e "MT_ENV=dev" \
    -e "MT_INSTANCE=${INSTANCE}" \
    -e "MT_TENANT=${TENANT}" \
    -e "KUBECONFIG=/workspace/kubeconfig.dev.yaml" \
    -e "TURN_SERVER_IP=172.233.137.114" \
    -e "GIT_AUTHOR_NAME=${GIT_NAME}" \
    -e "GIT_AUTHOR_EMAIL=${GIT_EMAIL}" \
    -e "GIT_COMMITTER_NAME=${GIT_NAME}" \
    -e "GIT_COMMITTER_EMAIL=${GIT_EMAIL}" \
    --user "$(id -u):$(id -g)" \
    --memory 4g \
    --cpus 2 \
    "$IMAGE_NAME"
