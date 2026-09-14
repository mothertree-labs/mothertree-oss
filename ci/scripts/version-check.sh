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

FAIL=0

# ---------------------------------------------------------------------------
# Assert every component's image pin in apps/image-versions.env matches its
# VERSION file.
#
# This runs UNCONDITIONALLY, not only when a component's sources changed. The
# drift it catches arises precisely from changes that do NOT touch
# image-versions.env: perf/VERSION went 0.1.0 -> 0.2.1 -> 0.2.2 across two
# Renovate batches while PERF_IMAGE_TAG stayed at 0.1.0, and version-check.sh
# explicitly excludes image-versions.env from source detection (see
# NON_SOURCE_PATTERNS), so nothing ever compared them. That drift was invisible
# for two releases because nothing consumed PERF_IMAGE; once the perf manifests
# started using it, CI would have built :0.2.2 while the Jobs pulled :0.1.0 --
# a clean, successful run of the wrong image rather than a loud failure.
# ---------------------------------------------------------------------------
# Anchor to the repo root: check_pin is this script's first filesystem read, so
# relative paths would make it the only part that depends on CWD.
_VC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_FILE="${_VC_ROOT}/apps/image-versions.env"

check_pin() {
  local name="$1" version_file="$2" pin_key="$3"
  local want have

  version_file="${_VC_ROOT}/${version_file}"

  if [ ! -f "$version_file" ]; then
    echo "ERROR: ${name} — ${version_file} not found"; FAIL=1; return
  fi
  want=$(tr -d ' \t\r\n' < "$version_file")
  have=$(grep -E "^${pin_key}=" "$PIN_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \t\r\n')

  if [ -z "$want" ]; then
    echo "ERROR: ${name} — ${version_file} is empty"; FAIL=1; return
  fi
  if [ -z "$have" ]; then
    echo "^^^ +++"
    echo "ERROR: ${name} — ${pin_key} is missing from ${PIN_FILE}."
    echo "Fix: add ${pin_key}=${want} to ${PIN_FILE}"
    FAIL=1; return
  fi
  case "$have" in
    *[\"\']*)
      echo "^^^ +++"
      echo "ERROR: ${name} — ${pin_key} in ${PIN_FILE} is quoted: ${pin_key}=${have}"
      echo "Values must be bare (KEY=1.2.3); image-tags.sh would export the quotes"
      echo "into the image reference and the pull would fail."
      FAIL=1; return ;;
  esac
  if [ "$want" != "$have" ]; then
    echo "^^^ +++"
    echo "ERROR: ${name} — image pin does not match its VERSION file."
    echo "  ${PIN_FILE}: ${pin_key}=${have}"
    echo "  ${version_file}: ${want}"
    echo ""
    echo "The deploy manifests pull the pinned tag, so a mismatch means the"
    echo "cluster runs a different build than CI produced -- silently."
    echo "Fix: set ${pin_key}=${want} in ${PIN_FILE}"
    echo ""
    echo "Deliberately pinning an older image (a rollback, or build-now-deploy-later)?"
    echo "Re-run with MT_ALLOW_PIN_DRIFT=1 to allow it. Note that this gate feeds"
    echo "validate -> mothertree-build -> deploy-prod, so without it the rollback"
    echo "does not deploy either."
    if [ "${MT_ALLOW_PIN_DRIFT:-0}" = "1" ]; then
      echo "MT_ALLOW_PIN_DRIFT=1 — allowing the mismatch."
      return
    fi
    FAIL=1; return
  fi
  echo "OK: ${name} — pin ${pin_key}=${have} matches ${version_file}"
}

check_pin "admin-portal"   "apps/admin-portal/VERSION"    "ADMIN_PORTAL_IMAGE_TAG"
check_pin "account-portal" "apps/account-portal/VERSION"  "ACCOUNT_PORTAL_IMAGE_TAG"
check_pin "roundcube"      "apps/docker/roundcube/VERSION" "ROUNDCUBE_IMAGE_TAG"
check_pin "perf"           "perf/VERSION"                 "PERF_IMAGE_TAG"

# A fifth component must not be silently unguarded -- that is the same
# "nothing ever compared them" failure this gate exists to prevent.
_vc_checked="ADMIN_PORTAL_IMAGE_TAG ACCOUNT_PORTAL_IMAGE_TAG ROUNDCUBE_IMAGE_TAG PERF_IMAGE_TAG"
while IFS= read -r _vc_key; do
  case " $_vc_checked " in
    *" $_vc_key "*) ;;
    *) echo "^^^ +++"
       echo "ERROR: ${_vc_key} in ${PIN_FILE} has no check_pin call in $(basename "${BASH_SOURCE[0]}")."
       echo "Add one so its pin is compared against its VERSION file."
       FAIL=1 ;;
  esac
done < <(grep -oE '^[A-Z_]+_IMAGE_TAG' "$PIN_FILE" 2>/dev/null || true)

if [ -z "$CHANGED_FILES" ]; then
  # The pin checks above need no diff and have already run. Reaching here also
  # covers a FAILED `git fetch`: the fetch is `|| true` and the diff is
  # `2>/dev/null || echo ""`, so an unreachable forge lands here with an empty
  # list -- which is exactly when a vacuous pass is most dangerous.
  echo "No changed files detected (or base ref unavailable); skipping the source/VERSION checks"
  if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "Version check failed on the pin invariant above."
    exit 1
  fi
  exit 0
fi

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
