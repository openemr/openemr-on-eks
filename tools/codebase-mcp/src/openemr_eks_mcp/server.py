"""FastMCP server definition for the local knowledge service."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

# FastMCP constructs its settings object during import and otherwise reads a
# working-directory .env file. Pin safe process settings before that import so
# repository-adjacent configuration cannot enable a network transport or update
# checks behind the CLI's explicit security boundary.
os.environ["FASTMCP_ENV_FILE"] = os.devnull
os.environ["FASTMCP_TRANSPORT"] = "stdio"
os.environ["FASTMCP_CHECK_FOR_UPDATES"] = "off"
os.environ["FASTMCP_SHOW_SERVER_BANNER"] = "false"

from fastmcp import FastMCP

from openemr_eks_mcp.knowledge import KnowledgeService


class StdioOnlyFastMCP(FastMCP):
    """FastMCP variant that rejects every network-capable production transport."""

    @staticmethod
    def _validate_transport(transport: Any) -> None:
        if transport not in (None, "stdio"):
            raise ValueError("Only the STDIO transport is supported.")

    def run(
        self,
        transport: Any = None,
        show_banner: bool | None = None,
        **transport_kwargs: Any,
    ) -> None:
        self._validate_transport(transport)
        super().run(transport="stdio", show_banner=False, **transport_kwargs)

    async def run_async(
        self,
        transport: Any = None,
        show_banner: bool | None = None,
        **transport_kwargs: Any,
    ) -> None:
        self._validate_transport(transport)
        await super().run_async(transport="stdio", show_banner=False, **transport_kwargs)

    def http_app(self, *args: Any, **kwargs: Any) -> Any:
        raise ValueError("HTTP transports are disabled; use STDIO.")

    async def run_http_async(self, *args: Any, **kwargs: Any) -> None:
        raise ValueError("HTTP transports are disabled; use STDIO.")


def _resource_json(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)


def create_server(repo_root: str | Path) -> StdioOnlyFastMCP:
    """Create a repository-bound server for in-memory tests and STDIO startup."""

    service = KnowledgeService(repo_root)
    mcp = StdioOnlyFastMCP(
        name="OpenEMR EKS Knowledge",
        instructions=(
            "Strictly read-only local knowledge for this OpenEMR on EKS checkout. "
            "The server never executes returned commands and never contacts AWS or a cluster."
        ),
        strict_input_validation=True,
    )

    @mcp.resource("knowledge://project/overview")
    def project_overview() -> str:
        """Project purpose, components, knowledge scope, and source precedence."""

        return _resource_json(service.project_overview())

    @mcp.resource("knowledge://project/architecture")
    def architecture_map() -> str:
        """Logical architecture, data flows, and authoritative implementation paths."""

        return _resource_json(service.architecture_map())

    @mcp.resource("knowledge://topics/catalog")
    def topic_catalog() -> str:
        """Curated topic names, aliases, summaries, and related topics."""

        return _resource_json(service.topic_catalog())

    @mcp.resource("knowledge://versions/current")
    def current_version_inventory() -> str:
        """Current versions parsed dynamically from versions.yaml."""

        return _resource_json(service.get_version_inventory())

    @mcp.resource("knowledge://security/model")
    def security_model() -> str:
        """Project security controls and this server's read-only boundaries."""

        return _resource_json(service.security_model())

    @mcp.resource("knowledge://topics/{topic}")
    def topic_resource(topic: str) -> str:
        """Curated topic details selected by slug or alias."""

        return _resource_json(service.get_topic(topic))

    @mcp.tool
    def get_topic(topic: str) -> dict[str, Any]:
        """Return concise curated topic guidance with authoritative repository paths."""

        return service.get_topic(topic)

    @mcp.tool
    def search_knowledge(
        query: str,
        max_results: int = 10,
        context_lines: int = 2,
    ) -> dict[str, Any]:
        """Search approved local text deterministically with bounded ranked results."""

        return service.search_knowledge(query, max_results, context_lines)

    @mcp.tool
    def read_repository_file(
        path: str,
        start_line: int = 1,
        max_lines: int = 100,
    ) -> dict[str, Any]:
        """Read a bounded line range from one approved repository-relative text file."""

        return service.read_repository_file(path, start_line, max_lines)

    @mcp.tool
    def get_version_inventory(component: str | None = None) -> dict[str, Any]:
        """Parse versions.yaml and report bounded source/configuration consumers."""

        return service.get_version_inventory(component)

    @mcp.tool
    def find_operational_command(
        task: str,
        max_results: int = 5,
    ) -> dict[str, Any]:
        """Explain relevant commands and label destructive, cloud, cost, and context risks."""

        return service.find_operational_command(task, max_results)

    return mcp


def run_stdio_server(repo_root: str | Path) -> None:
    """Run the only supported production transport with all banners disabled."""

    create_server(repo_root).run(transport="stdio", show_banner=False)
