"""
OMOP to CCDA Converter - Optimized for performance
Uses minimal dependencies (standard library + boto3)
"""

import logging
import csv
import io
import bz2
from pathlib import Path
from typing import Optional, Dict, List
from xml.etree.ElementTree import Element, SubElement, tostring
from datetime import datetime

import boto3

logger = logging.getLogger(__name__)


class OMOPToCCDAConverter:
    """Converts OMOP CDM data to CCDA format - optimized for speed"""

    CCDA_NAMESPACE = {
        "cda": "urn:hl7-org:v3",
        "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    }

    def __init__(
        self, data_source: str, aws_region: str = "us-east-1"
    ):
        """
        Initialize converter

        Args:
            data_source: S3 path (s3://bucket/path) or local directory path
            aws_region: AWS region for S3 access
        """
        self.data_source = data_source
        self.aws_region = aws_region
        self.s3_client = None

        if data_source.startswith("s3://"):
            self.s3_client = boto3.client("s3", region_name=aws_region)
            self._parse_s3_path(data_source)
        else:
            self.local_path = Path(data_source)
            if not self.local_path.exists():
                raise ValueError(f"Local path does not exist: {data_source}")

    def _parse_s3_path(self, s3_path: str):
        """Parse S3 path into bucket and prefix"""
        s3_path = s3_path.replace("s3://", "")
        parts = s3_path.split("/", 1)
        self.s3_bucket = parts[0]
        self.s3_prefix = parts[1] if len(parts) > 1 else ""

    def _load_csv(self, table_name: str) -> List[Dict]:
        """Load CSV file from S3 or local filesystem - returns list of dicts"""
        if self.s3_client:
            return self._load_from_s3(table_name)
        else:
            return self._load_from_local(table_name)

    def _load_from_s3(self, table_name: str) -> List[Dict]:
        """Load CSV file from S3 - handles compressed files and CDM naming"""
        # Try different naming conventions
        possible_keys = [
            f"{self.s3_prefix.rstrip('/')}/CDM_{table_name.upper()}.csv.bz2",
            f"{self.s3_prefix.rstrip('/')}/CDM_{table_name.upper()}.csv",
            f"{self.s3_prefix.rstrip('/')}/{table_name}.csv.bz2",
            f"{self.s3_prefix.rstrip('/')}/{table_name}.csv",
        ]

        for key in possible_keys:
            try:
                logger.debug(f"Trying to load from s3://{self.s3_bucket}/{key}")
                obj = self.s3_client.get_object(Bucket=self.s3_bucket, Key=key)
                content = obj["Body"].read()

                # Handle bz2 compression
                if key.endswith(".bz2"):
                    content = bz2.decompress(content)

                csv_content = content.decode("utf-8")
                logger.info(f"Successfully loaded {table_name} from {key}")
                return self._parse_csv(csv_content)
            except Exception as e:
                logger.debug(f"Failed to load {key}: {e}")
                continue

        raise FileNotFoundError(f"Could not find {table_name} table in S3 bucket")

    def _load_from_local(self, table_name: str) -> List[Dict]:
        """Load CSV file from local filesystem"""
        file_path = self.local_path / f"{table_name}.csv"
        if not file_path.exists():
            raise FileNotFoundError(f"Table file not found: {file_path}")

        logger.debug(f"Loading {table_name} from {file_path}")
        with open(file_path, "r", encoding="utf-8") as f:
            return self._parse_csv(f.read())

    def _parse_csv(self, csv_content: str) -> List[Dict]:
        """Parse CSV content into list of dictionaries - optimized"""
        reader = csv.DictReader(io.StringIO(csv_content))
        return list(reader)

    def load_data(self, max_records: Optional[int] = None, start_from: int = 0) -> Dict:
        """
        Load all OMOP data into memory for fast processing

        Returns:
            Dictionary with 'persons', 'conditions', 'medications', 'observations'
        """
        logger.info("Loading OMOP data tables...")

        # Load person table (handle CDM naming)
        persons = self._load_csv("PERSON")
        if max_records:
            persons = persons[start_from : start_from + max_records]
        else:
            persons = persons[start_from:]

        # Load related tables (only for persons we're processing)
        person_ids = {p.get("person_id") for p in persons}

        logger.info("Loading condition data...")
        try:
            all_conditions = self._load_csv("CONDITION_OCCURRENCE")
            conditions = [c for c in all_conditions if c.get("person_id") in person_ids]
        except Exception as e:
            logger.warning(f"Could not load CONDITION_OCCURRENCE: {e}")
            conditions = []

        logger.info("Loading medication data...")
        try:
            all_medications = self._load_csv("DRUG_EXPOSURE")
            medications = [
                m for m in all_medications if m.get("person_id") in person_ids
            ]
        except Exception as e:
            logger.warning(f"Could not load DRUG_EXPOSURE: {e}")
            medications = []

        logger.info("Loading observation data...")
        try:
            all_observations = self._load_csv("OBSERVATION")
            observations = [
                o for o in all_observations if o.get("person_id") in person_ids
            ]
        except Exception as e:
            logger.warning(f"Could not load OBSERVATION: {e}")
            observations = []

        logger.info(
            f"Loaded {len(persons)} persons, {len(conditions)} conditions, "
            f"{len(medications)} medications, {len(observations)} observations"
        )

        return {
            "persons": persons,
            "conditions": conditions,
            "medications": medications,
            "observations": observations,
        }

    def convert_to_ccda(
        self,
        person_data: Dict,
        conditions: List[Dict],
        observations: List[Dict],
        medications: List[Dict],
    ) -> str:
        """
        Create a CCDA XML document from OMOP data

        Returns:
            CCDA XML document as string
        """
        # Create root ClinicalDocument element with namespaces
        # ElementTree requires explicit namespace handling
        root = Element("{urn:hl7-org:v3}ClinicalDocument")
        root.set("xmlns", "urn:hl7-org:v3")
        root.set("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance")
        root.set("{http://www.w3.org/2001/XMLSchema-instance}type", "POCD_HD000040")

        # Add realm code
        realm_code = SubElement(root, "{urn:hl7-org:v3}realmCode")
        realm_code.set("code", "US")

        # Add type ID
        type_id = SubElement(root, "{urn:hl7-org:v3}typeId")
        type_id.set("root", "2.16.840.1.113883.1.3")
        type_id.set("extension", "POCD_HD000040")

        # Add template ID
        template_id = SubElement(root, "{urn:hl7-org:v3}templateId")
        template_id.set("root", "2.16.840.1.113883.10.20.22.1.1")

        # Add ID
        doc_id = SubElement(root, "{urn:hl7-org:v3}id")
        doc_id.set(
            "root", f"1.2.840.113619.6.197.{person_data.get('person_id', 'unknown')}"
        )

        # Add code
        code = SubElement(root, "{urn:hl7-org:v3}code")
        code.set("code", "34133-9")
        code.set("codeSystem", "2.16.840.1.113883.6.1")
        code.set("displayName", "Summarization of Episode Note")

        # Add title
        title = SubElement(root, "{urn:hl7-org:v3}title")
        title.text = (
            f"Clinical Summary for Patient {person_data.get('person_id', 'Unknown')}"
        )

        # Add effective time
        effective_time = SubElement(root, "{urn:hl7-org:v3}effectiveTime")
        effective_time.set("value", datetime.now().strftime("%Y%m%d%H%M%S"))

        # Add confidentiality code
        confidentiality = SubElement(root, "{urn:hl7-org:v3}confidentialityCode")
        confidentiality.set("code", "N")
        confidentiality.set("codeSystem", "2.16.840.1.113883.5.25")

        # Add language code
        language = SubElement(root, "{urn:hl7-org:v3}languageCode")
        language.set("code", "en-US")

        # Add record target (patient)
        record_target = SubElement(root, "{urn:hl7-org:v3}recordTarget")
        patient_role = SubElement(record_target, "{urn:hl7-org:v3}patientRole")

        # Patient ID
        patient_id = SubElement(patient_role, "{urn:hl7-org:v3}id")
        patient_id.set("root", "2.16.840.1.113883.19.5")
        patient_id.set("extension", str(person_data.get("person_id", "")))

        # Patient address (if available)
        if person_data.get("address_1"):
            addr = SubElement(patient_role, "{urn:hl7-org:v3}addr")
            street = SubElement(addr, "{urn:hl7-org:v3}streetAddressLine")
            street.text = person_data.get("address_1", "")
            if person_data.get("city"):
                city = SubElement(addr, "{urn:hl7-org:v3}city")
                city.text = person_data.get("city", "")
            if person_data.get("state"):
                state = SubElement(addr, "{urn:hl7-org:v3}state")
                state.text = person_data.get("state", "")
            if person_data.get("zip"):
                postal = SubElement(addr, "{urn:hl7-org:v3}postalCode")
                postal.text = str(person_data.get("zip", ""))

        # Patient telecom (if available)
        if person_data.get("phone"):
            telecom = SubElement(patient_role, "{urn:hl7-org:v3}telecom")
            telecom.set("value", f"tel:{person_data.get('phone', '')}")
            telecom.set("use", "HP")

        # Patient
        patient = SubElement(patient_role, "{urn:hl7-org:v3}patient")

        # Patient name
        name = SubElement(patient, "{urn:hl7-org:v3}name")
        if person_data.get("first_name"):
            given = SubElement(name, "{urn:hl7-org:v3}given")
            given.text = person_data.get("first_name", "")
        if person_data.get("last_name"):
            family = SubElement(name, "{urn:hl7-org:v3}family")
            family.text = person_data.get("last_name", "")

        # Administrative gender
        if person_data.get("gender_concept_id"):
            gender_code = self._map_gender(person_data.get("gender_concept_id"))
            if gender_code:
                gender = SubElement(patient, "{urn:hl7-org:v3}administrativeGenderCode")
                gender.set("code", gender_code)
                gender.set("codeSystem", "2.16.840.1.113883.5.1")

        # Birth time
        if person_data.get("birth_datetime"):
            birth_time = SubElement(patient, "{urn:hl7-org:v3}birthTime")
            birth_time.set(
                "value", self._format_datetime(person_data.get("birth_datetime"))
            )

        # Add component section for problems/conditions
        if conditions:
            component = SubElement(root, "{urn:hl7-org:v3}component")
            section = SubElement(component, "{urn:hl7-org:v3}section")

            code = SubElement(section, "{urn:hl7-org:v3}code")
            code.set("code", "11450-4")
            code.set("codeSystem", "2.16.840.1.113883.6.1")
            code.set("displayName", "Problem List")

            title = SubElement(section, "{urn:hl7-org:v3}title")
            title.text = "Problems"

            for condition in conditions:
                entry = SubElement(section, "{urn:hl7-org:v3}entry")
                act = SubElement(entry, "{urn:hl7-org:v3}act")
                act.set("classCode", "ACT")
                act.set("moodCode", "EVN")

                code = SubElement(act, "{urn:hl7-org:v3}code")
                code.set("code", str(condition.get("condition_concept_id", "")))
                code.set("codeSystem", "2.16.840.1.113883.6.96")

                effective_time = SubElement(act, "{urn:hl7-org:v3}effectiveTime")
                if condition.get("condition_start_date"):
                    effective_time.set(
                        "value",
                        self._format_date(condition.get("condition_start_date")),
                    )

        # Add medications section
        if medications:
            component = SubElement(root, "{urn:hl7-org:v3}component")
            section = SubElement(component, "{urn:hl7-org:v3}section")

            code = SubElement(section, "{urn:hl7-org:v3}code")
            code.set("code", "10160-0")
            code.set("codeSystem", "2.16.840.1.113883.6.1")
            code.set("displayName", "History of Medication Use")

            title = SubElement(section, "{urn:hl7-org:v3}title")
            title.text = "Medications"

            for med in medications:
                entry = SubElement(section, "{urn:hl7-org:v3}entry")
                substance = SubElement(entry, "{urn:hl7-org:v3}substanceAdministration")
                substance.set("classCode", "SBADM")
                substance.set("moodCode", "EVN")

                code = SubElement(substance, "{urn:hl7-org:v3}code")
                code.set("code", str(med.get("drug_concept_id", "")))
                code.set("codeSystem", "2.16.840.1.113883.6.88")

        # Convert to XML string
        return tostring(root, encoding="unicode", method="xml")

    def _map_gender(self, gender_concept_id: int) -> Optional[str]:
        """Map OMOP gender concept ID to HL7 gender code"""
        gender_map = {
            8507: "M",  # Male
            8532: "F",  # Female
            8570: "UN",  # Unknown
        }
        return gender_map.get(int(gender_concept_id))

    def _format_date(self, date_str: str) -> str:
        """Format date string to HL7 format (YYYYMMDD)"""
        try:
            if isinstance(date_str, str):
                dt = datetime.strptime(date_str.split(" ")[0], "%Y-%m-%d")
                return dt.strftime("%Y%m%d")
        except (ValueError, TypeError):
            pass
        return ""

    def _format_datetime(self, datetime_str: str) -> str:
        """Format datetime string to HL7 format (YYYYMMDDHHMMSS)"""
        try:
            if isinstance(datetime_str, str):
                dt = datetime.strptime(datetime_str.split(".")[0], "%Y-%m-%d %H:%M:%S")
                return dt.strftime("%Y%m%d%H%M%S")
        except (ValueError, TypeError):
            pass
        return ""
