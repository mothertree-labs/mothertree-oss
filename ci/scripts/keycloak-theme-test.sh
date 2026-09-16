#!/usr/bin/env bash
# Browser-test the platform Keycloak theme against the exact Keycloak image the
# cluster runs.
#
# Why: the theme's templates call into Keycloak's own static resources and page
# data, and a Keycloak release can move or drop them. webauthn-register.ftl
# loaded base64url from ${url.resourcesCommonPath}/node_modules/, which no
# Keycloak 26 image ships, so "Register Passkey" threw
# `ReferenceError: base64url is not defined` in production. The dev-cluster e2e
# suite never ran that page's own script (it re-implements the ceremony), and
# nothing re-checked the theme when Renovate bumped the image.
#
# What it does:
#   1. read the image from apps/values/keycloak-codecentric.yaml (override with
#      KEYCLOAK_IMAGE=quay.io/keycloak/keycloak:<tag> to try a candidate)
#   2. `docker run ... start-dev` with apps/themes/platform mounted where the
#      init container extracts it in the cluster (/opt/keycloak/themes/platform),
#      ports published on loopback only
#   3. run e2e/keycloak-theme/*.spec.ts (Playwright + virtual authenticator)
#
# No cluster, lease or secrets. Requires: docker, yq (mikefarah v4), node/npm,
# curl, openssl. All present on the CI VM.
set -euo pipefail

echo "--- :keycloak: Keycloak theme browser test"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALUES="${REPO_ROOT}/apps/values/keycloak-codecentric.yaml"

if [ -z "${KEYCLOAK_IMAGE:-}" ]; then
  repository="$(yq '.image.repository' "${VALUES}")"
  tag="$(yq '.image.tag' "${VALUES}")"
  if [ -z "${repository}" ] || [ "${repository}" = "null" ] || [ -z "${tag}" ] || [ "${tag}" = "null" ]; then
    echo "ERROR: could not read image.repository/image.tag from ${VALUES}"
    exit 1
  fi
  KEYCLOAK_IMAGE="${repository}:${tag}"
fi
echo "image: ${KEYCLOAK_IMAGE}"

container="mt-kc-theme-test-${CI_PIPELINE_NUMBER:-local}-$$"
admin_user="admin"
admin_password="$(openssl rand -hex 24)"

cleanup() {
  local rc=$?
  if [ "${rc}" -ne 0 ] && docker inspect "${container}" >/dev/null 2>&1; then
    echo "--- Keycloak container log (last 80 lines)"
    docker logs --tail 80 "${container}" 2>&1 || true
  fi
  docker rm -f "${container}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

docker pull --quiet "${KEYCLOAK_IMAGE}" >/dev/null
docker run -d --name "${container}" \
  -p 127.0.0.1::8080 -p 127.0.0.1::9000 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${admin_user}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${admin_password}" \
  -e KC_HEALTH_ENABLED=true \
  -v "${REPO_ROOT}/apps/themes/platform:/opt/keycloak/themes/platform:ro" \
  "${KEYCLOAK_IMAGE}" start-dev >/dev/null

host_port() {
  docker port "${container}" "$1/tcp" | head -n1 | sed 's/.*://'
}
http_port="$(host_port 8080)"
mgmt_port="$(host_port 9000)"
: "${http_port:?could not read the published Keycloak HTTP port}"
: "${mgmt_port:?could not read the published Keycloak management port}"

echo "Waiting for Keycloak to become ready..."
deadline=$((SECONDS + 240))
until curl -sf "http://127.0.0.1:${mgmt_port}/health/ready" >/dev/null; do
  if [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null)" != "true" ]; then
    echo "ERROR: Keycloak container exited during startup"
    exit 1
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "ERROR: Keycloak not ready after 240s"
    exit 1
  fi
  sleep 2
done
echo "Keycloak ready on port ${http_port}"

cd "${REPO_ROOT}/e2e"
if [ "${CI:-}" = "true" ]; then
  # Same shared browser cache the e2e shards use (see ci/scripts/e2e-setup.sh).
  export PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers
  npm ci --ignore-scripts
else
  [ -d node_modules ] || npm ci --ignore-scripts
fi
npx playwright install chromium

# `localhost`, not 127.0.0.1: WebAuthn needs a secure context and a domain RP ID.
KC_THEME_TEST_URL="http://localhost:${http_port}" \
KC_THEME_TEST_ADMIN_USER="${admin_user}" \
KC_THEME_TEST_ADMIN_PASSWORD="${admin_password}" \
  npx playwright test --config keycloak-theme/playwright.config.ts
