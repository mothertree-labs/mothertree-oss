.PHONY: setup pull lint

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
