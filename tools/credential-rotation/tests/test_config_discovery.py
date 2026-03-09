"""Tests for config_discovery.py — discover_runtime_paths."""

from pathlib import Path

import pytest

from credential_rotation.config_discovery import (
    RuntimeConfigPaths,
    discover_runtime_paths,
)


def test_discover_runtime_paths_success(tmp_path: Path):
    default_dir = tmp_path / "default"
    default_dir.mkdir()
    sqlconf = default_dir / "sqlconf.php"
    sqlconf.write_text("<?php\n$host = 'h';\n")

    result = discover_runtime_paths(str(tmp_path))
    assert isinstance(result, RuntimeConfigPaths)
    assert result.sqlconf_path == sqlconf


def test_discover_runtime_paths_missing_sqlconf(tmp_path: Path):
    with pytest.raises(FileNotFoundError, match="sqlconf.php not found"):
        discover_runtime_paths(str(tmp_path))


def test_discover_runtime_paths_missing_default_dir(tmp_path: Path):
    with pytest.raises(FileNotFoundError, match="sqlconf.php not found"):
        discover_runtime_paths(str(tmp_path))


def test_runtime_config_paths_is_frozen(tmp_path: Path):
    default_dir = tmp_path / "default"
    default_dir.mkdir()
    sqlconf = default_dir / "sqlconf.php"
    sqlconf.write_text("<?php\n")

    paths = discover_runtime_paths(str(tmp_path))
    with pytest.raises(AttributeError):
        paths.sqlconf_path = Path("/other")
