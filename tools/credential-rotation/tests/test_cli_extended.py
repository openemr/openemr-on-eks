"""Extended tests for cli.py — main(), fix_permissions, sync_db_users CLI paths."""

from __future__ import annotations

import json
import os
from pathlib import Path
from unittest.mock import MagicMock, patch

from credential_rotation.cli import build_parser, fix_permissions, main

# ---------------------------------------------------------------------------
# fix_permissions
# ---------------------------------------------------------------------------


class TestFixPermissions:
    def test_success(self, tmp_path: Path):
        sqlconf = tmp_path / "default" / "sqlconf.php"
        sqlconf.parent.mkdir(parents=True)
        sqlconf.write_text("<?php\n")
        sqlconf.chmod(0o400)

        with patch.dict(os.environ, {"OPENEMR_SITES_MOUNT_ROOT": str(tmp_path)}):
            assert fix_permissions() == 0
            assert oct(sqlconf.stat().st_mode)[-3:] == "644"

    def test_missing_file(self, tmp_path: Path, capsys):
        with patch.dict(os.environ, {"OPENEMR_SITES_MOUNT_ROOT": str(tmp_path)}):
            assert fix_permissions() == 1
            captured = capsys.readouterr()
            assert "not found" in captured.err

    def test_uses_default_mount_root(self, capsys):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("OPENEMR_SITES_MOUNT_ROOT", None)
            result = fix_permissions()
            assert result == 1


# ---------------------------------------------------------------------------
# build_parser
# ---------------------------------------------------------------------------


class TestBuildParser:
    def test_fix_permissions_flag(self):
        parser = build_parser()
        args = parser.parse_args(["--fix-permissions"])
        assert args.fix_permissions is True
        assert args.dry_run is False

    def test_sync_db_users_flag(self):
        parser = build_parser()
        args = parser.parse_args(["--sync-db-users"])
        assert args.sync_db_users is True
        assert args.dry_run is False

    def test_all_flags(self):
        parser = build_parser()
        args = parser.parse_args(["--dry-run", "--log-json", "--fix-permissions", "--sync-db-users"])
        assert args.dry_run is True
        assert args.log_json is True
        assert args.fix_permissions is True
        assert args.sync_db_users is True


# ---------------------------------------------------------------------------
# main() — rotation path
# ---------------------------------------------------------------------------


class TestMainRotation:
    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_rotation_success_text(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate", "--dry-run"]):
            result = main()
        assert result == 0
        mock_orch.rotate.assert_called_once()
        captured = capsys.readouterr()
        assert "Rotation completed" in captured.out

    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_rotation_success_json(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate", "--dry-run", "--log-json"]):
            result = main()
        assert result == 0
        captured = capsys.readouterr()
        data = json.loads(captured.out.strip())
        assert data["status"] == "ok"
        assert data["dry_run"] is True

    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_rotation_failure_text(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch.rotate.side_effect = RuntimeError("rotation boom")
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate"]):
            result = main()
        assert result == 1
        captured = capsys.readouterr()
        assert "rotation boom" in captured.err

    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_rotation_failure_json(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch.rotate.side_effect = RuntimeError("rotation boom")
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate", "--log-json"]):
            result = main()
        assert result == 1
        captured = capsys.readouterr()
        data = json.loads(captured.out.strip())
        assert data["status"] == "error"
        assert "rotation boom" in data["error"]


# ---------------------------------------------------------------------------
# main() — fix-permissions path
# ---------------------------------------------------------------------------


class TestMainFixPermissions:
    def test_fix_permissions_path(self, tmp_path: Path):
        sqlconf = tmp_path / "default" / "sqlconf.php"
        sqlconf.parent.mkdir(parents=True)
        sqlconf.write_text("<?php\n")

        with patch("sys.argv", ["rotate", "--fix-permissions"]):
            with patch.dict(os.environ, {"OPENEMR_SITES_MOUNT_ROOT": str(tmp_path)}):
                result = main()
        assert result == 0


# ---------------------------------------------------------------------------
# main() — sync-db-users path
# ---------------------------------------------------------------------------


class TestMainSyncDbUsers:
    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_sync_success_text(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate", "--sync-db-users"]):
            result = main()
        assert result == 0
        mock_orch.sync_db_users.assert_called_once()
        captured = capsys.readouterr()
        assert "synced" in captured.out.lower()

    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_sync_success_json(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate", "--sync-db-users", "--log-json"]):
            result = main()
        assert result == 0
        captured = capsys.readouterr()
        data = json.loads(captured.out.strip())
        assert data["status"] == "ok"
        assert data["action"] == "sync_db_users"

    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_sync_failure_text(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch.sync_db_users.side_effect = RuntimeError("sync boom")
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate", "--sync-db-users"]):
            result = main()
        assert result == 1
        captured = capsys.readouterr()
        assert "sync boom" in captured.err

    @patch("credential_rotation.cli.RotationOrchestrator")
    def test_sync_failure_json(self, mock_orch_cls, capsys):
        mock_orch = MagicMock()
        mock_orch.sync_db_users.side_effect = RuntimeError("sync boom")
        mock_orch_cls.from_env.return_value = mock_orch
        with patch("sys.argv", ["rotate", "--sync-db-users", "--log-json"]):
            result = main()
        assert result == 1
        captured = capsys.readouterr()
        data = json.loads(captured.out.strip())
        assert data["status"] == "error"
        assert "sync boom" in data["error"]
