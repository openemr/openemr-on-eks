"""Tests for warp/commands/ccda_data_upload.py — command execution, argument parsing, credential flows."""

import argparse
from unittest.mock import patch, MagicMock

from warp.commands.ccda_data_upload import CCDADataUploadCommand


class TestAddArguments:
    def test_all_expected_arguments_registered(self):
        parser = argparse.ArgumentParser()
        CCDADataUploadCommand.add_arguments(parser)

        args = parser.parse_args(["--data-source", "s3://bucket/path"])
        assert args.data_source == "s3://bucket/path"
        assert args.db_name == "openemr"
        assert args.namespace == "openemr"
        assert args.start_from == 0
        assert args.dry_run is False

    def test_dry_run_flag(self):
        parser = argparse.ArgumentParser()
        CCDADataUploadCommand.add_arguments(parser)

        args = parser.parse_args(["--data-source", "/data", "--dry-run"])
        assert args.dry_run is True

    def test_all_db_args(self):
        parser = argparse.ArgumentParser()
        CCDADataUploadCommand.add_arguments(parser)

        args = parser.parse_args(
            [
                "--data-source",
                "/data",
                "--db-host",
                "my-host",
                "--db-user",
                "my-user",
                "--db-password",
                "my-pw",
                "--db-name",
                "my-db",
            ]
        )
        assert args.db_host == "my-host"
        assert args.db_user == "my-user"
        assert args.db_password == "my-pw"
        assert args.db_name == "my-db"


class TestCalculateOptimalBatchSize:
    def test_returns_100(self):
        cmd = CCDADataUploadCommand()
        assert cmd._calculate_optimal_batch_size() == 100


class TestExecuteWithAllCredentials:
    """When all DB credentials are provided, no auto-discovery should occur."""

    @patch("warp.commands.ccda_data_upload.Uploader")
    @patch("warp.commands.ccda_data_upload.OMOPToCCDAConverter")
    @patch("warp.commands.ccda_data_upload.OpenEMRDBImporter")
    @patch("warp.commands.ccda_data_upload.CredentialDiscovery")
    def test_dry_run_skips_db_connect(self, mock_disc_cls, mock_db_cls, mock_conv_cls, mock_up_cls):
        mock_uploader = MagicMock()
        mock_uploader.process_and_upload.return_value = {
            "processed": 1,
            "uploaded": 1,
            "failed": 0,
            "skipped": 0,
            "duration": 0.1,
        }
        mock_up_cls.return_value = mock_uploader

        args = argparse.Namespace(
            db_host="h",
            db_user="u",
            db_password="p",
            db_name="openemr",
            namespace="openemr",
            terraform_dir=None,
            data_source="/tmp/data",
            batch_size=None,
            max_records=None,
            start_from=0,
            workers=1,
            aws_region="us-east-1",
            dry_run=True,
            verbose=False,
        )

        cmd = CCDADataUploadCommand()
        result = cmd.execute(args)
        assert result == 0
        mock_db_cls.return_value.connect.assert_not_called()

    @patch("warp.commands.ccda_data_upload.Uploader")
    @patch("warp.commands.ccda_data_upload.OMOPToCCDAConverter")
    @patch("warp.commands.ccda_data_upload.OpenEMRDBImporter")
    @patch("warp.commands.ccda_data_upload.CredentialDiscovery")
    def test_live_run_connects_to_db(self, mock_disc_cls, mock_db_cls, mock_conv_cls, mock_up_cls):
        mock_db = MagicMock()
        mock_db.connect.return_value = True
        mock_db_cls.return_value = mock_db

        mock_uploader = MagicMock()
        mock_uploader.process_and_upload.return_value = {
            "processed": 2,
            "uploaded": 2,
            "failed": 0,
            "skipped": 0,
            "duration": 1,
        }
        mock_up_cls.return_value = mock_uploader

        args = argparse.Namespace(
            db_host="h",
            db_user="u",
            db_password="p",
            db_name="openemr",
            namespace="openemr",
            terraform_dir=None,
            data_source="/tmp/data",
            batch_size=50,
            max_records=10,
            start_from=0,
            workers=2,
            aws_region="us-east-1",
            dry_run=False,
            verbose=False,
        )

        cmd = CCDADataUploadCommand()
        result = cmd.execute(args)
        assert result == 0
        mock_db.connect.assert_called_once()
        mock_db.disconnect.assert_called_once()

    @patch("warp.commands.ccda_data_upload.Uploader")
    @patch("warp.commands.ccda_data_upload.OMOPToCCDAConverter")
    @patch("warp.commands.ccda_data_upload.OpenEMRDBImporter")
    @patch("warp.commands.ccda_data_upload.CredentialDiscovery")
    def test_db_connect_failure_returns_1(self, mock_disc_cls, mock_db_cls, mock_conv_cls, mock_up_cls):
        mock_db = MagicMock()
        mock_db.connect.return_value = False
        mock_db_cls.return_value = mock_db

        args = argparse.Namespace(
            db_host="h",
            db_user="u",
            db_password="p",
            db_name="openemr",
            namespace="openemr",
            terraform_dir=None,
            data_source="/tmp",
            batch_size=None,
            max_records=None,
            start_from=0,
            workers=None,
            aws_region="us-east-1",
            dry_run=False,
            verbose=False,
        )

        result = CCDADataUploadCommand().execute(args)
        assert result == 1

    @patch("warp.commands.ccda_data_upload.Uploader")
    @patch("warp.commands.ccda_data_upload.OMOPToCCDAConverter")
    @patch("warp.commands.ccda_data_upload.OpenEMRDBImporter")
    @patch("warp.commands.ccda_data_upload.CredentialDiscovery")
    def test_failed_records_returns_1(self, mock_disc_cls, mock_db_cls, mock_conv_cls, mock_up_cls):
        mock_db = MagicMock()
        mock_db.connect.return_value = True
        mock_db_cls.return_value = mock_db

        mock_uploader = MagicMock()
        mock_uploader.process_and_upload.return_value = {
            "processed": 5,
            "uploaded": 3,
            "failed": 2,
            "skipped": 0,
            "duration": 1,
        }
        mock_up_cls.return_value = mock_uploader

        args = argparse.Namespace(
            db_host="h",
            db_user="u",
            db_password="p",
            db_name="openemr",
            namespace="openemr",
            terraform_dir=None,
            data_source="/tmp",
            batch_size=None,
            max_records=None,
            start_from=0,
            workers=None,
            aws_region="us-east-1",
            dry_run=False,
            verbose=False,
        )

        result = CCDADataUploadCommand().execute(args)
        assert result == 1


class TestAutoDiscovery:
    @patch("warp.commands.ccda_data_upload.Uploader")
    @patch("warp.commands.ccda_data_upload.OMOPToCCDAConverter")
    @patch("warp.commands.ccda_data_upload.OpenEMRDBImporter")
    @patch("warp.commands.ccda_data_upload.CredentialDiscovery")
    def test_discovery_fills_missing_credentials(self, mock_disc_cls, mock_db_cls, mock_conv_cls, mock_up_cls):
        mock_disc = MagicMock()
        mock_disc.get_db_credentials.return_value = {
            "host": "auto-h",
            "user": "auto-u",
            "password": "auto-p",
            "database": "openemr",
        }
        mock_disc_cls.return_value = mock_disc

        mock_db = MagicMock()
        mock_db.connect.return_value = True
        mock_db_cls.return_value = mock_db

        mock_uploader = MagicMock()
        mock_uploader.process_and_upload.return_value = {
            "processed": 0,
            "uploaded": 0,
            "failed": 0,
            "skipped": 0,
            "duration": 0,
        }
        mock_up_cls.return_value = mock_uploader

        args = argparse.Namespace(
            db_host=None,
            db_user=None,
            db_password=None,
            db_name="openemr",
            namespace="openemr",
            terraform_dir=None,
            data_source="/tmp",
            batch_size=None,
            max_records=None,
            start_from=0,
            workers=None,
            aws_region="us-east-1",
            dry_run=False,
            verbose=False,
        )

        result = CCDADataUploadCommand().execute(args)
        assert result == 0
        mock_db_cls.assert_called_with(db_host="auto-h", db_user="auto-u", db_password="auto-p", db_name="openemr")

    @patch("warp.commands.ccda_data_upload.CredentialDiscovery")
    def test_discovery_failure_returns_1(self, mock_disc_cls):
        mock_disc = MagicMock()
        mock_disc.get_db_credentials.return_value = None
        mock_disc_cls.return_value = mock_disc

        args = argparse.Namespace(
            db_host=None,
            db_user=None,
            db_password=None,
            db_name="openemr",
            namespace="openemr",
            terraform_dir=None,
            data_source="/tmp",
            batch_size=None,
            max_records=None,
            start_from=0,
            workers=None,
            aws_region="us-east-1",
            dry_run=False,
            verbose=False,
        )

        result = CCDADataUploadCommand().execute(args)
        assert result == 1
