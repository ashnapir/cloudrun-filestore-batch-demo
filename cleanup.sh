#!/usr/bin/env bash
# ==============================================================================
# Teardown Script: Hybrid Storage Parallel Batch Processing Demo
# ==============================================================================
set -euo pipefail

BOLD="\033[1m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
NC="\033[0m"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "")}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
GCS_INPUT_BUCKET="${GCS_INPUT_BUCKET:-${PROJECT_ID}-watermark-input}"
GCS_OUTPUT_BUCKET="${GCS_OUTPUT_BUCKET:-${PROJECT_ID}-watermark-output}"
FILESTORE_INSTANCE="${FILESTORE_INSTANCE:-demo-nfs}"
JOB_NAME="${JOB_NAME:-image-watermark-job}"
REPOSITORY="${REPOSITORY:-watermark-repo}"
SA_NAME="${SA_NAME:-watermark-job-sa}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  Tearing Down Hybrid Storage Batch Processing Demo Resources${NC}"
echo -e "${BOLD}======================================================================${NC}"
echo -e "  Project:             ${YELLOW}${PROJECT_ID}${NC}"
echo -e "  Region / Zone:       ${YELLOW}${REGION} / ${ZONE}${NC}"
echo -e "  Cloud Run Job:       ${YELLOW}${JOB_NAME}${NC}"
echo -e "  Filestore Instance:  ${YELLOW}${FILESTORE_INSTANCE}${NC}"
echo -e "  GCS Input Bucket:    ${YELLOW}gs://${GCS_INPUT_BUCKET}${NC}"
echo -e "  GCS Output Bucket:   ${YELLOW}gs://${GCS_OUTPUT_BUCKET}${NC}"
echo -e "  Service Account:     ${YELLOW}${SA_EMAIL}${NC}"
echo -e "  Artifact Registry:   ${YELLOW}${REPOSITORY}${NC}"
echo -e "======================================================================\n"

read -p "Are you sure you want to delete these resources? (y/N): " -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cleanup aborted."
    exit 0
fi

# 1. Delete Cloud Run Job
echo -e "\n${BLUE}[1/5] Deleting Cloud Run Job: ${JOB_NAME}...${NC}"
if gcloud run jobs describe "${JOB_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud run jobs delete "${JOB_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo -e "${GREEN}Cloud Run Job deleted.${NC}"
else
    echo "Cloud Run Job not found, skipping."
fi

# 2. Delete Filestore Instance
echo -e "\n${BLUE}[2/5] Deleting Filestore Instance: ${FILESTORE_INSTANCE}...${NC}"
if gcloud filestore instances describe "${FILESTORE_INSTANCE}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud filestore instances delete "${FILESTORE_INSTANCE}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
    echo -e "${GREEN}Filestore instance deleted.${NC}"
else
    echo "Filestore instance not found, skipping."
fi

# 3. Delete GCS Buckets
echo -e "\n${BLUE}[3/5] Deleting GCS Buckets...${NC}"
if gcloud storage buckets describe "gs://${GCS_INPUT_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud storage rm --recursive "gs://${GCS_INPUT_BUCKET}" --quiet
    echo -e "${GREEN}GCS Input bucket deleted.${NC}"
fi

if gcloud storage buckets describe "gs://${GCS_OUTPUT_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud storage rm --recursive "gs://${GCS_OUTPUT_BUCKET}" --quiet
    echo -e "${GREEN}GCS Output bucket deleted.${NC}"
fi

# 4. Delete Service Account
echo -e "\n${BLUE}[4/5] Deleting Service Account: ${SA_EMAIL}...${NC}"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
    echo -e "${GREEN}Service Account deleted.${NC}"
fi

# 5. Delete Artifact Registry Repository
echo -e "\n${BLUE}[5/5] Deleting Artifact Registry Repository: ${REPOSITORY}...${NC}"
if gcloud artifacts repositories describe "${REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud artifacts repositories delete "${REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" --quiet
    echo -e "${GREEN}Artifact Registry repository deleted.${NC}"
fi

echo -e "\n${GREEN}${BOLD}Cleanup completed successfully!${NC}\n"
