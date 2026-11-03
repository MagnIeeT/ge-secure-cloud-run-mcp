#!/usr/bin/env bash
# ==============================================================================
# Step 3: Create Custom VPC, Regional Subnet (with PGA enabled), and
#         PSC Network Attachment
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

set -a
source "${REPO_ROOT}/.env"
set +a

echo "==> [1/3] Creating VPC network (${VPC_NETWORK}) in ${VPC_HOST_PROJECT_ID} (if not exists)..."
if ! gcloud compute networks describe "${VPC_NETWORK}" --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks create "${VPC_NETWORK}" \
    --project="${VPC_HOST_PROJECT_ID}" \
    --subnet-mode=custom
else
  echo "    VPC ${VPC_NETWORK} already exists."
fi

echo "==> [2/3] Creating/updating subnet (${VPC_SUBNET}) in ${REGION} with Private Google Access enabled..."
if ! gcloud compute networks subnets describe "${VPC_SUBNET}" --region="${REGION}" --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create "${VPC_SUBNET}" \
    --project="${VPC_HOST_PROJECT_ID}" \
    --network="${VPC_NETWORK}" \
    --region="${REGION}" \
    --range="${SUBNET_RANGE}" \
    --enable-private-ip-google-access
else
  gcloud compute networks subnets update "${VPC_SUBNET}" \
    --project="${VPC_HOST_PROJECT_ID}" \
    --region="${REGION}" \
    --enable-private-ip-google-access
fi

echo "==> [3/3] Creating PSC Network Attachment (${PSC_ATTACHMENT}) in ${REGION}..."
if ! gcloud compute network-attachments describe "${PSC_ATTACHMENT}" --region="${REGION}" --project="${VPC_HOST_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute network-attachments create "${PSC_ATTACHMENT}" \
    --project="${VPC_HOST_PROJECT_ID}" \
    --region="${REGION}" \
    --subnets="${VPC_SUBNET}" \
    --connection-preference=ACCEPT_AUTOMATIC
else
  echo "    Network Attachment ${PSC_ATTACHMENT} already exists."
fi

echo ""
echo "=============================================================================="
echo "VPC, Subnet & PSC Network Attachment ready!"
echo "Network Attachment URI:"
echo "  projects/${VPC_HOST_PROJECT_ID}/regions/${REGION}/networkAttachments/${PSC_ATTACHMENT}"
echo ""
echo "Next: Run ./scripts/03_setup_agent_gateway.sh"
echo "=============================================================================="
