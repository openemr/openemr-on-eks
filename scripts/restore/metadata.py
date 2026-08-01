"""Load backup manifest v2 from S3 or local path."""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse


@dataclass
class RestorePlan:
    backup_bucket: str
    snapshot_id: str
    app_data_key: str
    openemr_version: str
    backup_strategy: str
    backup_region: str
    kms_key_id: str
    manifest_version: int
    metadata_uri: str

    @classmethod
    def from_metadata(cls, data: dict[str, Any], metadata_uri: str) -> RestorePlan:
        plan = data.get("restore_plan") or {}
        bucket = data.get("backup_bucket") or plan.get("backup_bucket", "")
        snapshot = data.get("aurora_snapshot_id") or plan.get("snapshot_id", "")
        timestamp = data.get("timestamp", "")

        app_data_key = plan.get("app_data_key")
        if not app_data_key and timestamp:
            app_data_key = f"application-data/app-data-backup-{timestamp}.tar.gz"

        if snapshot in ("none", "", None):
            snapshot = plan.get("snapshot_id", "")

        return cls(
            backup_bucket=bucket,
            snapshot_id=snapshot,
            app_data_key=app_data_key or "",
            openemr_version=plan.get("openemr_version") or data.get("openemr_version") or "8.2.0",
            backup_strategy=plan.get("backup_strategy") or data.get("backup_strategy") or "same-region",
            backup_region=plan.get("backup_region") or data.get("backup_region") or data.get("source_region") or "us-west-2",
            kms_key_id=plan.get("kms_key_id") or data.get("kms_key_id") or "",
            manifest_version=int(data.get("manifest_version") or 1),
            metadata_uri=metadata_uri,
        )


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=False, capture_output=True, text=True)


def load_metadata_from_path(path: str) -> RestorePlan:
    """Load restore plan from a local JSON metadata file."""
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return RestorePlan.from_metadata(data, path)


def load_metadata(metadata_ref: str, region: str) -> RestorePlan:
    """Load metadata from s3:// URI, local path, or bucket-relative key."""
    ref = metadata_ref.strip()
    local_path: str | None = None

    if ref.startswith("s3://"):
        parsed = urlparse(ref)
        bucket = parsed.netloc
        key = parsed.path.lstrip("/")
        local_path = f"/tmp/{key.split('/')[-1]}"
        result = _run(["aws", "s3", "cp", ref, local_path, "--region", region])
        if result.returncode != 0:
            raise RuntimeError(f"Failed to download metadata: {result.stderr.strip()}")
        metadata_uri = ref
    elif ref.startswith("/") or ref.startswith("./"):
        return load_metadata_from_path(ref)
    else:
        # bucket-relative: metadata/backup-metadata-....json
        if "/" not in ref:
            raise ValueError("Metadata reference must be s3:// URI, local path, or bucket/key form")
        bucket, key = ref.split("/", 1)
        local_path = f"/tmp/{key.split('/')[-1]}"
        result = _run(["aws", "s3", "cp", f"s3://{bucket}/{key}", local_path, "--region", region])
        if result.returncode != 0:
            raise RuntimeError(f"Failed to download metadata: {result.stderr.strip()}")
        metadata_uri = f"s3://{bucket}/{key}"

    with open(local_path, encoding="utf-8") as handle:
        data = json.load(handle)

    return RestorePlan.from_metadata(data, metadata_uri)


def extract_timestamp_from_snapshot(snapshot_id: str) -> str | None:
    match = re.search(r"backup-(\d{8}-\d{6})", snapshot_id)
    return match.group(1) if match else None
