#!/usr/bin/env bash
# ==============================================================================
# Provisioning Script: Hybrid Storage Parallel Image Watermarking Batch Job
# Aligned with Google Cloud Architecture Guidelines:
# - GCS Input Bucket (via GCS FUSE): Ingestion Source
# - Filestore NFS (via Direct VPC Egress): High-IOPS Temporary Scratch Space
# - GCS Output Bucket (via GCS FUSE): Persistent Archival Sink
# - Cloud Run Jobs: Multi-volume parallel batch processing
# ==============================================================================
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "")}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"

GCS_INPUT_BUCKET="${GCS_INPUT_BUCKET:-${PROJECT_ID}-watermark-input}"
GCS_OUTPUT_BUCKET="${GCS_OUTPUT_BUCKET:-${PROJECT_ID}-watermark-output}"

FILESTORE_INSTANCE="${FILESTORE_INSTANCE:-demo-nfs}"
FILESTORE_SHARE="${FILESTORE_SHARE:-share1}"
FILESTORE_TIER="${FILESTORE_TIER:-BASIC_HDD}"
FILESTORE_CAPACITY="${FILESTORE_CAPACITY:-1TB}"

VPC_NETWORK="${VPC_NETWORK:-default}"
VPC_SUBNET="${VPC_SUBNET:-default}"

JOB_NAME="${JOB_NAME:-image-watermark-job}"
REPOSITORY="${REPOSITORY:-watermark-repo}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
TASK_COUNT="${TASK_COUNT:-10}"
SEED_IMAGES="${SEED_IMAGES:-30}"
SA_NAME="${SA_NAME:-watermark-job-sa}"

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  Google Cloud Hybrid Storage Batch Architecture Deployment${NC}"
echo -e "${BOLD}======================================================================${NC}"
echo -e "  Project ID:          ${GREEN}${PROJECT_ID}${NC}"
echo -e "  Region / Zone:       ${GREEN}${REGION} / ${ZONE}${NC}"
echo -e "  GCS Input Bucket:    ${GREEN}gs://${GCS_INPUT_BUCKET}${NC} (Mounted at /mnt/gcs/input)"
echo -e "  GCS Output Bucket:   ${GREEN}gs://${GCS_OUTPUT_BUCKET}${NC} (Mounted at /mnt/gcs/output)"
echo -e "  Filestore Instance:  ${GREEN}${FILESTORE_INSTANCE}${NC} (Mounted at /mnt/nfs/scratch, Tier: ${FILESTORE_TIER})"
echo -e "  VPC Network/Subnet:  ${GREEN}${VPC_NETWORK} / ${VPC_SUBNET}${NC} (Direct VPC Egress)"
echo -e "  Cloud Run Job:       ${GREEN}${JOB_NAME}${NC} (Tasks: ${TASK_COUNT})"
echo -e "======================================================================"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    log_error "GCP Project ID is not configured. Set with: export PROJECT_ID=<PROJECT_ID>"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Enable Required GCP APIs
# ------------------------------------------------------------------------------
log_info "Step 1: Enabling required Google Cloud APIs..."
gcloud services enable \
    file.googleapis.com \
    run.googleapis.com \
    storage.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    compute.googleapis.com \
    iam.googleapis.com \
    --project="${PROJECT_ID}"

# ------------------------------------------------------------------------------
# 2. Provision GCS Buckets (Source & Sink)
# ------------------------------------------------------------------------------
log_info "Step 2: Checking GCS Input & Output Buckets..."
if ! gcloud storage buckets describe "gs://${GCS_INPUT_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Creating GCS input bucket: gs://${GCS_INPUT_BUCKET}..."
    gcloud storage buckets create "gs://${GCS_INPUT_BUCKET}" --location="${REGION}" --project="${PROJECT_ID}" --uniform-bucket-level-access
fi

if ! gcloud storage buckets describe "gs://${GCS_OUTPUT_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Creating GCS output bucket: gs://${GCS_OUTPUT_BUCKET}..."
    gcloud storage buckets create "gs://${GCS_OUTPUT_BUCKET}" --location="${REGION}" --project="${PROJECT_ID}" --uniform-bucket-level-access
fi
log_success "GCS Ingestion & Archival buckets are ready."

# ------------------------------------------------------------------------------
# 3. Provision Filestore NFS Instance (High-IOPS Scratch Space)
# ------------------------------------------------------------------------------
log_info "Step 3: Checking Filestore instance '${FILESTORE_INSTANCE}'..."
if gcloud filestore instances describe "${FILESTORE_INSTANCE}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Filestore instance '${FILESTORE_INSTANCE}' already exists."
else
    log_info "Creating Filestore instance '${FILESTORE_INSTANCE}' (Zone: ${ZONE}, Capacity: ${FILESTORE_CAPACITY})..."
    gcloud filestore instances create "${FILESTORE_INSTANCE}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --tier="${FILESTORE_TIER}" \
        --file-share=name="${FILESTORE_SHARE}",capacity="${FILESTORE_CAPACITY}" \
        --network=name="${VPC_NETWORK}"
fi

FILESTORE_IP=$(gcloud filestore instances describe "${FILESTORE_INSTANCE}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --format="value(networks.ipAddresses[0])")

if [[ -z "${FILESTORE_IP}" ]]; then
    log_error "Could not obtain Filestore IP. Please verify the instance is READY."
    exit 1
fi
log_success "Filestore NFS instance ready at: ${FILESTORE_IP}:/${FILESTORE_SHARE}"

# ------------------------------------------------------------------------------
# 4. Configure Minimal-Privilege Service Account
# ------------------------------------------------------------------------------
log_info "Step 4: Configuring minimal-privilege Service Account..."
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Creating Service Account: ${SA_EMAIL}..."
    gcloud iam service-accounts create "${SA_NAME}" \
        --display-name="Cloud Run Image Watermarking Worker SA" \
        --project="${PROJECT_ID}"
fi

# Grant least privilege: Storage Object User on input and output buckets only
log_info "Granting Storage Object User permissions on buckets..."
gcloud storage buckets add-iam-policy-binding "gs://${GCS_INPUT_BUCKET}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectUser" --quiet >/dev/null

gcloud storage buckets add-iam-policy-binding "gs://${GCS_OUTPUT_BUCKET}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectUser" --quiet >/dev/null
log_success "Service Account configured: ${SA_EMAIL}"

# ------------------------------------------------------------------------------
# 5. Build Container Image via Cloud Build & Artifact Registry
# ------------------------------------------------------------------------------
log_info "Step 5: Setting up Artifact Registry repository '${REPOSITORY}'..."
if ! gcloud artifacts repositories describe "${REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud artifacts repositories create "${REPOSITORY}" \
        --project="${PROJECT_ID}" \
        --repository-format=docker \
        --location="${REGION}" \
        --description="Docker repository for Cloud Run Filestore demo"
fi

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/watermark-worker:${IMAGE_TAG}"

log_info "Building container image with Cloud Build: ${IMAGE_URI}..."
gcloud builds submit --project="${PROJECT_ID}" --tag="${IMAGE_URI}" .

# ------------------------------------------------------------------------------
# 6. Deploy Cloud Run Job with Multi-Volume Mounts & Direct VPC Egress
# ------------------------------------------------------------------------------
log_info "Step 6: Deploying Cloud Run Job '${JOB_NAME}' with Multi-Volume Mounting..."

# Deploy using multi-volume flags:
# - GCS FUSE input bucket mounted at /mnt/gcs/input
# - GCS FUSE output bucket mounted at /mnt/gcs/output
# - Filestore NFS scratch space mounted at /mnt/nfs/scratch
gcloud run jobs deploy "${JOB_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --image="${IMAGE_URI}" \
    --service-account="${SA_EMAIL}" \
    --tasks="${TASK_COUNT}" \
    --max-retries=1 \
    --task-timeout=10m \
    --cpu=1 \
    --memory=512Mi \
    --network="${VPC_NETWORK}" \
    --subnet="${VPC_SUBNET}" \
    --vpc-egress=all-traffic \
    --set-env-vars="AUTO_SEED=true,SEED_IMAGES=${SEED_IMAGES},GCS_INPUT_DIR=/mnt/gcs/input,GCS_OUTPUT_DIR=/mnt/gcs/output,NFS_SCRATCH_DIR=/mnt/nfs/scratch" \
    --clear-volumes \
    --add-volume=name=gcs-input,type=cloud-storage,bucket="${GCS_INPUT_BUCKET}" \
    --add-volume-mount=volume=gcs-input,mount-path=/mnt/gcs/input \
    --add-volume=name=gcs-output,type=cloud-storage,bucket="${GCS_OUTPUT_BUCKET}" \
    --add-volume-mount=volume=gcs-output,mount-path=/mnt/gcs/output \
    --add-volume=name=nfs-scratch,type=nfs,location="${FILESTORE_IP}:/${FILESTORE_SHARE}" \
    --add-volume-mount=volume=nfs-scratch,mount-path=/mnt/nfs/scratch

log_success "Cloud Run Job deployed with multi-volume mounts!"

# ------------------------------------------------------------------------------
# 7. Execute Job
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  Executing Demo Pipeline: ${TASK_COUNT} Tasks in Parallel${NC}"
echo -e "${BOLD}======================================================================${NC}"
log_info "Executing Cloud Run Job: ${JOB_NAME}..."
gcloud run jobs execute "${JOB_NAME}" --region="${REGION}" --project="${PROJECT_ID}"

echo ""
log_success "Batch job executed successfully!"
echo ""
echo -e "${BOLD}Verification Commands:${NC}"
echo -e "  • Verify GCS Output Bucket:"
echo -e "    ${YELLOW}gcloud storage ls gs://${GCS_OUTPUT_BUCKET}/${NC}"
echo -e "  • Tail Cloud Run Job Execution Logs:"
echo -e "    ${YELLOW}gcloud logging read 'resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${JOB_NAME}\"' --limit=50 --format=\"table(timestamp,jsonPayload.task_index,jsonPayload.event,jsonPayload.image,jsonPayload.total_duration_ms)\"${NC}"
echo -e "  • Cloud Run Console:"
echo -e "    ${BLUE}https://console.cloud.google.com/run/jobs/details/${REGION}/${JOB_NAME}/executions?project=${PROJECT_ID}${NC}"
echo -e "  • Filestore Console:"
echo -e "    ${BLUE}https://console.cloud.google.com/filestore/instances/details/${ZONE}/${FILESTORE_INSTANCE}?project=${PROJECT_ID}${NC}"
echo -e "  • GCS Output Bucket Console:"
echo -e "    ${BLUE}https://console.cloud.google.com/storage/browser/${GCS_OUTPUT_BUCKET}?project=${PROJECT_ID}${NC}"
