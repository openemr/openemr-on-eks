from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

import pytest
from conftest import repository_digest
from fastmcp import Client

import openemr_eks_mcp.server as server_module
from openemr_eks_mcp.server import create_server, run_stdio_server


@pytest.mark.asyncio
async def test_in_memory_server_lists_and_reads_interface(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    server = create_server(root)

    async with Client(server) as client:
        tools = await client.list_tools()
        assert {tool.name for tool in tools} == {
            "get_topic",
            "search_knowledge",
            "read_repository_file",
            "get_version_inventory",
            "find_operational_command",
        }

        resources = await client.list_resources()
        assert {str(resource.uri) for resource in resources} == {
            "knowledge://project/overview",
            "knowledge://project/architecture",
            "knowledge://topics/catalog",
            "knowledge://versions/current",
            "knowledge://security/model",
        }

        templates = await client.list_resource_templates()
        assert {str(template.uriTemplate) for template in templates} == {"knowledge://topics/{topic}"}

        overview_content = await client.read_resource("knowledge://project/overview")
        overview = json.loads(overview_content[0].text)
        assert overview["server_properties"]["read_only"] is True

        architecture_content = await client.read_resource("knowledge://project/architecture")
        assert json.loads(architecture_content[0].text)["layers"]
        catalog_content = await client.read_resource("knowledge://topics/catalog")
        assert json.loads(catalog_content[0].text)["count"] == 12
        versions_content = await client.read_resource("knowledge://versions/current")
        assert json.loads(versions_content[0].text)["count"] == 3
        security_content = await client.read_resource("knowledge://security/model")
        assert json.loads(security_content[0].text)["knowledge_server_controls"]

        topic_content = await client.read_resource("knowledge://topics/security")
        topic = json.loads(topic_content[0].text)
        assert topic["topic"] == "security"


@pytest.mark.asyncio
async def test_in_memory_tools_return_structured_data_without_writes(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    before = repository_digest(root)

    async with Client(create_server(root)) as client:
        topic = await client.call_tool("get_topic", {"topic": "deployment"})
        assert topic.data["topic"] == "deployment"

        search = await client.call_tool(
            "search_knowledge",
            {"query": "EKS Auto Mode", "max_results": 2, "context_lines": 1},
        )
        assert search.data["result_count"] == 2

        read = await client.call_tool(
            "read_repository_file",
            {"path": "README.md", "start_line": 1, "max_lines": 2},
        )
        assert read.data["path"] == "README.md"

        versions = await client.call_tool(
            "get_version_inventory",
            {"component": "openemr"},
        )
        assert versions.data["items"][0]["current"] == "8.2.0"

        command = await client.call_tool(
            "find_operational_command",
            {"task": "destroy infrastructure", "max_results": 1},
        )
        assert command.data["results"][0]["risk"]["destructive"] is True

        invalid = await client.call_tool(
            "search_knowledge",
            {"query": "OpenEMR", "max_results": "2"},
            raise_on_error=False,
        )
        assert invalid.is_error is True

    assert repository_digest(root) == before


def test_stdio_runner_pins_transport_and_disables_banner(
    repo_factory: Callable[[], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = repo_factory()

    class StubServer:
        transport: str | None = None
        show_banner: bool | None = None

        def run(self, *, transport: str, show_banner: bool) -> None:
            self.transport = transport
            self.show_banner = show_banner

    stub = StubServer()
    monkeypatch.setattr(server_module, "create_server", lambda repo_root: stub)
    run_stdio_server(root)

    assert stub.transport == "stdio"
    assert stub.show_banner is False


def test_server_rejects_network_transports(repo_factory: Callable[[], Path]) -> None:
    server = create_server(repo_factory())

    with pytest.raises(ValueError, match="Only the STDIO transport"):
        server.run(transport="http")
    with pytest.raises(ValueError, match="Only the STDIO transport"):
        server.run(transport="streamable-http")
    with pytest.raises(ValueError, match="HTTP transports are disabled"):
        server.http_app()


@pytest.mark.asyncio
async def test_async_server_rejects_network_transports(
    repo_factory: Callable[[], Path],
) -> None:
    server = create_server(repo_factory())

    with pytest.raises(ValueError, match="Only the STDIO transport"):
        await server.run_async(transport="http")
    with pytest.raises(ValueError, match="HTTP transports are disabled"):
        await server.run_http_async()
