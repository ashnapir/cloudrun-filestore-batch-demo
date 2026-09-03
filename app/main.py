#!/usr/bin/env python3
"""
Hybrid Storage Parallel Image Watermarking Batch Worker for Cloud Run Jobs.

Architecture Implementation:
- GCS Input Bucket (via GCS FUSE at /mnt/gcs/input): Ingestion source of truth
- Filestore NFS (via NFS mount at /mnt/nfs/scratch): High-IOPS temporary scratch space
- GCS Output Bucket (via GCS FUSE at /mnt/gcs/output): Persistent archival destination
- Cloud Run Jobs: Distributed batch execution using CLOUD_RUN_TASK_INDEX/COUNT
- Direct VPC Egress: Secure private communication to Filestore IP
"""

import argparse
import glob
import json
import os
import shutil
import sys
import time
from PIL import Image, ImageDraw


def log_event(event_type: str, **kwargs):
    """Outputs structured JSON log entry for Cloud Logging ingestion."""
    payload = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event_type,
        **kwargs
    }
    print(json.dumps(payload), flush=True)


def seed_sample_images(input_dir: str, count: int = 30):
    """Populates test sample images directly onto GCS FUSE input mount."""
    os.makedirs(input_dir, exist_ok=True)
    log_event("seed_started", target_dir=input_dir, count=count)

    colors = [
        (66, 133, 244),   # Google Blue
        (234, 67, 53),    # Google Red
        (251, 188, 4),    # Google Yellow
        (52, 168, 83),    # Google Green
        (103, 58, 183),   # Deep Purple
        (0, 150, 136),    # Teal
        (255, 112, 67),   # Coral
        (69, 90, 100),    # Slate
    ]

    for i in range(1, count + 1):
        filename = f"sample_{i:03d}.jpg"
        filepath = os.path.join(input_dir, filename)
        if os.path.exists(filepath):
            continue

        width, height = 1280, 800
        base_color = colors[(i - 1) % len(colors)]
        img = Image.new("RGB", (width, height), color=base_color)
        draw = ImageDraw.Draw(img)

        # Draw decorative boundaries
        draw.rectangle([40, 40, width - 40, height - 40], outline=(255, 255, 255), width=6)
        draw.rectangle([60, 60, width - 60, height - 60], outline=(220, 220, 220), width=2)

        # Informational metadata text
        lines = [
            "HYBRID STORAGE: CLOUD RUN + FILESTORE + GCS",
            f"Image ID: #{i:03d} | Batch Pipeline Demo",
            f"Dimensions: {width}x{height} | Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            "Source: GCS FUSE (/mnt/gcs/input)",
            "Scratch: Filestore NFS (/mnt/nfs/scratch)",
            "Archive: GCS FUSE (/mnt/gcs/output)",
        ]
        y = 230
        for line in lines:
            draw.text((90, y), line, fill=(255, 255, 255))
            y += 55

        img.save(filepath, "JPEG", quality=90)

    log_event("seed_completed", target_dir=input_dir, count=count)


def locate_watermark(watermark_arg: str) -> str:
    """Finds the watermark graphic across expected locations."""
    candidates = [
        watermark_arg,
        os.path.join(os.path.dirname(__file__), "..", "images", "watermark.png"),
        os.path.join(os.path.dirname(__file__), "watermark.png"),
        "watermark.png",
        "/app/watermark.png",
    ]
    for path in candidates:
        if path and os.path.isfile(path):
            return os.path.abspath(path)
    return ""


def process_images():
    """Executes the 4-phase hybrid storage data pipeline."""
    # Environment variables populated by Cloud Run Jobs
    task_index = int(os.environ.get("CLOUD_RUN_TASK_INDEX", 0))
    task_count = int(os.environ.get("CLOUD_RUN_TASK_COUNT", 1))
    task_attempt = os.environ.get("CLOUD_RUN_TASK_ATTEMPT", "0")
    execution_name = os.environ.get("CLOUD_RUN_EXECUTION", "manual-execution")

    # Directory mounts per architecture specification
    gcs_input_dir = os.environ.get("GCS_INPUT_DIR", "/mnt/gcs/input")
    gcs_output_dir = os.environ.get("GCS_OUTPUT_DIR", "/mnt/gcs/output")
    nfs_scratch_dir = os.environ.get("NFS_SCRATCH_DIR", "/mnt/nfs/scratch")
    watermark_path = os.environ.get("WATERMARK_PATH", "watermark.png")

    task_scratch_dir = os.path.join(nfs_scratch_dir, f"task_{task_index:03d}")

    log_event("task_init",
              execution=execution_name,
              task_index=task_index,
              task_count=task_count,
              task_attempt=task_attempt,
              gcs_input=gcs_input_dir,
              gcs_output=gcs_output_dir,
              nfs_scratch=task_scratch_dir)

    # Ensure required directories exist
    os.makedirs(gcs_output_dir, exist_ok=True)
    os.makedirs(task_scratch_dir, exist_ok=True)

    # 1. Discover input images in GCS FUSE mount
    supported_exts = ("*.jpg", "*.jpeg", "*.png", "*.JPG", "*.JPEG", "*.PNG")
    all_files = []
    for ext in supported_exts:
        all_files.extend(glob.glob(os.path.join(gcs_input_dir, ext)))
    all_files = sorted(list(set(all_files)))

    # Handle auto-seeding if input is empty
    should_auto_seed = os.environ.get("AUTO_SEED", "false").lower() in ("true", "1", "yes")
    if not all_files:
        if should_auto_seed or os.environ.get("SEED_IMAGES"):
            seed_count = int(os.environ.get("SEED_IMAGES", 30))
            if task_index == 0:
                log_event("auto_seed_triggered", task_index=task_index, count=seed_count)
                seed_sample_images(gcs_input_dir, seed_count)
            else:
                log_event("wait_for_seed", task_index=task_index, wait_seconds=6)
                time.sleep(6)

            all_files = []
            for ext in supported_exts:
                all_files.extend(glob.glob(os.path.join(gcs_input_dir, ext)))
            all_files = sorted(list(set(all_files)))

    if not all_files:
        log_event("no_files_found", input_dir=gcs_input_dir, task_index=task_index)
        print(f"[Task {task_index}] No input images found in {gcs_input_dir}. Exiting.")
        return

    # Slice files based on Cloud Run task index: deterministic round-robin partitioning
    my_files = all_files[task_index::task_count]

    log_event("workload_assigned",
              task_index=task_index,
              total_files=len(all_files),
              assigned_files=len(my_files))

    # Load watermark asset
    resolved_wm = locate_watermark(watermark_path)
    if not resolved_wm:
        raise FileNotFoundError(f"Watermark asset not found at {watermark_path}")

    watermark = Image.open(resolved_wm).convert("RGBA")
    wm_orig_w, wm_orig_h = watermark.size

    total_start = time.time()
    processed_count = 0

    # 2 & 3. Fetch from GCS FUSE, Process on Filestore NFS scratch, Output to GCS
    for img_path in my_files:
        item_start = time.time()
        base_name = os.path.basename(img_path)

        # Temporary paths on Filestore NFS scratch
        nfs_raw_path = os.path.join(task_scratch_dir, f"raw_{base_name}")
        nfs_processed_path = os.path.join(task_scratch_dir, f"proc_{base_name}")
        final_gcs_out_path = os.path.join(gcs_output_dir, base_name)

        try:
            # Phase A: Fetch from GCS FUSE mount into Filestore NFS Scratch
            fetch_start = time.time()
            shutil.copyfile(img_path, nfs_raw_path)
            fetch_ms = int((time.time() - fetch_start) * 1000)

            # Phase B: High-IOPS image processing in Filestore Scratch space
            proc_start = time.time()
            with Image.open(nfs_raw_path).convert("RGBA") as base:
                base_w, base_h = base.size

                # Dynamic watermark scaling
                max_wm_w = int(base_w * 0.25)
                if wm_orig_w > max_wm_w and max_wm_w > 50:
                    scale = max_wm_w / wm_orig_w
                    wm_resized = watermark.resize(
                        (int(wm_orig_w * scale), int(wm_orig_h * scale)),
                        Image.Resampling.LANCZOS
                    )
                else:
                    wm_resized = watermark

                wm_w, wm_h = wm_resized.size
                padding = 24
                pos = (max(0, base_w - wm_w - padding), max(0, base_h - wm_h - padding))

                # Composite watermark
                base.paste(wm_resized, pos, wm_resized)

                # Save intermediate processed result to Filestore NFS scratch
                base.convert("RGB").save(nfs_processed_path, "JPEG", quality=92)

            proc_ms = int((time.time() - proc_start) * 1000)

            # Phase C: Archival write directly to GCS Output Bucket
            archive_start = time.time()
            shutil.copyfile(nfs_processed_path, final_gcs_out_path)
            archive_ms = int((time.time() - archive_start) * 1000)

            # Phase D: Cleanup intermediate artifacts on Filestore NFS
            if os.path.exists(nfs_raw_path):
                os.remove(nfs_raw_path)
            if os.path.exists(nfs_processed_path):
                os.remove(nfs_processed_path)

            total_item_ms = int((time.time() - item_start) * 1000)
            processed_count += 1

            log_event("image_processed",
                      task_index=task_index,
                      image=base_name,
                      dimensions=f"{base_w}x{base_h}",
                      fetch_from_gcs_ms=fetch_ms,
                      filestore_scratch_proc_ms=proc_ms,
                      archive_to_gcs_ms=archive_ms,
                      total_duration_ms=total_item_ms)

        except Exception as e:
            log_event("image_processing_error",
                      task_index=task_index,
                      image=base_name,
                      error=str(e))

    # Phase 4: Final cleanup of task-specific scratch directory on Filestore NFS
    try:
        shutil.rmtree(task_scratch_dir, ignore_errors=True)
        log_event("nfs_scratch_cleaned", task_index=task_index, dir=task_scratch_dir)
    except Exception as e:
        log_event("nfs_cleanup_warning", task_index=task_index, error=str(e))

    total_duration = time.time() - total_start
    log_event("task_completed",
              task_index=task_index,
              processed_count=processed_count,
              assigned_count=len(my_files),
              total_seconds=round(total_duration, 2))


def main():
    parser = argparse.ArgumentParser(description="Hybrid Storage Batch Worker: GCS + Filestore + Cloud Run")
    parser.add_argument("--seed", type=int, nargs="?", const=30, default=None,
                        help="Seed N sample images to GCS input directory and exit")
    parser.add_argument("--gcs-input", type=str, default=None, help="GCS input mount path")
    parser.add_argument("--gcs-output", type=str, default=None, help="GCS output mount path")
    parser.add_argument("--nfs-scratch", type=str, default=None, help="Filestore NFS scratch path")
    args = parser.parse_args()

    if args.gcs_input:
        os.environ["GCS_INPUT_DIR"] = args.gcs_input
    if args.gcs_output:
        os.environ["GCS_OUTPUT_DIR"] = args.gcs_output
    if args.nfs_scratch:
        os.environ["NFS_SCRATCH_DIR"] = args.nfs_scratch

    if args.seed is not None:
        target_dir = os.environ.get("GCS_INPUT_DIR", "/mnt/gcs/input")
        seed_sample_images(target_dir, args.seed)
        sys.exit(0)

    process_images()


if __name__ == "__main__":
    main()
