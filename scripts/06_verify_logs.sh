#!/usr/bin/env bash
# ==============================================================================
# Verification: Inspect Private Routing & Dual-Header Auth in Cloud Logging
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

set -a
source "${REPO_ROOT}/.env"
set +a

echo "==> [1/2] Egress Agent Gateway Logs (check SERVER_IP: 199.36.153.8/30 for PGA or ${PSC_ENDPOINT_IP} for PSC):"
gcloud logging read 'resource.type="networkservices.googleapis.com/Gateway"' \
  --project="${PROJECT_ID}" \
  --limit=10 \
  --format="table(timestamp, jsonPayload.agentGatewayInfo.mcpInfo.method, httpRequest.requestUrl, httpRequest.serverIp, httpRequest.status, httpRequest.latency)"

echo ""
echo "==> [2/2] Private Cloud Run MCP Server Logs (check has_auth_header=True | has_x_serverless_auth=True):"
gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${SERVICE_NAME}\"" \
  --project="${PROJECT_ID}" \
  --limit=15 \
  --format="table(timestamp, httpRequest.status, textPayload)"
