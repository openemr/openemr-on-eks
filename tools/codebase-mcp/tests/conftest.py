from __future__ import annotations

import hashlib
from collections.abc import Callable
from pathlib import Path

import pytest
from openemr_eks_mcp.catalog import COMMANDS, TOPICS


def _write(path: Path, content: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        path.write_bytes(content)
    else:
        path.write_text(content, encoding="utf-8")


@pytest.fixture
def repo_factory(tmp_path: Path) -> Callable[[], Path]:
    def make_repo() -> Path:
        root = tmp_path / "fixture-repo"
        root.mkdir()
        _write(
            root / "versions.yaml",
            """
applications:
  openemr:
    current: "8.2.0"
    registry: "openemr/openemr"
    requires_aws_cli: false
    description: "OpenEMR image"
infrastructure:
  eks:
    current: "1.36"
    requires_aws_cli: true
    description: "EKS version"
python_packages:
  fastmcp:
    current: "3.4.5"
    package_manager: "pip"
    description: "Knowledge server framework"
notifications:
  github_issues:
    enabled: true
""".lstrip(),
        )
        _write(
            root / "README.md",
            "# Fixture OpenEMR on EKS\n\nEKS Auto Mode runs the OpenEMR application.\n",
        )
        _write(root / "VERSION", "0.1.0\n")
        _write(
            root / "docs/DEPLOYMENT_GUIDE.md",
            "# Deployment\n\nDeploy OpenEMR after EKS Auto Mode is ready.\n",
        )
        _write(
            root / "docs/SECURITY_SCANNING.md",
            "# Security\n\nKMS encryption and least privilege are required.\n",
        )
        _write(
            root / "docs/CREDENTIAL_ROTATION_GUIDE.md",
            "# Credential rotation\n\nSafe documentation about dual-slot credentials.\n",
        )
        _write(
            root / "terraform/main.tf",
            'terraform { required_version = ">= 1.15.8" }\n# EKS 1.36\n',
        )
        _write(
            root / "terraform/terraform.tfvars.example",
            'openemr_version = "8.2.0"\nkubernetes_version = "1.36"\n',
        )
        _write(root / "terraform/terraform.tfvars", 'db_password = "not-a-real-secret"\n')
        _write(
            root / "k8s/deployment.yaml",
            "kind: Deployment\nmetadata:\n  name: openemr\n# image 8.2.0\n",
        )
        _write(
            root / "k8s/credential-rotation-job.yaml",
            "kind: Job\nmetadata:\n  name: credential-rotation\n",
        )
        _write(root / "k8s/secrets.yaml", "password: fixture-value\n")
        _write(
            root / "scripts/destroy.sh",
            "#!/usr/bin/env bash\n# Destroy all infrastructure\nexit 0\n",
        )
        _write(root / "scripts/openemr_dr/backup/metadata.py", "def build_manifest():\n    return {}\n")
        _write(root / ".external_modules/vendor/main.tf", 'resource "external" "fixture" {}\n')
        _write(root / ".git/config", "[remote]\nurl = local-fixture\n")
        _write(root / ".terraform/state.txt", "state output\n")
        _write(root / "credentials/token.txt", "fixture-token\n")
        _write(root / "prod-secrets/database.txt", "password=fixture-value\n")
        _write(root / "ops/db-credentials.sh", "#!/usr/bin/env bash\npassword=fixture-value\n")
        _write(root / "backup/export.txt", "fixture backup\n")
        _write(root / "reports/security-report.txt", "fixture report\n")
        _write(root / "binary.txt", b"text-prefix\x00binary-suffix")
        _write(root / "oversized.txt", b"x" * (512 * 1024 + 1))

        catalog_paths = {source.path for topic in TOPICS for source in topic.sources} | {
            path for command in COMMANDS for path in command.source_paths
        }
        for relative in catalog_paths:
            path = root / relative
            if not path.exists():
                _write(path, "# Fixture catalog source\n")
        return root

    return make_repo


def repository_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(root).as_posix().encode()
        digest.update(relative)
        if path.is_symlink():
            digest.update(b"symlink:")
            digest.update(path.readlink().as_posix().encode())
        elif path.is_file():
            digest.update(path.read_bytes())
    return digest.hexdigest()
