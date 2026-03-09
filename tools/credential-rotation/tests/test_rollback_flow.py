from pathlib import Path
from unittest.mock import patch

from credential_rotation.rotate import RotationOrchestrator

from conftest import make_context


class _DummyOrchestrator(RotationOrchestrator):
    def __init__(self, context):
        super().__init__(context)
        self.validated = False

    def _validate_runtime(self, rds_slot):
        self.validated = True


@patch("credential_rotation.rotate.atomic_write")
@patch("credential_rotation.rotate.rollout_restart_deployment")
@patch("credential_rotation.rotate.update_k8s_db_secret")
def test_rollback_restores_sqlconf_and_k8s(mock_k8s_secret, mock_rollout, mock_atomic_write, tmp_path: Path):
    """Rollback should write original sqlconf, update K8s secret, restart deployment, and validate."""
    sqlconf = tmp_path / "sqlconf.php"

    ctx = make_context(tmp_path)
    orch = _DummyOrchestrator(ctx)

    active_slot = {
        "host": "h",
        "port": 3306,
        "username": "u",
        "password": "p",
        "dbname": "d",
    }
    orch._rollback(sqlconf, "original-content", active_slot)

    mock_atomic_write.assert_called_once_with(sqlconf, "original-content")
    mock_k8s_secret.assert_called_once_with(namespace="openemr", secret_name="openemr-db-credentials", slot=active_slot)
    mock_rollout.assert_called_once_with(namespace="openemr", deployment_name="openemr")
    assert orch.validated is True


@patch("credential_rotation.rotate.atomic_write")
@patch("credential_rotation.rotate.rollout_restart_deployment")
@patch("credential_rotation.rotate.update_k8s_db_secret")
def test_rollback_calls_in_correct_order(mock_k8s_secret, mock_rollout, mock_atomic_write, tmp_path: Path):
    """Verify rollback steps execute in the correct sequence: write -> K8s secret -> restart -> validate."""
    call_order = []

    mock_atomic_write.side_effect = lambda *a, **kw: call_order.append("atomic_write")
    mock_k8s_secret.side_effect = lambda *a, **kw: call_order.append("k8s_secret")
    mock_rollout.side_effect = lambda *a, **kw: call_order.append("rollout")

    ctx = make_context(tmp_path)

    class _OrderTrackingOrch(RotationOrchestrator):
        def _validate_runtime(self, rds_slot):
            call_order.append("validate")

    orch = _OrderTrackingOrch(ctx)
    sqlconf = tmp_path / "sqlconf.php"
    active_slot = {
        "host": "h",
        "port": 3306,
        "username": "u",
        "password": "p",
        "dbname": "d",
    }
    orch._rollback(sqlconf, "orig", active_slot)

    assert call_order == ["atomic_write", "k8s_secret", "rollout", "validate"]
