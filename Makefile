.PHONY: setup pull lint ci-validate ci-build

# Initialize/update all submodules (requires access to private config repos)
setup:
	git submodule update --init --recursive

# Pull latest changes including submodule updates
pull:
	git pull --recurse-submodules
	git submodule update --recursive

# Lint Helm values (requires helmfile, helm)
lint:
	cd apps && helmfile -e dev lint

# Run all CI validation checks locally
ci-validate:
	ci/scripts/shellcheck.sh
	ci/scripts/terraform-validate.sh
	ci/scripts/helmfile-lint.sh
	ci/scripts/npm-check.sh

# Build all images locally (no push)
ci-build:
	ci/scripts/build-admin-portal.sh
	ci/scripts/build-account-portal.sh
	apps/scripts/build-roundcube-image.sh
	cd apps && apps/scripts/perf/build-k6-image.sh
