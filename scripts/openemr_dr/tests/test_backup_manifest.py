"""Tests for backup manifest builder."""

from __future__ import annotations

from openemr_dr.backup.manifest import build_manifest


def test_build_manifest_v2_fields() -> None:
    manifest = build_manifest(
        backup_id="id",
        timestamp="20260703-120000",
        source_region="us-west-2",
        backup_region="us-west-2",
        cluster_name="c",
        namespace="openemr",
        backup_bucket="bucket",
        openemr_version="8.2.0",
        aurora_cluster_id="cluster",
        snapshot_id="snap",
        backup_success=True,
        backup_strategy="same-region",
        target_account_id="",
        kms_key_id="",
        copy_tags=True,
        app_backup_file="app-data-backup-20260703-120000.tar.gz",
        database_config={},
        created_by="arn:user",
        aws_account="123",
    )
    assert manifest["manifest_version"] == 2
    assert manifest["restore_plan"]["app_data_key"].startswith("application-data/")
    assert "restore_command" in manifest
