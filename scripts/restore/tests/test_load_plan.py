"""Unit tests for load_plan CLI helper."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


class TestLoadPlanCli(unittest.TestCase):
    def test_load_plan_prints_json_from_local_file(self) -> None:
        script = Path(__file__).resolve().parents[1] / "load_plan.py"
        payload = {
            "manifest_version": 2,
            "backup_bucket": "test-bucket",
            "aurora_snapshot_id": "snap-abc",
            "timestamp": "20260703-120000",
            "restore_plan": {
                "app_data_key": "application-data/app-data-backup-20260703-120000.tar.gz",
                "openemr_version": "8.2.0",
                "backup_region": "us-west-2",
            },
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tmp:
            json.dump(payload, tmp)
            path = tmp.name

        try:
            result = subprocess.run(
                ["python3", str(script), path, "us-west-2"],
                check=True,
                capture_output=True,
                text=True,
            )
            data = json.loads(result.stdout)
            self.assertEqual(data["backup_bucket"], "test-bucket")
            self.assertEqual(data["snapshot_id"], "snap-abc")
            self.assertIn("app-data-backup-20260703-120000", data["app_data_key"])
        finally:
            Path(path).unlink(missing_ok=True)

    def test_load_plan_missing_args_exits_nonzero(self) -> None:
        script = Path(__file__).resolve().parents[1] / "load_plan.py"
        result = subprocess.run(["python3", str(script)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
