# Contributing to Mothertree

Thank you for your interest in contributing to Mothertree! This document provides guidelines and information for contributors.

## Getting Started

### Development Environment

1. **Clone the repository**
   ```bash
   git clone https://github.com/YOUR_ORG/mothertree.git
   cd mothertree
   ```

2. **Install prerequisites**
   - `terraform` >= 1.0
   - `kubectl`
   - `helm` >= 3.0
   - `helmfile`
   - `yq` >= 4.0
   - `node` >= 18 (for admin-portal and account-portal)

3. **Set up tenant configuration**
   ```bash
   cp -r tenants/example tenants/my-dev-tenant
   # Edit config files with your domain and settings
   ```

4. **Set up secrets**
   ```bash
   cp secrets.tfvars.env.example secrets.tfvars.env
   cp tenants/my-dev-tenant/dev.secrets.yaml.example tenants/my-dev-tenant/dev.secrets.yaml
   # Fill in actual values
   ```

### Running Locally

**Admin Portal:**
```bash
cd apps/admin-portal
npm install
cp .env.example .env  # Edit with your settings
npm start
```

**Account Portal:**
```bash
cd apps/account-portal
npm install
cp .env.example .env  # Edit with your settings
npm start
```

## Making Changes

### Branching Strategy

- `main` is the stable branch
- Create feature branches from `main`: `feature/description`
- Create bugfix branches from `main`: `fix/description`

### Pull Request Process

1. Create a feature branch from `main`
2. Make your changes with clear, atomic commits
3. Ensure your changes don't introduce hardcoded domains or credentials
4. Test your changes in a dev environment if possible
5. Open a pull request against `main`

### PR Requirements

- Clear description of what changed and why
- No hardcoded domains, credentials, or personal information
- Scripts should read configuration from tenant config files or environment variables
- New features should follow the existing multi-tenant architecture

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

## Reporting Issues

- Use GitHub Issues for bug reports and feature requests
- Include relevant logs, configuration (sanitized), and steps to reproduce
- For security vulnerabilities, see the Security section in [README.md](README.md)

## License

By contributing to Mothertree, you agree that your contributions will be licensed under the [AGPL-3.0 License](LICENSE).
