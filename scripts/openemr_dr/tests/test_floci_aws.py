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


def test_floci_rds_describe_seeded_cluster() -> None:
    _require_floci()
    cluster_id = os.environ.get("FLOCI_RDS_CLUSTER_ID", "openemr-floci-aurora")

    def _clusters() -> list[dict]:
        # Floci often returns HTTP 200 with DBClusters=[] for a missing id (exit 0).
        try:
            payload = run_json(
                ["aws", "rds", "describe-db-clusters", "--db-cluster-identifier", cluster_id],
                retries=1,
                check=False,
            )
        except Exception:
            return []
        if not isinstance(payload, dict):
            return []
        return list(payload.get("DBClusters") or [])

    clusters = _clusters()
    if not any(c.get("DBClusterIdentifier") == cluster_id for c in clusters):
        run(
            [
                "aws",
                "rds",
                "create-db-cluster",
                "--db-cluster-identifier",
                cluster_id,
                "--engine",
                "aurora-mysql",
                "--master-username",
                "openemr",
                "--master-user-password",
                "SeedPassword123!",
                "--database-name",
                "openemr",
            ],
            retries=1,
        )
        clusters = _clusters()

    assert clusters, f"Floci returned no DBClusters for {cluster_id}"
    assert clusters[0].get("DBClusterIdentifier") == cluster_id


def test_floci_secrets_manager_get_slot_secret() -> None:
    _require_floci()
    secret_name = os.environ.get("FLOCI_SLOT_SECRET_NAME", "openemr/floci/rds-slots")
    try:
        data = run_json(
            ["aws", "secretsmanager", "get-secret-value", "--secret-id", secret_name],
            retries=1,
        )
    except Exception:
        run(
            [
                "aws",
                "secretsmanager",
                "create-secret",
                "--name",
                secret_name,
                "--secret-string",
                '{"active_slot":"A","A":{"username":"openemr","password":"slot-a-password"}}',
            ],
            retries=1,
        )
        data = run_json(
            ["aws", "secretsmanager", "get-secret-value", "--secret-id", secret_name],
            retries=1,
        )
    payload = data.get("SecretString") or ""
    assert "active_slot" in payload
