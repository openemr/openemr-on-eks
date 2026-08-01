"""Curated knowledge, bounded search, safe reads, and dynamic version inventory."""

from __future__ import annotations

import re
from collections.abc import Mapping
from pathlib import Path
from typing import Any

import yaml
from yaml.constructor import ConstructorError
from yaml.nodes import MappingNode
from yaml.resolver import BaseResolver

from openemr_eks_mcp.catalog import COMMANDS, SOURCE_PRECEDENCE, TOPICS
from openemr_eks_mcp.models import OperationalCommand, SourceReference, Topic
from openemr_eks_mcp.policy import (
    MAX_SEARCH_FILE_BYTES,
    RepositoryPolicy,
    TraversalStats,
)

MAX_QUERY_CHARS = 200
MAX_RESULTS = 20
MAX_CONTEXT_LINES = 5
MAX_READ_LINES = 250
MAX_READ_LINE_CHARS = 4_000
MAX_READ_CONTENT_CHARS = 48_000
MAX_SNIPPET_CHARS = 2_400
MAX_MATCH_CHARS = 600
MAX_SEARCH_FILES = 5_000
MAX_SEARCH_BYTES = 32 * 1024 * 1024
MAX_CONSUMER_FILES = 2_500
MAX_CONSUMER_BYTES = 16 * 1024 * 1024
MAX_CONSUMERS = 12
MAX_VERSION_ENTRIES = 256
MAX_VERSION_NAME_CHARS = 100
MAX_VERSION_VALUE_CHARS = 500

TOKEN_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:/+-]*")
CONSUMER_EXTENSIONS = frozenset(
    {".bats", ".go", ".hcl", ".json", ".mod", ".py", ".sh", ".tf", ".toml", ".yaml", ".yml"}
)

VERSION_CONSUMER_HINTS: dict[str, tuple[str, ...]] = {
    "applications.openemr": (
        "k8s/deployment.yaml",
        "terraform/variables.tf",
        "terraform/terraform.tfvars.example",
    ),
    "applications.fluent_bit": ("k8s/logging.yaml", "k8s/deployment.yaml"),
    "applications.python": (
        "warp/Dockerfile",
        "tools/credential-rotation/Dockerfile",
    ),
    "infrastructure.eks": (
        "terraform/variables.tf",
        "terraform/terraform.tfvars.example",
        ".github/workflows/ci-contract-tests.yml",
    ),
    "infrastructure.terraform": (
        "terraform/main.tf",
        "oidc_provider/main.tf",
        ".github/workflows/ci-contract-tests.yml",
    ),
    "databases.aurora_mysql": ("terraform/rds.tf",),
    "eks_addons.efs_csi_driver": ("terraform/eks.tf",),
    "eks_addons.metrics_server": ("terraform/eks.tf",),
    "python_packages.fastmcp": ("tools/codebase-mcp/pyproject.toml",),
    "python_packages.pyyaml": ("tools/codebase-mcp/pyproject.toml",),
    "python_packages.uv": (
        ".github/workflows/ci-cd-tests.yml",
        "docs/KNOWLEDGE_MCP.md",
    ),
    "monitoring.prometheus_operator": ("monitoring/install-monitoring.sh",),
    "monitoring.loki": ("monitoring/install-monitoring.sh",),
    "monitoring.tempo": ("monitoring/install-monitoring.sh",),
    "monitoring.mimir": ("monitoring/install-monitoring.sh",),
}


class _UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate mapping keys."""


def _construct_unique_mapping(
    loader: _UniqueKeyLoader,
    node: MappingNode,
    deep: bool = False,
) -> dict[Any, Any]:
    loader.flatten_mapping(node)
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as exc:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found an unhashable mapping key",
                key_node.start_mark,
            ) from exc
        if duplicate:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_UniqueKeyLoader.add_constructor(
    BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_unique_mapping,
)


def _require_bounded_int(name: str, value: int, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{name} must be an integer.")
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}.")
    return value


def _require_query(name: str, value: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string.")
    normalized = value.strip()
    if not normalized:
        raise ValueError(f"{name} must not be empty.")
    if len(normalized) > MAX_QUERY_CHARS:
        raise ValueError(f"{name} must be at most {MAX_QUERY_CHARS} characters.")
    if any(ord(character) < 32 for character in normalized):
        raise ValueError(f"{name} must not contain control characters.")
    return normalized


def _normalized_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")


def _truncate(value: str, limit: int) -> tuple[str, bool]:
    if len(value) <= limit:
        return value, False
    if limit <= 1:
        return value[:limit], True
    return f"{value[: limit - 1]}…", True


class KnowledgeService:
    """All server behavior, independent of MCP transport."""

    def __init__(self, repo_root: str | Path) -> None:
        self.policy = RepositoryPolicy(repo_root)
        self.policy.validate_repository()
        self._topic_lookup = self._build_topic_lookup()

    @staticmethod
    def _build_topic_lookup() -> dict[str, Topic]:
        lookup: dict[str, Topic] = {}
        for topic in TOPICS:
            for key in (topic.slug, topic.title, *topic.aliases):
                normalized = _normalized_key(key)
                existing = lookup.get(normalized)
                if existing is not None and existing.slug != topic.slug:
                    raise RuntimeError(f"Duplicate topic alias: {key}")
                lookup[normalized] = topic
        return lookup

    def _source_exists(self, path: str) -> bool:
        try:
            self.policy.approve_file(path)
        except ValueError:
            return False
        return True

    def _source_dict(self, source: SourceReference) -> dict[str, Any]:
        return source.to_dict(exists=self._source_exists(source.path))

    def project_overview(self) -> dict[str, Any]:
        return {
            "name": "OpenEMR on Amazon EKS",
            "purpose": (
                "Production-oriented OpenEMR deployment on Amazon EKS Auto Mode with "
                "encrypted data services, operational automation, and observability."
            ),
            "deployment_model": "Terraform infrastructure plus Kubernetes application manifests",
            "major_components": [
                "EKS Auto Mode managed compute",
                "OpenEMR application workloads",
                "Aurora MySQL",
                "Valkey serverless cache",
                "encrypted EFS shared storage",
                "ALB and WAF ingress",
                "CloudWatch and optional Grafana observability stack",
                "AWS Backup and application-aware disaster recovery",
            ],
            "knowledge_scope": [topic.slug for topic in TOPICS],
            "server_properties": {
                "read_only": True,
                "transport": "STDIO",
                "network_calls": False,
                "command_execution": False,
                "repository_writes": False,
                "cloud_dependency": False,
            },
            "authoritative_sources": [
                {"path": "terraform/", "role": "AWS infrastructure implementation"},
                {"path": "k8s/", "role": "Kubernetes application implementation"},
                {"path": "scripts/", "role": "Operational automation"},
                {"path": "versions.yaml", "role": "Central version inventory"},
                {"path": "docs/", "role": "Focused runbooks and explanations"},
            ],
            "source_precedence": list(SOURCE_PRECEDENCE),
        }

    def architecture_map(self) -> dict[str, Any]:
        sources = (
            SourceReference("terraform/eks.tf", "EKS Auto Mode", 1),
            SourceReference("terraform/vpc.tf", "VPC and subnets", 1),
            SourceReference("terraform/rds.tf", "Aurora", 1),
            SourceReference("terraform/elasticache.tf", "Valkey", 1),
            SourceReference("terraform/efs.tf", "EFS", 1),
            SourceReference("k8s/deployment.yaml", "OpenEMR workloads", 1),
            SourceReference("monitoring/README.md", "Optional observability", 3),
        )
        return {
            "name": "OpenEMR EKS logical architecture",
            "layers": [
                {
                    "name": "edge",
                    "components": ["Application Load Balancer", "WAFv2", "TLS"],
                },
                {
                    "name": "compute",
                    "components": ["EKS Auto Mode", "Bottlerocket nodes", "OpenEMR pods"],
                },
                {
                    "name": "data",
                    "components": ["Aurora MySQL", "Valkey", "EFS", "S3"],
                },
                {
                    "name": "security",
                    "components": [
                        "KMS",
                        "Secrets Manager",
                        "IAM and pod identity",
                        "security groups",
                        "network policies",
                    ],
                },
                {
                    "name": "operations",
                    "components": [
                        "CloudWatch",
                        "CloudTrail",
                        "AWS Backup",
                        "optional Grafana observability",
                    ],
                },
            ],
            "primary_flows": [
                "client -> ALB/WAF -> OpenEMR service -> OpenEMR pods",
                "OpenEMR pods -> Aurora MySQL for relational data",
                "OpenEMR pods -> Valkey for cache and sessions",
                "OpenEMR pods -> EFS for shared sites and document data",
                "logs/metrics/traces -> CloudWatch and optional observability backends",
                "scheduled and on-demand processes -> encrypted backup storage",
            ],
            "management_boundary": (
                "EKS Auto Mode manages core cluster compute, networking, and storage capabilities; "
                "the repository still defines workloads, policies, add-ons, and data services."
            ),
            "authoritative_sources": [self._source_dict(item) for item in sources],
            "source_precedence": list(SOURCE_PRECEDENCE),
        }

    def security_model(self) -> dict[str, Any]:
        sources = (
            SourceReference("terraform/kms.tf", "Encryption configuration", 1),
            SourceReference("terraform/iam.tf", "Identity and access", 1),
            SourceReference("k8s/security.yaml", "Workload hardening", 1),
            SourceReference("k8s/network-policies.yaml", "Network segmentation", 1),
            SourceReference("docs/SECURITY_SCANNING.md", "Scanning policy", 3),
        )
        return {
            "scope": "Project controls and local knowledge-server boundaries",
            "project_controls": [
                "KMS-backed encryption at rest and TLS in transit",
                "least-privilege IAM, pod identity, and Kubernetes RBAC",
                "Secrets Manager rather than committed runtime credentials",
                "security groups, WAF, security contexts, and network policies",
                "CloudTrail, CloudWatch, and flow-log audit paths",
                "multi-scanner CI security validation",
            ],
            "compliance_boundary": (
                "Technical controls support healthcare workloads but do not by themselves provide "
                "HIPAA compliance; an AWS BAA and organizational controls remain required."
            ),
            "knowledge_server_controls": [
                "canonical repository-root containment",
                "absolute-path and parent-traversal rejection",
                "external symlink-target and symlink-directory rejection",
                "no-follow file opens with device/inode identity verification",
                "denied secret, state, credential, output, cache, and artifact locations",
                "recognized credential-content and literal-assignment rejection",
                "UTF-8 text allowlist with binary and file-size rejection",
                "bounded traversal, queries, results, context, lines, files, bytes, and snippets",
                "deterministic lexical traversal and ranking",
            ],
            "knowledge_server_non_capabilities": [
                "no file writes",
                "no subprocess or shell execution",
                "no Git operations",
                "no network calls",
                "no AWS or Kubernetes API calls",
                "no HTTP transport",
            ],
            "authoritative_sources": [self._source_dict(item) for item in sources],
        }

    def topic_catalog(self) -> dict[str, Any]:
        return {
            "count": len(TOPICS),
            "topics": [
                {
                    "topic": topic.slug,
                    "title": topic.title,
                    "summary": topic.summary,
                    "aliases": list(topic.aliases),
                    "related_topics": list(topic.related_topics),
                }
                for topic in TOPICS
            ],
            "source_precedence": list(SOURCE_PRECEDENCE),
        }

    def get_topic(self, topic: str) -> dict[str, Any]:
        requested = _require_query("topic", topic)
        entry = self._topic_lookup.get(_normalized_key(requested))
        if entry is None:
            available = ", ".join(item.slug for item in TOPICS)
            raise ValueError(f"Unknown topic. Available topics: {available}.")
        return {
            "topic": entry.slug,
            "title": entry.title,
            "summary": entry.summary,
            "key_points": list(entry.key_points),
            "authoritative_sources": [self._source_dict(item) for item in entry.sources],
            "related_topics": list(entry.related_topics),
            "aliases": list(entry.aliases),
            "source_precedence": list(SOURCE_PRECEDENCE),
        }

    @staticmethod
    def _search_tokens(query: str) -> tuple[str, ...]:
        tokens = tuple(dict.fromkeys(token.casefold() for token in TOKEN_PATTERN.findall(query)))
        if not tokens:
            raise ValueError("query must contain at least one letter or number.")
        return tokens

    @staticmethod
    def _line_score(
        *,
        line: str,
        path: str,
        phrase_pattern: re.Pattern[str],
        tokens: tuple[str, ...],
    ) -> int:
        lowered = line.casefold()
        phrase_count = len(phrase_pattern.findall(lowered))
        line_tokens = {token.casefold() for token in TOKEN_PATTERN.findall(line)}
        token_hits = sum(token in line_tokens for token in tokens)
        if phrase_count == 0 and token_hits == 0:
            return 0
        score = phrase_count * 120 + token_hits * 24
        if token_hits == len(tokens):
            score += 36
        if line.lstrip().startswith(("#", "resource ", "module ", "def ", "class ")):
            score += 8
        path_lower = path.casefold()
        score += sum(4 for token in tokens if token in path_lower)
        if path_lower.startswith("docs/"):
            score += 3
        return score

    @staticmethod
    def _candidate_sort_key(candidate: Mapping[str, Any]) -> tuple[int, str, int]:
        return (
            -int(candidate["score"]),
            str(candidate["path"]).casefold(),
            int(candidate["line"]),
        )

    @staticmethod
    def _make_snippet(
        lines: list[str],
        index: int,
        context_lines: int,
    ) -> tuple[str, int, int, bool]:
        start = max(0, index - context_lines)
        end = min(len(lines), index + context_lines + 1)
        rendered_lines: list[str] = []
        line_was_truncated = False
        for line_index in range(start, end):
            rendered, truncated = _truncate(lines[line_index], MAX_MATCH_CHARS)
            line_was_truncated = line_was_truncated or truncated
            rendered_lines.append(f"{line_index + 1}: {rendered}")
        snippet, snippet_was_truncated = _truncate(
            "\n".join(rendered_lines),
            MAX_SNIPPET_CHARS,
        )
        return snippet, start + 1, end, line_was_truncated or snippet_was_truncated

    def search_knowledge(
        self,
        query: str,
        max_results: int = 10,
        context_lines: int = 2,
    ) -> dict[str, Any]:
        normalized = _require_query("query", query)
        result_limit = _require_bounded_int("max_results", max_results, 1, MAX_RESULTS)
        context_limit = _require_bounded_int(
            "context_lines",
            context_lines,
            0,
            MAX_CONTEXT_LINES,
        )
        phrase = normalized.casefold()
        phrase_pattern = re.compile(rf"(?<![A-Za-z0-9]){re.escape(phrase)}(?![A-Za-z0-9])")
        tokens = self._search_tokens(normalized)
        candidates: list[dict[str, Any]] = []
        total_matches = 0
        scanned_files = 0
        scanned_bytes = 0
        scan_limited = False
        traversal = TraversalStats()

        for approved in self.policy.iter_approved_files(stats=traversal):
            if scanned_files >= MAX_SEARCH_FILES or scanned_bytes + approved.size_bytes > MAX_SEARCH_BYTES:
                scan_limited = True
                break
            scanned_files += 1
            scanned_bytes += approved.size_bytes
            try:
                _, text = self.policy.read_text(
                    approved.relative_path,
                    max_size=MAX_SEARCH_FILE_BYTES,
                )
            except ValueError:
                continue
            lines = text.splitlines()
            for index, line in enumerate(lines):
                score = self._line_score(
                    line=line,
                    path=approved.relative_path,
                    phrase_pattern=phrase_pattern,
                    tokens=tokens,
                )
                if score <= 0:
                    continue
                total_matches += 1
                snippet, snippet_start, snippet_end, snippet_truncated = self._make_snippet(
                    lines,
                    index,
                    context_limit,
                )
                matched_line, match_truncated = _truncate(line, MAX_MATCH_CHARS)
                candidates.append(
                    {
                        "path": approved.relative_path,
                        "line": index + 1,
                        "score": score,
                        "match": matched_line,
                        "match_truncated": match_truncated,
                        "snippet": snippet,
                        "snippet_start_line": snippet_start,
                        "snippet_end_line": snippet_end,
                        "snippet_truncated": snippet_truncated,
                    }
                )
                candidates.sort(key=self._candidate_sort_key)
                if len(candidates) > result_limit:
                    candidates.pop()

        return {
            "query": normalized,
            "result_count": len(candidates),
            "total_matches": total_matches,
            "max_results": result_limit,
            "context_lines": context_limit,
            "searched_file_count": scanned_files,
            "searched_bytes": scanned_bytes,
            "traversal_entries": traversal.examined_entries,
            "traversal_limited": traversal.limited,
            "scan_limited": scan_limited or traversal.limited,
            "truncated": scan_limited or traversal.limited or total_matches > len(candidates),
            "results": candidates,
        }

    def read_repository_file(
        self,
        path: str,
        start_line: int = 1,
        max_lines: int = 100,
    ) -> dict[str, Any]:
        start = _require_bounded_int("start_line", start_line, 1, 2_147_483_647)
        line_limit = _require_bounded_int("max_lines", max_lines, 1, MAX_READ_LINES)
        approved, text = self.policy.read_text(path)
        lines = text.splitlines()
        if lines and start > len(lines):
            raise ValueError("start_line exceeds the file length.")
        if not lines and start != 1:
            raise ValueError("start_line exceeds the file length.")
        selected = lines[start - 1 : start - 1 + line_limit]
        rendered_lines: list[str] = []
        rendered_chars = 0
        content_truncated = False
        for line in selected:
            rendered_line, line_truncated = _truncate(line, MAX_READ_LINE_CHARS)
            content_truncated = content_truncated or line_truncated
            separator_chars = 1 if rendered_lines else 0
            remaining = MAX_READ_CONTENT_CHARS - rendered_chars - separator_chars
            if remaining <= 0:
                content_truncated = True
                break
            if len(rendered_line) > remaining:
                rendered_line, _ = _truncate(rendered_line, remaining)
                content_truncated = True
            rendered_lines.append(rendered_line)
            rendered_chars += separator_chars + len(rendered_line)
            if rendered_chars >= MAX_READ_CONTENT_CHARS:
                content_truncated = True
                break
        end_line = start + len(rendered_lines) - 1 if rendered_lines else 0
        return {
            "path": approved.relative_path,
            "size_bytes": approved.size_bytes,
            "start_line": start,
            "end_line": end_line,
            "max_lines": line_limit,
            "total_lines": len(lines),
            "lines_returned": len(rendered_lines),
            "truncated": end_line < len(lines) or content_truncated,
            "content_truncated": content_truncated,
            "content_limit_chars": MAX_READ_CONTENT_CHARS,
            "content": "\n".join(rendered_lines),
        }

    @staticmethod
    def _version_metadata(raw: Mapping[str, Any]) -> dict[str, Any]:
        keys = (
            "description",
            "registry",
            "source",
            "chart",
            "repository",
            "module_path",
            "package_manager",
            "min_version",
            "requires_aws_cli",
            "notify_on_update",
            "update_policy",
            "migration_target_repository",
            "migration_notes_url",
            "sha",
            "kind",
            "minimum_go_version",
            "compatibility_source",
        )
        metadata: dict[str, Any] = {}
        for key in keys:
            if key not in raw:
                continue
            value = raw[key]
            if value is not None and not isinstance(value, (str, int, float, bool)):
                raise ValueError(f"versions.yaml metadata field {key!r} must be a scalar.")
            if isinstance(value, str) and len(value) > MAX_VERSION_VALUE_CHARS:
                raise ValueError(f"versions.yaml metadata field {key!r} is too long.")
            metadata[key] = value
        return metadata

    def _load_version_items(self) -> list[dict[str, Any]]:
        _, text = self.policy.read_text("versions.yaml")
        loader = _UniqueKeyLoader(text)
        try:
            loaded: Any = loader.get_single_data()
        except yaml.YAMLError as exc:
            raise ValueError("versions.yaml is not valid YAML.") from exc
        finally:
            loader.dispose()  # type: ignore[no-untyped-call]
        if not isinstance(loaded, Mapping):
            raise ValueError("versions.yaml must contain a mapping.")

        items: list[dict[str, Any]] = []
        for category_raw, members_raw in loaded.items():
            if not isinstance(category_raw, str) or not isinstance(members_raw, Mapping):
                continue
            if len(category_raw) > MAX_VERSION_NAME_CHARS:
                raise ValueError("A versions.yaml category name is too long.")
            for component_raw, details_raw in members_raw.items():
                if (
                    not isinstance(component_raw, str)
                    or not isinstance(details_raw, Mapping)
                    or "current" not in details_raw
                ):
                    continue
                if len(component_raw) > MAX_VERSION_NAME_CHARS:
                    raise ValueError("A versions.yaml component name is too long.")
                current = details_raw["current"]
                if isinstance(current, bool) or not isinstance(current, (str, int, float)):
                    raise ValueError("A versions.yaml current value is not a supported scalar.")
                current_text = str(current)
                if len(current_text) > MAX_VERSION_VALUE_CHARS:
                    raise ValueError("A versions.yaml current value is too long.")
                if len(items) >= MAX_VERSION_ENTRIES:
                    raise ValueError(f"versions.yaml exceeds the {MAX_VERSION_ENTRIES}-entry limit.")
                items.append(
                    {
                        "category": category_raw,
                        "component": component_raw,
                        "current": current_text,
                        "metadata": self._version_metadata(details_raw),
                    }
                )
        if not items:
            raise ValueError("versions.yaml does not contain any version entries.")
        return sorted(
            items,
            key=lambda item: (
                str(item["category"]).casefold(),
                str(item["component"]).casefold(),
            ),
        )

    def _select_version_items(
        self,
        items: list[dict[str, Any]],
        component: str | None,
    ) -> tuple[list[dict[str, Any]], str | None]:
        if component is None:
            return items, None
        requested = _require_query("component", component)
        normalized = _normalized_key(requested)
        selected = [
            item
            for item in items
            if normalized
            in {
                _normalized_key(str(item["category"])),
                _normalized_key(str(item["component"])),
                _normalized_key(f"{item['category']}.{item['component']}"),
            }
        ]
        if not selected:
            raise ValueError("Unknown version component or category.")
        return selected, requested

    def _add_hint_consumers(
        self,
        item: Mapping[str, Any],
        paths: set[str],
    ) -> None:
        key = f"{item['category']}.{item['component']}"
        for path in VERSION_CONSUMER_HINTS.get(key, ()):
            if len(paths) >= MAX_CONSUMERS:
                break
            if self._source_exists(path):
                paths.add(path)

    @staticmethod
    def _version_occurs(current: str, text: str) -> bool:
        """Match a complete version token without treating longer versions as consumers."""

        pattern = re.compile(rf"(?<![0-9A-Za-z.]){re.escape(current)}(?![0-9A-Za-z.])")
        return pattern.search(text) is not None

    def _attach_version_consumers(
        self,
        items: list[dict[str, Any]],
    ) -> dict[str, Any]:
        consumers: dict[tuple[str, str], set[str]] = {}
        for item in items:
            key = (str(item["category"]), str(item["component"]))
            consumers[key] = set()
            self._add_hint_consumers(item, consumers[key])

        scanned_files = 0
        scanned_bytes = 0
        scan_limited = False
        traversal = TraversalStats()
        for approved in self.policy.iter_approved_files(stats=traversal):
            if approved.relative_path == "versions.yaml":
                continue
            if approved.relative_path.startswith("docs/"):
                continue
            if Path(approved.relative_path).suffix.casefold() not in CONSUMER_EXTENSIONS:
                continue
            if scanned_files >= MAX_CONSUMER_FILES or (scanned_bytes + approved.size_bytes > MAX_CONSUMER_BYTES):
                scan_limited = True
                break
            scanned_files += 1
            scanned_bytes += approved.size_bytes
            try:
                _, text = self.policy.read_text(
                    approved.relative_path,
                    max_size=MAX_SEARCH_FILE_BYTES,
                )
            except ValueError:
                continue
            for item in items:
                key = (str(item["category"]), str(item["component"]))
                item_consumers = consumers[key]
                if len(item_consumers) >= MAX_CONSUMERS:
                    continue
                if self._version_occurs(str(item["current"]), text):
                    item_consumers.add(approved.relative_path)

        for item in items:
            key = (str(item["category"]), str(item["component"]))
            paths = sorted(consumers[key], key=lambda value: (value.casefold(), value))
            item["consumer_paths"] = paths[:MAX_CONSUMERS]
            item["consumer_path_count"] = len(paths[:MAX_CONSUMERS])
            item["consumer_limit"] = MAX_CONSUMERS

        return {
            "searched_file_count": scanned_files,
            "searched_bytes": scanned_bytes,
            "traversal_entries": traversal.examined_entries,
            "traversal_limited": traversal.limited,
            "scan_limited": scan_limited or traversal.limited,
        }

    def get_version_inventory(self, component: str | None = None) -> dict[str, Any]:
        items = self._load_version_items()
        selected, requested = self._select_version_items(items, component)
        scan = self._attach_version_consumers(selected)
        return {
            "source": "versions.yaml",
            "component_filter": requested,
            "count": len(selected),
            "items": selected,
            "consumer_scan": scan,
            "source_precedence": [
                "versions.yaml current values",
                "consumer source and configuration paths",
                "documentation references",
            ],
        }

    @staticmethod
    def _command_score(
        command: OperationalCommand,
        phrase: str,
        tokens: tuple[str, ...],
    ) -> int:
        fields = " ".join(
            (
                command.task,
                command.command,
                command.description,
                *command.aliases,
            )
        ).casefold()
        phrase_count = fields.count(phrase)
        hits = sum(token in fields for token in tokens)
        if phrase_count == 0 and hits == 0:
            return 0
        score = phrase_count * 100 + hits * 20
        if hits == len(tokens):
            score += 40
        if phrase in command.task.casefold():
            score += 30
        return score

    def find_operational_command(
        self,
        task: str,
        max_results: int = 5,
    ) -> dict[str, Any]:
        normalized = _require_query("task", task)
        result_limit = _require_bounded_int("max_results", max_results, 1, MAX_RESULTS)
        phrase = normalized.casefold()
        tokens = self._search_tokens(normalized)
        matches: list[tuple[int, OperationalCommand]] = []
        for command in COMMANDS:
            score = self._command_score(command, phrase, tokens)
            if score > 0:
                matches.append((score, command))
        matches.sort(key=lambda pair: (-pair[0], pair[1].task.casefold(), pair[1].command))
        selected = matches[:result_limit]
        return {
            "task": normalized,
            "result_count": len(selected),
            "max_results": result_limit,
            "server_executes_commands": False,
            "warning": (
                "These are explanations, not approvals. Verify prerequisites and active contexts "
                "before running any command outside this server."
            ),
            "results": [
                {
                    "task": command.task,
                    "command": command.command,
                    "description": command.description,
                    "score": score,
                    "prerequisites": list(command.prerequisites),
                    "source_paths": [
                        {"path": path, "exists": self._source_exists(path)} for path in command.source_paths
                    ],
                    "risk": command.risk.to_dict(),
                }
                for score, command in selected
            ],
        }

    def check(self) -> dict[str, Any]:
        inventory = self.get_version_inventory()
        source_paths = {source.path for topic in TOPICS for source in topic.sources} | {
            path for command in COMMANDS for path in command.source_paths
        }
        missing_sources = sorted(
            (path for path in source_paths if not self._source_exists(path)),
            key=lambda path: (path.casefold(), path),
        )
        if missing_sources:
            preview = ", ".join(missing_sources[:10])
            suffix = "" if len(missing_sources) <= 10 else f" (+{len(missing_sources) - 10} more)"
            raise ValueError(f"Curated knowledge sources are missing or denied: {preview}{suffix}.")
        return {
            "ok": True,
            "repository_root": str(self.policy.root),
            "topic_count": len(TOPICS),
            "version_entry_count": inventory["count"],
            "read_only": True,
            "transport": "STDIO",
        }
