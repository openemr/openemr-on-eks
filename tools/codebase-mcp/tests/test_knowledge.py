from __future__ import annotations

import socket
from collections.abc import Callable
from pathlib import Path

import pytest
from conftest import repository_digest

import openemr_eks_mcp.knowledge as knowledge_module
from openemr_eks_mcp.knowledge import MAX_READ_CONTENT_CHARS, KnowledgeService


def test_topic_catalog_and_topic_alias(repo_factory: Callable[[], Path]) -> None:
    service = KnowledgeService(repo_factory())

    catalog = service.topic_catalog()
    assert catalog["count"] == 12
    assert {entry["topic"] for entry in catalog["topics"]} >= {
        "deployment",
        "architecture",
        "security",
        "monitoring",
        "backup-restore-dr",
        "credentials-rotation",
        "versions",
        "ci-cd",
        "testing",
        "troubleshooting",
        "cleanup",
        "openemr-initialization",
    }

    topic = service.get_topic("EKS Auto Mode")
    assert topic["topic"] == "architecture"
    assert topic["authoritative_sources"]
    assert all({"path", "role", "precedence", "exists"} <= set(source) for source in topic["authoritative_sources"])
    with pytest.raises(ValueError, match="Unknown topic"):
        service.get_topic("not-a-topic")


def test_core_resources_have_stable_structure(repo_factory: Callable[[], Path]) -> None:
    service = KnowledgeService(repo_factory())

    overview = service.project_overview()
    assert overview["server_properties"]["read_only"] is True
    assert overview["server_properties"]["transport"] == "STDIO"
    assert overview["server_properties"]["network_calls"] is False
    assert service.architecture_map()["layers"]
    security = service.security_model()
    assert "no subprocess or shell execution" in security["knowledge_server_non_capabilities"]


def test_search_is_relevant_deterministic_and_structured(
    repo_factory: Callable[[], Path],
) -> None:
    service = KnowledgeService(repo_factory())

    first = service.search_knowledge("EKS Auto Mode", max_results=5, context_lines=1)
    second = service.search_knowledge("EKS Auto Mode", max_results=5, context_lines=1)

    assert first == second
    assert first["result_count"] >= 1
    assert first["results"][0]["path"] in {
        "README.md",
        "docs/DEPLOYMENT_GUIDE.md",
    }
    assert first["results"] == sorted(
        first["results"],
        key=lambda result: (-result["score"], result["path"].casefold(), result["line"]),
    )
    assert {
        "path",
        "line",
        "score",
        "match",
        "match_truncated",
        "snippet",
        "snippet_start_line",
        "snippet_end_line",
        "snippet_truncated",
    } <= set(first["results"][0])


def test_search_excludes_denied_and_binary_content(repo_factory: Callable[[], Path]) -> None:
    service = KnowledgeService(repo_factory())

    for secret_query in ("fixture-value", "not-a-real-secret", "fixture-token", "binary-suffix"):
        result = service.search_knowledge(secret_query)
        assert result["result_count"] == 0
    safe_documentation = service.search_knowledge("dual-slot credentials")
    assert safe_documentation["results"][0]["path"] == "docs/CREDENTIAL_ROTATION_GUIDE.md"


def test_search_charges_rejected_files_to_scan_budget(
    repo_factory: Callable[[], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = repo_factory()
    (root / "000-binary.txt").write_bytes(b"prefix\x00query-after-nul")
    monkeypatch.setattr(knowledge_module, "MAX_SEARCH_FILES", 1)

    result = KnowledgeService(root).search_knowledge("OpenEMR")
    assert result["searched_file_count"] == 1
    assert result["scan_limited"] is True
    assert result["result_count"] == 0


def test_search_requires_complete_tokens(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    (root / "docs/DIAGRAM.md").write_text("This architecture diagram is current.\n", encoding="utf-8")
    (root / "terraform/iam.tf").write_text('resource "aws_iam_role" "app" {}\n# IAM policy\n', encoding="utf-8")

    result = KnowledgeService(root).search_knowledge("iam")
    assert result["result_count"] >= 1
    assert all(item["path"] != "docs/DIAGRAM.md" for item in result["results"])


@pytest.mark.parametrize(
    ("query", "max_results", "context_lines", "message"),
    [
        ("", 5, 1, "must not be empty"),
        ("x" * 201, 5, 1, "at most 200"),
        ("---", 5, 1, "letter or number"),
        ("openemr", 0, 1, "between 1 and 20"),
        ("openemr", 21, 1, "between 1 and 20"),
        ("openemr", 5, -1, "between 0 and 5"),
        ("openemr", 5, 6, "between 0 and 5"),
    ],
)
def test_search_bounds_and_malformed_inputs(
    repo_factory: Callable[[], Path],
    query: str,
    max_results: int,
    context_lines: int,
    message: str,
) -> None:
    service = KnowledgeService(repo_factory())
    with pytest.raises(ValueError, match=message):
        service.search_knowledge(query, max_results, context_lines)


def test_safe_file_read_and_ranges(repo_factory: Callable[[], Path]) -> None:
    service = KnowledgeService(repo_factory())

    result = service.read_repository_file("docs/DEPLOYMENT_GUIDE.md", 1, 2)
    assert result["path"] == "docs/DEPLOYMENT_GUIDE.md"
    assert result["size_bytes"] == 59
    assert result["start_line"] == 1
    assert result["end_line"] == 2
    assert result["max_lines"] == 2
    assert result["total_lines"] == 3
    assert result["truncated"] is True
    assert result["content"] == "# Deployment\n"
    final = service.read_repository_file("docs/DEPLOYMENT_GUIDE.md", 3, 10)
    assert final["content"] == "Deploy OpenEMR after EKS Auto Mode is ready."
    assert final["truncated"] is False
    assert service.read_repository_file("VERSION")["content"] == "0.1.0"


def test_file_read_bounds_single_line_output(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    (root / "long-line.txt").write_text("x" * 100_000, encoding="utf-8")
    result = KnowledgeService(root).read_repository_file("long-line.txt", 1, 1)

    assert len(result["content"]) <= MAX_READ_CONTENT_CHARS
    assert result["content_truncated"] is True
    assert result["content_limit_chars"] == MAX_READ_CONTENT_CHARS
    assert result["truncated"] is True


@pytest.mark.parametrize(
    ("path", "start", "limit", "message"),
    [
        ("missing.md", 1, 10, "does not exist"),
        ("README.md", 0, 10, "start_line"),
        ("README.md", 99, 10, "exceeds"),
        ("README.md", 1, 0, "max_lines"),
        ("README.md", 1, 251, "max_lines"),
        ("../README.md", 1, 10, "traversal"),
        ("k8s/secrets.yaml", 1, 10, "denied"),
        ("oversized.txt", 1, 10, "exceeds"),
    ],
)
def test_file_read_rejects_invalid_requests(
    repo_factory: Callable[[], Path],
    path: str,
    start: int,
    limit: int,
    message: str,
) -> None:
    service = KnowledgeService(repo_factory())
    with pytest.raises(ValueError, match=message):
        service.read_repository_file(path, start, limit)


def test_dynamic_version_inventory_and_filter(repo_factory: Callable[[], Path]) -> None:
    service = KnowledgeService(repo_factory())

    inventory = service.get_version_inventory()
    assert inventory["source"] == "versions.yaml"
    assert inventory["count"] == 3
    openemr = next(item for item in inventory["items"] if item["component"] == "openemr")
    assert openemr["current"] == "8.2.0"
    assert "k8s/deployment.yaml" in openemr["consumer_paths"]
    assert len(openemr["consumer_paths"]) <= openemr["consumer_limit"] == 12

    filtered = service.get_version_inventory("infrastructure.eks")
    assert filtered["count"] == 1
    assert filtered["items"][0]["component"] == "eks"
    with pytest.raises(ValueError, match="Unknown version"):
        service.get_version_inventory("absent")


def test_version_consumer_matching_rejects_longer_versions(
    repo_factory: Callable[[], Path],
) -> None:
    service = KnowledgeService(repo_factory())

    assert service._version_occurs("v4", "uses: github/codeql-action/upload-sarif@v4")
    assert not service._version_occurs("v4", 'rev: "v4.17.0"')
    assert not service._version_occurs("v7", "Loki v7.0.0")


def test_malformed_version_inventory_is_rejected(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    (root / "versions.yaml").write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(ValueError, match="mapping"):
        KnowledgeService(root).get_version_inventory()


def test_duplicate_version_keys_are_rejected(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    (root / "versions.yaml").write_text(
        'applications:\n  openemr:\n    current: "8.2.0"\n    current: "8.3.0"\n',
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="not valid YAML"):
        KnowledgeService(root).get_version_inventory()


def test_version_inventory_rejects_excessive_entries(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    entries = "".join(f'  package_{index}:\n    current: "1.0.{index}"\n' for index in range(257))
    (root / "versions.yaml").write_text(f"packages:\n{entries}", encoding="utf-8")
    with pytest.raises(ValueError, match="256-entry limit"):
        KnowledgeService(root).get_version_inventory()


def test_version_inventory_rejects_nested_metadata(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    (root / "versions.yaml").write_text(
        'applications:\n  openemr:\n    current: "8.2.0"\n    description:\n      nested: unsupported\n',
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="must be a scalar"):
        KnowledgeService(root).get_version_inventory()


def test_operational_commands_include_explicit_risk_labels(
    repo_factory: Callable[[], Path],
) -> None:
    service = KnowledgeService(repo_factory())

    destroy = service.find_operational_command("delete everything", max_results=3)
    assert destroy["server_executes_commands"] is False
    assert destroy["results"][0]["command"] == "./scripts/destroy.sh"
    assert destroy["results"][0]["risk"] == {
        "level": "destructive",
        "read_only": False,
        "destructive": True,
        "cloud_affecting": True,
        "costly": False,
        "requires_active_context": True,
        "requires_network": True,
    }

    health = service.find_operational_command("deployment health")
    assert health["results"][0]["risk"]["read_only"] is True
    assert health["results"][0]["risk"]["requires_active_context"] is True
    updates = service.find_operational_command("check version updates", 1)
    assert updates["results"][0]["command"] == "./scripts/version-manager.sh check"
    assert updates["results"][0]["risk"]["requires_network"] is True
    status = service.find_operational_command("version status", 1)
    assert status["results"][0]["command"] == "./scripts/version-manager.sh status"
    assert status["results"][0]["risk"]["level"] == "local-writing"
    assert status["results"][0]["risk"]["read_only"] is False
    with pytest.raises(ValueError, match="max_results"):
        service.find_operational_command("deploy", 0)


def test_operations_need_no_aws_credentials_or_network(
    repo_factory: Callable[[], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for name in (
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_PROFILE",
        "KUBECONFIG",
    ):
        monkeypatch.delenv(name, raising=False)

    def fail_socket(*args: object, **kwargs: object) -> socket.socket:
        del args, kwargs
        raise AssertionError("network access is forbidden")

    monkeypatch.setattr(socket, "socket", fail_socket)
    service = KnowledgeService(repo_factory())
    assert service.get_topic("security")["topic"] == "security"
    assert service.search_knowledge("OpenEMR")["result_count"] > 0
    assert service.get_version_inventory("openemr")["count"] == 1


def test_exposed_operations_leave_repository_unchanged(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    before = repository_digest(root)
    service = KnowledgeService(root)

    service.project_overview()
    service.architecture_map()
    service.security_model()
    service.topic_catalog()
    service.get_topic("deployment")
    service.search_knowledge("OpenEMR")
    service.read_repository_file("README.md")
    service.get_version_inventory("openemr")
    service.find_operational_command("backup")
    service.check()

    assert repository_digest(root) == before


def test_check_rejects_missing_curated_sources(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    (root / "docs/TROUBLESHOOTING.md").unlink()

    with pytest.raises(ValueError, match=r"Curated knowledge sources.*TROUBLESHOOTING"):
        KnowledgeService(root).check()
