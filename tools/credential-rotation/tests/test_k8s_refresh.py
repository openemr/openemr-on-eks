import base64
from unittest.mock import patch, MagicMock

from credential_rotation.k8s_refresh import update_k8s_db_secret, rollout_restart_deployment


@patch("credential_rotation.k8s_refresh._load_k8s_config")
@patch("credential_rotation.k8s_refresh.client")
def test_update_k8s_db_secret_patches_correct_data(mock_client, mock_config):
    mock_v1 = MagicMock()
    mock_client.CoreV1Api.return_value = mock_v1

    slot = {"host": "db.example.com", "username": "openemr_a", "password": "s3cret!", "dbname": "openemr"}
    update_k8s_db_secret(namespace="openemr", secret_name="openemr-db-credentials", slot=slot)

    mock_v1.patch_namespaced_secret.assert_called_once()
    call_kwargs = mock_v1.patch_namespaced_secret.call_args
    assert call_kwargs.kwargs["name"] == "openemr-db-credentials"
    assert call_kwargs.kwargs["namespace"] == "openemr"

    body = call_kwargs.kwargs["body"]
    assert base64.b64decode(body["data"]["mysql-host"]).decode() == "db.example.com"
    assert base64.b64decode(body["data"]["mysql-user"]).decode() == "openemr_a"
    assert base64.b64decode(body["data"]["mysql-password"]).decode() == "s3cret!"
    assert base64.b64decode(body["data"]["mysql-database"]).decode() == "openemr"


@patch("credential_rotation.k8s_refresh._load_k8s_config")
@patch("credential_rotation.k8s_refresh.client")
def test_rollout_restart_annotates_deployment(mock_client, mock_config):
    mock_apps = MagicMock()
    mock_client.AppsV1Api.return_value = mock_apps

    mock_status = MagicMock()
    mock_status.spec.replicas = 2
    mock_status.status.updated_replicas = 2
    mock_status.status.ready_replicas = 2
    mock_status.status.available_replicas = 2
    mock_status.status.unavailable_replicas = 0
    mock_apps.read_namespaced_deployment_status.return_value = mock_status

    rollout_restart_deployment(namespace="openemr", deployment_name="openemr", timeout_seconds=30)

    mock_apps.patch_namespaced_deployment.assert_called_once()
    patch_body = mock_apps.patch_namespaced_deployment.call_args.kwargs["body"]
    assert "credential-rotation/restartedAt" in patch_body["spec"]["template"]["metadata"]["annotations"]
