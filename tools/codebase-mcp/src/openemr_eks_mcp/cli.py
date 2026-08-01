"""Command-line entry point for the STDIO-only MCP server."""

from __future__ import annotations

import argparse
import json
import os
from collections.abc import Mapping, Sequence
from pathlib import Path

from openemr_eks_mcp import __version__
from openemr_eks_mcp.knowledge import KnowledgeService
from openemr_eks_mcp.server import run_stdio_server

REPO_ROOT_ENV = "OPENEMR_EKS_REPO_ROOT"


def _looks_like_repo_root(path: Path) -> bool:
    return (path / "versions.yaml").is_file() and any(
        marker.exists() for marker in (path / "README.md", path / "terraform", path / "k8s")
    )


def discover_repository_root(
    repo_root: str | Path | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> Path:
    """Resolve explicit, environment, or upward-discovered repository root."""

    environment = os.environ if environ is None else environ
    if repo_root is not None:
        return Path(repo_root).expanduser().resolve()
    configured = environment.get(REPO_ROOT_ENV)
    if configured:
        return Path(configured).expanduser().resolve()

    start = Path.cwd() if cwd is None else cwd
    start = start.expanduser().resolve()
    for candidate in (start, *start.parents):
        if _looks_like_repo_root(candidate):
            return candidate
    raise ValueError("Repository root was not found. Use --repo-root or OPENEMR_EKS_REPO_ROOT.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="openemr-eks-mcp",
        description="Run the strictly read-only local OpenEMR EKS knowledge MCP server.",
    )
    parser.add_argument(
        "--repo-root",
        help=(
            "OpenEMR on EKS repository root. Falls back to OPENEMR_EKS_REPO_ROOT, "
            "then current-directory upward discovery."
        ),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate repository access and exit without starting STDIO.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run a validation check or start FastMCP's default STDIO transport."""

    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        repo_root = discover_repository_root(args.repo_root)
        if args.check:
            result = KnowledgeService(repo_root).check()
            print(json.dumps(result, sort_keys=True))
            return 0
        run_stdio_server(repo_root)
    except ValueError as exc:
        parser.error(str(exc))
    return 0
