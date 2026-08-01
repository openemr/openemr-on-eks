from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

import openemr_eks_mcp.policy as policy_module
import pytest
from openemr_eks_mcp.policy import MAX_FILE_BYTES, RepositoryPolicy, TraversalStats


def test_repository_validation_and_sorted_traversal(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    policy = RepositoryPolicy(root)
    policy.validate_repository()

    paths = [item.relative_path for item in policy.iter_approved_files()]
    assert paths == sorted(paths, key=lambda value: (value.casefold(), value))
    assert "README.md" in paths
    assert "VERSION" in paths
    assert "terraform/terraform.tfvars.example" in paths
    assert "docs/CREDENTIAL_ROTATION_GUIDE.md" in paths
    assert "k8s/credential-rotation-job.yaml" in paths
    assert "scripts/openemr_dr/backup/metadata.py" in paths
    assert ".external_modules/vendor/main.tf" not in paths
    assert ".git/config" not in paths
    assert ".terraform/state.txt" not in paths
    assert "credentials/token.txt" not in paths
    assert "backup/export.txt" not in paths
    assert "reports/security-report.txt" not in paths
    assert "terraform/terraform.tfvars" not in paths
    assert "k8s/secrets.yaml" not in paths
    assert "oversized.txt" not in paths


def test_traversal_skips_oversized_directories_deterministically(
    repo_factory: Callable[[], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    policy = RepositoryPolicy(repo_factory())
    monkeypatch.setattr(policy_module, "MAX_DIRECTORY_ENTRIES", 1)
    stats = TraversalStats()

    assert list(policy.iter_approved_files(stats=stats)) == []
    assert stats.limited is True
    assert stats.skipped_oversized_directories == 1


@pytest.mark.parametrize(
    ("path", "message"),
    [
        ("../outside.txt", "traversal"),
        ("docs/../../outside.txt", "traversal"),
        ("/etc/passwd", "Absolute"),
        (r"C:\Users\example\file.txt", "Absolute"),
        ("docs//file.md", "empty component"),
        ("", "non-empty"),
        ("x" * 4_097, "at most 4096"),
    ],
)
def test_rejects_unsafe_paths(
    repo_factory: Callable[[], Path],
    path: str,
    message: str,
) -> None:
    policy = RepositoryPolicy(repo_factory())
    with pytest.raises(ValueError, match=message):
        policy.read_text(path)


@pytest.mark.parametrize(
    "path",
    [
        "terraform/terraform.tfvars",
        ".external_modules/vendor/main.tf",
        "k8s/secrets.yaml",
        "credentials/token.txt",
        "prod-secrets/database.txt",
        "ops/db-credentials.sh",
        "reports/security-report.txt",
    ],
)
def test_rejects_secret_and_denied_locations(
    repo_factory: Callable[[], Path],
    path: str,
) -> None:
    policy = RepositoryPolicy(repo_factory())
    with pytest.raises(ValueError, match="denied"):
        policy.read_text(path)


def test_rejects_binary_oversized_and_unsupported_files(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    (root / "image.png").write_bytes(b"plain but unsupported")
    policy = RepositoryPolicy(root)

    with pytest.raises(ValueError, match="Binary"):
        policy.read_text("binary.txt")
    with pytest.raises(ValueError, match="exceeds"):
        policy.read_text("oversized.txt")
    with pytest.raises(ValueError, match="allowlist"):
        policy.read_text("image.png")
    with pytest.raises(ValueError, match="max_size"):
        policy.approve_file("README.md", max_size=MAX_FILE_BYTES + 1)


def test_rejects_private_key_material_in_safe_named_file(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    (root / "notes.txt").write_text(
        "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nfixture\n",
        encoding="utf-8",
    )
    policy = RepositoryPolicy(root)
    with pytest.raises(ValueError, match="private key"):
        policy.read_text("notes.txt")


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("AKIA" + "1234567890ABCDEF\n", "AWS credential"),
        # checkov:skip=CKV_SECRET_6:Synthetic split token verifies repository-policy detection.
        ("ghp_" + "1234567890abcdefghijklmnopqrstuvwxyz\n", "GitHub token"),
        # checkov:skip=CKV_SECRET_6:Synthetic split token verifies repository-policy detection.
        ("xoxb-" + "123456789012-abcdefghijklmnopqrstuvwx\n", "Slack token"),
        # checkov:skip=CKV_SECRET_6:Synthetic split token verifies repository-policy detection.
        ("AI" + "za1234567890abcdefghijklmnopqrstuvwxy\n", "Google API key"),
    ],
)
def test_rejects_recognizable_credentials_in_safe_named_files(
    repo_factory: Callable[[], Path],
    value: str,
    message: str,
) -> None:
    root = repo_factory()
    (root / "notes.txt").write_text(value, encoding="utf-8")
    with pytest.raises(ValueError, match=message):
        RepositoryPolicy(root).read_text("notes.txt")


def test_rejects_literal_credential_assignment_in_safe_named_file(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    (root / "notes.txt").write_text(
        # checkov:skip=CKV_SECRET_6:Synthetic credential assignment is the test fixture under validation.
        'db_password = "CorrectHorseBatteryStaple"\n',
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="literal credential"):
        RepositoryPolicy(root).read_text("notes.txt")


@pytest.mark.parametrize(
    ("path", "content", "message"),
    [
        (
            "config.json",
            '{"database": {"password": "CorrectHorseBatteryStaple"}}\n',
            "literal credential",
        ),
        (
            "settings.yaml",
            'database:\n  password: "CorrectHorseBatteryStaple"\n',
            "literal credential",
        ),
        (
            "cluster.yaml",
            ("apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\ncurrent-context: production\nusers: []\n"),
            "kubeconfig",
        ),
        (
            "signing.json",
            '{"kty": "RSA", "n": "public-modulus", "e": "AQAB", "d": "private-exponent"}\n',
            "JSON Web Key",
        ),
        (
            "renamed.txt",
            "apiVersion: v1\nkind: Secret\nmetadata:\n  name: renamed\ndata:\n  value: c2VjcmV0\n",
            "Kubernetes Secret",
        ),
    ],
)
def test_rejects_structured_secrets_in_safe_named_files(
    repo_factory: Callable[[], Path],
    path: str,
    content: str,
    message: str,
) -> None:
    root = repo_factory()
    (root / path).write_text(content, encoding="utf-8")

    with pytest.raises(ValueError, match=message):
        RepositoryPolicy(root).read_text(path)


def test_allows_explicit_structured_placeholders(repo_factory: Callable[[], Path]) -> None:
    root = repo_factory()
    (root / "config.json").write_text(
        # checkov:skip=CKV_SECRET_6:Explicit placeholder verifies safe configuration is accepted.
        '{"database": {"password": "placeholder-password"}}\n',
        encoding="utf-8",
    )

    assert RepositoryPolicy(root).read_text("config.json")[1].startswith('{"database"')


def test_rejects_additional_secret_state_and_report_names(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    denied = {
        "terraform/prod.auto.tfvars.json": "{}\n",
        "prod.env": "VALUE=fixture\n",
        "kubeconfig-development.yaml": "clusters: []\n",
        "access-token.json": "{}\n",
        "local-report.json": "{}\n",
        ".kube/config.yaml": "clusters: []\n",
        "private.pem.example": "placeholder\n",
    }
    for relative, content in denied.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    example = root / "credentials.example.yaml"
    example.write_text("placeholder: true\n", encoding="utf-8")
    wrapped_example = root / "settings.conf.example"
    wrapped_example.write_text("placeholder=true\n", encoding="utf-8")
    policy = RepositoryPolicy(root)
    for relative in denied:
        with pytest.raises(ValueError, match="denied"):
            policy.read_text(relative)
    assert policy.read_text("credentials.example.yaml")[1] == "placeholder: true\n"
    assert policy.read_text("settings.conf.example")[1] == "placeholder=true\n"


def test_rejects_symlink_escape(
    repo_factory: Callable[[], Path],
    tmp_path: Path,
) -> None:
    root = repo_factory()
    outside = tmp_path / "outside.txt"
    outside.write_text("outside content\n", encoding="utf-8")
    link = root / "outside-link.txt"
    try:
        link.symlink_to(outside)
    except (NotImplementedError, OSError):
        pytest.skip("symbolic links are unavailable on this platform")

    policy = RepositoryPolicy(root)
    with pytest.raises(ValueError, match=r"Symbolic-link|outside"):
        policy.read_text("outside-link.txt")
    assert "outside-link.txt" not in {item.relative_path for item in policy.iter_approved_files()}


def test_rejects_in_repository_file_symlinks_regardless_of_extension(
    repo_factory: Callable[[], Path],
) -> None:
    root = repo_factory()
    target = root / "signing.json"
    target.write_text(
        '{"kty": "RSA", "n": "public", "e": "AQAB", "d": "private"}\n',
        encoding="utf-8",
    )
    link = root / "notes.txt"
    try:
        link.symlink_to(target)
    except (NotImplementedError, OSError):
        pytest.skip("symbolic links are unavailable on this platform")

    with pytest.raises(ValueError, match="Symbolic-link files"):
        RepositoryPolicy(root).read_text("notes.txt")


def test_rejects_paths_through_symlink_directories(
    repo_factory: Callable[[], Path],
    tmp_path: Path,
) -> None:
    root = repo_factory()
    target = tmp_path / "outside-directory"
    target.mkdir()
    (target / "file.txt").write_text("outside\n", encoding="utf-8")
    link = root / "linked-directory"
    try:
        link.symlink_to(target, target_is_directory=True)
    except (NotImplementedError, OSError):
        pytest.skip("symbolic links are unavailable on this platform")

    policy = RepositoryPolicy(root)
    with pytest.raises(ValueError, match="symbolic-link directories"):
        policy.read_text("linked-directory/file.txt")


def test_rejects_file_replaced_by_symlink_after_approval(
    repo_factory: Callable[[], Path],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = repo_factory()
    outside = tmp_path / "outside-race.txt"
    outside.write_text("outside content\n", encoding="utf-8")
    target = root / "race.txt"
    target.write_text("inside content\n", encoding="utf-8")
    policy = RepositoryPolicy(root)
    original_approve = policy.approve_file

    def approve_then_replace(path: str, *, max_size: int = MAX_FILE_BYTES):
        approved = original_approve(path, max_size=max_size)
        target.unlink()
        try:
            target.symlink_to(outside)
        except (NotImplementedError, OSError):
            pytest.skip("symbolic links are unavailable on this platform")
        return approved

    monkeypatch.setattr(policy, "approve_file", approve_then_replace)
    with pytest.raises(ValueError, match=r"could not be read|changed during"):
        policy.read_text("race.txt")


def test_rejects_hard_link_to_file_outside_repository(
    repo_factory: Callable[[], Path],
    tmp_path: Path,
) -> None:
    root = repo_factory()
    outside = tmp_path / "outside-hard-link.txt"
    outside.write_text("outside content\n", encoding="utf-8")
    linked = root / "hard-link.txt"
    try:
        linked.hardlink_to(outside)
    except (NotImplementedError, OSError):
        pytest.skip("hard links are unavailable on this platform")

    with pytest.raises(ValueError, match="Multiply linked"):
        RepositoryPolicy(root).read_text("hard-link.txt")
