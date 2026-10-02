#!/usr/bin/env bash
# Unit tests for ci/scripts/magic-link-pin.sh. No network: MAVEN_BASE points at a
# file:// tree, and a throwaway GnuPG key stands in for phasetwo's signer.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="${REPO_ROOT}/ci/scripts/magic-link-pin.sh"
command -v gpg >/dev/null || { echo "FAIL: gpg is required for this test"; exit 1; }

tmp=$(mktemp -d)
trap 'GNUPGHOME="$tmp/keys" gpgconf --kill all 2>/dev/null; rm -rf "$tmp"' EXIT
export GNUPGHOME="$tmp/keys"
mkdir -m 700 "$GNUPGHOME"

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
sha1_of()   { if command -v sha1sum   >/dev/null; then sha1sum   "$1"; else shasum -a 1   "$1"; fi | cut -d' ' -f1; }

genkey() {  # genkey <uid> -> prints the primary fingerprint
  gpg --batch --quiet --passphrase '' --quick-gen-key "$1" ed25519 sign never 2>/dev/null
  gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'
}
GOOD_FPR=$(genkey "signer <signer@example.com>")
EVIL_FPR=$(genkey "other <other@example.com>")
gpg --batch --armor --export "$GOOD_FPR" > "$tmp/signer.asc"

# publish <version> <content> [signing-fpr]: lay out a Maven Central-like release.
publish() {
  local dir="$tmp/maven/io/phasetwo/keycloak/keycloak-magic-link/$1"
  local jar="$dir/keycloak-magic-link-$1.jar"
  mkdir -p "$dir"
  printf '%s' "$2" > "$jar"
  sha1_of "$jar" > "$jar.sha1"
  rm -f "$jar.asc"
  gpg --batch --quiet --armor --detach-sign -u "${3:-$GOOD_FPR}" -o "$jar.asc" "$jar" 2>/dev/null
  sha256_of "$jar"
}
values() {  # values <version> <sha256> -> path to a minimal values file
  local f="$tmp/values-$RANDOM.yaml"
  printf '      - |\n        ML_VERSION="%s"\n        ML_SHA256="%s"\n        echo done\n' "$1" "$2" > "$f"
  echo "$f"
}
run() {  # run <expected-rc> <name> <args...>
  local want=$1 name=$2 rc=0; shift 2
  MAGIC_LINK_PIN_TEST=1 MAVEN_BASE_OVERRIDE="file://$tmp/maven" \
    MAGIC_LINK_SIGNER_KEY_FILE="$tmp/signer.asc" MAGIC_LINK_SIGNER_FPR="$GOOD_FPR" \
    "$PIN" "$@" >"$tmp/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL: $name (rc=$rc, want $want)"; cat "$tmp/out"; exit 1
  fi
  echo "ok - $name"
}

SHA_1=$(publish 1.0 "jar one")
SHA_2=$(publish 2.0 "jar two")
STALE=$(printf 'a%.0s' {1..64})

f=$(values 1.0 "$SHA_1"); run 0 "check passes when the pin matches" --check "$f"
f=$(values 2.0 "$SHA_1"); run 1 "check fails on a stale hash after a version bump" --check "$f"
grep -q "actual: $SHA_2" "$tmp/out" || { echo "FAIL: check does not print the actual hash"; exit 1; }

f=$(values 2.0 "$SHA_1"); run 0 "fix rewrites a stale hash for a signed jar" --fix "$f"
grep -qx "        ML_SHA256=\"$SHA_2\"" "$f" || { echo "FAIL: fix did not write the new hash"; cat "$f"; exit 1; }
grep -qx '        echo done' "$f" || { echo "FAIL: fix damaged the rest of the file"; exit 1; }
run 0 "check passes after fix" --check "$f"
run 0 "fix is a no-op when the pin already matches" --fix "$f"

SHA_3=$(publish 3.0 "jar three" "$EVIL_FPR")
f=$(values 3.0 "$STALE"); run 2 "fix refuses a jar signed by another key" --fix "$f"
grep -q "ML_SHA256=\"$STALE\"" "$f" || { echo "FAIL: refused fix still modified the file"; exit 1; }
[ "$SHA_3" != "$STALE" ]

publish 4.0 "jar four" >/dev/null
printf 'tampered' >> "$tmp/maven/io/phasetwo/keycloak/keycloak-magic-link/4.0/keycloak-magic-link-4.0.jar"
f=$(values 4.0 "$STALE"); run 2 "check errors when the download does not match .sha1" --check "$f"
f=$(values 4.0 "$STALE"); run 2 "fix refuses a jar whose signature no longer verifies" --fix "$f"

f=$(values 1.0 "$SHA_1"); echo "        ML_SHA256=\"$SHA_1\"" >> "$f"
run 2 "refuses a file with two ML_SHA256 lines" --check "$f"
f=$(values 1.0 "$SHA_1"); echo "        export ML_SHA256=$STALE" >> "$f"
run 2 "refuses a second ML_SHA256 assignment in another form" --check "$f"
f=$(values 1.0 "$SHA_1"); echo "        true; ML_VERSION=2.0" >> "$f"
run 2 "refuses a mid-line ML_VERSION reassignment" --check "$f"

# Without test mode the overrides are ignored: the real (network) Maven base
# would be used, so point it at a version that cannot exist offline and expect
# the default signer, not ours, to be in effect.
rc=0; MAVEN_BASE_OVERRIDE="file://$tmp/maven" MAGIC_LINK_SIGNER_FPR="$GOOD_FPR" \
  "$PIN" --fix "$(values 1.0 "$STALE")" >"$tmp/out" 2>&1 || rc=$?
grep -q "file://" "$tmp/out" && { echo "FAIL: overrides honoured outside test mode"; cat "$tmp/out"; exit 1; }
[ "$rc" != 0 ] || { echo "FAIL: fix succeeded with ignored overrides"; exit 1; }
echo "ok - env overrides are ignored outside test mode"

# A signature by an expired key: gpg reports VALIDSIG *and* EXPKEYSIG.
EXP_FPR=$(genkey "expiring <exp@example.com>")
gpg --batch --quiet --quick-set-expire "$EXP_FPR" seconds=1 2>/dev/null \
  || gpg --batch --quiet --passphrase '' --quick-set-expire "$EXP_FPR" 1d 2>/dev/null
SHA_5=$(publish 5.0 "jar five" "$EXP_FPR")
gpg --batch --armor --export "$EXP_FPR" > "$tmp/exp.asc"
sleep 2
rc=0; MAGIC_LINK_PIN_TEST=1 MAVEN_BASE_OVERRIDE="file://$tmp/maven" \
  MAGIC_LINK_SIGNER_KEY_FILE="$tmp/exp.asc" MAGIC_LINK_SIGNER_FPR="$EXP_FPR" \
  "$PIN" --fix "$(values 5.0 "$STALE")" >"$tmp/out" 2>&1 || rc=$?
grep -q "not validly signed" "$tmp/out" || { echo "FAIL: expired-key refusal had the wrong cause"; cat "$tmp/out"; exit 1; }
[ "$rc" = 2 ] || { echo "FAIL: fix accepted a signature by an expired key (rc=$rc)"; cat "$tmp/out"; exit 1; }
[ "$SHA_5" != "$STALE" ]
echo "ok - fix refuses a signature by an expired key"
f=$(values 9.9 "$SHA_1"); run 2 "errors when the version is not published" --check "$f"
run 2 "rejects an unknown mode" --frobnicate "$f"

echo "All magic-link-pin tests passed"
