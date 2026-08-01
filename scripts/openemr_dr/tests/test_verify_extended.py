"""Extended verify phase tests."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from openemr_dr.errors import PhaseError
from openemr_dr.models.restore import RestoreContext
from openemr_dr.restore.phases import verify


def test_deployment_replicas() -> None:
    with patch("openemr_dr.restore.phases.verify.run_cmd") as mock_run:
        mock_run.side_effect = [
            MagicMock(stdout="2"),
            MagicMock(stdout="3"),
        ]
        assert verify._deployment_replicas("openemr") == (2, 3)


def test_running_pod_and_health() -> None:
    with patch("openemr_dr.restore.phases.verify.run_cmd") as mock_run:
        mock_run.side_effect = [
            MagicMock(stdout="pod-1"),
            MagicMock(stdout="True"),
            MagicMock(returncode=0),
        ]
        assert verify._running_pod("openemr") == "pod-1"
        assert verify._pod_is_ready("openemr", "pod-1") is True
        assert verify._pod_serves_http("openemr", "pod-1") is True


def test_restore_autoscaling_applies(tmp_path: Path) -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s", namespace="restored")
    hpa = tmp_path / "hpa.yaml"
    hpa.write_text(
        """
metadata:
  namespace: openemr
spec:
  minReplicas: ${OPENEMR_MIN_REPLICAS}
  maxReplicas: ${OPENEMR_MAX_REPLICAS}
  cpu: ${OPENEMR_CPU_THRESHOLD}
  memory: ${OPENEMR_MEMORY_THRESHOLD}
  down: ${OPENEMR_SCALE_DOWN_STABILIZATION}
  up: ${OPENEMR_SCALE_UP_STABILIZATION}
""",
        encoding="utf-8",
    )
    autoscaling = {
        "min_replicas": 2,
        "max_replicas": 10,
        "cpu_utilization_threshold": 70,
        "memory_utilization_threshold": 80,
        "scale_down_stabilization_seconds": 300,
        "scale_up_stabilization_seconds": 60,
    }
    rendered: list[str] = []

    def fake_run(cmd: list[str], **_kwargs: object) -> MagicMock:
        if cmd[0] == "terraform":
            return MagicMock(returncode=0, stdout=json.dumps(autoscaling))
        rendered.append(Path(cmd[-1]).read_text(encoding="utf-8"))
        return MagicMock(returncode=0)

    with patch("openemr_dr.restore.phases.verify.K8S_DIR", tmp_path):
        with patch("openemr_dr.restore.phases.verify.run_cmd", side_effect=fake_run) as mock_run:
            verify.restore_autoscaling(ctx)
    assert mock_run.call_count == 2
    assert "namespace: restored" in rendered[0]
    assert "minReplicas: 2" in rendered[0]
    assert "maxReplicas: 10" in rendered[0]
    assert "${OPENEMR_" not in rendered[0]


def test_restore_autoscaling_requires_template(tmp_path: Path) -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s")
    with patch("openemr_dr.restore.phases.verify.K8S_DIR", tmp_path):
        with pytest.raises(PhaseError, match="HPA template missing"):
            verify.restore_autoscaling(ctx)


def test_restore_autoscaling_fails_without_terraform_config(tmp_path: Path) -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s")
    hpa = tmp_path / "hpa.yaml"
    hpa.write_text("${OPENEMR_MIN_REPLICAS}", encoding="utf-8")
    with patch("openemr_dr.restore.phases.verify.K8S_DIR", tmp_path):
        with patch(
            "openemr_dr.restore.phases.verify.run_cmd",
            return_value=MagicMock(returncode=1),
        ):
            with pytest.raises(PhaseError, match="autoscaling configuration"):
                verify.restore_autoscaling(ctx)


def test_restore_autoscaling_rejects_invalid_config_json(tmp_path: Path) -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s")
    (tmp_path / "hpa.yaml").write_text("${OPENEMR_MIN_REPLICAS}", encoding="utf-8")
    with patch("openemr_dr.restore.phases.verify.K8S_DIR", tmp_path):
        with patch(
            "openemr_dr.restore.phases.verify.run_cmd",
            return_value=MagicMock(returncode=0, stdout="{"),
        ):
            with pytest.raises(PhaseError, match="invalid JSON"):
                verify.restore_autoscaling(ctx)


def test_restore_autoscaling_rejects_non_object_config(tmp_path: Path) -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s")
    (tmp_path / "hpa.yaml").write_text("${OPENEMR_MIN_REPLICAS}", encoding="utf-8")
    with patch("openemr_dr.restore.phases.verify.K8S_DIR", tmp_path):
        with patch(
            "openemr_dr.restore.phases.verify.run_cmd",
            return_value=MagicMock(returncode=0, stdout="[]"),
        ):
            with pytest.raises(PhaseError, match="not an object"):
                verify.restore_autoscaling(ctx)


def test_restore_autoscaling_rejects_incomplete_config(tmp_path: Path) -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s")
    (tmp_path / "hpa.yaml").write_text("${OPENEMR_MIN_REPLICAS}", encoding="utf-8")
    with patch("openemr_dr.restore.phases.verify.K8S_DIR", tmp_path):
        with patch(
            "openemr_dr.restore.phases.verify.run_cmd",
            return_value=MagicMock(returncode=0, stdout='{"min_replicas": 2}'),
        ):
            with pytest.raises(PhaseError, match="missing values"):
                verify.restore_autoscaling(ctx)


def test_restore_autoscaling_fails_when_apply_fails(tmp_path: Path) -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s")
    (tmp_path / "hpa.yaml").write_text(
        """
${OPENEMR_MIN_REPLICAS}
${OPENEMR_MAX_REPLICAS}
${OPENEMR_CPU_THRESHOLD}
${OPENEMR_MEMORY_THRESHOLD}
${OPENEMR_SCALE_DOWN_STABILIZATION}
${OPENEMR_SCALE_UP_STABILIZATION}
""",
        encoding="utf-8",
    )
    autoscaling = {
        "min_replicas": 2,
        "max_replicas": 10,
        "cpu_utilization_threshold": 70,
        "memory_utilization_threshold": 80,
        "scale_down_stabilization_seconds": 300,
        "scale_up_stabilization_seconds": 60,
    }
    rendered_path: Path | None = None

    def fake_run(cmd: list[str], **_kwargs: object) -> MagicMock:
        nonlocal rendered_path
        if cmd[0] == "terraform":
            return MagicMock(returncode=0, stdout=json.dumps(autoscaling))
        rendered_path = Path(cmd[-1])
        return MagicMock(returncode=1)

    with patch("openemr_dr.restore.phases.verify.K8S_DIR", tmp_path):
        with patch("openemr_dr.restore.phases.verify.run_cmd", side_effect=fake_run):
            with pytest.raises(PhaseError, match="Failed to restore HPA"):
                verify.restore_autoscaling(ctx)
    assert rendered_path is not None
    assert not rendered_path.exists()


def test_cleanup_crypto_keys_no_pods() -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s", namespace="openemr")
    with patch("openemr_dr.restore.phases.verify.time.sleep"):
        with patch("openemr_dr.restore.phases.verify.run_cmd", return_value=MagicMock(stdout="")):
            verify.cleanup_crypto_keys(ctx)


def test_cleanup_crypto_keys_with_pods() -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s", namespace="openemr")
    with patch("openemr_dr.restore.phases.verify.time.sleep"):
        with patch("openemr_dr.restore.phases.verify.run_cmd", return_value=MagicMock(stdout="pod-a pod-b")):
            verify.cleanup_crypto_keys(ctx)


def test_verify_once_success() -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s", namespace="openemr")
    with patch("openemr_dr.restore.phases.verify._deployment_replicas", return_value=(1, 1)):
        with patch("openemr_dr.restore.phases.verify.openemr_pod_is_healthy", return_value=True):
            assert verify.verify_once(ctx) is True


def test_verify_once_no_deployment() -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s", namespace="openemr")
    with patch("openemr_dr.restore.phases.verify._deployment_replicas", return_value=(0, 0)):
        with patch("openemr_dr.restore.phases.verify.time.sleep"):
            assert verify.verify_once(ctx) is False


def test_openemr_pod_unhealthy() -> None:
    with patch("openemr_dr.restore.phases.verify._running_pod", return_value=""):
        assert verify.openemr_pod_is_healthy("openemr") is False


def test_prepare_single_replica_no_deployment() -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s", namespace="openemr")
    with patch("openemr_dr.restore.phases.verify.run_cmd") as mock_run:
        mock_run.side_effect = [
            MagicMock(returncode=0),
            MagicMock(returncode=1),
        ]
        verify.prepare_single_replica(ctx)
    assert mock_run.call_args_list[0].args[0][:4] == [
        "kubectl",
        "delete",
        "hpa",
        "openemr-hpa",
    ]


def test_deploy_failure_on_deploy_sh() -> None:
    ctx = RestoreContext(backup_bucket="b", snapshot_id="s")
    with patch("openemr_dr.restore.phases.deploy.run_cmd") as mock_run:
        mock_run.side_effect = [
            MagicMock(returncode=0),
            MagicMock(returncode=0),
            MagicMock(returncode=1),
        ]
        with pytest.raises(PhaseError, match=r"deploy\.sh"):
            from openemr_dr.restore.phases import deploy

            deploy.run(ctx)
