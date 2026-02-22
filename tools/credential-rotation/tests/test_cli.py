import os
from unittest.mock import patch

import pytest

from credential_rotation.cli import build_parser
from credential_rotation.rotate import RotationOrchestrator


def test_parser_defaults():
    parser = build_parser()
    args = parser.parse_args([])
    assert args.dry_run is False
    assert args.log_json is False
    assert args.fix_permissions is False
    assert args.sync_db_users is False


def test_parser_flags():
    parser = build_parser()
    args = parser.parse_args(["--dry-run", "--log-json"])
    assert args.dry_run is True
    assert args.log_json is True


def test_from_env_raises_on_missing_vars():
    env = {"AWS_REGION": "us-east-1"}
    with patch.dict(os.environ, env, clear=True):
        with pytest.raises(RuntimeError, match="Missing required environment variables"):
            RotationOrchestrator.from_env(dry_run=True)


@patch("credential_rotation.secrets_manager.boto3")
def test_from_env_succeeds_with_all_vars(mock_boto):
    env = {
        "AWS_REGION": "us-east-1",
        "RDS_SLOT_SECRET_ID": "arn:aws:secretsmanager:us-east-1:123:secret:slots",
        "RDS_ADMIN_SECRET_ID": "arn:aws:secretsmanager:us-east-1:123:secret:admin",
        "OPENEMR_SITES_MOUNT_ROOT": "/mnt/sites",
        "K8S_NAMESPACE": "openemr",
        "K8S_DEPLOYMENT_NAME": "openemr",
        "K8S_SECRET_NAME": "openemr-db-credentials",
    }
    with patch.dict(os.environ, env, clear=True):
        orch = RotationOrchestrator.from_env(dry_run=True)
        assert orch.ctx.region == "us-east-1"
        assert orch.ctx.k8s_namespace == "openemr"
        assert orch.ctx.dry_run is True
        assert orch.ctx.openemr_health_url is None
