#!/usr/bin/env bash
# ==============================================================================
# Step 4: Create Egress Agent Gateway, Grant IAM to Auto-Created Gateway Service
#         Accounts, and Attach the PSC Network Attachment
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

wait_for_lro() {
  local op_name="$1"
  echo "    Waiting for operation ${op_name} to complete..."
  while true; do
    local token
    token="$(gcloud auth print-access-token)"
    local op_json
    op_json="$(curl -sS -H "Authorization: Bearer ${token}" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" \
      "https://networkservices.googleapis.com/v1alpha1/${op_name}")"

    local status
    status="$( OP_JSON="${op_json}" "${PYTHON_BIN}" -c '
import json, os, sys
data = json.loads(os.environ["OP_JSON"])
if "error" in data:
    print("ERROR:" + json.dumps(data["error"]))
elif data.get("done") is True:
    print("DONE")
else:
    print("RUNNING")
' )"

    if [[ "${status}" == "DONE" ]]; then
      echo "    Operation completed!"
      break
    elif [[ "${status}" == ERROR:* ]]; then
      echo "    Operation failed: ${status#ERROR:}" >&2
      exit 1
    fi
    sleep 5
  done
}

TOKEN="$(gcloud auth print-access-token)"
GW_URL="https://networkservices.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGENT_GATEWAY_ID}"

echo "==> [1/3] Creating Egress Agent Gateway (${AGENT_GATEWAY_ID}) in ${REGION} (if not exists)..."
HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  "${GW_URL}")"

if [[ "${HTTP_CODE}" == "404" ]]; then
  CREATE_RESP="$(curl -sS -X POST \
    "https://networkservices.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/agentGateways?agentGatewayId=${AGENT_GATEWAY_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d '{
      "protocols": ["MCP"],
      "googleManaged": {
        "governedAccessPath": "AGENT_TO_ANYWHERE"
      }
    }')"

  OP_NAME="$( OP_JSON="${CREATE_RESP}" "${PYTHON_BIN}" -c '
import json, os, sys
data = json.loads(os.environ["OP_JSON"])
if "error" in data:
    sys.stderr.write(json.dumps(data["error"], indent=2) + "\n")
    sys.exit(1)
print(data["name"])
' )"
  wait_for_lro "${OP_NAME}"
else
  echo "    Egress Agent Gateway ${AGENT_GATEWAY_ID} already exists (HTTP ${HTTP_CODE})."
fi

echo "==> [2/3] Granting IAM roles to Google's auto-created Agent Gateway service accounts..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-agentgateway.iam.gserviceaccount.com" \
  --role="roles/agentregistry.viewer" \
  --quiet >/dev/null

for ROLE in roles/compute.networkUser roles/dns.peer; do
  gcloud projects add-iam-policy-binding "${VPC_HOST_PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-agentgateway.iam.gserviceaccount.com" \
    --role="${ROLE}" \
    --quiet >/dev/null

  gcloud projects add-iam-policy-binding "${VPC_HOST_PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com" \
    --role="${ROLE}" \
    --quiet >/dev/null || true
done

echo "    Waiting 10s for IAM bindings to propagate..."
sleep 10

echo "==> [3/3] Attaching PSC Network Attachment (${PSC_ATTACHMENT}) to ${AGENT_GATEWAY_ID}..."
TOKEN="$(gcloud auth print-access-token)"
PATCH_RESP="$(curl -sS -X PATCH \
  "${GW_URL}?updateMask=registries,networkConfig.egress.networkAttachment" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d "{
    \"registries\": [
      \"//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}\"
    ],
    \"networkConfig\": {
      \"egress\": {
        \"networkAttachment\": \"projects/${VPC_HOST_PROJECT_ID}/regions/${REGION}/networkAttachments/${PSC_ATTACHMENT}\"
      }
    }
  }")"

OP_NAME="$( OP_JSON="${PATCH_RESP}" "${PYTHON_BIN}" -c '
import json, os, sys
data = json.loads(os.environ["OP_JSON"])
if "error" in data:
    sys.stderr.write(json.dumps(data["error"], indent=2) + "\n")
    sys.exit(1)
print(data["name"])
' )"
wait_for_lro "${OP_NAME}"

echo ""
echo "==> Verifying PSC Network Attachment connection status:"
gcloud compute network-attachments describe "${PSC_ATTACHMENT}" \
  --region="${REGION}" \
  --project="${VPC_HOST_PROJECT_ID}" \
  --format="yaml(name,connectionPreference,connectionEndpoints)"

echo "=============================================================================="
echo "Egress Agent Gateway '${AGENT_GATEWAY_ID}' created and attached to '${PSC_ATTACHMENT}'!"
echo "Next: Run ./scripts/04a_setup_routing_pga.sh (Option A: PGA)"
echo "   or ./scripts/04b_setup_routing_psc.sh (Option B: PSC Endpoint)"
echo "=============================================================================="
