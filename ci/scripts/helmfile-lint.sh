#!/usr/bin/env bash
set -euo pipefail

echo "--- :helm: Helmfile Lint"

# Dummy env vars for all requiredEnv references in helmfile.yaml.gotmpl.
# Only needed for template rendering during lint — no real cluster access.
# shellcheck source=ci/scripts/lib/helmfile-lint-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/helmfile-lint-env.sh"

cd apps

helmfile -e dev lint
echo "Helmfile lint passed"
