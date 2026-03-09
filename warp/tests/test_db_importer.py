"""Tests for warp/core/db_importer.py — direct database import logic."""

from unittest.mock import patch, MagicMock

import pymysql
import pytest

from warp.core.db_importer import OpenEMRDBImporter


@pytest.fixture()
def importer():
    return OpenEMRDBImporter(db_host="localhost", db_user="root", db_password="pw", db_name="openemr")


@pytest.fixture()
def connected_importer(importer):
    """Importer with a mocked connection already attached."""
    mock_conn = MagicMock()
    importer.connection = mock_conn
    return importer


class TestInit:
    def test_stores_connection_params(self, importer):
        assert importer.db_host == "localhost"
        assert importer.db_user == "root"
        assert importer.db_password == "pw"
        assert importer.db_name == "openemr"
        assert importer.connection is None

    def test_default_db_name(self):
        imp = OpenEMRDBImporter(db_host="h", db_user="u", db_password="p")
        assert imp.db_name == "openemr"


class TestConnect:
    @patch("warp.core.db_importer.pymysql.connect")
    def test_connect_success(self, mock_connect, importer):
        mock_connect.return_value = MagicMock()
        assert importer.connect() is True
        assert importer.connection is not None
        mock_connect.assert_called_once_with(
            host="localhost",
            user="root",
            password="pw",
            database="openemr",
            charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=False,
        )

    @patch("warp.core.db_importer.pymysql.connect")
    def test_connect_failure(self, mock_connect, importer):
        mock_connect.side_effect = pymysql.OperationalError("refused")
        assert importer.connect() is False
        assert importer.connection is None


class TestDisconnect:
    def test_disconnect_closes_connection(self, connected_importer):
        connected_importer.disconnect()
        connected_importer.connection.close.assert_called_once()

    def test_disconnect_noop_when_not_connected(self, importer):
        importer.disconnect()


class TestGetNextPid:
    def test_returns_max_plus_one(self, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.fetchone.return_value = {"max_pid": 42}
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        assert connected_importer._get_next_pid() == 43

    def test_returns_1_when_table_empty(self, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.fetchone.return_value = {"max_pid": None}
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        assert connected_importer._get_next_pid() == 1

    def test_propagates_db_error(self, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = pymysql.OperationalError("fail")
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        with pytest.raises(pymysql.OperationalError):
            connected_importer._get_next_pid()


class TestGenerateUuid:
    def test_returns_16_bytes(self, importer):
        result = importer._generate_uuid()
        assert isinstance(result, bytes)
        assert len(result) == 16

    def test_uuids_are_unique(self, importer):
        a = importer._generate_uuid()
        b = importer._generate_uuid()
        assert a != b


class TestImportPatient:
    def test_returns_none_when_not_connected(self, importer):
        result = importer.import_patient(person_data={"PERSON_ID": "1"})
        assert result is None

    @patch.object(OpenEMRDBImporter, "_generate_uuid", return_value=b"\x00" * 16)
    @patch.object(OpenEMRDBImporter, "_get_next_pid", return_value=100)
    def test_successful_import_returns_pid(self, mock_pid, mock_uuid, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.fetchone.side_effect = [
            {"option_id": "standard"},
            {"uuid": b"\x00" * 16},
        ]
        mock_cursor.lastrowid = 1
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        person = {
            "PERSON_ID": "123456",
            "YEAR_OF_BIRTH": "1990",
            "MONTH_OF_BIRTH": "6",
            "DAY_OF_BIRTH": "15",
            "GENDER_CONCEPT_ID": "8507",
        }

        result = connected_importer.import_patient(person_data=person)
        assert result == 100
        connected_importer.connection.commit.assert_called_once()

    @patch.object(OpenEMRDBImporter, "_generate_uuid", return_value=b"\x00" * 16)
    @patch.object(OpenEMRDBImporter, "_get_next_pid", return_value=1)
    def test_invalid_dob_uses_default(self, mock_pid, mock_uuid, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.fetchone.side_effect = [{"option_id": "standard"}, {"uuid": b"\x00" * 16}]
        mock_cursor.lastrowid = 1
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        person = {"PERSON_ID": "1", "YEAR_OF_BIRTH": "2000", "MONTH_OF_BIRTH": "13", "DAY_OF_BIRTH": "32"}

        result = connected_importer.import_patient(person_data=person)
        assert result == 1
        insert_call = mock_cursor.execute.call_args_list[1]
        dob_arg = insert_call[0][1][7]
        assert dob_arg == "1900-01-01"

    @patch.object(OpenEMRDBImporter, "_generate_uuid", return_value=b"\x00" * 16)
    @patch.object(OpenEMRDBImporter, "_get_next_pid", return_value=1)
    def test_gender_mapping(self, mock_pid, mock_uuid, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.fetchone.side_effect = [{"option_id": "standard"}, {"uuid": b"\x00" * 16}]
        mock_cursor.lastrowid = 1
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        for concept_id, expected_sex in [("8507", "Male"), ("8532", "Female"), ("9999", "Other")]:
            mock_cursor.reset_mock()
            mock_cursor.fetchone.side_effect = [{"option_id": "standard"}, {"uuid": b"\x00" * 16}]
            mock_cursor.lastrowid = 1

            person = {"PERSON_ID": "1", "GENDER_CONCEPT_ID": concept_id}
            connected_importer.import_patient(person_data=person)

            insert_call = mock_cursor.execute.call_args_list[1]
            sex_arg = insert_call[0][1][6]
            assert sex_arg == expected_sex, f"concept_id={concept_id}"

    @patch.object(OpenEMRDBImporter, "_generate_uuid", return_value=b"\x00" * 16)
    @patch.object(OpenEMRDBImporter, "_get_next_pid", return_value=1)
    def test_uuid_updated_when_not_set(self, mock_pid, mock_uuid, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.fetchone.side_effect = [
            {"option_id": "standard"},
            {"uuid": None},
        ]
        mock_cursor.lastrowid = 5
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        connected_importer.import_patient(person_data={"PERSON_ID": "1"})

        update_calls = [c for c in mock_cursor.execute.call_args_list if "UPDATE patient_data SET uuid" in str(c)]
        assert len(update_calls) == 1

    @patch.object(OpenEMRDBImporter, "_generate_uuid", return_value=b"\x00" * 16)
    @patch.object(OpenEMRDBImporter, "_get_next_pid", side_effect=pymysql.OperationalError("fail"))
    def test_rollback_on_error(self, mock_pid, mock_uuid, connected_importer):
        result = connected_importer.import_patient(person_data={"PERSON_ID": "1"})
        assert result is None
        connected_importer.connection.rollback.assert_called_once()

    @patch.object(OpenEMRDBImporter, "_generate_uuid", return_value=b"\x00" * 16)
    @patch.object(OpenEMRDBImporter, "_get_next_pid", return_value=1)
    def test_pricelevel_defaults_to_standard(self, mock_pid, mock_uuid, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.fetchone.side_effect = [None, {"uuid": b"\x00" * 16}]
        mock_cursor.lastrowid = 1
        connected_importer.connection.cursor.return_value.__enter__ = lambda s: mock_cursor
        connected_importer.connection.cursor.return_value.__exit__ = MagicMock(return_value=False)

        connected_importer.import_patient(person_data={"PERSON_ID": "1"})

        insert_call = mock_cursor.execute.call_args_list[1]
        pricelevel_arg = insert_call[0][1][-1]
        assert pricelevel_arg == "standard"


class TestImportCondition:
    def test_inserts_condition_with_valid_date(self, connected_importer):
        mock_cursor = MagicMock()
        condition = {"CONDITION_START_DATE": "2023-06-15", "CONDITION_CONCEPT_ID": "12345"}

        connected_importer._import_condition(mock_cursor, pid=1, condition=condition)
        mock_cursor.execute.assert_called_once()
        args = mock_cursor.execute.call_args[0][1]
        assert args[0] == 1
        assert args[1] == "medical_problem"
        assert args[4] is None
        assert args[5] == "12345"

    def test_handles_invalid_date(self, connected_importer):
        mock_cursor = MagicMock()
        condition = {"CONDITION_START_DATE": "not-a-date", "CONDITION_CONCEPT_ID": "99"}

        connected_importer._import_condition(mock_cursor, pid=1, condition=condition)
        mock_cursor.execute.assert_called_once()
        args = mock_cursor.execute.call_args[0][1]
        assert args[3] is None

    def test_handles_missing_fields(self, connected_importer):
        mock_cursor = MagicMock()
        connected_importer._import_condition(mock_cursor, pid=1, condition={})
        mock_cursor.execute.assert_called_once()

    def test_swallows_exception(self, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = Exception("db error")
        connected_importer._import_condition(mock_cursor, pid=1, condition={})


class TestImportMedication:
    def test_inserts_medication_with_valid_date(self, connected_importer):
        mock_cursor = MagicMock()
        med = {"DRUG_EXPOSURE_START_DATE": "2023-01-01", "DRUG_CONCEPT_ID": "555"}

        connected_importer._import_medication(mock_cursor, pid=2, medication=med)
        mock_cursor.execute.assert_called_once()
        args = mock_cursor.execute.call_args[0][1]
        assert args[0] == 2
        assert args[1] == "medication"
        assert args[5] == "555"

    def test_handles_invalid_date(self, connected_importer):
        mock_cursor = MagicMock()
        connected_importer._import_medication(mock_cursor, pid=1, medication={"DRUG_EXPOSURE_START_DATE": "bad"})
        args = mock_cursor.execute.call_args[0][1]
        assert args[3] is None

    def test_swallows_exception(self, connected_importer):
        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = Exception("db error")
        connected_importer._import_medication(mock_cursor, pid=1, medication={})


class TestImportObservation:
    def test_is_noop_placeholder(self, connected_importer):
        mock_cursor = MagicMock()
        connected_importer._import_observation(mock_cursor, pid=1, observation={"some": "data"})
        mock_cursor.execute.assert_not_called()


class TestImportBatch:
    @patch.object(OpenEMRDBImporter, "import_patient")
    def test_counts_successes_and_failures(self, mock_import, connected_importer):
        mock_import.side_effect = [1, None, 3]

        patients = [
            {"person_data": {"PERSON_ID": "1"}},
            {"person_data": {"PERSON_ID": "2"}},
            {"person_data": {"PERSON_ID": "3"}},
        ]

        stats = connected_importer.import_batch(patients)
        assert stats["processed"] == 3
        assert stats["imported"] == 2
        assert stats["failed"] == 1

    @patch.object(OpenEMRDBImporter, "import_patient")
    def test_handles_exception_in_import(self, mock_import, connected_importer):
        mock_import.side_effect = RuntimeError("crash")

        stats = connected_importer.import_batch([{"person_data": {}}])
        assert stats["processed"] == 1
        assert stats["failed"] == 1
        assert stats["imported"] == 0

    def test_empty_batch(self, connected_importer):
        stats = connected_importer.import_batch([])
        assert stats == {"processed": 0, "imported": 0, "failed": 0}
