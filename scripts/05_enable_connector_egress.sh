#!/usr/bin/env bash
# ==============================================================================
# Step 7C: Enable Egress Agent Gateway Routing (use_agent_gateway_egress: true)
#          and ACTIONS Mode on the Gemini Enterprise Custom MCP Data Connector
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

set -a
source "${REPO_ROOT}/.env"
set +a

PYTHON_BIN="${REPO_ROOT}/.venv/bin/python"
if [[ ! -x "${PYTHON_BIN}" ]]; then
  PYTHON_BIN="python3"
fi

TOKEN="$(gcloud auth print-access-token)"

echo "==> Looking up Custom MCP DataConnector in '${GE_LOCATION}'..."
COLLECTIONS_JSON="$(curl -sS \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  "https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${GE_LOCATION}/collections")"

RESOLVED_COLLECTION_ID="$(
  COLLECTIONS_JSON="${COLLECTIONS_JSON}" TARGET_ID="${CONNECTOR_COLLECTION_ID:-}" "${PYTHON_BIN}" -c '
import json, os, sys
data = json.loads(os.environ["COLLECTIONS_JSON"])
target = os.environ.get("TARGET_ID", "").strip()
collections = data.get("collections", [])
mcp_cols = [
    c for c in collections
    if c.get("dataConnector", {}).get("dataSource") == "custom_mcp"
]
for c in mcp_cols:
    cid = c["name"].split("/")[-1]
    if target and cid == target:
        print(cid)
        sys.exit(0)
for c in mcp_cols:
    cid = c["name"].split("/")[-1]
    dname = c.get("displayName", "")
    if target and (dname == target or cid.startswith(target + "_")):
        print(cid)
        sys.exit(0)
if len(mcp_cols) == 1:
    print(mcp_cols[0]["name"].split("/")[-1])
    sys.exit(0)
sys.exit(1)
' || true
)"

if [[ -z "${RESOLVED_COLLECTION_ID}" ]]; then
  echo "Error: Could not find a Custom MCP DataConnector matching '${CONNECTOR_COLLECTION_ID:-}'." >&2
  exit 1
fi

if [[ "${RESOLVED_COLLECTION_ID}" != "${CONNECTOR_COLLECTION_ID:-}" ]]; then
  echo "    Auto-detected Collection ID: ${RESOLVED_COLLECTION_ID} (updating .env)"
  sed -i "s|^CONNECTOR_COLLECTION_ID=.*|CONNECTOR_COLLECTION_ID=${RESOLVED_COLLECTION_ID}|" "${REPO_ROOT}/.env"
  CONNECTOR_COLLECTION_ID="${RESOLVED_COLLECTION_ID}"
fi

CONNECTOR_URL="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${GE_LOCATION}/collections/${CONNECTOR_COLLECTION_ID}/dataConnector"

echo "==> [1/2] Updating actionConfig (use_agent_gateway_egress=true) on (${CONNECTOR_COLLECTION_ID})..."
curl -sS -X PATCH \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  "${CONNECTOR_URL}?updateMask=bapConfig,dynamicTools,actionConfig" \
  -d "{
    \"name\": \"projects/${PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/${CONNECTOR_COLLECTION_ID}/dataConnector\",
    \"actionConfig\": {
      \"actionParams\": {
        \"mcp_server_source\": \"BYO_MCP\",
        \"auth_key\": \"OAuth\",
        \"client_secret_basic_override\": true,
        \"auth_type\": \"OAUTH\",
        \"token_uri\": \"https://oauth2.googleapis.com/token\",
        \"instance_uri\": \"https://${MCP_SERVICE_FQDN}/mcp\",
        \"pkce_support_enabled\": false,
        \"use_agent_gateway_egress\": true,
        \"auth_uri_params\": \"&access_type=offline&prompt=consent\",
        \"scopes\": \"openid email profile\",
        \"auth_uri\": \"https://accounts.google.com/o/oauth2/v2/auth\"
      },
      \"createBapConnection\": true
    },
    \"bapConfig\": {
      \"enabledActions\": [
        \"get_private_vpc_record\",
        \"whoami\"
      ]
    },
    \"dynamicTools\": [
      {
        \"name\": \"get_private_vpc_record\",
        \"displayName\": \"get_private_vpc_record\",
        \"description\": \"Fetches a sample confidential record from the private Cloud Run MCP server.\",
        \"enabled\": true
      },
      {
        \"name\": \"whoami\",
        \"displayName\": \"whoami\",
        \"description\": \"Returns the authenticated OAuth 2.0 user identity and dual-header auth status.\",
        \"enabled\": true
      }
    ]
  }" >/dev/null || true

echo "==> [2/2] Enabling FEDERATED and ACTIONS modes and verifying use_agent_gateway_egress..."
FINAL_RESP="$(curl -sS -X PATCH \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  "${CONNECTOR_URL}?updateMask=connectorModes,bapConfig,dynamicTools,actionConfig.actionParams.use_agent_gateway_egress" \
  -d "{
    \"name\": \"projects/${PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/${CONNECTOR_COLLECTION_ID}/dataConnector\",
    \"connectorModes\": [
      \"FEDERATED\",
      \"ACTIONS\"
    ],
    \"actionConfig\": {
      \"actionParams\": {
        \"use_agent_gateway_egress\": true
      }
    },
    \"bapConfig\": {
      \"enabledActions\": [
        \"get_private_vpc_record\",
        \"whoami\"
      ]
    },
    \"dynamicTools\": [
      {
        \"name\": \"get_private_vpc_record\",
        \"displayName\": \"get_private_vpc_record\",
        \"description\": \"Fetches a sample confidential record from the private Cloud Run MCP server.\",
        \"enabled\": true
      },
      {
        \"name\": \"whoami\",
        \"displayName\": \"whoami\",
        \"description\": \"Returns the authenticated OAuth 2.0 user identity and dual-header auth status.\",
        \"enabled\": true
      }
    ]
  }")"

echo "${FINAL_RESP}" | "${PYTHON_BIN}" -m json.tool
