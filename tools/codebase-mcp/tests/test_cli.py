from __future__ import annotations

import json
import os
import runpy
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

import pytest

import openemr_eks_mcp.cli as cli
from openemr_eks_mcp import __version__
from openemr_eks_mcp.cli import REPO_ROOT_ENV, discover_repository_root, main


def test_cli_check_validates_without_starting_stdio(
    repo_factory: Callable[[], Path],
    capsys: pytest.CaptureFixture[str],
) -> None:
    root = repo_factory()
    assert main(["--repo-root", str(root), "--check"]) == 0

    result = json.loads(capsys.readouterr().out)
    assert result["ok"] is True
    assert result["read_only"] is True
    assert result["transport"] == "STDIO"
    assert result["version_entry_count"] == 3


def test_environment_and_upward_discovery(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    nested = root / "tools/example"
    nested.mkdir(parents=True)

    assert discover_repository_root(environ={REPO_ROOT_ENV: str(root)}) == root.resolve()
    assert discover_repository_root(environ={}, cwd=nested) == root.resolve()


def test_cli_version(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as raised:
        main(["--version"])
    assert raised.value.code == 0
    assert capsys.readouterr().out.strip() == f"openemr-eks-mcp {__version__}"


def test_cli_reports_invalid_repository(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    with pytest.raises(SystemExit) as raised:
        main(["--repo-root", str(tmp_path), "--check"])
    assert raised.value.code == 2
    assert "versions.yaml" in capsys.readouterr().err


def test_discovery_failure_is_clear(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="OPENEMR_EKS_REPO_ROOT"):
        discover_repository_root(environ={}, cwd=tmp_path)


def test_default_cli_path_starts_server(
    repo_factory: Callable[[], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = repo_factory()
    called_with: list[Path] = []

    monkeypatch.setattr(cli, "run_stdio_server", called_with.append)
    assert cli.main(["--repo-root", str(root)]) == 0
    assert called_with == [root]


def test_real_stdio_startup_ignores_transport_override_without_network_or_cache_writes(
    repo_factory: Callable[[], Path],
    tmp_path: Path,
) -> None:
    root = repo_factory()
    home = tmp_path / "home"
    home.mkdir()
    startup_cwd = tmp_path / "startup-cwd"
    startup_cwd.mkdir()
    (startup_cwd / ".env").write_text(
        f"FASTMCP_TRANSPORT=http\nFASTMCP_CHECK_FOR_UPDATES=stable\nFASTMCP_HOME={home / 'dotenv-fastmcp'}\n",
        encoding="utf-8",
    )
    startup_guard = tmp_path / "startup-guard"
    startup_guard.mkdir()
    (startup_guard / "sitecustomize.py").write_text(
        "import socket\n"
        "class NoNetworkSocket(socket.socket):\n"
        "    def connect(self, *args, **kwargs):\n"
        "        raise RuntimeError('network disabled in startup test')\n"
        "    def connect_ex(self, *args, **kwargs):\n"
        "        raise RuntimeError('network disabled in startup test')\n"
        "socket.socket = NoNetworkSocket\n"
        "def deny_connection(*args, **kwargs):\n"
        "    raise RuntimeError('network disabled in startup test')\n"
        "socket.create_connection = deny_connection\n",
        encoding="utf-8",
    )
    environment = os.environ.copy()
    environment.update(
        {
            "FASTMCP_CHECK_FOR_UPDATES": "stable",
            "FASTMCP_HOME": str(home / "fastmcp"),
            "FASTMCP_TRANSPORT": "http",
            "HOME": str(home),
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": os.pathsep.join(filter(None, (str(startup_guard), environment.get("PYTHONPATH", "")))),
            "XDG_CACHE_HOME": str(home / "cache"),
            "XDG_CONFIG_HOME": str(home / "config"),
            "XDG_DATA_HOME": str(home / "data"),
        }
    )

    completed = subprocess.run(
        [sys.executable, "-m", "openemr_eks_mcp", "--repo-root", str(root)],
        input="",
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
        env=environment,
        cwd=startup_cwd,
    )
    assert completed.returncode == 0, completed.stderr
    assert list(home.iterdir()) == []


def test_python_module_entrypoint_reports_version(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(sys, "argv", ["openemr-eks-mcp", "--version"])
    with pytest.raises(SystemExit) as raised:
        runpy.run_module("openemr_eks_mcp", run_name="__main__")
    assert raised.value.code == 0
    assert capsys.readouterr().out.strip() == f"openemr-eks-mcp {__version__}"
