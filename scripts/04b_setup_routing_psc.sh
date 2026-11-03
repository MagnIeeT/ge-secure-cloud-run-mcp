#!/usr/bin/env bash
# ==============================================================================
# Step 5B (Option B — Isolated / Zero-Default-Route VPCs):
# Provision Global PSC Endpoint for Google APIs (all-apis -> 240.0.0.10),
# Gateway AuthzPolicy, FQDN-Scoped Private Cloud DNS, and DNS Peering
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

TOKEN="$(gcloud auth print-access-token)"

echo "==> [1/6] Ensuring Subnet Private Google Access is enabled on ${VPC_SUBNET}..."
# Note: Subnets sending traffic to a PSC Google APIs endpoint still require
# --enable-private-ip-google-access enabled on the subnet.
gcloud compute networks subnets update "${VPC_SUBNET}" \
  --region="${REGION}" \
  --project="${VPC_HOST_PROJECT_ID}" \
  --enable-private-ip-google-access

echo "==> [2/6] Reserving global internal IP (${PSC_ENDPOINT_IP}) for Google APIs PSC endpoint..."
if ! gcloud compute addresses describe "${PSC_ADDRESS_NAME}" --global --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses create "${PSC_ADDRESS_NAME}" \
    --global \
    --purpose=PRIVATE_SERVICE_CONNECT \
    --addresses="${PSC_ENDPOINT_IP}" \
    --network="${VPC_NETWORK}" \
    --project="${VPC_HOST_PROJECT_ID}"
else
  echo "    Global PSC IP ${PSC_ADDRESS_NAME} (${PSC_ENDPOINT_IP}) already reserved."
fi

echo "==> [3/6] Creating global PSC forwarding rule (${PSC_ENDPOINT_NAME}) targeting 'all-apis'..."
if ! gcloud compute forwarding-rules describe "${PSC_ENDPOINT_NAME}" --global --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute forwarding-rules create "${PSC_ENDPOINT_NAME}" \
    --global \
    --network="${VPC_NETWORK}" \
    --address="${PSC_ADDRESS_NAME}" \
    --target-google-apis-bundle=all-apis \
    --project="${VPC_HOST_PROJECT_ID}"
else
  echo "    Global PSC forwarding rule ${PSC_ENDPOINT_NAME} already exists."
fi

echo "==> [4/6] Ensuring REQUEST_AUTHZ policy exists on Agent Gateway (${AGENT_GATEWAY_ID})..."
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

echo "==> [5/6] Creating/updating FQDN-scoped Private Cloud DNS zone (${MCP_SERVICE_FQDN}.) -> PSC VIP (${PSC_ENDPOINT_IP})..."
if ! gcloud dns managed-zones describe "${DNS_ZONE_NAME}" --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud dns managed-zones create "${DNS_ZONE_NAME}" \
    --description="Scoped private DNS zone ONLY for ${MCP_SERVICE_FQDN} (PSC all-apis)" \
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
    --rrdatas="${PSC_ENDPOINT_IP}" \
    --project="${VPC_HOST_PROJECT_ID}"
else
  gcloud dns record-sets create "${MCP_SERVICE_FQDN}." \
    --zone="${DNS_ZONE_NAME}" \
    --type=A \
    --ttl=60 \
    --rrdatas="${PSC_ENDPOINT_IP}" \
    --project="${VPC_HOST_PROJECT_ID}"
fi

echo "==> [6/6] Configuring FQDN-scoped DNS Peering on ${AGENT_GATEWAY_ID} and locking Cloud Run to --ingress=internal..."
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
echo "Option B (PSC Endpoint 'all-apis': ${PSC_ENDPOINT_IP}) configured!"
echo "PSC Endpoint    : ${PSC_ENDPOINT_NAME} (${PSC_ENDPOINT_IP} -> all-apis)"
echo "Scoped DNS Zone : ${DNS_ZONE_NAME} (${MCP_SERVICE_FQDN}. -> ${PSC_ENDPOINT_IP})"
echo "Cloud Run Ingress: internal"
echo "=============================================================================="
