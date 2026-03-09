"""Tests for warp/core/credential_discovery.py — K8s and Terraform credential discovery."""

import base64
import json
from unittest.mock import patch, MagicMock

from warp.core.credential_discovery import CredentialDiscovery


class TestKubernetesDiscovery:
    @patch("warp.core.credential_discovery.subprocess.run")
    def test_returns_credentials_from_k8s_secret(self, mock_run):
        secret = {
            "data": {
                "mysql-host": base64.b64encode(b"db.example.com").decode(),
                "mysql-user": base64.b64encode(b"openemr").decode(),
                "mysql-password": base64.b64encode(b"secret123").decode(),
                "mysql-database": base64.b64encode(b"openemr").decode(),
            }
        }
        mock_run.return_value = MagicMock(returncode=0, stdout=json.dumps(secret))

        discovery = CredentialDiscovery(namespace="openemr")
        creds = discovery.get_db_credentials()

        assert creds == {
            "host": "db.example.com",
            "user": "openemr",
            "password": "secret123",
            "database": "openemr",
        }

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_database_defaults_to_openemr_when_missing(self, mock_run):
        secret = {
            "data": {
                "mysql-host": base64.b64encode(b"host").decode(),
                "mysql-user": base64.b64encode(b"user").decode(),
                "mysql-password": base64.b64encode(b"pw").decode(),
            }
        }
        mock_run.return_value = MagicMock(returncode=0, stdout=json.dumps(secret))

        creds = CredentialDiscovery().get_db_credentials()
        assert creds["database"] == "openemr"

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_returns_none_when_kubectl_fails(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stdout="")

        creds = CredentialDiscovery().get_db_credentials()
        assert creds is None

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_returns_none_when_secret_has_missing_fields(self, mock_run):
        secret = {"data": {"mysql-host": base64.b64encode(b"host").decode()}}
        mock_run.return_value = MagicMock(returncode=0, stdout=json.dumps(secret))

        creds = CredentialDiscovery().get_db_credentials()
        assert creds is None

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_handles_subprocess_exception(self, mock_run):
        mock_run.side_effect = FileNotFoundError("kubectl not found")

        creds = CredentialDiscovery().get_db_credentials()
        assert creds is None

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_uses_custom_namespace(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stdout="")

        CredentialDiscovery(namespace="custom-ns").get_db_credentials()

        call_args = mock_run.call_args[0][0]
        assert "-n" in call_args
        ns_idx = call_args.index("-n")
        assert call_args[ns_idx + 1] == "custom-ns"


class TestTerraformDiscovery:
    @patch("warp.core.credential_discovery.subprocess.run")
    def test_returns_credentials_from_terraform(self, mock_run):
        # First call (kubectl) fails, second call (terraform) succeeds
        tf_output = {
            "aurora_endpoint": {"value": "aurora.cluster.rds.amazonaws.com"},
            "aurora_password": {"value": "tf_password"},
        }
        mock_run.side_effect = [
            MagicMock(returncode=1, stdout=""),
            MagicMock(returncode=0, stdout=json.dumps(tf_output)),
        ]

        discovery = CredentialDiscovery(terraform_dir="/path/to/tf")
        creds = discovery.get_db_credentials()

        assert creds == {
            "host": "aurora.cluster.rds.amazonaws.com",
            "user": "openemr",
            "password": "tf_password",
            "database": "openemr",
        }

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_terraform_not_tried_without_terraform_dir(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stdout="")

        creds = CredentialDiscovery(terraform_dir=None).get_db_credentials()
        assert creds is None
        assert mock_run.call_count == 1

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_returns_none_when_terraform_missing_outputs(self, mock_run):
        tf_output = {"some_other_output": {"value": "foo"}}
        mock_run.side_effect = [
            MagicMock(returncode=1, stdout=""),
            MagicMock(returncode=0, stdout=json.dumps(tf_output)),
        ]

        creds = CredentialDiscovery(terraform_dir="/tf").get_db_credentials()
        assert creds is None

    @patch("warp.core.credential_discovery.subprocess.run")
    def test_terraform_exception_returns_none(self, mock_run):
        mock_run.side_effect = [
            MagicMock(returncode=1, stdout=""),
            FileNotFoundError("terraform not found"),
        ]

        creds = CredentialDiscovery(terraform_dir="/tf").get_db_credentials()
        assert creds is None
