#!/usr/bin/env bash
# Platform release version loader
# Reads VERSION from repo root and computes a deploy-time release string.
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/release.sh"
#   _mt_load_release_version
#
# After loading, this variable is set:
#   RELEASE_VERSION - e.g. "0.8.0-ab292eb" (clean) or "0.8.0-ab292eb-M" (dirty)

# Guard against double-sourcing
if [ -n "${_MT_RELEASE_LOADED:-}" ]; then
  return 0
fi
_MT_RELEASE_LOADED=1

_mt_load_release_version() {
  local repo_root="${REPO_ROOT:?REPO_ROOT must be set}"
  local version_file="${repo_root}/VERSION"

  if [ ! -f "$version_file" ]; then
    export RELEASE_VERSION="unknown"
    return 0
  fi

  local base_version
  base_version="$(cat "$version_file" | tr -d '[:space:]')"

  local git_hash=""
  local dirty=""

  if git -C "$repo_root" rev-parse --git-dir > /dev/null 2>&1; then
    git_hash="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || true)"
    if ! git -C "$repo_root" diff --quiet HEAD 2>/dev/null; then
      dirty="-M"
    fi
  fi

  if [ -n "$git_hash" ]; then
    export RELEASE_VERSION="${base_version}-${git_hash}${dirty}"
  else
    export RELEASE_VERSION="${base_version}"
  fi
}
