#!/usr/bin/env bash
# ==============================================================================
# Step 1: Enable Required APIs, Grant Cloud Build Roles, Deploy Cloud Run MCP
#         Server, and Grant Invoker Access to Gemini Enterprise
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "Error: ${REPO_ROOT}/.env not found. Copy .env.example to .env and fill in your values."
  exit 1
fi

set -a
source "${REPO_ROOT}/.env"
set +a

echo "==> [1/4] Enabling required Google Cloud APIs in ${PROJECT_ID}..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  discoveryengine.googleapis.com \
  compute.googleapis.com \
  networkservices.googleapis.com \
  networksecurity.googleapis.com \
  agentregistry.googleapis.com \
  cloudapiregistry.googleapis.com \
  dns.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> [2/4] Granting Cloud Build permissions to Default Compute Service Account..."
for ROLE in roles/cloudbuild.builds.builder roles/storage.objectViewer roles/logging.logWriter roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="${ROLE}" \
    --quiet >/dev/null
done

echo "==> [3/4] Deploying Cloud Run MCP server (${SERVICE_NAME}) in ${REGION}..."
if ! gcloud run deploy "${SERVICE_NAME}" \
  --source="${REPO_ROOT}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --no-allow-unauthenticated \
  --ingress=internal \
  --set-env-vars="REQUIRE_OAUTH=${REQUIRE_OAUTH},SERVICE_NAME=${SERVICE_NAME}"; then
  echo "    [Info] Waiting 25s for new-project IAM bindings on ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com to propagate, then retrying..."
  sleep 25
  gcloud run deploy "${SERVICE_NAME}" \
    --source="${REPO_ROOT}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --no-allow-unauthenticated \
    --ingress=internal \
    --set-env-vars="REQUIRE_OAUTH=${REQUIRE_OAUTH},SERVICE_NAME=${SERVICE_NAME}"
fi

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format='value(status.url)')"
DETECTED_FQDN="${SERVICE_URL#https://}"

echo "==> [4/4] Provisioning Gemini Enterprise service identity and granting roles/run.invoker..."
gcloud beta services identity create \
  --service=discoveryengine.googleapis.com \
  --project="${PROJECT_ID}" || true

gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

if grep -q "^MCP_SERVICE_FQDN=" "${REPO_ROOT}/.env"; then
  sed -i "s|^MCP_SERVICE_FQDN=.*|MCP_SERVICE_FQDN=${DETECTED_FQDN}|" "${REPO_ROOT}/.env"
else
  echo "MCP_SERVICE_FQDN=${DETECTED_FQDN}" >> "${REPO_ROOT}/.env"
fi

echo ""
echo "=============================================================================="
echo "Cloud Run MCP server deployed and locked to --ingress=internal!"
echo "Service URL : ${SERVICE_URL}"
echo "MCP Endpoint: ${SERVICE_URL}/mcp"
echo "Auto-saved MCP_SERVICE_FQDN=${DETECTED_FQDN} into .env"
echo "=============================================================================="
