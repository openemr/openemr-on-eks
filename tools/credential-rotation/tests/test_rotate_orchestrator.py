"""Tests for the main rotation orchestrator logic in rotate.py.

Covers: rotate() flow, _slot_matches_sqlconf, _ensure_slot_initialized,
_bootstrap_slots_from_sqlconf, _reconcile_active_slot_to_standby,
_rotate_old_slot, _upsert_openemr_db_user, _rotate_admin_password,
_load_admin_secret, sync_db_users, main_json_error.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict
from unittest.mock import MagicMock, patch

import pymysql
import pytest

from credential_rotation.rotate import (
    main_json_error,
)
from credential_rotation.secrets_manager import SecretsManagerSlots, SlotSecretState

from conftest import NoValidateOrchestrator, make_context, make_rds_state, make_slot

_SAMPLE_SQLCONF = """\
<?php
$host = 'db.example.com';
$port = '3306';
$login = 'openemr_a';
$pass  = 'pass_a';
$dbase = 'openemr';
"""

_SAMPLE_SQLCONF_STANDBY = """\
<?php
$host = 'db.example.com';
$port = '3306';
$login = 'openemr_b';
$pass  = 'pass_b';
$dbase = 'openemr';
"""

_SAMPLE_SQLCONF_UNKNOWN = """\
<?php
$host = 'db.example.com';
$port = '3306';
$login = 'admin';
$pass  = 'root_password';
$dbase = 'openemr';
"""


# ---------------------------------------------------------------------------
# _slot_matches_sqlconf
# ---------------------------------------------------------------------------


class TestSlotMatchesSqlconf:
    def test_exact_match(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot = make_slot("a")
        sqlconf = {
            "host": "db.example.com",
            "port": "3306",
            "username": "openemr_a",
            "password": "pass_a",
            "dbname": "openemr",
        }
        assert orch._slot_matches_sqlconf(slot, sqlconf) is True

    def test_mismatch_username(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot = make_slot("a")
        sqlconf = {
            "host": "db.example.com",
            "port": "3306",
            "username": "openemr_b",
            "password": "pass_a",
            "dbname": "openemr",
        }
        assert orch._slot_matches_sqlconf(slot, sqlconf) is False

    def test_mismatch_password(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot = make_slot("a")
        sqlconf = {
            "host": "db.example.com",
            "port": "3306",
            "username": "openemr_a",
            "password": "wrong",
            "dbname": "openemr",
        }
        assert orch._slot_matches_sqlconf(slot, sqlconf) is False

    def test_mismatch_host(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot = make_slot("a")
        sqlconf = {
            "host": "other-host.com",
            "port": "3306",
            "username": "openemr_a",
            "password": "pass_a",
            "dbname": "openemr",
        }
        assert orch._slot_matches_sqlconf(slot, sqlconf) is False

    def test_port_defaults(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot = {"host": "h", "username": "u", "password": "p", "dbname": "d"}
        sqlconf = {"host": "h", "username": "u", "password": "p", "dbname": "d"}
        assert orch._slot_matches_sqlconf(slot, sqlconf) is True

    def test_port_coerced_to_string(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot = {
            "host": "h",
            "port": 3306,
            "username": "u",
            "password": "p",
            "dbname": "d",
        }
        sqlconf = {
            "host": "h",
            "port": "3306",
            "username": "u",
            "password": "p",
            "dbname": "d",
        }
        assert orch._slot_matches_sqlconf(slot, sqlconf) is True


# ---------------------------------------------------------------------------
# _ensure_slot_initialized
# ---------------------------------------------------------------------------


class TestEnsureSlotInitialized:
    def test_fills_missing_fields(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot: Dict[str, Any] = {}
        with patch("credential_rotation.rotate.generate_password", return_value="gen_pwd"):
            orch._ensure_slot_initialized(slot, fallback_host="fb_host", fallback_db="fb_db")
        assert slot["username"] == "openemr_slot"
        assert slot["password"] == "gen_pwd"
        assert slot["host"] == "fb_host"
        assert slot["port"] == "3306"
        assert slot["dbname"] == "fb_db"

    def test_does_not_overwrite_existing_fields(self, tmp_path):
        orch = NoValidateOrchestrator(make_context(tmp_path))
        slot = {
            "username": "existing",
            "password": "existing_pw",
            "host": "my_host",
            "port": "5432",
            "dbname": "my_db",
        }
        orch._ensure_slot_initialized(slot, fallback_host="fb_host", fallback_db="fb_db")
        assert slot["username"] == "existing"
        assert slot["password"] == "existing_pw"
        assert slot["host"] == "my_host"
        assert slot["port"] == "5432"
        assert slot["dbname"] == "my_db"


# ---------------------------------------------------------------------------
# _bootstrap_slots_from_sqlconf
# ---------------------------------------------------------------------------


class TestBootstrapSlotsFromSqlconf:
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.generate_password", side_effect=["pw_a", "pw_b"])
    def test_bootstrap_dry_run_skips_upsert(self, mock_gen, mock_validate, tmp_path):
        ctx = make_context(tmp_path, dry_run=True)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch._upsert_openemr_db_user = MagicMock()

        rds_state = make_rds_state()
        sqlconf = {"host": "h", "port": "3306", "dbname": "openemr"}

        orch._bootstrap_slots_from_sqlconf(sqlconf, rds_state, active="A", standby="B")

        orch._upsert_openemr_db_user.assert_not_called()
        mock_validate.assert_not_called()
        orch.secrets.put_payload.assert_not_called()

    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.generate_password", side_effect=["pw_a", "pw_b"])
    def test_bootstrap_creates_app_users_and_updates_secret(self, mock_gen, mock_validate, tmp_path):
        ctx = make_context(tmp_path, dry_run=False)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch._upsert_openemr_db_user = MagicMock()

        rds_state = make_rds_state()
        sqlconf = {"host": "h", "port": "3306", "dbname": "openemr"}

        orch._bootstrap_slots_from_sqlconf(sqlconf, rds_state, active="A", standby="B")

        assert orch._upsert_openemr_db_user.call_count == 2
        slot_a_arg = orch._upsert_openemr_db_user.call_args_list[0][0][0]
        slot_b_arg = orch._upsert_openemr_db_user.call_args_list[1][0][0]
        assert slot_a_arg["username"] == "openemr_a"
        assert slot_a_arg["password"] == "pw_a"
        assert slot_b_arg["username"] == "openemr_b"
        assert slot_b_arg["password"] == "pw_b"

        orch.secrets.put_payload.assert_called_once()
        payload = orch.secrets.put_payload.call_args[0][1]
        assert payload["active_slot"] == "A"
        assert payload["A"]["username"] == "openemr_a"
        assert payload["B"]["username"] == "openemr_b"


# ---------------------------------------------------------------------------
# _reconcile_active_slot_to_standby
# ---------------------------------------------------------------------------


class TestReconcileActiveSlotToStandby:
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    def test_reconcile_flips_active_and_rotates_old(self, mock_gen, mock_validate, tmp_path):
        ctx = make_context(tmp_path, dry_run=False)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch._upsert_openemr_db_user = MagicMock()

        rds_state = make_rds_state(active="A")
        orch.secrets.get_secret.return_value = rds_state
        orch.secrets.standby_slot = SecretsManagerSlots.standby_slot

        orch._reconcile_active_slot_to_standby(rds_state, active="A", standby="B")

        orch.secrets.put_payload.assert_called()
        first_put = orch.secrets.put_payload.call_args_list[0]
        assert first_put[0][1]["active_slot"] == "B"

    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    def test_reconcile_dry_run_skips_put(self, mock_gen, mock_validate, tmp_path):
        ctx = make_context(tmp_path, dry_run=True)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch._upsert_openemr_db_user = MagicMock()

        rds_state = make_rds_state(active="A")
        orch.secrets.get_secret.return_value = rds_state
        orch.secrets.standby_slot = SecretsManagerSlots.standby_slot

        orch._reconcile_active_slot_to_standby(rds_state, active="A", standby="B")

        orch.secrets.put_payload.assert_not_called()


# ---------------------------------------------------------------------------
# _rotate_old_slot
# ---------------------------------------------------------------------------


class TestRotateOldSlot:
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.generate_password", return_value="rotated_pw")
    def test_dry_run_does_not_mutate(self, mock_gen, mock_validate, tmp_path):
        ctx = make_context(tmp_path, dry_run=True)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch.secrets.get_secret.return_value = make_rds_state()
        orch._upsert_openemr_db_user = MagicMock()

        orch._rotate_old_slot(new_active="A", old_slot="B")

        orch._upsert_openemr_db_user.assert_not_called()
        mock_validate.assert_not_called()
        orch.secrets.put_payload.assert_not_called()

    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.generate_password", return_value="rotated_pw")
    def test_rotates_old_slot_password(self, mock_gen, mock_validate, tmp_path):
        ctx = make_context(tmp_path, dry_run=False)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch.secrets.get_secret.return_value = make_rds_state()
        orch._upsert_openemr_db_user = MagicMock()

        orch._rotate_old_slot(new_active="A", old_slot="B")

        orch._upsert_openemr_db_user.assert_called_once()
        upserted_slot = orch._upsert_openemr_db_user.call_args[0][0]
        assert upserted_slot["password"] == "rotated_pw"

        mock_validate.assert_called_once()

        orch.secrets.put_payload.assert_called_once()
        payload = orch.secrets.put_payload.call_args[0][1]
        assert payload["active_slot"] == "A"
        assert payload["B"]["password"] == "rotated_pw"


# ---------------------------------------------------------------------------
# _upsert_openemr_db_user
# ---------------------------------------------------------------------------


class TestUpsertOpenemrDbUser:
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_upsert_creates_and_grants(self, mock_connect, tmp_path, mock_pymysql_conn):
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)

        mock_conn, mock_cursor = mock_pymysql_conn
        mock_connect.return_value = mock_conn

        admin = {
            "host": "admin-host",
            "port": 3306,
            "username": "admin",
            "password": "admin_pw",
        }
        orch._load_admin_secret = MagicMock(return_value=admin)

        slot = {
            "host": "db.example.com",
            "port": "3306",
            "username": "openemr_a",
            "password": "pass_a",
            "dbname": "openemr",
        }
        orch._upsert_openemr_db_user(slot)

        assert mock_cursor.execute.call_count == 4
        create_call = mock_cursor.execute.call_args_list[0]
        assert "CREATE USER" in create_call[0][0]
        alter_call = mock_cursor.execute.call_args_list[1]
        assert "ALTER USER" in alter_call[0][0]
        grant_call = mock_cursor.execute.call_args_list[2]
        assert "GRANT ALL" in grant_call[0][0]
        flush_call = mock_cursor.execute.call_args_list[3]
        assert "FLUSH PRIVILEGES" in flush_call[0][0]

    @patch("credential_rotation.rotate.pymysql.connect")
    def test_upsert_rejects_unsafe_dbname(self, mock_connect, tmp_path):
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)
        orch._load_admin_secret = MagicMock(return_value={"host": "h", "port": 3306, "username": "a", "password": "p"})

        slot = {
            "host": "h",
            "port": "3306",
            "username": "u",
            "password": "p",
            "dbname": "openemr; DROP TABLE",
        }
        with pytest.raises(ValueError, match="Unsupported dbname"):
            orch._upsert_openemr_db_user(slot)

    @patch("credential_rotation.rotate.pymysql.connect")
    def test_upsert_closes_connection_on_error(self, mock_connect, tmp_path):
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)
        orch._load_admin_secret = MagicMock(return_value={"host": "h", "port": 3306, "username": "a", "password": "p"})

        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = pymysql.OperationalError("fail")
        mock_conn = MagicMock()
        mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
        mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)
        mock_connect.return_value = mock_conn

        slot = {
            "host": "h",
            "port": "3306",
            "username": "u",
            "password": "p",
            "dbname": "openemr",
        }
        with pytest.raises(pymysql.OperationalError):
            orch._upsert_openemr_db_user(slot)

        mock_conn.close.assert_called_once()


# ---------------------------------------------------------------------------
# _load_admin_secret
# ---------------------------------------------------------------------------


class TestLoadAdminSecret:
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_returns_admin_when_password_works(self, mock_connect, tmp_path):
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()

        admin_payload = {
            "host": "h",
            "port": 3306,
            "username": "admin",
            "password": "good_pw",
        }
        orch.secrets.get_secret.return_value = SlotSecretState(secret_arn="arn:admin", payload=admin_payload)

        mock_conn = MagicMock()
        mock_connect.return_value = mock_conn

        result = orch._load_admin_secret()
        assert result["password"] == "good_pw"
        mock_conn.close.assert_called_once()

    @patch("credential_rotation.rotate.pymysql.connect")
    def test_tries_slot_passwords_on_drift(self, mock_connect, tmp_path):
        """When the admin secret's password is stale, fall back to slot passwords."""
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()

        admin_payload = {
            "host": "h",
            "port": 3306,
            "username": "admin",
            "password": "stale_pw",
        }
        slot_a = {"username": "admin", "password": "slot_a_pw"}
        slot_b = {"username": "other_user", "password": "slot_b_pw"}
        rds_state = SlotSecretState(
            secret_arn="arn:slots",
            payload={"active_slot": "A", "A": slot_a, "B": slot_b},
        )
        orch.secrets.get_secret.side_effect = [
            SlotSecretState(secret_arn="arn:admin", payload=admin_payload),
            rds_state,
        ]

        connect_calls = [0]

        def connect_side_effect(**kwargs):
            connect_calls[0] += 1
            if connect_calls[0] == 1:
                raise pymysql.OperationalError("auth failed")
            return MagicMock()

        mock_connect.side_effect = connect_side_effect

        result = orch._load_admin_secret()
        assert result["password"] == "slot_a_pw"
        orch.secrets.put_payload.assert_called_once()

    @patch("credential_rotation.rotate.pymysql.connect")
    def test_raises_when_no_password_works(self, mock_connect, tmp_path):
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()

        admin_payload = {
            "host": "h",
            "port": 3306,
            "username": "admin",
            "password": "bad_pw",
        }
        rds_state = SlotSecretState(
            secret_arn="arn:slots",
            payload={
                "active_slot": "A",
                "A": {"username": "other", "password": "x"},
                "B": {"username": "other2", "password": "y"},
            },
        )
        orch.secrets.get_secret.side_effect = [
            SlotSecretState(secret_arn="arn:admin", payload=admin_payload),
            rds_state,
        ]
        mock_connect.side_effect = pymysql.OperationalError("auth failed")

        with pytest.raises(RuntimeError, match="Admin credentials in RDS admin secret are invalid"):
            orch._load_admin_secret()


# ---------------------------------------------------------------------------
# _rotate_admin_password
# ---------------------------------------------------------------------------


class TestRotateAdminPassword:
    @patch("credential_rotation.rotate.generate_password", return_value="new_admin_pw")
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_rotates_admin_password_successfully(self, mock_connect, mock_gen, tmp_path, mock_pymysql_conn):
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()

        admin = {"host": "h", "port": 3306, "username": "admin", "password": "old_pw"}
        orch._load_admin_secret = MagicMock(return_value=admin)

        mock_conn, mock_cursor = mock_pymysql_conn
        mock_connect.return_value = mock_conn

        orch._rotate_admin_password()

        assert mock_cursor.execute.call_count == 1
        alter_call = mock_cursor.execute.call_args
        assert "ALTER USER" in alter_call[0][0]
        assert alter_call[0][1] == ("admin", "new_admin_pw")

        assert mock_connect.call_count == 2
        orch.secrets.put_payload.assert_called_once()
        payload = orch.secrets.put_payload.call_args[0][1]
        assert payload["password"] == "new_admin_pw"


# ---------------------------------------------------------------------------
# sync_db_users
# ---------------------------------------------------------------------------


class TestSyncDbUsers:
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.generate_password", return_value="gen_pw")
    def test_syncs_both_slots(self, mock_gen, mock_validate, tmp_path):
        ctx = make_context(tmp_path)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch.secrets.get_secret.return_value = make_rds_state()
        orch._upsert_openemr_db_user = MagicMock()

        orch.sync_db_users()

        assert orch._upsert_openemr_db_user.call_count == 2
        assert mock_validate.call_count == 2


# ---------------------------------------------------------------------------
# rotate() – full flow
# ---------------------------------------------------------------------------


class TestRotateFlow:
    def _setup_sqlconf(self, tmp_path: Path, content: str) -> Path:
        default_dir = tmp_path / "default"
        default_dir.mkdir()
        sqlconf = default_dir / "sqlconf.php"
        sqlconf.write_text(content)
        return sqlconf

    def _make_orch(self, tmp_path, dry_run=False):
        ctx = make_context(tmp_path, dry_run=dry_run)
        orch = NoValidateOrchestrator(ctx)
        orch.secrets = MagicMock()
        orch.secrets.standby_slot = SecretsManagerSlots.standby_slot
        return orch

    def _setup_secrets(self, orch, rds_state):
        """Configure secrets mock to return proper data for both slots and admin secrets."""
        admin_state = SlotSecretState(
            secret_arn="arn:admin",
            payload={
                "host": "db.example.com",
                "port": 3306,
                "username": "admin",
                "password": "admin_pw",
            },
        )

        def get_secret_side_effect(secret_id):
            if secret_id == orch.ctx.rds_admin_secret_id:
                return admin_state
            return rds_state

        orch.secrets.get_secret.side_effect = get_secret_side_effect

    @patch("credential_rotation.rotate.rollout_restart_deployment")
    @patch("credential_rotation.rotate.update_k8s_db_secret")
    @patch("credential_rotation.rotate.atomic_write")
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.validate_openemr_health")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_dry_run_returns_early(
        self,
        mock_pymysql,
        mock_gen,
        mock_health,
        mock_rds_validate,
        mock_atomic,
        mock_k8s,
        mock_rollout,
        tmp_path,
        mock_pymysql_conn,
    ):
        self._setup_sqlconf(tmp_path, _SAMPLE_SQLCONF)
        orch = self._make_orch(tmp_path, dry_run=True)
        self._setup_secrets(orch, make_rds_state())

        mock_conn, _ = mock_pymysql_conn
        mock_pymysql.return_value = mock_conn

        orch.rotate()

        mock_atomic.assert_not_called()
        mock_k8s.assert_not_called()
        mock_rollout.assert_not_called()

    @patch("credential_rotation.rotate.rollout_restart_deployment")
    @patch("credential_rotation.rotate.update_k8s_db_secret")
    @patch("credential_rotation.rotate.atomic_write")
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.validate_openemr_health")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_normal_rotation_active_a(
        self,
        mock_pymysql,
        mock_gen,
        mock_health,
        mock_rds_validate,
        mock_atomic,
        mock_k8s,
        mock_rollout,
        tmp_path,
        mock_pymysql_conn,
    ):
        """Config matches active slot A; should rotate to standby slot B."""
        self._setup_sqlconf(tmp_path, _SAMPLE_SQLCONF)
        orch = self._make_orch(tmp_path, dry_run=False)
        self._setup_secrets(orch, make_rds_state(active="A"))

        mock_conn, _ = mock_pymysql_conn
        mock_pymysql.return_value = mock_conn

        orch.rotate()

        mock_atomic.assert_called_once()
        mock_k8s.assert_called()
        mock_rollout.assert_called()

        flip_calls = [c for c in orch.secrets.put_payload.call_args_list if c[0][1].get("active_slot") == "B"]
        assert len(flip_calls) >= 1

    @patch("credential_rotation.rotate.rollout_restart_deployment")
    @patch("credential_rotation.rotate.update_k8s_db_secret")
    @patch("credential_rotation.rotate.atomic_write")
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.validate_openemr_health")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_bootstrap_when_neither_slot_matches(
        self,
        mock_pymysql,
        mock_gen,
        mock_health,
        mock_rds_validate,
        mock_atomic,
        mock_k8s,
        mock_rollout,
        tmp_path,
        mock_pymysql_conn,
    ):
        """When sqlconf doesn't match either slot, bootstrap both slots."""
        self._setup_sqlconf(tmp_path, _SAMPLE_SQLCONF_UNKNOWN)
        orch = self._make_orch(tmp_path, dry_run=False)

        initial_state = make_rds_state(active="A")
        admin_state = SlotSecretState(
            secret_arn="arn:admin",
            payload={
                "host": "db.example.com",
                "port": 3306,
                "username": "admin",
                "password": "admin_pw",
            },
        )
        post_bootstrap_state = make_rds_state(
            active="A",
            slot_a={
                "host": "db.example.com",
                "port": "3306",
                "username": "openemr_a",
                "password": "new_pw",
                "dbname": "openemr",
            },
            slot_b={
                "host": "db.example.com",
                "port": "3306",
                "username": "openemr_b",
                "password": "new_pw",
                "dbname": "openemr",
            },
        )

        call_count = [0]

        def get_secret_side_effect(secret_id):
            if secret_id == orch.ctx.rds_admin_secret_id:
                return admin_state
            call_count[0] += 1
            if call_count[0] <= 1:
                return initial_state
            return post_bootstrap_state

        orch.secrets.get_secret.side_effect = get_secret_side_effect

        mock_conn, _ = mock_pymysql_conn
        mock_pymysql.return_value = mock_conn

        orch.rotate()

        assert orch.secrets.put_payload.call_count >= 1

    @patch("credential_rotation.rotate.rollout_restart_deployment")
    @patch("credential_rotation.rotate.update_k8s_db_secret")
    @patch("credential_rotation.rotate.atomic_write")
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.validate_openemr_health")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_reconcile_when_standby_matches(
        self,
        mock_pymysql,
        mock_gen,
        mock_health,
        mock_rds_validate,
        mock_atomic,
        mock_k8s,
        mock_rollout,
        tmp_path,
        mock_pymysql_conn,
    ):
        """When sqlconf matches the standby slot, reconcile (flip active_slot)."""
        self._setup_sqlconf(tmp_path, _SAMPLE_SQLCONF_STANDBY)
        orch = self._make_orch(tmp_path, dry_run=False)
        self._setup_secrets(orch, make_rds_state(active="A"))

        mock_conn, _ = mock_pymysql_conn
        mock_pymysql.return_value = mock_conn

        orch.rotate()

        flip_calls = [c for c in orch.secrets.put_payload.call_args_list if c[0][1].get("active_slot") == "B"]
        assert len(flip_calls) >= 1

    @patch("credential_rotation.rotate.rollout_restart_deployment")
    @patch("credential_rotation.rotate.update_k8s_db_secret")
    @patch("credential_rotation.rotate.atomic_write")
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.validate_openemr_health")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_rollback_triggered_on_failure(
        self,
        mock_pymysql,
        mock_gen,
        mock_health,
        mock_rds_validate,
        mock_atomic,
        mock_k8s,
        mock_rollout,
        tmp_path,
        mock_pymysql_conn,
    ):
        """Verify rollback is triggered when an exception occurs during rotation."""
        self._setup_sqlconf(tmp_path, _SAMPLE_SQLCONF)
        orch = self._make_orch(tmp_path, dry_run=False)
        self._setup_secrets(orch, make_rds_state(active="A"))

        mock_conn, _ = mock_pymysql_conn
        mock_pymysql.return_value = mock_conn

        mock_k8s.side_effect = RuntimeError("K8s patch failed")

        with pytest.raises(RuntimeError, match="K8s patch failed"):
            orch.rotate()

        assert mock_atomic.call_count == 2

    @patch("credential_rotation.rotate.rollout_restart_deployment")
    @patch("credential_rotation.rotate.update_k8s_db_secret")
    @patch("credential_rotation.rotate.atomic_write")
    @patch("credential_rotation.rotate.validate_rds_connection")
    @patch("credential_rotation.rotate.validate_openemr_health")
    @patch("credential_rotation.rotate.generate_password", return_value="new_pw")
    @patch("credential_rotation.rotate.pymysql.connect")
    def test_active_b_rotates_old_slot_only(
        self,
        mock_pymysql,
        mock_gen,
        mock_health,
        mock_rds_validate,
        mock_atomic,
        mock_k8s,
        mock_rollout,
        tmp_path,
        mock_pymysql_conn,
    ):
        """When config matches active B, just rotate the old slot (A) — no flip."""
        sqlconf_b = """\
<?php
$host = 'db.example.com';
$port = '3306';
$login = 'openemr_b';
$pass  = 'pass_b';
$dbase = 'openemr';
"""
        self._setup_sqlconf(tmp_path, sqlconf_b)
        orch = self._make_orch(tmp_path, dry_run=False)
        self._setup_secrets(orch, make_rds_state(active="B"))

        mock_conn, _ = mock_pymysql_conn
        mock_pymysql.return_value = mock_conn

        orch.rotate()

        mock_atomic.assert_not_called()
        mock_k8s.assert_not_called()


# ---------------------------------------------------------------------------
# main_json_error
# ---------------------------------------------------------------------------


class TestMainJsonError:
    def test_formats_error_as_json(self):
        import json

        result = main_json_error(RuntimeError("boom"))
        parsed = json.loads(result)
        assert parsed["status"] == "error"
        assert parsed["error"] == "boom"

    def test_handles_empty_message(self):
        import json

        result = main_json_error(Exception(""))
        parsed = json.loads(result)
        assert parsed["status"] == "error"
        assert parsed["error"] == ""
