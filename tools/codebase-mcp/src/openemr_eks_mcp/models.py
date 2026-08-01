"""Stable data models returned by the knowledge service."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class SourceReference:
    """A curated repository source and why it is authoritative."""

    path: str
    role: str
    precedence: int

    def to_dict(self, *, exists: bool) -> dict[str, Any]:
        data = asdict(self)
        data["exists"] = exists
        return data


@dataclass(frozen=True, slots=True)
class Topic:
    """A concise topic entry backed by repository source paths."""

    slug: str
    title: str
    summary: str
    key_points: tuple[str, ...]
    sources: tuple[SourceReference, ...]
    related_topics: tuple[str, ...]
    aliases: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class RiskProfile:
    """Operational properties that callers should assess before running a command."""

    level: str
    read_only: bool
    destructive: bool
    cloud_affecting: bool
    costly: bool
    requires_active_context: bool
    requires_network: bool

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True, slots=True)
class OperationalCommand:
    """A documented project command. The MCP server never executes it."""

    task: str
    command: str
    description: str
    aliases: tuple[str, ...]
    prerequisites: tuple[str, ...]
    source_paths: tuple[str, ...]
    risk: RiskProfile
