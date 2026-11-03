#!/usr/bin/env bash
# ==============================================================================
# Step 5A (Option A — Recommended Default):
# Configure Gateway AuthzPolicy, FQDN-Scoped Private Cloud DNS with
# Subnet Private Google Access (PGA VIPs: 199.36.153.8/30), and DNS Peering
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

set -a
source "${REPO_ROOT}/.env"
set +a

if [[ -z "${MCP_SERVICE_FQDN:-}" ]]; then
  echo "Error: MCP_SERVICE_FQDN is empty in .env. Set it to your Cloud Run hostname (e.g. private-vpc-mcp-12345.us-central1.run.app)."
  exit 1
fi

PGA_VIPS="199.36.153.8,199.36.153.9,199.36.153.10,199.36.153.11"
TOKEN="$(gcloud auth print-access-token)"

echo "==> [1/4] Ensuring Subnet Private Google Access is enabled on ${VPC_SUBNET}..."
gcloud compute networks subnets update "${VPC_SUBNET}" \
  --region="${REGION}" \
  --project="${VPC_HOST_PROJECT_ID}" \
  --enable-private-ip-google-access

echo "==> [2/4] Ensuring REQUEST_AUTHZ policy exists on Agent Gateway (${AGENT_GATEWAY_ID})..."
AUTHZ_URL="https://networksecurity.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/authzPolicies/${AGENT_GATEWAY_ID}-authz-allow-all"
AUTHZ_CODE="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" -H "X-Goog-User-Project: ${PROJECT_ID}" "${AUTHZ_URL}")"
if [[ "${AUTHZ_CODE}" == "404" ]]; then
  curl -sS -X POST \
    "https://networksecurity.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/authzPolicies?authzPolicyId=${AGENT_GATEWAY_ID}-authz-allow-all" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
    -H "Content-Type: application/json" \
    -d "{
      \"target\": {
        \"resources\": [
          \"projects/${PROJECT_NUMBER}/locations/${REGION}/agentGateways/${AGENT_GATEWAY_ID}\"
        ]
      },
      \"httpRules\": [
        {
          \"to\": {
            \"operations\": [
              {
                \"paths\": [
                  {
                    \"prefix\": \"/\"
                  }
                ]
              }
            ]
          }
        }
      ],
      \"action\": \"ALLOW\",
      \"policyProfile\": \"REQUEST_AUTHZ\"
    }" >/dev/null
  echo "    Created AuthzPolicy ${AGENT_GATEWAY_ID}-authz-allow-all."
else
  echo "    AuthzPolicy ${AGENT_GATEWAY_ID}-authz-allow-all already exists."
fi

echo "==> [3/4] Creating/updating FQDN-scoped Private Cloud DNS zone (${MCP_SERVICE_FQDN}.) -> PGA VIPs (${PGA_VIPS})..."
if ! gcloud dns managed-zones describe "${DNS_ZONE_NAME}" --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud dns managed-zones create "${DNS_ZONE_NAME}" \
    --description="Scoped private DNS zone ONLY for ${MCP_SERVICE_FQDN} (PGA)" \
    --dns-name="${MCP_SERVICE_FQDN}." \
    --visibility=private \
    --networks="${VPC_NETWORK}" \
    --project="${VPC_HOST_PROJECT_ID}"
fi

if gcloud dns record-sets describe "${MCP_SERVICE_FQDN}." --zone="${DNS_ZONE_NAME}" --type=A --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud dns record-sets update "${MCP_SERVICE_FQDN}." \
    --zone="${DNS_ZONE_NAME}" \
    --type=A \
    --ttl=60 \
    --rrdatas="${PGA_VIPS}" \
    --project="${VPC_HOST_PROJECT_ID}"
else
  gcloud dns record-sets create "${MCP_SERVICE_FQDN}." \
    --zone="${DNS_ZONE_NAME}" \
    --type=A \
    --ttl=60 \
    --rrdatas="${PGA_VIPS}" \
    --project="${VPC_HOST_PROJECT_ID}"
fi

echo "==> [4/4] Configuring FQDN-scoped DNS Peering on ${AGENT_GATEWAY_ID} and locking Cloud Run to --ingress=internal..."
curl -sS -X PATCH \
  "https://networkservices.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGENT_GATEWAY_ID}?updateMask=networkConfig.dnsPeeringConfig" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  -H "Content-Type: application/json" \
  -d "{
    \"networkConfig\": {
      \"dnsPeeringConfig\": {
        \"domains\": [
          \"${MCP_SERVICE_FQDN}.\"
        ],
        \"targetProject\": \"${VPC_HOST_PROJECT_ID}\",
        \"targetNetwork\": \"projects/${VPC_HOST_PROJECT_ID}/global/networks/${VPC_NETWORK}\"
      }
    }
  }"
echo ""

gcloud run services update "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --ingress=internal

echo ""
echo "=============================================================================="
echo "Option A (Subnet Private Google Access: 199.36.153.8/30) configured!"
echo "Scoped DNS Zone : ${DNS_ZONE_NAME} (${MCP_SERVICE_FQDN}. -> ${PGA_VIPS})"
echo "Cloud Run Ingress: internal"
echo "=============================================================================="
