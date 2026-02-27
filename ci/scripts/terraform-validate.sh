#!/usr/bin/env bash
set -euo pipefail

echo "--- :terraform: Terraform Validate"

FAIL=0

for dir in phase1 infra ci/terraform; do
  if [ ! -d "$dir" ]; then
    echo "Skipping $dir (not found)"
    continue
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
