"""Extended tests for warp/core/omop_to_ccda.py — load_data, local loading, S3, convert sections."""

import os
from unittest.mock import patch, MagicMock

import pytest

from warp.core.omop_to_ccda import OMOPToCCDAConverter


@pytest.fixture()
def local_converter(tmp_path):
    """Converter backed by a local temp directory."""
    return OMOPToCCDAConverter(data_source=str(tmp_path))


def _write_csv(directory, filename, content):
    with open(os.path.join(str(directory), filename), "w") as f:
        f.write(content)


class TestInitialization:
    def test_local_path_stores_path(self, tmp_path):
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        assert conv.local_path == tmp_path
        assert conv.s3_client is None

    def test_local_path_raises_on_nonexistent(self):
        with pytest.raises(ValueError, match="does not exist"):
            OMOPToCCDAConverter(data_source="/nonexistent/path/12345")

    @patch("warp.core.omop_to_ccda.boto3.client")
    def test_s3_path_creates_client(self, mock_client):
        conv = OMOPToCCDAConverter(data_source="s3://my-bucket/data/prefix")
        mock_client.assert_called_once_with("s3", region_name="us-east-1")
        assert conv.s3_bucket == "my-bucket"
        assert conv.s3_prefix == "data/prefix"

    @patch("warp.core.omop_to_ccda.boto3.client")
    def test_s3_path_bucket_only(self, mock_client):
        conv = OMOPToCCDAConverter(data_source="s3://bucket-only")
        assert conv.s3_bucket == "bucket-only"
        assert conv.s3_prefix == ""


class TestParseS3Path:
    @patch("warp.core.omop_to_ccda.boto3.client")
    def test_parses_bucket_and_prefix(self, mock_client):
        conv = OMOPToCCDAConverter(data_source="s3://b/p/q")
        assert conv.s3_bucket == "b"
        assert conv.s3_prefix == "p/q"


class TestLoadFromLocal:
    def test_loads_csv_from_file(self, tmp_path):
        _write_csv(tmp_path, "MY_TABLE.csv", "col1,col2\na,b\nc,d\n")
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        rows = conv._load_from_local("MY_TABLE")
        assert len(rows) == 2
        assert rows[0]["col1"] == "a"

    def test_raises_on_missing_file(self, tmp_path):
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        with pytest.raises(FileNotFoundError, match="Table file not found"):
            conv._load_from_local("NONEXISTENT")


class TestLoadFromS3:
    @patch("warp.core.omop_to_ccda.boto3.client")
    def test_loads_plain_csv(self, mock_boto_client):
        mock_s3 = MagicMock()
        mock_boto_client.return_value = mock_s3

        csv_bytes = b"person_id,name\n1,Alice\n2,Bob\n"
        mock_s3.get_object.return_value = {"Body": MagicMock(read=lambda: csv_bytes)}

        conv = OMOPToCCDAConverter(data_source="s3://bucket/prefix")
        rows = conv._load_from_s3("PERSON")
        assert len(rows) == 2

    @patch("warp.core.omop_to_ccda.boto3.client")
    def test_loads_bz2_csv(self, mock_boto_client):
        import bz2

        mock_s3 = MagicMock()
        mock_boto_client.return_value = mock_s3

        csv_bytes = bz2.compress(b"person_id,name\n1,Alice\n")

        call_count = [0]

        def get_object_side_effect(**kwargs):
            call_count[0] += 1
            if call_count[0] == 1:
                return {"Body": MagicMock(read=lambda: csv_bytes)}
            raise Exception("not found")

        mock_s3.get_object.side_effect = get_object_side_effect

        conv = OMOPToCCDAConverter(data_source="s3://bucket/prefix")
        rows = conv._load_from_s3("PERSON")
        assert len(rows) == 1

    @patch("warp.core.omop_to_ccda.boto3.client")
    def test_raises_when_not_found(self, mock_boto_client):
        mock_s3 = MagicMock()
        mock_boto_client.return_value = mock_s3
        mock_s3.get_object.side_effect = Exception("NoSuchKey")

        conv = OMOPToCCDAConverter(data_source="s3://bucket/prefix")
        with pytest.raises(FileNotFoundError, match="Could not find"):
            conv._load_from_s3("MISSING_TABLE")


class TestLoadData:
    def test_loads_all_tables(self, tmp_path):
        _write_csv(tmp_path, "PERSON.csv", "person_id,name\n1,Alice\n2,Bob\n")
        _write_csv(tmp_path, "CONDITION_OCCURRENCE.csv", "person_id,condition_concept_id\n1,100\n")
        _write_csv(tmp_path, "DRUG_EXPOSURE.csv", "person_id,drug_concept_id\n2,200\n")
        _write_csv(tmp_path, "OBSERVATION.csv", "person_id,value\n1,ok\n")

        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        data = conv.load_data()

        assert len(data["persons"]) == 2
        assert len(data["conditions"]) == 1
        assert len(data["medications"]) == 1
        assert len(data["observations"]) == 1

    def test_max_records_limits_persons(self, tmp_path):
        _write_csv(tmp_path, "PERSON.csv", "person_id\n1\n2\n3\n4\n5\n")
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        data = conv.load_data(max_records=2)
        assert len(data["persons"]) == 2

    def test_start_from_skips_persons(self, tmp_path):
        _write_csv(tmp_path, "PERSON.csv", "person_id\n1\n2\n3\n")
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        data = conv.load_data(start_from=1)
        assert len(data["persons"]) == 2
        assert data["persons"][0]["person_id"] == "2"

    def test_missing_optional_tables_return_empty(self, tmp_path):
        _write_csv(tmp_path, "PERSON.csv", "person_id\n1\n")
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        data = conv.load_data()

        assert data["conditions"] == []
        assert data["medications"] == []
        assert data["observations"] == []


class TestConvertToCCDAExtended:
    def test_conditions_section_present(self, tmp_path):
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        person = {"person_id": "1", "first_name": "Test", "last_name": "User"}
        conditions = [{"condition_concept_id": "444", "condition_start_date": "2023-01-01"}]

        xml = conv.convert_to_ccda(person, conditions, [], [])
        assert "Problem List" in xml
        assert "444" in xml

    def test_medications_section_present(self, tmp_path):
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        person = {"person_id": "1"}
        meds = [{"drug_concept_id": "555"}]

        xml = conv.convert_to_ccda(person, [], [], meds)
        assert "Medications" in xml
        assert "555" in xml

    def test_address_included(self, tmp_path):
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        person = {"person_id": "1", "address_1": "123 Main St", "city": "Springfield", "state": "IL", "zip": "62701"}

        xml = conv.convert_to_ccda(person, [], [], [])
        assert "123 Main St" in xml
        assert "Springfield" in xml
        assert "IL" in xml
        assert "62701" in xml

    def test_phone_included(self, tmp_path):
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        person = {"person_id": "1", "phone": "555-1234"}

        xml = conv.convert_to_ccda(person, [], [], [])
        assert "tel:555-1234" in xml

    def test_no_sections_for_empty_data(self, tmp_path):
        conv = OMOPToCCDAConverter(data_source=str(tmp_path))
        person = {"person_id": "1"}

        xml = conv.convert_to_ccda(person, [], [], [])
        assert "Problem List" not in xml
        assert "Medications" not in xml
