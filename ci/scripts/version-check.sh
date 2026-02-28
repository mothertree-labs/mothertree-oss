#!/usr/bin/env bash
# Validate that VERSION files are bumped when source files change.
# Runs on every push/PR. Fails with a clear error if source changed but VERSION didn't.
#
# Usage: ci/scripts/version-check.sh

set -euo pipefail

echo "--- :label: Checking VERSION bumps"

# Determine base ref for diffing
if [ -n "${CI_COMMIT_TARGET_BRANCH:-}" ]; then
  # PR: diff against target branch
  git fetch origin "${CI_COMMIT_TARGET_BRANCH}" --depth=1 2>/dev/null || true
  BASE_REF="origin/${CI_COMMIT_TARGET_BRANCH}"
elif [ "${CI_COMMIT_BRANCH:-}" = "main" ]; then
  # Main branch: diff against previous commit
  BASE_REF="HEAD~1"
else
  # Feature branch (not a PR): diff against main
  git fetch origin main --depth=1 2>/dev/null || true
  BASE_REF="origin/main"
fi

echo "Base ref: ${BASE_REF}"

# Get list of changed files
CHANGED_FILES=$(git diff --name-only "${BASE_REF}" HEAD 2>/dev/null || echo "")

if [ -z "$CHANGED_FILES" ]; then
  echo "No changed files detected, skipping version check"
  exit 0
fi

FAIL=0

# Patterns that don't count as "source changes" requiring a version bump.
# These are test infrastructure, config, and non-runtime files.
NON_SOURCE_PATTERNS=(
  '/__tests__/'
  '/jest\.config\.'
  '/\.gitignore$'
  '/coverage/'
  '/\.eslintrc'
  '/\.prettierrc'
  'image-versions\.env$'
  '/package\.json$'
  '/package-lock\.json$'
)

# Filter out non-source files from a list of changed files.
# Reads file paths from stdin, outputs only source-relevant files.
filter_source_files() {
  local pattern_args=()
  for pat in "${NON_SOURCE_PATTERNS[@]}"; do
    pattern_args+=(-e "$pat")
  done
  grep -v "${pattern_args[@]}" || true
}

# Check each component: if source paths changed (excluding VERSION and non-source files),
# VERSION must also change.
check_component() {
  local name="$1"
  local version_file="$2"
  shift 2
  local source_paths=("$@")

  local source_changed=false
  local version_changed=false

  for path in "${source_paths[@]}"; do
    # Get changed files under this path, excluding VERSION and non-source patterns
    local relevant
    relevant=$(echo "$CHANGED_FILES" | grep "^${path}" | grep -vx "${version_file}" | filter_source_files || true)
    if [ -n "$relevant" ]; then
      source_changed=true
      break
    fi
  done

  if echo "$CHANGED_FILES" | grep -qx "${version_file}"; then
    version_changed=true
  fi

  if [ "$source_changed" = true ] && [ "$version_changed" = false ]; then
    echo "^^^ +++"
    echo "ERROR: ${name} source files changed but ${version_file} was not bumped."
    echo ""
    echo "Changed files in ${name}:"
    for path in "${source_paths[@]}"; do
      echo "$CHANGED_FILES" | grep "^${path}" | grep -vx "${version_file}" | filter_source_files || true
    done
    echo ""
    echo "Fix: bump the version in ${version_file}"
    FAIL=1
  elif [ "$source_changed" = true ] && [ "$version_changed" = true ]; then
    echo "OK: ${name} — source changed, VERSION bumped"
  else
    echo "OK: ${name} — no source changes (test/config-only changes are excluded)"
  fi
}

check_component "admin-portal" \
  "apps/admin-portal/VERSION" \
  "apps/admin-portal/"

check_component "account-portal" \
  "apps/account-portal/VERSION" \
  "apps/account-portal/"

check_component "roundcube" \
  "apps/docker/roundcube/VERSION" \
  "apps/docker/roundcube/" \
  "submodules/roundcubemail-plugins-kolab/" \
  "submodules/mailvelope_client/"

check_component "perf" \
  "perf/VERSION" \
  "perf/"

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Version check failed. Bump the VERSION file(s) listed above."
  exit 1
fi

echo ""
echo "All version checks passed"
