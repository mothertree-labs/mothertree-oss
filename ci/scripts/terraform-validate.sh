#!/usr/bin/env bash
set -euo pipefail

echo "--- :terraform: Terraform Validate"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../.."

# A provider pinned in more than one place must carry the same constraint
# everywhere, or a root and a module it calls disagree and `terraform init`
# resolves to the empty set (#504). Pure text, no network, so it runs first
# and names the offending files even when init below would only say
# "no available releases match".
"$HERE/terraform-provider-drift.sh"

FAIL=0

# Every ROOT config an operator or CI runs. Modules are exercised through the
# roots that call them: `init -backend=false` still installs modules and
# intersects their provider constraints. A missing root is an error, not a
# skip -- a silent skip is how phase1-dev went unvalidated for months.
for dir in phase1 phase1-dev ci/terraform; do
  if [ ! -d "$dir" ]; then
    echo "^^^ +++"
    echo "Terraform root $dir not found -- update the list in $0 if it moved"
    exit 1
  fi

  echo "--- Validating $dir"
  pushd "$dir" > /dev/null

  if ! terraform init -backend=false -input=false; then
    echo "^^^ +++"
    echo "Terraform init failed in $dir"
    FAIL=1
    popd > /dev/null
    continue
  fi
  if ! terraform validate; then
    echo "^^^ +++"
    echo "Terraform validate failed in $dir"
    FAIL=1
  fi

  if ! terraform fmt -check -diff; then
    echo "^^^ +++"
    echo "Terraform fmt check failed in $dir"
    FAIL=1
  fi

  popd > /dev/null
done

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi

echo "All Terraform directories validated"
