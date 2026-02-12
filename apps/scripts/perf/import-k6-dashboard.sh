#!/usr/bin/env bash
set -euo pipefail

# Import a Grafana dashboard JSON via HTTP API.
# Requires: GRAFANA_URL, GRAFANA_API_KEY, and DASHBOARD_JSON path.

if [[ -z "${GRAFANA_URL:-}" || -z "${GRAFANA_API_KEY:-}" ]]; then
  echo "Set GRAFANA_URL and GRAFANA_API_KEY" >&2
  exit 1
fi

DASHBOARD_JSON=${DASHBOARD_JSON:-perf/grafana/k6-dashboard.json}

if [[ ! -f "${DASHBOARD_JSON}" ]]; then
  echo "Dashboard JSON not found: ${DASHBOARD_JSON}" >&2
  exit 2
fi

payload=$(jq -c --argjson dash "$(cat "${DASHBOARD_JSON}")" '{dashboard: $dash, overwrite: true, folderId: 0}')

curl -sS -X POST "${GRAFANA_URL%/}/api/dashboards/db" \
  -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "${payload}"

echo
echo "Dashboard import attempted. Check Grafana UI for results."



