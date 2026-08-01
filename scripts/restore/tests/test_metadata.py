"""Unit tests for restore metadata loading."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from metadata import (  # noqa: E402
    RestorePlan,
    extract_timestamp_from_snapshot,
    load_metadata,
    load_metadata_from_path,
)


class TestRestorePlanFromMetadata(unittest.TestCase):
    def test_v2_manifest_with_explicit_restore_plan(self) -> None:
        data = {
            "manifest_version": 2,
            "backup_bucket": "openemr-backups-123-openemr-eks-20260702",
            "aurora_snapshot_id": "openemr-eks-test-aurora-abc-backup-20260702-213048",
            "timestamp": "20260702-213048",
            "restore_plan": {
                "app_data_key": "application-data/app-data-backup-20260702-213048.tar.gz",
                "openemr_version": "8.2.0",
                "backup_region": "us-west-2",
                "backup_strategy": "cross-region",
                "kms_key_id": "arn:aws:kms:us-west-2:123:key/abc",
            },
        }
        plan = RestorePlan.from_metadata(data, "s3://bucket/metadata/file.json")
        self.assertEqual(plan.manifest_version, 2)
        self.assertEqual(plan.backup_bucket, "openemr-backups-123-openemr-eks-20260702")
        self.assertEqual(plan.snapshot_id, "openemr-eks-test-aurora-abc-backup-20260702-213048")
        self.assertEqual(plan.app_data_key, "application-data/app-data-backup-20260702-213048.tar.gz")
        self.assertEqual(plan.openemr_version, "8.2.0")
        self.assertEqual(plan.backup_strategy, "cross-region")
        self.assertEqual(plan.kms_key_id, "arn:aws:kms:us-west-2:123:key/abc")

    def test_v1_manifest_derives_app_data_key_from_timestamp(self) -> None:
        data = {
            "manifest_version": 1,
            "backup_bucket": "my-bucket",
            "aurora_snapshot_id": "cluster-backup-20260101-120000",
            "timestamp": "20260101-120000",
            "backup_strategy": "same-region",
            "source_region": "eu-west-1",
        }
        plan = RestorePlan.from_metadata(data, "/tmp/meta.json")
        self.assertEqual(plan.manifest_version, 1)
        self.assertEqual(plan.app_data_key, "application-data/app-data-backup-20260101-120000.tar.gz")
        self.assertEqual(plan.backup_region, "eu-west-1")
        self.assertEqual(plan.openemr_version, "8.2.0")

    def test_snapshot_none_falls_back_to_restore_plan(self) -> None:
        data = {
            "aurora_snapshot_id": "none",
            "restore_plan": {"snapshot_id": "real-snapshot-id", "backup_bucket": "b"},
        }
        plan = RestorePlan.from_metadata(data, "uri")
        self.assertEqual(plan.snapshot_id, "real-snapshot-id")
        self.assertEqual(plan.backup_bucket, "b")

    def test_load_metadata_from_path_roundtrip(self) -> None:
        payload = {
            "manifest_version": 2,
            "backup_bucket": "bucket-a",
            "aurora_snapshot_id": "snap-1",
            "timestamp": "20260703-100000",
            "restore_plan": {
                "app_data_key": "application-data/app-data-backup-20260703-100000.tar.gz",
            },
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tmp:
            json.dump(payload, tmp)
            path = tmp.name
        try:
            plan = load_metadata_from_path(path)
            self.assertEqual(plan.backup_bucket, "bucket-a")
            self.assertEqual(plan.metadata_uri, path)
        finally:
            Path(path).unlink(missing_ok=True)

    def test_load_metadata_rejects_bare_filename(self) -> None:
        with self.assertRaises(ValueError):
            load_metadata("backup-metadata.json", "us-west-2")

    def test_extract_timestamp_valid_and_invalid(self) -> None:
        self.assertEqual(
            extract_timestamp_from_snapshot("openemr-eks-test-aurora-x-backup-20260702-213048"),
            "20260702-213048",
        )
        self.assertIsNone(extract_timestamp_from_snapshot("invalid-snapshot-name"))


if __name__ == "__main__":
    unittest.main()
