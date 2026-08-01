"""Restore domain models."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from openemr_dr.common.paths import PROJECT_ROOT


@dataclass
class RestorePlan:
    backup_bucket: str
    snapshot_id: str
    app_data_key: str = ""
    openemr_version: str = "8.2.0"
    backup_strategy: str = "same-region"
    backup_region: str = "us-west-2"
    kms_key_id: str = ""
    manifest_version: int = 1
    metadata_uri: str = ""


@dataclass
class RestoreContext:
    """Runtime configuration for a restore run."""

    backup_bucket: str
    snapshot_id: str
    aws_region: str = "us-west-2"
    namespace: str = "openemr"
    cluster_name: str = ""
    app_data_key: str = ""
    metadata_uri: str = ""
    use_aws_backup: bool = False
    legacy_order: bool = False
    dry_run: bool = False
    custom_kms_key: str = ""
    project_root: Path = field(default_factory=lambda: PROJECT_ROOT)

    def resolve_app_data_key(self) -> str:
        if self.app_data_key:
            return self.app_data_key
        import re

        match = re.search(r"backup-(\d{8}-\d{6})", self.snapshot_id)
        if not match:
            raise ValueError("Cannot derive app_data_key; set explicitly or use manifest v2")
        return f"application-data/app-data-backup-{match.group(1)}.tar.gz"


PHASES = ("preflight", "bootstrap", "rds", "data", "deploy", "verify")
