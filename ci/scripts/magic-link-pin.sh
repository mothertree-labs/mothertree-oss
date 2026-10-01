#!/usr/bin/env bash
# Keep the Keycloak magic-link jar pin consistent: ML_VERSION + ML_SHA256 in the
# fetch-magic-link-provider init container (apps/values/keycloak-codecentric.yaml).
#
# Why: Renovate bumps ML_VERSION but cannot touch ML_SHA256 (hosted Renovate has
# no file digest for Maven and does not run postUpgradeTasks). A stale hash is
# only noticed by the init container, which then crash-loops Keycloak on the
# shared dev cluster and times out every pipeline's deploy-dev-prep.
#
#   --check  (validate step, every pipeline) download the pinned version and fail
#            unless its sha256 equals ML_SHA256. Runs before any dev deploy.
#   --fix    (GitHub Action on renovate/** branches) verify the jar's PGP
#            signature against phasetwo's pinned key (ci/keys/phasetwo-bot.asc)
#            and rewrite ML_SHA256 to the verified jar's sha256.
#
# Both modes also require Maven Central's .sha1 to match the download. That only
# guards against a corrupt transfer; trust comes from the committed pin (check)
# or the signature (fix).
#
# Usage: magic-link-pin.sh --check|--fix [values-file]
# Exit:  0 pin matches (or was rewritten by --fix), 1 pin mismatch (--check),
#        2 any other error.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAVEN_BASE="https://repo1.maven.org/maven2"
ARTIFACT_PATH="io/phasetwo/keycloak/keycloak-magic-link"
# Primary key of phasetwo-bot <bot@phasetwo.io>, which signs every release on
# Maven Central.
SIGNER_KEY_FILE="${REPO_ROOT}/ci/keys/phasetwo-bot.asc"
SIGNER_FPR="51E5BAA1B195629172C33395BC6B4EADEB514AFD"
# Overrides for scripts/tests/magic-link-pin.test.sh only (file:// Maven tree and
# a throwaway key). Ignored otherwise, so a job environment cannot quietly swap
# the trust root the --fix signature check rests on.
if [ "${MAGIC_LINK_PIN_TEST:-}" = 1 ]; then
  MAVEN_BASE="${MAVEN_BASE_OVERRIDE:?}"
  SIGNER_KEY_FILE="${MAGIC_LINK_SIGNER_KEY_FILE:?}"
  SIGNER_FPR="${MAGIC_LINK_SIGNER_FPR:?}"
fi

die() { echo "ERROR: $*" >&2; exit 2; }

mode="${1:-}"
case "$mode" in
  --check|--fix) ;;
  *) die "usage: $0 --check|--fix [values-file]" ;;
esac
values="${2:-${REPO_ROOT}/apps/values/keycloak-codecentric.yaml}"
[ -f "$values" ] || die "values file not found: $values"

# Exactly one assignment of each, in exactly the canonical form: --fix can never
# rewrite the wrong line, and no second assignment in another form (export,
# unquoted, `; NAME=` mid-line) can override the value --check verified.
pin_value() {
  local name=$1 lines any
  lines=$(grep -cE "^[[:space:]]*${name}=\"[^\"]*\"[[:space:]]*$" "$values" || true)
  any=$(grep -cE "${name}[[:space:]]*=" "$values" || true)
  [ "$lines" = 1 ] && [ "$any" = 1 ] \
    || die "expected exactly one ${name}=\"...\" line and no other ${name} assignment in $values (canonical: ${lines}, any: ${any})"
  sed -nE "s/^[[:space:]]*${name}=\"([^\"]*)\"[[:space:]]*$/\\1/p" "$values"
}
version=$(pin_value ML_VERSION)
pinned=$(pin_value ML_SHA256)
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "ML_VERSION is not a plain version: '$version'"
[[ "$pinned" =~ ^[0-9a-f]{64}$ ]] || die "ML_SHA256 is not a sha256: '$pinned'"

tmp=$(mktemp -d)
trap '[ -d "$tmp/gnupg" ] && GNUPGHOME="$tmp/gnupg" gpgconf --kill all 2>/dev/null; rm -rf "$tmp"' EXIT
url="${MAVEN_BASE}/${ARTIFACT_PATH}/${version}/keycloak-magic-link-${version}.jar"

fetch() {
  curl -fsSL --retry 3 --retry-delay 5 --max-time 120 -o "$2" "$1" \
    || die "download failed: $1"
}
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
sha1_of()   { if command -v sha1sum   >/dev/null; then sha1sum   "$1"; else shasum -a 1   "$1"; fi | cut -d' ' -f1; }

echo "magic-link ${version}: ${url}"
fetch "$url" "$tmp/jar"
fetch "${url}.sha1" "$tmp/jar.sha1"
published_sha1=$(tr -d '[:space:]' < "$tmp/jar.sha1" | cut -c1-40)
[ "$(sha1_of "$tmp/jar")" = "$published_sha1" ] \
  || die "download does not match Maven Central's .sha1 (${published_sha1}) — corrupt transfer?"
actual=$(sha256_of "$tmp/jar")

if [ "$mode" = --check ]; then
  if [ "$actual" = "$pinned" ]; then
    echo "OK: ML_SHA256 matches keycloak-magic-link ${version}"
    exit 0
  fi
  echo "FAIL: ML_SHA256 does not match keycloak-magic-link ${version}" >&2
  echo "  pinned: ${pinned}" >&2
  echo "  actual: ${actual}" >&2
  echo "  The init container would refuse this jar and crash-loop Keycloak." >&2
  echo "  On renovate/** branches the magic-link-pin GitHub Action rewrites the hash" >&2
  echo "  after verifying the release signature; elsewhere run: ci/scripts/magic-link-pin.sh --fix" >&2
  exit 1
fi

# --fix: the new hash is only as trustworthy as this signature check.
command -v gpg >/dev/null || die "gpg is required for --fix"
[ -f "$SIGNER_KEY_FILE" ] || die "signer key not found: $SIGNER_KEY_FILE"
fetch "${url}.asc" "$tmp/jar.asc"
export GNUPGHOME="$tmp/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$SIGNER_KEY_FILE" 2>/dev/null || die "cannot import $SIGNER_KEY_FILE"
status=$(gpg --batch --status-fd 1 --verify "$tmp/jar.asc" "$tmp/jar" 2>/dev/null || true)
# VALIDSIG <signing-key-fpr> ... <primary-key-fpr>: accept the pinned primary key
# or a subkey of it, nothing else that might be in the imported file.
# gpg still prints VALIDSIG next to EXPKEYSIG/REVKEYSIG, so those (and any
# BADSIG/ERRSIG) veto it.
if ! awk -v fpr="$SIGNER_FPR" '
    $1=="[GNUPG:]" && $2=="VALIDSIG" && ($3==fpr || $NF==fpr) {ok=1}
    $1=="[GNUPG:]" && $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG)$/ {bad=1}
    END {exit !(ok && !bad)}' <<<"$status"; then
  die "keycloak-magic-link ${version} is not validly signed by ${SIGNER_FPR} — refusing to pin it"
fi
echo "Signature OK (${SIGNER_FPR})"

if [ "$actual" = "$pinned" ]; then
  echo "OK: ML_SHA256 already matches keycloak-magic-link ${version}"
  exit 0
fi
sed -E "s/^([[:space:]]*ML_SHA256=\")[0-9a-f]{64}(\"[[:space:]]*)$/\\1${actual}\\2/" "$values" > "$tmp/values"
cat "$tmp/values" > "$values"
[ "$(pin_value ML_SHA256)" = "$actual" ] || die "rewrite of ML_SHA256 in $values did not take"
echo "UPDATED: ML_SHA256 ${pinned} -> ${actual} (keycloak-magic-link ${version})"
