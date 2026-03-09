"""Extended tests for validators.py — validate_rds_connection and health check edge cases."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pymysql
import pytest

from credential_rotation.validators import (
    ValidationError,
    validate_openemr_health,
    validate_rds_connection,
)

# ---------------------------------------------------------------------------
# validate_rds_connection
# ---------------------------------------------------------------------------


class TestValidateRdsConnection:
    @patch("credential_rotation.validators.pymysql.connect")
    def test_success(self, mock_connect, mock_pymysql_conn):
        mock_conn, mock_cursor = mock_pymysql_conn
        mock_cursor.fetchone.return_value = (1,)
        mock_connect.return_value = mock_conn

        slot = {
            "host": "db.example.com",
            "username": "user",
            "password": "pw",
            "dbname": "openemr",
            "port": 3306,
        }
        validate_rds_connection(slot)

        mock_connect.assert_called_once()
        mock_conn.close.assert_called_once()

    @patch("credential_rotation.validators.pymysql.connect")
    def test_connection_failure_propagates(self, mock_connect):
        mock_connect.side_effect = pymysql.OperationalError("Connection refused")
        slot = {"host": "h", "username": "u", "password": "p", "dbname": "d"}
        with pytest.raises(pymysql.OperationalError, match="Connection refused"):
            validate_rds_connection(slot)

    @patch("credential_rotation.validators.pymysql.connect")
    def test_unexpected_query_result_raises_validation_error(self, mock_connect, mock_pymysql_conn):
        mock_conn, mock_cursor = mock_pymysql_conn
        mock_cursor.fetchone.return_value = (0,)
        mock_connect.return_value = mock_conn

        slot = {"host": "h", "username": "u", "password": "p", "dbname": "d"}
        with pytest.raises(ValidationError, match="unexpected result"):
            validate_rds_connection(slot)

    @patch("credential_rotation.validators.pymysql.connect")
    def test_null_result_raises_validation_error(self, mock_connect, mock_pymysql_conn):
        mock_conn, mock_cursor = mock_pymysql_conn
        mock_cursor.fetchone.return_value = None
        mock_connect.return_value = mock_conn

        slot = {"host": "h", "username": "u", "password": "p", "dbname": "d"}
        with pytest.raises(ValidationError, match="unexpected result"):
            validate_rds_connection(slot)

    @patch("credential_rotation.validators.pymysql.connect")
    def test_ssl_disabled_when_ssl_required_false(self, mock_connect, mock_pymysql_conn):
        mock_conn, mock_cursor = mock_pymysql_conn
        mock_cursor.fetchone.return_value = (1,)
        mock_connect.return_value = mock_conn

        slot = {
            "host": "h",
            "username": "u",
            "password": "p",
            "dbname": "d",
            "ssl_required": False,
        }
        validate_rds_connection(slot)

        call_kwargs = mock_connect.call_args.kwargs
        assert call_kwargs.get("ssl") is None

    @patch("credential_rotation.validators.pymysql.connect")
    def test_ssl_enabled_by_default(self, mock_connect, mock_pymysql_conn):
        mock_conn, mock_cursor = mock_pymysql_conn
        mock_cursor.fetchone.return_value = (1,)
        mock_connect.return_value = mock_conn

        slot = {"host": "h", "username": "u", "password": "p", "dbname": "d"}
        validate_rds_connection(slot)

        call_kwargs = mock_connect.call_args.kwargs
        assert call_kwargs.get("ssl") == {"ssl": {}}

    @patch("credential_rotation.validators.pymysql.connect")
    def test_default_port(self, mock_connect, mock_pymysql_conn):
        mock_conn, mock_cursor = mock_pymysql_conn
        mock_cursor.fetchone.return_value = (1,)
        mock_connect.return_value = mock_conn

        slot = {"host": "h", "username": "u", "password": "p", "dbname": "d"}
        validate_rds_connection(slot)

        call_kwargs = mock_connect.call_args.kwargs
        assert call_kwargs["port"] == 3306


# ---------------------------------------------------------------------------
# validate_openemr_health – additional cases
# ---------------------------------------------------------------------------


class TestValidateOpenemrHealthExtended:
    @patch("credential_rotation.validators.requests")
    def test_non_200_status_prints_warning(self, mock_requests, capsys):
        mock_response = MagicMock()
        mock_response.status_code = 500
        mock_requests.get.return_value = mock_response

        validate_openemr_health("http://example.com/health")
        captured = capsys.readouterr()
        assert "WARNING" in captured.out
        assert "500" in captured.out

    @patch("credential_rotation.validators.requests")
    def test_redirect_301_is_accepted(self, mock_requests):
        mock_response = MagicMock()
        mock_response.status_code = 301
        mock_requests.get.return_value = mock_response

        validate_openemr_health("http://example.com/health")

    @patch("credential_rotation.validators.requests")
    def test_redirect_302_is_accepted(self, mock_requests):
        mock_response = MagicMock()
        mock_response.status_code = 302
        mock_requests.get.return_value = mock_response

        validate_openemr_health("http://example.com/health")

    @patch("credential_rotation.validators.requests")
    def test_timeout_prints_warning(self, mock_requests, capsys):
        mock_requests.get.side_effect = TimeoutError("timed out")
        validate_openemr_health("http://example.com/health")
        captured = capsys.readouterr()
        assert "WARNING" in captured.out
        assert "unreachable" in captured.out

    @patch("credential_rotation.validators.requests")
    def test_custom_timeout(self, mock_requests):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_requests.get.return_value = mock_response

        validate_openemr_health("http://example.com/health", timeout_seconds=30)
        call_kwargs = mock_requests.get.call_args
        assert call_kwargs.kwargs.get("timeout") == 30 or call_kwargs[1].get("timeout") == 30
