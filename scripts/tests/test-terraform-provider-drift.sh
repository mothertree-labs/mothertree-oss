#!/usr/bin/env bash
# Unit tests for ci/scripts/terraform-provider-drift.sh -- the CI guard that
# turns a split provider bump (root at `~> 5.0`, module still at `~> 4.0`) into
# a red PR instead of a merged `terraform init` failure. See the script header.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/ci/scripts/terraform-provider-drift.sh"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"
    fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

# --- Fixture: a root that calls a module, both agreeing on linode. The module
# also pins a provider the root does not (dns), in the one-line block form.
mk "$TMP/agree/root/main.tf" <<'TF'
terraform {
  required_version = ">= 1.0"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
    # A documented example must not count as a pin:
    #   version = "~> 9.9"
  }
}
module "m" {
  source = "../modules/m"
}
TF
mk "$TMP/agree/modules/m/main.tf" <<'TF'
terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
    dns = { source = "hashicorp/dns", version = "~> 3.0" }
  }
}
TF
# Stale copies under .terraform/ (e.g. an old init) must be ignored.
mk "$TMP/agree/root/.terraform/modules/m/main.tf" <<'TF'
terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 1.0"
    }
  }
}
TF

out="$("$SCRIPT" "$TMP/agree" 2>&1)"; rc=$?
check "consistent tree exits 0" 0 "$rc"
check "consistent tree summary" "Provider constraints consistent: 2 providers, 3 declarations" "$out"

# --- Split bump: the root moved to ~> 5.0, the module did not.
cp -R "$TMP/agree" "$TMP/split"
sed 's/~> 4.0/~> 5.0/' "$TMP/agree/root/main.tf" > "$TMP/split/root/main.tf"

out="$("$SCRIPT" "$TMP/split" 2>&1)"; rc=$?
check "split bump exits 1" 1 "$rc"
check "split bump names the provider" 1 "$(printf '%s\n' "$out" | grep -c '^  linode/linode$')"
check "split bump lists the root" 1 "$(printf '%s\n' "$out" | grep -c '~> 5.0 .*root/main.tf')"
check "split bump lists the module" 1 "$(printf '%s\n' "$out" | grep -c '~> 4.0 .*modules/m/main.tf')"
check "split bump does not blame dns" 0 "$(printf '%s\n' "$out" | grep -c 'hashicorp/dns')"

# --- An unconstrained declaration intersects with anything: not drift.
cp -R "$TMP/agree" "$TMP/unpinned"
mk "$TMP/unpinned/root/extra.tf" <<'TF'
terraform {
  required_providers {
    linode = {
      source = "linode/linode"
    }
  }
}
TF
out="$("$SCRIPT" "$TMP/unpinned" 2>&1)"; rc=$?
check "unconstrained declaration is ignored" 0 "$rc"

# --- Nothing to parse is an error, not a pass (fail-fast).
mkdir -p "$TMP/empty"
"$SCRIPT" "$TMP/empty" >/dev/null 2>&1; rc=$?
check "no required_providers exits 2" 2 "$rc"
"$SCRIPT" "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
check "missing directory exits 2" 2 "$rc"

# --- The real tree must pass, or CI is already red.
"$SCRIPT" >/dev/null 2>&1; rc=$?
check "repository tree is consistent" 0 "$rc"

echo "terraform-provider-drift: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
