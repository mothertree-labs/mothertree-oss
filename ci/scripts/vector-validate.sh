#!/usr/bin/env bash
# Validate the rendered Vector configuration with the exact Vector binary the
# cluster will run.
#
# Why: a Helm chart bump can change the packaged Vector version, and Vector
# rejects config keys that newer releases removed (exit 78 at startup). Neither
# `helmfile lint` nor the e2e suite sees that; the DaemonSet just crash-loops
# after deploy (issue #612, chart 0.46 -> 0.58 dropped `api.playground`).
#
# What it does, per helmfile environment:
#   1. `helmfile template` the `vector` release with dummy requiredEnv values
#   2. pull the ConfigMap the DaemonSet mounts and the image the DaemonSet runs
#   3. `docker run <that image> validate --no-environment --deny-warnings`
#
# `--no-environment` skips data_dir / permission / sink health checks (no Loki
# here); the config schema and every VRL program are still fully checked.
#
# Requires: helmfile, helm, yq (mikefarah v4), docker. All present on the CI VM.
set -euo pipefail

echo "--- :vector: Vector config validation"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/scripts/lib/helmfile-lint-env.sh
source "${REPO_ROOT}/ci/scripts/lib/helmfile-lint-env.sh"

# Every helmfile environment that deploys the vector release. Override with a
# space-separated list if an environment needs to be skipped temporarily.
VECTOR_VALIDATE_ENVS="${VECTOR_VALIDATE_ENVS:-dev prod prod-eu}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "${REPO_ROOT}/apps"

FAIL=0
for env in ${VECTOR_VALIDATE_ENVS}; do
  echo ""
  echo "=== environment: ${env}"
  out="${tmp}/${env}"
  mkdir -p "${out}"

  # No --skip-deps here: this step must be able to fetch a chart version the
  # CI box has never seen (a chart-bump PR is exactly the case it guards), so
  # let helmfile add/refresh the repo itself.
  helmfile -e "${env}" -l name=vector template > "${out}/rendered.yaml"

  image="$(yq 'select(.kind=="DaemonSet" and .metadata.name=="vector") | .spec.template.spec.containers[0].image' "${out}/rendered.yaml")"
  : "${image:?could not find the vector DaemonSet image in the rendered helmfile output (env=${env})}"
  [ "${image}" != "null" ] || { echo "ERROR: vector DaemonSet image rendered as null (env=${env})"; exit 1; }

  yq 'select(.kind=="ConfigMap" and .metadata.name=="vector") | .data["vector.yaml"]' "${out}/rendered.yaml" > "${out}/vector.yaml"
  if [ ! -s "${out}/vector.yaml" ] || [ "$(head -c 4 "${out}/vector.yaml")" = "null" ]; then
    echo "ERROR: rendered ConfigMap 'vector' has no vector.yaml key (env=${env})"
    exit 1
  fi

  echo "image: ${image}"
  echo "config: $(wc -l < "${out}/vector.yaml") lines"
  # Only vector.yaml is mounted; rendered.yaml stays outside the container.
  mkdir -p "${out}/etc"
  cp "${out}/vector.yaml" "${out}/etc/vector.yaml"
  # `validate --no-environment` needs no network, capabilities or privilege:
  # run the (repo-controlled) image with all of them removed.
  if docker run --rm --network none --cap-drop ALL \
       --security-opt no-new-privileges --pids-limit 256 \
       -v "${out}/etc:/etc/vector:ro" "${image}" \
       validate --no-environment --deny-warnings /etc/vector/vector.yaml; then
    echo "OK: vector config valid for ${image} (env=${env})"
  else
    echo "FAIL: vector config rejected by ${image} (env=${env}) — see output above"
    FAIL=1
  fi
done

echo ""
if [ "${FAIL}" -ne 0 ]; then
  echo "Vector config validation FAILED"
  exit 1
fi
echo "Vector config validation passed"
