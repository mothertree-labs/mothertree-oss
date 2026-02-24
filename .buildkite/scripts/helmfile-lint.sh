#!/usr/bin/env bash
set -euo pipefail

echo "--- :helm: Helmfile Lint"

cd apps

# Export dummy env vars for all requiredEnv references in helmfile.yaml.gotmpl
# These are only needed for template rendering during lint — no real cluster access
export NS_INGRESS="infra-ingress"
export NS_CERTMANAGER="infra-cert-manager"
export NS_MONITORING="infra-monitoring"
export NS_INGRESS_INTERNAL="infra-ingress-internal"
export NS_AUTH="infra-auth"
export NS_OFFICE="tn-lint-docs"
export NS_MATRIX="tn-lint-matrix"
export NS_FILES="tn-lint-files"
export NS_JITSI="tn-lint-jitsi"

helmfile -e dev lint
echo "Helmfile lint passed"
