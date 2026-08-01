"""Backup manifest v2 loading."""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from openemr_dr.models.restore import RestorePlan


def from_metadata_dict(data: dict[str, Any], metadata_uri: str) -> RestorePlan:
    plan = data.get("restore_plan") or {}
    bucket = data.get("backup_bucket") or plan.get("backup_bucket", "")
    snapshot = data.get("aurora_snapshot_id") or plan.get("snapshot_id", "")
    timestamp = data.get("timestamp", "")

    app_data_key = plan.get("app_data_key")
    if not app_data_key and timestamp:
        app_data_key = f"application-data/app-data-backup-{timestamp}.tar.gz"

    if snapshot in ("none", "", None):
        snapshot = plan.get("snapshot_id", "")

    return RestorePlan(
        backup_bucket=bucket,
        snapshot_id=snapshot or "",
        app_data_key=app_data_key or "",
        openemr_version=plan.get("openemr_version") or data.get("openemr_version") or "8.2.0",
        backup_strategy=plan.get("backup_strategy") or data.get("backup_strategy") or "same-region",
        backup_region=plan.get("backup_region")
        or data.get("backup_region")
        or data.get("source_region")
        or "us-west-2",
        kms_key_id=plan.get("kms_key_id") or data.get("kms_key_id") or "",
        manifest_version=int(data.get("manifest_version") or 1),
        metadata_uri=metadata_uri,
    )


def load_from_path(path: str) -> RestorePlan:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return from_metadata_dict(data, path)


def _temp_download_path(filename: str) -> str:
    return str(Path(tempfile.gettempdir()) / filename)


def load_metadata(metadata_ref: str, region: str) -> RestorePlan:
    ref = metadata_ref.strip()
    if ref.startswith("s3://"):
        local_path = _temp_download_path(urlparse(ref).path.split("/")[-1])
        result = subprocess.run(
            ["aws", "s3", "cp", ref, local_path, "--region", region],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "s3 cp failed")
        return load_from_path(local_path)
    if ref.startswith("/") or ref.startswith("./"):
        return load_from_path(ref)
    if "/" not in ref:
        raise ValueError("Metadata reference must be s3:// URI, local path, or bucket/key")
    bucket, key = ref.split("/", 1)
    local_path = _temp_download_path(key.split("/")[-1])
    result = subprocess.run(
        ["aws", "s3", "cp", f"s3://{bucket}/{key}", local_path, "--region", region],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "s3 cp failed")
    return load_from_path(local_path)


def extract_timestamp_from_snapshot(snapshot_id: str) -> str | None:
    match = re.search(r"backup-(\d{8}-\d{6})", snapshot_id)
    return match.group(1) if match else None
