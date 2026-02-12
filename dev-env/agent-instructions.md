# Agent Environment

You are running inside a containerized dev environment. Your instance name is in `$MT_INSTANCE` and your assigned tenant is in `$MT_TENANT`.

## What You Can Do

- Edit code, commit, push, and create PRs on your branch
- Deploy your tenant's apps: `./scripts/create_env --tenant=$MT_TENANT dev`
- Run kubectl, helm, helmfile commands against the dev cluster
- Build and push Docker images (admin portal, roundcube)
- Run any scripts in `apps/` and `scripts/` that use kubectl/helm/helmfile

## What You Cannot Do

- **DO NOT run Terraform commands** (`terraform plan`, `terraform apply`, `deploy_infra`, `manage_infra`). There is no Terraform state in this environment and running these commands could damage shared infrastructure.
- If your task requires Terraform changes (DNS modules, infra config, cluster changes), edit the Terraform files and create a PR. Ask the user to apply the changes from the host.

## Deployment

Your tenant is `$MT_TENANT`. You deploy to `tn-$MT_TENANT-*` namespaces only.

```bash
# Deploy all tenant apps
./scripts/create_env --tenant=$MT_TENANT dev

# Deploy a single component (these are called by create_env)
MT_ENV=dev apps/deploy-docs.sh
MT_ENV=dev apps/deploy-jitsi.sh
MT_ENV=dev apps/deploy-stalwart.sh
MT_ENV=dev apps/deploy-nextcloud.sh
MT_ENV=dev TENANT=$MT_TENANT apps/deploy-roundcube.sh

# Helmfile (Synapse, Element)
cd apps && helmfile -e dev -l tier=apps sync
```

## Git Workflow

- Your branch is already checked out. Commit and push freely.
- Create PRs with: `gh pr create --base main`
- The remote is pre-configured with authentication.
