#!/usr/bin/env bash
# Image tag loader for deploy scripts
# Sources image-tags.env from config/platform and constructs full image refs.
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/image-tags.sh"
#   _mt_load_image_tags
#
# After loading, these variables are set:
#   ADMIN_PORTAL_IMAGE   - Full image ref (registry/name:tag)
#   ACCOUNT_PORTAL_IMAGE - Full image ref
#   ROUNDCUBE_IMAGE      - Full image ref
#   PERF_IMAGE           - Full image ref
#
# Override precedence (highest to lowest):
#   1. Existing env var (e.g., ADMIN_PORTAL_IMAGE_TAG=sha-xyz)
#   2. config/platform/image-tags.env
#   3. Fallback to :latest (for OSS users without CI)

# Guard against double-sourcing
if [ -n "${_MT_IMAGE_TAGS_LOADED:-}" ]; then
  return 0
fi
_MT_IMAGE_TAGS_LOADED=1

_mt_load_image_tags() {
  local repo_root="${REPO_ROOT:?REPO_ROOT must be set}"

  # Ensure paths.sh is loaded for project.conf resolution
  if [ -z "${MT_PROJECT_CONF+x}" ]; then
    source "${repo_root}/scripts/lib/paths.sh"
    _mt_resolve_project_conf
    [[ -n "$MT_PROJECT_CONF" ]] && source "$MT_PROJECT_CONF"
  fi

  local registry="${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}"

  # Source image tags file if it exists (env vars already set take precedence)
  local tags_file="${repo_root}/config/platform/image-tags.env"
  if [ -f "$tags_file" ]; then
    # Only set variables that aren't already set in the environment
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^#.*$ ]] && continue
      [[ -z "$key" ]] && continue
      # Use indirect expansion to check if already set
      if [ -z "${!key+x}" ]; then
        export "$key=$value"
      fi
    done < "$tags_file"
  fi

  # Construct full image refs with fallback to :latest
  export ADMIN_PORTAL_IMAGE="${ADMIN_PORTAL_IMAGE:-${registry}/mothertree-admin-portal:${ADMIN_PORTAL_IMAGE_TAG:-latest}}"
  export ACCOUNT_PORTAL_IMAGE="${ACCOUNT_PORTAL_IMAGE:-${registry}/mothertree-account-portal:${ACCOUNT_PORTAL_IMAGE_TAG:-latest}}"
  export ROUNDCUBE_IMAGE="${ROUNDCUBE_IMAGE:-${registry}/mothertree-roundcube:${ROUNDCUBE_IMAGE_TAG:-latest}}"
  export PERF_IMAGE="${PERF_IMAGE:-${registry}/mothertree-perf:${PERF_IMAGE_TAG:-latest}}"
}
