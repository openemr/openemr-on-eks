"""Floci-backed AWS CLI integration tests for openemr_dr helpers."""

from __future__ import annotations

import contextlib
import os
import tempfile
import uuid
from pathlib import Path

import pytest

from openemr_dr.aws import kms as kms_mod
from openemr_dr.common.shell import run, run_json

pytestmark = pytest.mark.floci


def _require_floci() -> None:
    if not os.environ.get("AWS_ENDPOINT_URL", "").strip():
        pytest.skip("AWS_ENDPOINT_URL unset (Floci not configured)")


def test_floci_sts_identity_via_shell() -> None:
    _require_floci()
    data = run_json(["aws", "sts", "get-caller-identity"], retries=1)
    assert data.get("Account")
    assert data.get("Arn")


def test_floci_s3_backup_prefix_round_trip() -> None:
    _require_floci()
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    bucket = os.environ.get("FLOCI_BACKUP_BUCKET")
    if not bucket:
        account = run_json(["aws", "sts", "get-caller-identity"], retries=1)["Account"]
        bucket = f"openemr-backups-{account}-openemr-eks-floci-test"
        run(["aws", "s3", "mb", f"s3://{bucket}", "--region", region], retries=1)

    key = f"metadata/floci-test-{uuid.uuid4().hex}.json"
    body = '{"cluster_name":"openemr-eks-floci","created_by":"floci-test"}'
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        handle.write(body)
        local_path = handle.name
    try:
        run(["aws", "s3", "cp", local_path, f"s3://{bucket}/{key}", "--region", region], retries=1)
    finally:
        Path(local_path).unlink(missing_ok=True)

    listed = run(
        ["aws", "s3", "ls", f"s3://{bucket}/metadata/", "--region", region],
        capture=True,
        retries=1,
    )
    assert key.split("/")[-1] in (listed.stdout or "")


def test_floci_kms_describe_key() -> None:
    _require_floci()
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    alias = os.environ.get("FLOCI_KMS_ALIAS", "alias/openemr-floci-test")
    try:
        state, enabled = kms_mod._describe_key(region, alias)
    except Exception:
        created = run_json(["aws", "kms", "create-key", "--description", "openemr-floci-test"], retries=1)
        key_id = str((created.get("KeyMetadata") or {}).get("KeyId") or "").strip()
        assert key_id
        with contextlib.suppress(Exception):
            run(
                ["aws", "kms", "create-alias", "--alias-name", alias, "--target-key-id", key_id],
                retries=1,
            )
        state, enabled = kms_mod._describe_key(region, alias)

    assert enabled is True
    assert state
