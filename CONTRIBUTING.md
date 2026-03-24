# Contributing to Mothertree

Thank you for your interest in contributing to Mothertree! This document provides guidelines and information for contributors.

## Getting Started

### Development Environment

1. **Clone the repository**
   ```bash
   git clone --recurse-submodules https://github.com/YOUR_ORG/mothertree.git
   cd mothertree
   make setup  # Initialize submodules if you have access
   ```

2. **Install prerequisites** (see [tool installation guide](#installing-cli-tools) below)
   - `terraform` >= 1.0
   - `kubectl` >= 1.27
   - `helm` >= 3.0
   - `helmfile` >= 1.0
   - `kustomize` >= 5.0
   - `yq` >= 4.0
   - `jq`
   - `envsubst` (from `gettext`)
   - `openssl`
   - `curl`
   - `node` >= 22 LTS (for admin-portal and account-portal)

3. **Set up tenant configuration**
   ```bash
   # Create your own tenant from the example template
   cp -r tenants/.example tenants/my-dev-tenant
   # Edit config files with your domain and settings
   ```

4. **Set up secrets**
   ```bash
   cp secrets.tfvars.env.example secrets.tfvars.env
   cp tenants/my-dev-tenant/dev.secrets.yaml.example tenants/my-dev-tenant/dev.secrets.yaml
   # Fill in actual values
   ```

### Running Locally

**Account Portal (with Keycloak):**
```bash
# First-time setup: starts Keycloak and account-portal
./scripts/localhost/setup-account-portal.sh --restart-keycloak

# Subsequent runs: just start the account-portal (assumes Keycloak is running)
./scripts/localhost/setup-account-portal.sh
```

The script:
- Starts a local Keycloak container (version synced with prod)
- Creates a dev realm with a test user
- Configures the account-portal client
- Starts the account-portal on http://localhost:3000
- Test credentials: `testuser` / `testpassword`

**Admin Portal:**
```bash
cd apps/admin-portal
npm install
cp .env.example .env  # Edit with your settings
npm start
```

## Installing CLI Tools

### macOS (Homebrew)

```bash
# Core tools — all available via Homebrew
brew install terraform kubectl helm helmfile kustomize yq jq gettext openssl curl node@22

# gettext (provides envsubst) needs to be linked since it's keg-only
brew link --force gettext

# Verify
terraform version && kubectl version --client && helm version && helmfile version && \
kustomize version && yq --version && jq --version && envsubst --version && node --version
```

Optional tools:
```bash
brew install ansible gh dig swaks postgresql linode-cli docker
```

### Linux (Fedora / RHEL / CentOS)

Most tools are **not available** via `dnf` in compatible versions. Install from upstream releases.

> **Warning**: On Fedora, running an uninstalled command may create a PackageKit stub script instead of reporting "command not found". Always verify tools work correctly after installing — run `<tool> version` and check the output makes sense.

```bash
# System packages (available via dnf)
sudo dnf install -y jq gettext openssl curl git

# Node.js 22 LTS (via NodeSource)
curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
sudo dnf install -y nodejs

# kubectl
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# Terraform
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Helmfile — must be v1.x, not v0.x (check latest: https://github.com/helmfile/helmfile/releases)
curl -fsSL -o /tmp/helmfile.tar.gz https://github.com/helmfile/helmfile/releases/download/v1.4.2/helmfile_1.4.2_linux_amd64.tar.gz
tar xzf /tmp/helmfile.tar.gz -C /tmp helmfile
sudo mv /tmp/helmfile /usr/local/bin/helmfile && rm /tmp/helmfile.tar.gz

# Kustomize (check latest: https://github.com/kubernetes-sigs/kustomize/releases)
curl -fsSL -o /tmp/kustomize.tar.gz https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz
tar xzf /tmp/kustomize.tar.gz -C /tmp
sudo mv /tmp/kustomize /usr/local/bin/kustomize && rm /tmp/kustomize.tar.gz

# yq (check latest: https://github.com/mikefarah/yq/releases)
curl -fsSL -o /tmp/yq https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64
sudo install -o root -g root -m 0755 /tmp/yq /usr/local/bin/yq && rm /tmp/yq

# Verify all tools
terraform version && kubectl version --client && helm version && helmfile version && \
kustomize version && yq --version && jq --version && envsubst --version && node --version
```

Optional tools:
```bash
# Ansible (for VPN/Postfix relay setup)
sudo dnf install -y ansible-core

# GitHub CLI
sudo dnf install -y 'dnf-command(config-manager)'
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh

# Other optional tools
sudo dnf install -y bind-utils swaks postgresql docker-ce
```

### Linux (Ubuntu / Debian)

```bash
# System packages
sudo apt-get update && sudo apt-get install -y jq gettext-base openssl curl git

# Node.js 22 LTS (via NodeSource)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs

# kubectl
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# Terraform
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Helmfile — must be v1.x, not v0.x (check latest: https://github.com/helmfile/helmfile/releases)
curl -fsSL -o /tmp/helmfile.tar.gz https://github.com/helmfile/helmfile/releases/download/v1.4.2/helmfile_1.4.2_linux_amd64.tar.gz
tar xzf /tmp/helmfile.tar.gz -C /tmp helmfile
sudo mv /tmp/helmfile /usr/local/bin/helmfile && rm /tmp/helmfile.tar.gz

# Kustomize (check latest: https://github.com/kubernetes-sigs/kustomize/releases)
curl -fsSL -o /tmp/kustomize.tar.gz https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz
tar xzf /tmp/kustomize.tar.gz -C /tmp
sudo mv /tmp/kustomize /usr/local/bin/kustomize && rm /tmp/kustomize.tar.gz

# yq (check latest: https://github.com/mikefarah/yq/releases)
curl -fsSL -o /tmp/yq https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64
sudo install -o root -g root -m 0755 /tmp/yq /usr/local/bin/yq && rm /tmp/yq

# Verify all tools
terraform version && kubectl version --client && helm version && helmfile version && \
kustomize version && yq --version && jq --version && envsubst --version && node --version
```

Optional tools:
```bash
# Ansible (for VPN/Postfix relay setup)
sudo apt-get install -y ansible

# GitHub CLI (https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
(type -p wget >/dev/null || sudo apt-get install wget -y) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt-get update && sudo apt-get install gh -y

# Other optional tools
sudo apt-get install -y dnsutils swaks postgresql-client docker.io
```

### Verifying Your Setup

After installing all tools, run the verification one-liner:

```bash
echo "--- Tool Versions ---" && \
for cmd in terraform kubectl helm helmfile kustomize yq jq envsubst openssl curl node; do
  printf "%-12s " "$cmd:" && ($cmd --version 2>/dev/null || $cmd version 2>/dev/null) | head -1
done
```

All commands should print a version. If any command prints package metadata, help text, or errors instead of a version, the binary is likely a stub or the wrong tool — reinstall it from the upstream source.

## Making Changes

### Branching Strategy

- `main` is the stable branch
- Create feature branches from `main`: `feature/description`
- Create bugfix branches from `main`: `fix/description`

### Pull Request Process

1. Create a feature branch from `main`
2. Make your changes with clear, atomic commits
3. Ensure your changes don't introduce hardcoded domains or credentials
4. Push and open a pull request against `main`
5. CI automatically: validates, builds images, deploys to dev, runs E2E tests
6. Once the `mothertree-build` gate passes, the PR is ready for review
7. On merge to main, CI automatically deploys to prod (all tenants)

### PR Requirements

- Clear description of what changed and why
- No hardcoded domains, credentials, or personal information
- Scripts should read configuration from tenant config files or environment variables
- New features should follow the existing multi-tenant architecture
- CI must pass (validate + E2E) before merge

## Code Style

### Shell Scripts
- Use `set -euo pipefail` for error handling
- Use functions for reusable logic
- Use `print_status`, `print_success`, `print_error` for output
- Read tenant config via `yq` from `tenants/<name>/<env>.config.yaml`

### JavaScript (Admin/Account Portals)
- Express + EJS templates
- OIDC authentication via Keycloak
- Required environment variables should fail fast at startup

### Terraform
- Use modules for reusable infrastructure
- Use variables with descriptions for all configurable values
- Use workspaces to separate environments

### Helm/Helmfile
- Use Go templates for environment-aware configuration
- Use `values/` for base values, `environments/<env>/` for overrides

## Architecture Principles

- **Multi-tenant isolation**: Each tenant gets its own namespaces and resources
- **Configuration over code**: Domains, ports, and features come from tenant config files
- **Three-phase deployment**: Infrastructure -> Shared services -> Tenant apps
- **No hardcoded defaults**: Scripts should fail if required configuration is missing
- **Config separation**: Operator-specific config (domains, registries, sizing) lives in private `config/` submodules. The main repo contains only generic, public-safe code. See `scripts/lib/paths.sh` for the path resolution logic that supports both submodule and flat layouts.

## Reporting Issues

- Use GitHub Issues for bug reports and feature requests
- Include relevant logs, configuration (sanitized), and steps to reproduce
- For security vulnerabilities, see the Security section in [README.md](README.md)

## License

By contributing to Mothertree, you agree that your contributions will be licensed under the [AGPL-3.0 License](LICENSE).
