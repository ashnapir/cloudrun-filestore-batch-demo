# Parallel Image Watermarking Batch Job Architecture
## Serverless Compute with Hybrid Storage (Cloud Run Jobs + Filestore NFS + Cloud Storage FUSE)

[![Cloud Run](https://img.shields.io/badge/Google_Cloud-Cloud_Run_Jobs-blue.svg)](https://cloud.google.com/run)
[![Filestore](https://img.shields.io/badge/Google_Cloud-Filestore_NFS-green.svg)](https://cloud.google.com/filestore)
[![Cloud Storage](https://img.shields.io/badge/Google_Cloud-Cloud_Storage_FUSE-4285F4.svg)](https://cloud.google.com/storage)
[![Python](https://img.shields.io/badge/Python-3.11+-yellow.svg)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED.svg)](https://www.docker.com/)

This repository implements the high-performance, parallelized image watermarking batch processing architecture on Google Cloud. It leverages **Cloud Run Jobs** with **Hybrid Storage Mounting** (Google Cloud Storage via GCS FUSE + Google Cloud Filestore via NFS) and **Direct VPC Egress** to optimize both throughput and large-scale batch processing.

---

## Architecture Overview

```mermaid
graph TD
    subgraph Ingestion ["External / Ingestion"]
        Uploads["Image Uploads"] --> GCSIn["(GCS Input Bucket)<br/>gs://${PROJECT_ID}-watermark-input"]
    end

    subgraph VPC ["VPC Network (default)"]
        subgraph ComputeLayer ["Compute Layer"]
            CR["Cloud Run Job<br/>(image-watermark-job)<br/>10 Tasks in Parallel"]
        end

        subgraph StorageLayer ["Storage Layer"]
            FS[("(Filestore NFS Instance)<br/>IP: 10.x.x.x<br/>Share: /share1")]
        end

        CR -.->|"Direct VPC Egress<br/>(Private RFC 1918)"| FS
    end

    GCSIn ==>|"GCS FUSE Mount<br/>(/mnt/gcs/input)"| CR
    FS ===|"NFS Mount<br/>(/mnt/nfs/scratch)"| CR
    CR ==>|"GCS FUSE Mount<br/>(/mnt/gcs/output)"| GCSOut["(GCS Output Bucket)<br/>gs://${PROJECT_ID}-watermark-output"]

    style Ingestion fill:#f8f9fa,stroke:#dadce0
    style GCSIn fill:#e8f0fe,stroke:#1a73e8
    style CR fill:#e8f0fe,stroke:#1a73e8
    style FS fill:#fef7e0,stroke:#f9ab00
    style GCSOut fill:#e6f4ea,stroke:#1e8e3e
```

### Technical Components

| Component | Role in Architecture | Key Configuration |
| :--- | :--- | :--- |
| **Google Cloud Storage (GCS)** | Source and Sink for image assets. | Regional/multi-regional buckets with uniform bucket-level access. |
| **Cloud Run Jobs** | Serverless compute engine for parallel batch processing. | Multi-volume mounting enabled (`gen2`), 10 parallel tasks. |
| **GCS FUSE** | Mounts GCS buckets as local POSIX-like directories (`/mnt/gcs/input` and `/mnt/gcs/output`). | Used for direct streaming and archival of image files. |
| **Filestore (NFS)** | High-performance shared scratch filesystem (`/mnt/nfs/scratch`). | Basic or Enterprise tier providing high IOPS and low-latency temporary manipulation space. |
| **Direct VPC Egress** | Network bridge for serverless to VPC communication. | Subnet-based egress routing all NFS traffic privately to the Filestore IP. |

---

## Step-by-Step Data Pipeline

```
+-----------------------------------------------------------------------------------------+
|                                    DATA PIPELINE                                        |
+-------------------+     +-------------------------+     +-------------------------------+
|  1. INGESTION     | --> |  2. VOLUME MOUNTING     | --> |  3. PARALLEL BATCH PROCESSING |
|  Upload raw image |     |  - GCS FUSE: /mnt/gcs/* |     |  - Fetch from GCS FUSE        |
|  assets to GCS    |     |  - NFS: /mnt/nfs/scratch|     |  - High-IOPS Filestore Scratch|
|  Input Bucket     |     |  - Direct VPC Egress    |     |  - Archival to GCS Output     |
+-------------------+     +-------------------------+     +---------------+---------------+
                                                                          |
                                                                          v
                                                          +-------------------------------+
                                                          |  4. OUTPUT & CLEANUP          |
                                                          |  - Watermarked file in GCS    |
                                                          |  - Purge Filestore scratch    |
                                                          |  - Cloud Logging audit metrics|
                                                          +-------------------------------+
```

1. **Ingestion Phase:** Raw image assets are uploaded to the primary source-of-truth GCS Input Bucket (`gs://${PROJECT_ID}-watermark-input`).
   > [!NOTE]
   > If you do not upload your own test images to the input bucket, the pipeline's auto-seed mechanism (`AUTO_SEED=true`) automatically generates 30 sample test images in the input bucket so you can test the pipeline immediately.
2. **Initialization & Multi-Volume Mounting:** The Cloud Run Job initializes with multi-volume mounts:
   * **GCS FUSE Mounting:** Mounts input bucket to `/mnt/gcs/input` and output bucket to `/mnt/gcs/output`.
   * **Filestore NFS Mounting:** Mounts Filestore instance to `/mnt/nfs/scratch`.
3. **Parallel Batch Processing:**
   * **Fetch:** Container reads raw image from `/mnt/gcs/input`.
   * **Process:** Copies image to `/mnt/nfs/scratch/task_XXX/` for high-IOPS manipulation (watermark rendering, format conversion).
   * **Compute:** Direct VPC Egress securely communicates with Filestore's internal IP.
4. **Output & Archival:**
   * Watermarked image is written directly to the GCS Output Bucket (`/mnt/gcs/output`).
   * Task-specific temporary scratch directory on Filestore NFS is automatically purged.
   * Structured JSON metrics are streamed to Cloud Logging.

---

## Security & Connectivity

* **Least-Privilege Service Account:** The Cloud Run Job executes under a dedicated service account (`watermark-job-sa@${PROJECT_ID}.iam.gserviceaccount.com`) granted only `roles/storage.objectUser` on the designated input and output buckets.
* **Direct VPC Egress (Zero Public IP Exposure):** All communication between Cloud Run and Filestore occurs strictly over internal RFC 1918 private networking. Filestore NFS port 2049 is never exposed to the public internet.

---

## Repository Structure

```
cloudrun-filestore-batch-demo/
├── app/
│   ├── main.py          # Hybrid data pipeline worker logic & structured logging
│   └── requirements.txt # Python dependencies (Pillow)
├── deploy/
│   └── job.yaml         # Multi-volume Cloud Run Job declarative manifest
├── images/
│   └── watermark.png    # Watermark asset
├── Dockerfile           # Container build definition
├── setup.sh             # End-to-end automated deployment and execution script
├── cleanup.sh           # Clean resource teardown script
└── README.md            # Architecture, setup guide, and screenshot walkthrough
```

---

## Prerequisites & Setup

### 1. Required Google Cloud APIs

```bash
gcloud services enable \
    file.googleapis.com \
    run.googleapis.com \
    storage.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    compute.googleapis.com \
    iam.googleapis.com
```

### 2. Environment Variables

Set the configuration variables for your Google Cloud project. 

> [!IMPORTANT]
> **VPC Network & Subnet Requirements:**
> - If your project does not have the `default` VPC network, set `VPC_NETWORK` and `VPC_SUBNET` to your existing VPC and subnet.
> - The subnet specified in `VPC_SUBNET` **must reside in the same region** as `REGION` (e.g., `us-central1`).
> - Cloud Run Direct VPC Egress allocates a private IP address per concurrent task instance. Ensure the subnet has sufficient available IPs (at least 10 available IPs for 10 parallel tasks; a `/28` or larger subnet is recommended).

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export ZONE="us-central1-a"
export GCS_INPUT_BUCKET="${PROJECT_ID}-watermark-input"
export GCS_OUTPUT_BUCKET="${PROJECT_ID}-watermark-output"
export FILESTORE_INSTANCE="demo-nfs"
export FILESTORE_SHARE="share1"

# Network configuration: set to your custom VPC/subnet (or 'default')
export VPC_NETWORK="your-vpc-name"
export VPC_SUBNET="your-subnet-name"

gcloud config set project "$PROJECT_ID"
```

---

## Quickstart (Automated Deployment)

Clone this repository, configure your environment variables (especially `VPC_NETWORK` and `VPC_SUBNET` if not using `default`), and run the provisioning script:

```bash
git clone <repository-url>
cd cloudrun-filestore-batch-demo
chmod +x setup.sh cleanup.sh

# Optional: override default network and subnet if your project uses custom VPCs
# export VPC_NETWORK="your-vpc"
# export VPC_SUBNET="your-subnet-in-us-central1"

./setup.sh
```

`setup.sh` automatically performs:
1. Enabling required Google Cloud APIs.
2. Creating GCS Input and Output buckets with uniform bucket-level access.
3. Provisioning the Filestore NFS instance (1TB `BASIC_HDD`).
4. Creating a dedicated Service Account, waiting for IAM replication, and binding `roles/storage.objectUser` permissions to both buckets.
5. Building the container image via Cloud Build and pushing to Artifact Registry.
6. Deploying the Cloud Run Job with **Multi-Volume Mounting** (GCS Input + GCS Output + Filestore NFS Scratch) and **Direct VPC Egress**.
7. Triggering job execution with 10 parallel tasks. (Note: If no images are found in the input bucket, the script automatically seeds 30 sample test images into `gs://${GCS_INPUT_BUCKET}` so the pipeline can be tested immediately).

---

## Manual Step-by-Step Deployment

### Step 1: Create GCS Input & Output Buckets

```bash
gcloud storage buckets create "gs://${GCS_INPUT_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access

gcloud storage buckets create "gs://${GCS_OUTPUT_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
```

> [!TIP]
> **Uploading Your Own Images vs. Automatic Seeding:**
> - **Upload your own images:** You can copy any number of JPEG/PNG images into `gs://${GCS_INPUT_BUCKET}/` before running the job (e.g., `gcloud storage cp /path/to/*.jpg gs://${GCS_INPUT_BUCKET}/`).
> - **Automatic generation:** If you don't upload your own images, the batch worker automatically generates 30 colorful sample images in `gs://${GCS_INPUT_BUCKET}/` on its first run (`AUTO_SEED=true`).

### Step 2: Create Filestore NFS Instance

> [!NOTE]
> The Filestore instance and the Cloud Run Direct VPC Egress subnet must belong to the same VPC network (`${VPC_NETWORK}`).

```bash
gcloud filestore instances create "${FILESTORE_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --tier=BASIC_HDD \
    --file-share=name="${FILESTORE_SHARE}",capacity=1TB \
    --network=name="${VPC_NETWORK}"

export FILESTORE_IP=$(gcloud filestore instances describe "${FILESTORE_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --format="value(networks.ipAddresses[0])")
```

### Step 3: Configure Service Account & IAM Permissions

> [!IMPORTANT]
> **IAM Eventual Consistency Delay:**
> When creating a new service account, Google Cloud IAM requires 5–10 seconds to propagate globally. Attempting to add bucket IAM policy bindings immediately after creation can result in:
> `Service account ... does not exist.`
> A `sleep 10` pause is included below to ensure the service account is recognized by Cloud Storage before binding the role.

```bash
# 1. Create the Service Account
gcloud iam service-accounts create watermark-job-sa \
    --project="${PROJECT_ID}" \
    --display-name="Cloud Run Image Watermarking Worker SA"

export SA_EMAIL="watermark-job-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# 2. Wait for IAM propagation to complete
sleep 10

# 3. Grant Storage Object User on both Input and Output buckets
gcloud storage buckets add-iam-policy-binding "gs://${GCS_INPUT_BUCKET}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectUser"

gcloud storage buckets add-iam-policy-binding "gs://${GCS_OUTPUT_BUCKET}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectUser"

# 4. Verify bindings are present on both buckets
gcloud storage buckets get-iam-policy "gs://${GCS_INPUT_BUCKET}"
gcloud storage buckets get-iam-policy "gs://${GCS_OUTPUT_BUCKET}"
```

### Step 4: Build Container Image

```bash
gcloud artifacts repositories create watermark-repo \
    --project="${PROJECT_ID}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Docker repository for Cloud Run Filestore demo"

export IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/watermark-repo/watermark-worker:latest"
gcloud builds submit --project="${PROJECT_ID}" --tag "${IMAGE_URI}" .
```

### Step 5: Deploy Cloud Run Job with Multi-Volume Mounts

Deploy the Cloud Run Job with:
- **Direct VPC Egress:** Configured with `--network`, `--subnet`, and `--vpc-egress=all-traffic` to reach the private Filestore IP.
- **Multi-Volume Mounts:**
  - `gcs-input`: GCS FUSE mount to `/mnt/gcs/input`
  - `gcs-output`: GCS FUSE mount to `/mnt/gcs/output`
  - `nfs-scratch`: Filestore NFS mount to `/mnt/nfs/scratch`

```bash
gcloud run jobs deploy image-watermark-job \
    --project="${PROJECT_ID}" \
    --image="${IMAGE_URI}" \
    --region="${REGION}" \
    --service-account="${SA_EMAIL}" \
    --tasks=10 \
    --max-retries=1 \
    --task-timeout=10m \
    --cpu=1 \
    --memory=512Mi \
    --network="${VPC_NETWORK}" \
    --subnet="${VPC_SUBNET}" \
    --vpc-egress=all-traffic \
    --set-env-vars="AUTO_SEED=true,SEED_IMAGES=30,GCS_INPUT_DIR=/mnt/gcs/input,GCS_OUTPUT_DIR=/mnt/gcs/output,NFS_SCRATCH_DIR=/mnt/nfs/scratch" \
    --clear-volumes \
    --add-volume=name=gcs-input,type=cloud-storage,bucket="${GCS_INPUT_BUCKET}" \
    --add-volume-mount=volume=gcs-input,mount-path=/mnt/gcs/input \
    --add-volume=name=gcs-output,type=cloud-storage,bucket="${GCS_OUTPUT_BUCKET}" \
    --add-volume-mount=volume=gcs-output,mount-path=/mnt/gcs/output \
    --add-volume=name=nfs-scratch,type=nfs,location="${FILESTORE_IP}:/${FILESTORE_SHARE}" \
    --add-volume-mount=volume=nfs-scratch,mount-path=/mnt/nfs/scratch
```

### Step 6: Execute Parallel Job

```bash
gcloud run jobs execute image-watermark-job \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
```

---

## Troubleshooting & Common Failure Points

### 1. Volume Mount Failure: `Permission 'storage.objects.list' denied`
* **Symptom:**
  Tasks fail immediately with exit code `255` or `1`:
  ```text
  terminated: Application failed to run: volume (type: gcs, name: gcs-input): mount operation failed
  Error: mountWithStorageHandle: fs.NewServer: ... storageLayout call failed: ... PermissionDenied desc = ... does not have storage.objects.list access
  ```
* **Cause:**
  The Cloud Run service account was not granted `roles/storage.objectUser` on the input bucket, typically because `add-iam-policy-binding` was executed immediately after service account creation before IAM replication finished.
* **Resolution:**
  Re-apply the binding to the bucket and re-run the job:
  ```bash
  gcloud storage buckets add-iam-policy-binding "gs://${GCS_INPUT_BUCKET}" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="roles/storage.objectUser"
  gcloud run jobs execute image-watermark-job --region="${REGION}" --project="${PROJECT_ID}"
  ```

### 2. VPC Subnetwork Mismatch or Missing Network
* **Symptom:**
  Job deployment fails with: `The specified subnetwork 'default' does not exist in region 'us-central1'`.
* **Cause:**
  The project does not have a default auto-mode VPC network or uses custom subnets.
* **Resolution:**
  Specify your existing VPC and a subnetwork that is located in `${REGION}`:
  ```bash
  export VPC_NETWORK="<your-vpc>"
  export VPC_SUBNET="<your-subnet-in-selected-region>"
  ```

### 3. NFS Connectivity or Timeout
* **Symptom:**
  Tasks hang during initialization or log connection timeout errors when accessing `/mnt/nfs/scratch`.
* **Cause:**
  - Filestore instance and Cloud Run Job are deployed to different VPC networks.
  - Custom VPC firewall rules block egress/ingress traffic on NFS port `2049`.
* **Resolution:**
  - Ensure the Filestore instance is created on the same `${VPC_NETWORK}` as Cloud Run.
  - If using strict firewall policies in a custom VPC, ensure traffic on TCP port `2049` (NFS) and TCP port `111` (RPC) is permitted between the Cloud Run subnet and the Filestore IP.

### 4. Subnet IP Exhaustion with High Task Counts
* **Symptom:**
  Tasks fail with network allocation errors during execution.
* **Cause:**
  Direct VPC Egress assigns an internal IP from the specified subnet to each concurrent task instance. If running 10 parallel tasks, at least 10 free IPs are needed in the subnet.
* **Resolution:**
  Ensure the target subnet has sufficient IP address space (e.g. `/28` provides 16 IP addresses, with ~11 usable by GCP instances).

---

## Presentation & Screenshot Walkthrough Guide

| # | Moment to Capture | Location | Key Visual Indicator |
|---|---|---|---|
| **1** | **Filestore Dashboard** | Cloud Console > Filestore > Instances | Show internal IP (`10.x.x.x`) and share (`/share1`) mounted as scratch space. |
| **2** | **Multi-Volume Mounts UI** | Cloud Console > Cloud Run > Jobs > `image-watermark-job` > Configuration | Volumes tab showing **3 volumes**: GCS Input (`/mnt/gcs/input`), GCS Output (`/mnt/gcs/output`), and NFS Scratch (`/mnt/nfs/scratch`). |
| **3** | **Parallel Execution Graph** | Cloud Console > Cloud Run > Jobs > Executions | 10 tasks running concurrently in parallel. |
| **4** | **Structured Cloud Logging** | Cloud Console > Logging > Log Explorer | Query JSON metrics demonstrating fetch, Filestore scratch processing, and GCS archival per task. |
| **5** | **Output Archival Validation** | Cloud Console > Cloud Storage > `${PROJECT_ID}-watermark-output` | Verify watermarked JPEG outputs preserved permanently in GCS. |

### Querying Structured Logs in Cloud Logging

```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="image-watermark-job"' \
    --limit=50 \
    --format="table(timestamp,jsonPayload.task_index,jsonPayload.event,jsonPayload.image,jsonPayload.fetch_from_gcs_ms,jsonPayload.filestore_scratch_proc_ms,jsonPayload.archive_to_gcs_ms)"
```

---

## Clean Up

To tear down all resources and avoid incurring charges:

```bash
./cleanup.sh
```
