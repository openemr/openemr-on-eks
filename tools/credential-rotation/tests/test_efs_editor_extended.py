"""Extended tests for efs_editor.py — atomic_write, read_text, render_sqlconf edge cases."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from credential_rotation.efs_editor import (
    atomic_write,
    parse_sqlconf,
    read_text,
    render_sqlconf,
)

# ---------------------------------------------------------------------------
# read_text
# ---------------------------------------------------------------------------


class TestReadText:
    def test_reads_file_content(self, tmp_path: Path):
        f = tmp_path / "test.txt"
        f.write_text("hello world", encoding="utf-8")
        assert read_text(f) == "hello world"

    def test_reads_utf8(self, tmp_path: Path):
        f = tmp_path / "test.txt"
        f.write_text("café résumé", encoding="utf-8")
        assert read_text(f) == "café résumé"

    def test_raises_on_missing_file(self, tmp_path: Path):
        f = tmp_path / "nonexistent.txt"
        with pytest.raises(FileNotFoundError):
            read_text(f)


# ---------------------------------------------------------------------------
# atomic_write
# ---------------------------------------------------------------------------


class TestAtomicWrite:
    @patch("credential_rotation.efs_editor.os.chown")
    @patch("credential_rotation.efs_editor.os.fchown")
    @patch("credential_rotation.efs_editor.os.chmod")
    @patch("credential_rotation.efs_editor.os.fchmod")
    def test_writes_content(self, mock_fchmod, mock_chmod, mock_fchown, mock_chown, tmp_path: Path):
        target = tmp_path / "default" / "sqlconf.php"
        atomic_write(target, "new content")
        assert target.read_text() == "new content"

    @patch("credential_rotation.efs_editor.os.chown")
    @patch("credential_rotation.efs_editor.os.fchown")
    @patch("credential_rotation.efs_editor.os.chmod")
    @patch("credential_rotation.efs_editor.os.fchmod")
    def test_creates_parent_directories(self, mock_fchmod, mock_chmod, mock_fchown, mock_chown, tmp_path: Path):
        target = tmp_path / "deep" / "nested" / "file.txt"
        atomic_write(target, "content")
        assert target.exists()
        assert target.read_text() == "content"

    @patch("credential_rotation.efs_editor.os.chown")
    @patch("credential_rotation.efs_editor.os.fchown")
    @patch("credential_rotation.efs_editor.os.chmod")
    @patch("credential_rotation.efs_editor.os.fchmod")
    def test_overwrites_existing_file(self, mock_fchmod, mock_chmod, mock_fchown, mock_chown, tmp_path: Path):
        target = tmp_path / "file.txt"
        target.write_text("old")
        atomic_write(target, "new")
        assert target.read_text() == "new"

    @patch("credential_rotation.efs_editor.os.chown")
    @patch("credential_rotation.efs_editor.os.fchown")
    @patch("credential_rotation.efs_editor.os.chmod")
    @patch("credential_rotation.efs_editor.os.fchmod")
    def test_sets_permissions(self, mock_fchmod, mock_chmod, mock_fchown, mock_chown, tmp_path: Path):
        target = tmp_path / "file.txt"
        atomic_write(target, "content")
        mock_fchmod.assert_called_once()
        assert mock_fchmod.call_args[0][1] == 0o644
        mock_chmod.assert_called()

    @patch("credential_rotation.efs_editor.os.chown")
    @patch("credential_rotation.efs_editor.os.fchown")
    @patch("credential_rotation.efs_editor.os.chmod")
    @patch("credential_rotation.efs_editor.os.fchmod")
    def test_sets_ownership(self, mock_fchmod, mock_chmod, mock_fchown, mock_chown, tmp_path: Path):
        target = tmp_path / "file.txt"
        atomic_write(target, "content")
        mock_fchown.assert_called_once()
        assert mock_fchown.call_args[0][1] == 1000
        assert mock_fchown.call_args[0][2] == 101


# ---------------------------------------------------------------------------
# render_sqlconf – error cases
# ---------------------------------------------------------------------------


class TestRenderSqlconfErrors:
    def test_missing_host_variable_raises(self):
        content = """\
<?php
$port = '3306';
$login = 'user';
$pass  = 'pw';
$dbase = 'db';
"""
        slot = {
            "host": "h",
            "port": "3306",
            "username": "u",
            "password": "p",
            "dbname": "d",
        }
        with pytest.raises(ValueError, match=r"Unable to locate \$host"):
            render_sqlconf(content, slot)

    def test_missing_login_variable_raises(self):
        content = """\
<?php
$host = 'h';
$port = '3306';
$pass  = 'pw';
$dbase = 'db';
"""
        slot = {
            "host": "h",
            "port": "3306",
            "username": "u",
            "password": "p",
            "dbname": "d",
        }
        with pytest.raises(ValueError, match=r"Unable to locate \$login"):
            render_sqlconf(content, slot)

    def test_missing_pass_variable_raises(self):
        content = """\
<?php
$host = 'h';
$port = '3306';
$login = 'u';
$dbase = 'db';
"""
        slot = {
            "host": "h",
            "port": "3306",
            "username": "u",
            "password": "p",
            "dbname": "d",
        }
        with pytest.raises(ValueError, match=r"Unable to locate \$pass"):
            render_sqlconf(content, slot)


# ---------------------------------------------------------------------------
# parse_sqlconf – edge cases
# ---------------------------------------------------------------------------


class TestParseSqlconfEdgeCases:
    def test_double_quoted_values(self):
        content = '<?php\n$host = "db.host.com";\n$port = "3306";\n$login = "user";\n$pass = "pw";\n$dbase = "db";\n'
        parsed = parse_sqlconf(content)
        assert parsed["host"] == "db.host.com"
        assert parsed["username"] == "user"

    def test_extra_whitespace(self):
        content = "<?php\n$host   =   'db.host.com'   ;\n$port = '3306';\n$login = 'user';\n$pass  = 'pw';\n$dbase = 'db';\n"
        parsed = parse_sqlconf(content)
        assert parsed["host"] == "db.host.com"

    def test_empty_content_returns_empty(self):
        assert parse_sqlconf("") == {}

    def test_partial_content(self):
        content = "<?php\n$host = 'h';\n$dbase = 'd';\n"
        parsed = parse_sqlconf(content)
        assert parsed["host"] == "h"
        assert parsed["dbname"] == "d"
        assert "username" not in parsed
        assert "password" not in parsed
