"""Extended tests for warp/core/uploader.py — non-dry-run, errors, batch processing."""

from unittest.mock import MagicMock

import pytest

from warp.core.uploader import Uploader


@pytest.fixture()
def mock_converter():
    conv = MagicMock()
    conv.load_data.return_value = {
        "persons": [{"person_id": str(i)} for i in range(5)],
        "conditions": [],
        "medications": [],
        "observations": [],
    }
    return conv


@pytest.fixture()
def mock_db_importer():
    return MagicMock()


class TestUploaderInit:
    def test_raises_without_db_importer(self):
        with pytest.raises(ValueError, match="db_importer is required"):
            Uploader(converter=MagicMock(), db_importer=None)

    def test_defaults_workers_to_cpu_count(self, mock_converter, mock_db_importer):
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer)
        assert up.workers >= 1

    def test_custom_workers(self, mock_converter, mock_db_importer):
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, workers=4)
        assert up.workers == 4

    def test_custom_batch_size(self, mock_converter, mock_db_importer):
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, batch_size=50)
        assert up.batch_size == 50


class TestProcessAndUploadDryRun:
    def test_dry_run_counts_all_as_uploaded(self, mock_converter, mock_db_importer):
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, batch_size=10, workers=1)
        stats = up.process_and_upload(dry_run=True)

        assert stats["processed"] == 5
        assert stats["uploaded"] == 5
        assert stats["failed"] == 0
        assert "duration" in stats


class TestProcessAndUploadLive:
    def test_live_calls_import_patient(self, mock_converter, mock_db_importer):
        mock_db_importer.import_patient.return_value = 1
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, batch_size=10, workers=1)

        stats = up.process_and_upload(dry_run=False)
        assert stats["uploaded"] == 5
        assert stats["failed"] == 0
        assert mock_db_importer.import_patient.call_count == 5

    def test_failed_imports_counted(self, mock_converter, mock_db_importer):
        mock_db_importer.import_patient.return_value = None
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, batch_size=10, workers=1)

        stats = up.process_and_upload(dry_run=False)
        assert stats["failed"] == 5
        assert stats["uploaded"] == 0

    def test_mixed_success_and_failure(self, mock_converter, mock_db_importer):
        mock_db_importer.import_patient.side_effect = [1, None, 3, None, 5]
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, batch_size=10, workers=1)

        stats = up.process_and_upload(dry_run=False)
        assert stats["uploaded"] == 3
        assert stats["failed"] == 2


class TestProcessBatch:
    def test_matches_conditions_by_person_id(self, mock_converter, mock_db_importer):
        mock_db_importer.import_patient.return_value = 1
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, batch_size=10, workers=1)

        data = {
            "persons": [{"person_id": "1"}],
            "conditions": [{"person_id": "1", "cid": "100"}, {"person_id": "2", "cid": "200"}],
            "medications": [],
            "observations": [],
        }

        up._process_batch(data["persons"], data, dry_run=False)
        call_kwargs = mock_db_importer.import_patient.call_args
        assert len(call_kwargs.kwargs.get("conditions", call_kwargs[1].get("conditions", []))) == 1

    def test_exception_in_processing_counted_as_failed(self, mock_converter, mock_db_importer):
        mock_db_importer.import_patient.side_effect = RuntimeError("crash")
        up = Uploader(converter=mock_converter, db_importer=mock_db_importer, batch_size=10, workers=1)

        batch = [{"person_id": "1"}]
        data = {"conditions": [], "medications": [], "observations": []}

        batch_stats = up._process_batch(batch, data, dry_run=False)
        assert batch_stats["failed"] == 1
        assert batch_stats["processed"] == 1


class TestProcessAndUploadWithBatching:
    def test_multiple_batches(self, mock_db_importer):
        conv = MagicMock()
        conv.load_data.return_value = {
            "persons": [{"person_id": str(i)} for i in range(10)],
            "conditions": [],
            "medications": [],
            "observations": [],
        }
        mock_db_importer.import_patient.return_value = 1

        up = Uploader(converter=conv, db_importer=mock_db_importer, batch_size=3, workers=1)
        stats = up.process_and_upload(dry_run=False)

        assert stats["processed"] == 10
        assert stats["uploaded"] == 10

    def test_passes_max_records_to_converter(self, mock_db_importer):
        conv = MagicMock()
        conv.load_data.return_value = {"persons": [], "conditions": [], "medications": [], "observations": []}

        up = Uploader(converter=conv, db_importer=mock_db_importer, batch_size=10, workers=1)
        up.process_and_upload(max_records=50, start_from=10, dry_run=True)

        conv.load_data.assert_called_once_with(max_records=50, start_from=10)


class TestProcessAndUploadErrors:
    def test_fatal_error_reraises(self, mock_db_importer):
        conv = MagicMock()
        conv.load_data.side_effect = RuntimeError("data load failed")

        up = Uploader(converter=conv, db_importer=mock_db_importer, batch_size=10, workers=1)
        with pytest.raises(RuntimeError, match="data load failed"):
            up.process_and_upload(dry_run=False)
