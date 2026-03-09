"""Extended tests for k8s_refresh.py — _wait_for_rollout and _load_k8s_config."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from credential_rotation.k8s_refresh import (
    _load_k8s_config,
    _wait_for_rollout,
    rollout_restart_deployment,
)

# ---------------------------------------------------------------------------
# _load_k8s_config
# ---------------------------------------------------------------------------


class TestLoadK8sConfig:
    @patch("credential_rotation.k8s_refresh.config")
    def test_in_cluster_preferred(self, mock_config):
        mock_config.ConfigException = Exception
        _load_k8s_config()
        mock_config.load_incluster_config.assert_called_once()
        mock_config.load_kube_config.assert_not_called()

    @patch("credential_rotation.k8s_refresh.config")
    def test_falls_back_to_kubeconfig(self, mock_config):
        mock_config.ConfigException = Exception
        mock_config.load_incluster_config.side_effect = Exception("not in cluster")
        _load_k8s_config()
        mock_config.load_kube_config.assert_called_once()


# ---------------------------------------------------------------------------
# _wait_for_rollout
# ---------------------------------------------------------------------------


class TestWaitForRollout:
    def _make_status(self, replicas=2, updated=2, ready=2, available=2, unavailable=0):
        dep = MagicMock()
        dep.spec.replicas = replicas
        dep.status.updated_replicas = updated
        dep.status.ready_replicas = ready
        dep.status.available_replicas = available
        dep.status.unavailable_replicas = unavailable
        return dep

    @patch("credential_rotation.k8s_refresh.time.sleep")
    @patch("credential_rotation.k8s_refresh.time.monotonic")
    def test_completes_immediately_when_ready(self, mock_monotonic, mock_sleep):
        mock_monotonic.return_value = 0
        apps_v1 = MagicMock()
        apps_v1.read_namespaced_deployment_status.return_value = self._make_status()

        _wait_for_rollout(apps_v1, "openemr", "openemr", timeout_seconds=60)

        mock_sleep.assert_not_called()

    @patch("credential_rotation.k8s_refresh.time.sleep")
    @patch("credential_rotation.k8s_refresh.time.monotonic")
    def test_polls_until_ready(self, mock_monotonic, mock_sleep):
        call_count = [0]

        def monotonic_side_effect():
            call_count[0] += 1
            return (call_count[0] - 1) * 10

        mock_monotonic.side_effect = monotonic_side_effect

        in_progress = self._make_status(updated=1, ready=1, available=1, unavailable=1)
        complete = self._make_status()

        apps_v1 = MagicMock()
        apps_v1.read_namespaced_deployment_status.side_effect = [in_progress, complete]

        _wait_for_rollout(apps_v1, "openemr", "openemr", timeout_seconds=300)

        mock_sleep.assert_called()

    @patch("credential_rotation.k8s_refresh.time.sleep")
    @patch("credential_rotation.k8s_refresh.time.monotonic")
    def test_raises_on_timeout(self, mock_monotonic, mock_sleep):
        call_count = [0]

        def monotonic_side_effect():
            call_count[0] += 1
            return call_count[0] * 1000

        mock_monotonic.side_effect = monotonic_side_effect

        in_progress = self._make_status(updated=1, ready=1, available=1, unavailable=1)
        apps_v1 = MagicMock()
        apps_v1.read_namespaced_deployment_status.return_value = in_progress

        with pytest.raises(RuntimeError, match="did not complete"):
            _wait_for_rollout(apps_v1, "openemr", "openemr", timeout_seconds=60)

    @patch("credential_rotation.k8s_refresh.time.sleep")
    @patch("credential_rotation.k8s_refresh.time.monotonic")
    def test_handles_none_replicas(self, mock_monotonic, mock_sleep):
        """When spec.replicas is None, should default to 1."""
        mock_monotonic.return_value = 0
        dep = MagicMock()
        dep.spec.replicas = None
        dep.status.updated_replicas = 1
        dep.status.ready_replicas = 1
        dep.status.available_replicas = 1
        dep.status.unavailable_replicas = 0

        apps_v1 = MagicMock()
        apps_v1.read_namespaced_deployment_status.return_value = dep

        _wait_for_rollout(apps_v1, "openemr", "openemr", timeout_seconds=60)


# ---------------------------------------------------------------------------
# rollout_restart_deployment — timeout parameter forwarding
# ---------------------------------------------------------------------------


class TestRolloutRestartTimeout:
    @patch("credential_rotation.k8s_refresh._wait_for_rollout")
    @patch("credential_rotation.k8s_refresh._load_k8s_config")
    @patch("credential_rotation.k8s_refresh.client")
    def test_custom_timeout_forwarded(self, mock_client, mock_config, mock_wait):
        mock_apps = MagicMock()
        mock_client.AppsV1Api.return_value = mock_apps

        rollout_restart_deployment("ns", "deploy", timeout_seconds=42)

        mock_wait.assert_called_once_with(mock_apps, "ns", "deploy", 42)
