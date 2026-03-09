"""Shared pytest fixtures for credential-rotation tests."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict
from unittest.mock import MagicMock

import pytest

from credential_rotation.rotate import RotationContext, RotationOrchestrator
from credential_rotation.secrets_manager import SlotSecretState

# ---------------------------------------------------------------------------
# Orchestrator subclass that stubs _validate_runtime
# ---------------------------------------------------------------------------


class NoValidateOrchestrator(RotationOrchestrator):
    """Orchestrator subclass that stubs _validate_runtime for unit tests."""

    def _validate_runtime(self, rds_slot):
        pass


# ---------------------------------------------------------------------------
# Factory helpers
# ---------------------------------------------------------------------------


def make_context(tmp_path: Path, dry_run: bool = False, health_url: str | None = None) -> RotationContext:
    return RotationContext(
        region="us-east-1",
        rds_slots_secret_id="arn:slots",
        rds_admin_secret_id="arn:admin",
        sites_mount_root=str(tmp_path),
        k8s_namespace="openemr",
        k8s_deployment_name="openemr",
        k8s_secret_name="openemr-db-credentials",
        openemr_health_url=health_url,
        dry_run=dry_run,
    )


def make_slot(
    name: str = "a",
    host: str = "db.example.com",
    port: str = "3306",
    dbname: str = "openemr",
) -> Dict[str, Any]:
    return {
        "host": host,
        "port": port,
        "username": f"openemr_{name}",
        "password": f"pass_{name}",
        "dbname": dbname,
    }


def make_rds_state(active: str = "A", slot_a: dict | None = None, slot_b: dict | None = None) -> SlotSecretState:
    return SlotSecretState(
        secret_arn="arn:slots",
        payload={
            "active_slot": active,
            "A": slot_a or make_slot("a"),
            "B": slot_b or make_slot("b"),
        },
    )


# ---------------------------------------------------------------------------
# Mock pymysql connection + cursor (the most commonly duplicated pattern)
# ---------------------------------------------------------------------------


@pytest.fixture()
def mock_pymysql_conn():
    """Return a (mock_connect, mock_conn, mock_cursor) triple.

    Usage in tests that patch ``pymysql.connect``::

        @patch("credential_rotation.rotate.pymysql.connect")
        def test_something(self, patch_connect, mock_pymysql_conn):
            mock_connect, mock_conn, mock_cursor = mock_pymysql_conn
            patch_connect.return_value = mock_conn
            ...
    """
    mock_cursor = MagicMock()
    mock_conn = MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)
    return mock_conn, mock_cursor
