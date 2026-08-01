"""Repository containment and text-access policy.

This module is intentionally limited to local, read-only filesystem operations.
It never invokes Git, a shell, a network client, or a cloud SDK.
"""

from __future__ import annotations

import json
import os
import re
import stat
from collections.abc import Iterator
from dataclasses import dataclass
from itertools import islice
from pathlib import Path, PureWindowsPath

import yaml

MAX_FILE_BYTES = 512 * 1024
MAX_SEARCH_FILE_BYTES = 256 * 1024
MAX_PATH_CHARS = 4_096
MAX_DIRECTORY_ENTRIES = 5_000
MAX_TRAVERSAL_ENTRIES = 20_000

DENIED_DIRECTORY_NAMES = frozenset(
    {
        ".aws",
        ".backup",
        ".backups",
        ".cache",
        ".coverage",
        ".external_modules",
        ".git",
        ".hg",
        ".hypothesis",
        ".kube",
        ".mypy_cache",
        ".nox",
        ".output",
        ".outputs",
        ".pytest_cache",
        ".ruff_cache",
        ".svn",
        ".terraform",
        ".terragrunt-cache",
        ".tox",
        ".venv",
        "__pycache__",
        "artifacts",
        "backup",
        "backup-output",
        "backup_output",
        "backups",
        "build",
        "cache",
        "caches",
        "coverage",
        "credentials",
        "dist",
        "env",
        "generated",
        "generated-output",
        "htmlcov",
        "node_modules",
        "output",
        "outputs",
        "reports",
        "secrets",
        "site",
        "target",
        "temp",
        "test-artifacts",
        "test-results",
        "tmp",
        "tool-cache",
        "tooling-cache",
        "venv",
        "vendor",
    }
)

ALLOWED_EXTENSIONS = frozenset(
    {
        ".bash",
        ".bats",
        ".cfg",
        ".conf",
        ".css",
        ".go",
        ".hcl",
        ".html",
        ".ini",
        ".js",
        ".json",
        ".jsx",
        ".lock",
        ".md",
        ".mod",
        ".properties",
        ".ps1",
        ".py",
        ".rst",
        ".sh",
        ".sum",
        ".tf",
        ".toml",
        ".ts",
        ".tsx",
        ".txt",
        ".xml",
        ".yaml",
        ".yml",
        ".zsh",
    }
)

ALLOWED_EXTENSIONLESS_NAMES = frozenset(
    {
        ".dockerignore",
        ".gitignore",
        ".markdownlintignore",
        ".shellcheckrc",
        "dockerfile",
        "license",
        "makefile",
        "notice",
        "version",
    }
)

DENIED_KEY_OR_CERT_EXTENSIONS = frozenset(
    {
        ".cer",
        ".crt",
        ".der",
        ".jks",
        ".key",
        ".keystore",
        ".p12",
        ".pem",
        ".pfx",
        ".pkcs12",
    }
)

DENIED_REPORT_EXTENSIONS = frozenset({".lcov", ".log", ".out", ".sarif"})

DENIED_EXACT_FILENAMES = frozenset(
    {
        ".env",
        ".envrc",
        ".netrc",
        ".npmrc",
        ".pypirc",
        "aws_credentials",
        "credentials",
        "credentials.json",
        "credentials.yaml",
        "credentials.yml",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "id_rsa",
        "kubeconfig",
        "secrets.json",
        "secrets.yaml",
        "secrets.yml",
        "service-account-key.json",
        "terraform.tfstate",
        "token",
        "token.json",
        "tokens.json",
    }
)

DENIED_SECRET_CONTENT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "AWS credential",
        re.compile(r"\b(?:AIDA|AIPA|AKIA|ANPA|ANVA|AROA|ASIA)[A-Z0-9]{16}\b"),
    ),
    (
        "AWS credential",
        re.compile(r"""(?im)\baws_secret_access_key\b\s*[:=]\s*["']?[A-Za-z0-9/+=]{40}(?:["']|\s|$)"""),
    ),
    (
        "GitHub token",
        re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    ),
    (
        "Slack token",
        re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    ),
    (
        "Google API key",
        re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    ),
)

SENSITIVE_ASSIGNMENT_PATTERN = re.compile(
    r"""(?im)(?:^|[,{]\s*)\s*["']?[A-Za-z0-9_-]*(?:password|passwd|token|api[_-]?key|access[_-]?key|"""
    r"""secret[_-]?access[_-]?key|client[_-]?secret|private[_-]?key)["']?\s*[:=]\s*"""
    r"""(?:["'](?P<quoted>[^"'\r\n]{8,})["']|(?P<bare>[A-Za-z0-9/+_=.@!#$%^&*-]{8,}))"""
    r"""\s*(?:[#;,\]}]|$)"""
)

SAFE_CREDENTIAL_VALUE_PREFIXES = (
    "changeme",
    "dummy",
    "example",
    "fixture",
    "not-a-real",
    "placeholder",
    "redacted",
    "replace",
    "test-only",
    "your-",
    "your_",
)


@dataclass(frozen=True, slots=True)
class ApprovedFile:
    """A canonical, approved repository text file."""

    absolute_path: Path
    relative_path: str
    size_bytes: int
    device: int
    inode: int
    link_count: int


@dataclass(slots=True)
class TraversalStats:
    """Bounded traversal diagnostics returned to search callers."""

    examined_entries: int = 0
    skipped_oversized_directories: int = 0
    limited: bool = False


class RepositoryPolicy:
    """Enforce containment, exclusions, type allowlists, and size limits."""

    def __init__(self, root: str | Path) -> None:
        candidate = Path(root).expanduser()
        try:
            resolved = candidate.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise ValueError("Repository root does not exist or cannot be resolved.") from exc
        if not resolved.is_dir():
            raise ValueError("Repository root must be a directory.")
        self.root = resolved

    def validate_repository(self) -> None:
        """Validate inexpensive repository identity markers."""

        versions = self.root / "versions.yaml"
        if not versions.is_file():
            raise ValueError("Repository root must contain versions.yaml.")
        if not any(marker.exists() for marker in (self.root / "README.md", self.root / "terraform", self.root / "k8s")):
            raise ValueError("Repository root does not contain expected project markers.")
        self.read_text("versions.yaml")

    @staticmethod
    def _is_denied_directory_path(relative: Path) -> bool:
        safe_source_directories = {"scripts/openemr_dr/backup"}
        secret_terms = {"credential", "credentials", "secret", "secrets", "token", "tokens"}
        safe_context = {"example", "guide", "policy", "rotation", "schema", "test", "tests"}
        prefix_parts: list[str] = []
        for part in relative.parts:
            prefix_parts.append(part)
            lowered = part.casefold()
            prefix = Path(*prefix_parts).as_posix().casefold()
            if prefix in safe_source_directories:
                continue
            if lowered in DENIED_DIRECTORY_NAMES:
                return True
            tokens = {token for token in re.split(r"[-_.]+", lowered) if token}
            if tokens & secret_terms and not tokens & safe_context:
                return True
        return False

    @staticmethod
    def _looks_like_example(name: str) -> bool:
        lowered = name.casefold()
        return (
            ".example." in lowered
            or ".sample." in lowered
            or ".template." in lowered
            or lowered.endswith((".example", ".sample", ".template"))
        )

    @classmethod
    def _is_secret_like_name(cls, relative: Path) -> bool:
        name = relative.name.casefold()
        suffix = relative.suffix.casefold()
        suffixes = {item.casefold() for item in relative.suffixes}
        posix = relative.as_posix().casefold()
        example = cls._looks_like_example(name)
        name_tokens = frozenset(part for part in re.split(r"[-_.]+", name) if part)

        if posix == "k8s/secrets.yaml":
            return True
        if "kubeconfig" in name:
            return True
        if suffixes & (DENIED_KEY_OR_CERT_EXTENSIONS | DENIED_REPORT_EXTENSIONS):
            return True
        if name in DENIED_EXACT_FILENAMES:
            return True
        if name in {"coverage.xml", ".coverage"} or name.startswith(".coverage."):
            return True
        if name.endswith(".tfstate") or ".tfstate." in name:
            return True
        if (name.endswith(".tfvars") or ".tfvars." in name) and not example:
            return True
        if (name.startswith(".env") or name.endswith(".env") or ".env." in name) and not example:
            return True
        if "report" in name_tokens and suffix in {".html", ".json", ".txt", ".xml", ".yaml", ".yml"} and not example:
            return True
        secret_terms = {"credential", "credentials", "secret", "secrets", "token", "tokens"}
        safe_context = {
            "cronjob",
            "discovery",
            "example",
            "guide",
            "job",
            "manager",
            "policy",
            "rbac",
            "rotation",
            "schema",
            "test",
            "tests",
        }
        if (
            suffix
            in {
                ".bash",
                ".conf",
                ".ini",
                ".json",
                ".properties",
                ".ps1",
                ".py",
                ".sh",
                ".tf",
                ".toml",
                ".txt",
                ".yaml",
                ".yml",
                ".zsh",
            }
            and name_tokens & secret_terms
            and not name_tokens & safe_context
            and not example
        ):
            return True
        return not example and (
            name.startswith(("credential.", "credentials.", "secret.", "secrets.", "token.", "tokens."))
            or name.endswith((".credentials", ".secret", ".secrets", ".token", ".tokens"))
        )

    @classmethod
    def _has_allowed_text_name(cls, relative: Path) -> bool:
        name = relative.name.casefold()
        if name.endswith((".tfvars.example", ".tfvars.sample", ".tfvars.template")):
            return True
        if relative.suffix.casefold() in ALLOWED_EXTENSIONS:
            return True
        if cls._looks_like_example(name):
            wrapped_name = Path(relative.stem)
            return (
                wrapped_name.suffix.casefold() in ALLOWED_EXTENSIONS
                or wrapped_name.name.casefold() in ALLOWED_EXTENSIONLESS_NAMES
            )
        return name in ALLOWED_EXTENSIONLESS_NAMES

    @staticmethod
    def _contains_private_jwk(text: str) -> bool:
        """Detect private JSON Web Keys without returning parsed secret values."""

        try:
            loaded = json.loads(text)
        except (json.JSONDecodeError, RecursionError):
            return False

        pending: list[tuple[object, int]] = [(loaded, 0)]
        examined = 0
        while pending:
            value, depth = pending.pop()
            examined += 1
            if examined > 10_000 or depth > 32:
                return True
            if isinstance(value, dict):
                keys = {str(key).casefold() for key in value}
                if "kty" in keys and "d" in keys:
                    return True
                pending.extend((item, depth + 1) for item in value.values())
            elif isinstance(value, list):
                pending.extend((item, depth + 1) for item in value)
        return False

    @staticmethod
    def _looks_like_kubeconfig(text: str) -> bool:
        """Recognize renamed YAML or JSON kubeconfig files by structural keys."""

        keys = {
            match.casefold()
            for match in re.findall(
                r"""(?im)(?:^|[,{]\s*)["']?"""
                r"""(apiVersion|clusters|contexts|current-context|kind|users)["']?\s*:""",
                text,
            )
        }
        return {"clusters", "contexts", "users"} <= keys and (
            "current-context" in keys
            or re.search(r"""(?im)["']?kind["']?\s*:\s*["']?Config["']?(?:\s*[,}]|\s*$)""", text) is not None
        )

    @staticmethod
    def _contains_kubernetes_secret(text: str) -> bool:
        """Detect a Kubernetes Secret even after a benign filename rename."""

        if re.search(r"""(?im)["']?kind["']?\s*:\s*["']?Secret["']?""", text) is None:
            return False
        try:
            for document in yaml.safe_load_all(text):
                if isinstance(document, dict) and str(document.get("kind", "")).casefold() == "secret":
                    return True
        except (RecursionError, yaml.YAMLError):
            return False
        return False

    @classmethod
    def _reject_sensitive_content(cls, approved: ApprovedFile, text: str) -> None:
        if "-----BEGIN " in text and "PRIVATE KEY-----" in text:
            raise ValueError("Files containing private key material are denied.")
        for description, pattern in DENIED_SECRET_CONTENT_PATTERNS:
            if pattern.search(text):
                raise ValueError(f"Files containing {description} material are denied.")
        for match in SENSITIVE_ASSIGNMENT_PATTERN.finditer(text):
            value = (match.group("quoted") or match.group("bare")).strip().casefold()
            if value.startswith(SAFE_CREDENTIAL_VALUE_PREFIXES) or set(value) <= {"*", "x"}:
                continue
            raise ValueError("Files containing a literal credential assignment are denied.")

        if cls._looks_like_kubeconfig(text):
            raise ValueError("Files containing kubeconfig material are denied.")
        if cls._contains_private_jwk(text):
            raise ValueError("Files containing private JSON Web Key material are denied.")
        if cls._contains_kubernetes_secret(text):
            raise ValueError("Files containing Kubernetes Secret material are denied.")

    @staticmethod
    def _validate_user_path_text(path: str) -> Path:
        if not isinstance(path, str) or not path:
            raise ValueError("path must be a non-empty repository-relative string.")
        if len(path) > MAX_PATH_CHARS:
            raise ValueError(f"path must be at most {MAX_PATH_CHARS} characters.")
        if "\x00" in path:
            raise ValueError("path contains an invalid character.")
        windows_path = PureWindowsPath(path)
        native_path = Path(path)
        if native_path.is_absolute() or windows_path.is_absolute() or windows_path.drive:
            raise ValueError("Absolute paths are not allowed.")
        normalized_parts = path.replace("\\", "/").split("/")
        if any(part == ".." for part in normalized_parts):
            raise ValueError("Parent-directory traversal is not allowed.")
        if any(part == "" for part in normalized_parts):
            raise ValueError("path contains an empty component.")
        return native_path

    def _reject_denied_parts(self, relative: Path) -> None:
        if self._is_denied_directory_path(Path(*relative.parts[:-1])):
            raise ValueError("Access to this repository directory is denied.")

    def _reject_symlink_directories(self, relative: Path) -> None:
        current = self.root
        for part in relative.parts[:-1]:
            current = current / part
            try:
                if current.is_symlink():
                    raise ValueError("Paths through symbolic-link directories are not allowed.")
            except OSError as exc:
                raise ValueError("Repository path cannot be safely inspected.") from exc

    def approve_file(self, path: str, *, max_size: int = MAX_FILE_BYTES) -> ApprovedFile:
        """Resolve and approve one repository-relative text file."""

        if not 1 <= max_size <= MAX_FILE_BYTES:
            raise ValueError(f"max_size must be between 1 and {MAX_FILE_BYTES} bytes.")
        relative = self._validate_user_path_text(path)
        self._reject_denied_parts(relative)
        if self._is_secret_like_name(relative):
            raise ValueError("Access to this secret-like repository file is denied.")
        if not self._has_allowed_text_name(relative):
            raise ValueError("File type is not in the repository text allowlist.")
        self._reject_symlink_directories(relative)

        candidate = self.root / relative
        try:
            if candidate.is_symlink():
                raise ValueError("Symbolic-link files are denied.")
        except OSError as exc:
            raise ValueError("Repository path cannot be safely inspected.") from exc
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError as exc:
            raise ValueError("Repository file does not exist.") from exc
        except (OSError, RuntimeError) as exc:
            raise ValueError("Repository file cannot be safely resolved.") from exc

        try:
            canonical_relative = resolved.relative_to(self.root)
        except ValueError as exc:
            raise ValueError("Path resolves outside the repository root.") from exc
        self._reject_denied_parts(canonical_relative)
        if self._is_secret_like_name(canonical_relative):
            raise ValueError("Access to this secret-like repository file is denied.")
        if not self._has_allowed_text_name(canonical_relative):
            raise ValueError("File type is not in the repository text allowlist.")
        try:
            metadata = resolved.stat()
        except OSError as exc:
            raise ValueError("Repository file metadata cannot be read.") from exc
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("Repository path is not a regular file.")
        if metadata.st_nlink > 1:
            raise ValueError("Multiply linked repository files are denied.")
        if metadata.st_size > max_size:
            raise ValueError(f"Repository file exceeds the {max_size}-byte limit.")
        return ApprovedFile(
            absolute_path=resolved,
            relative_path=relative.as_posix(),
            size_bytes=metadata.st_size,
            device=metadata.st_dev,
            inode=metadata.st_ino,
            link_count=metadata.st_nlink,
        )

    def read_text(
        self,
        path: str,
        *,
        max_size: int = MAX_FILE_BYTES,
    ) -> tuple[ApprovedFile, str]:
        """Read one approved UTF-8 file after all path and size checks."""

        approved = self.approve_file(path, max_size=max_size)
        flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(approved.absolute_path, flags)
            with os.fdopen(descriptor, "rb") as stream:
                opened = os.fstat(stream.fileno())
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or opened.st_dev != approved.device
                    or opened.st_ino != approved.inode
                    or opened.st_nlink != approved.link_count
                    or opened.st_nlink > 1
                ):
                    raise ValueError("Repository file changed during security validation.")
                data = stream.read(max_size + 1)
        except ValueError:
            raise
        except OSError as exc:
            raise ValueError("Repository file could not be read.") from exc
        if len(data) > max_size:
            raise ValueError(f"Repository file exceeds the {max_size}-byte limit.")
        if b"\x00" in data:
            raise ValueError("Binary files are not allowed.")
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError as exc:
            raise ValueError("Repository file is not valid UTF-8 text.") from exc
        self._reject_sensitive_content(approved, text)
        return approved, text

    def iter_approved_files(
        self,
        *,
        stats: TraversalStats | None = None,
    ) -> Iterator[ApprovedFile]:
        """Yield approved regular files in deterministic path order.

        Symbolic links are never followed or explicitly readable.
        """

        traversal = stats if stats is not None else TraversalStats()
        pending: list[tuple[Path, int]] = [(self.root, 0)]
        while pending:
            if traversal.examined_entries >= MAX_TRAVERSAL_ENTRIES:
                traversal.limited = True
                return
            entry, depth = pending.pop()
            traversal.examined_entries += 1
            if depth > 64:
                traversal.limited = True
                continue
            try:
                if entry != self.root:
                    relative = entry.relative_to(self.root)
                    if entry.is_symlink():
                        continue
                    if entry.is_file():
                        try:
                            approved = self.approve_file(relative.as_posix())
                        except ValueError:
                            continue
                        yield approved
                        continue
                    if not entry.is_dir() or self._is_denied_directory_path(relative):
                        continue
                children = list(islice(entry.iterdir(), MAX_DIRECTORY_ENTRIES + 1))
                if len(children) > MAX_DIRECTORY_ENTRIES:
                    traversal.skipped_oversized_directories += 1
                    traversal.limited = True
                    continue
                children = sorted(
                    children,
                    key=lambda item: (item.name.casefold(), item.name),
                    reverse=True,
                )
            except OSError:
                continue
            for child in children:
                pending.append((child, depth + 1))
