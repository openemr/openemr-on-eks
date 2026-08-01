"""Tests for openemr_dr backup metadata."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from openemr_dr.backup.metadata import (
    extract_timestamp_from_snapshot,
    from_metadata_dict,
    load_from_path,
)


class TestMetadata(unittest.TestCase):
    def test_v2_restore_plan(self) -> None:
        data = {
            "manifest_version": 2,
            "backup_bucket": "b",
            "aurora_snapshot_id": "snap-backup-20260702-213048",
            "restore_plan": {"app_data_key": "application-data/x.tar.gz", "openemr_version": "8.2.0"},
        }
        plan = from_metadata_dict(data, "uri")
        self.assertEqual(plan.manifest_version, 2)
        self.assertEqual(plan.app_data_key, "application-data/x.tar.gz")

    def test_v1_derives_app_key(self) -> None:
        data = {"timestamp": "20260101-120000", "backup_bucket": "b", "aurora_snapshot_id": "s"}
        plan = from_metadata_dict(data, "u")
        self.assertIn("20260101-120000", plan.app_data_key)

    def test_load_from_path(self) -> None:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tmp:
            json.dump({"backup_bucket": "x", "aurora_snapshot_id": "y", "timestamp": "20260703-000000"}, tmp)
            path = tmp.name
        try:
            plan = load_from_path(path)
            self.assertEqual(plan.backup_bucket, "x")
        finally:
            Path(path).unlink(missing_ok=True)

    def test_extract_timestamp(self) -> None:
        self.assertEqual(extract_timestamp_from_snapshot("a-backup-20260702-213048"), "20260702-213048")
        self.assertIsNone(extract_timestamp_from_snapshot("no-ts"))


if __name__ == "__main__":
    unittest.main()
