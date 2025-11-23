"""
Direct Database Importer for OpenEMR

This is the ONLY supported method for uploading data to OpenEMR.
Direct database access provides maximum speed and reliability by bypassing
the API/web interface entirely.
"""

import logging
import uuid
from typing import Dict, List, Optional
from datetime import datetime, date

import pymysql

logger = logging.getLogger(__name__)


class OpenEMRDBImporter:
    """
    Direct database importer for OpenEMR.
    
    This is the ONLY supported method for uploading data to OpenEMR.
    Direct database access bypasses the API/web interface entirely for
    maximum performance and reliability.
    """

    def __init__(
        self, db_host: str, db_user: str, db_password: str, db_name: str = "openemr"
    ):
        """
        Initialize database connection

        Args:
            db_host: Database hostname
            db_user: Database username
            db_password: Database password
            db_name: Database name (default: openemr)
        """
        self.db_host = db_host
        self.db_user = db_user
        self.db_password = db_password
        self.db_name = db_name
        self.connection = None

    def connect(self) -> bool:
        """Establish database connection"""
        try:
            self.connection = pymysql.connect(
                host=self.db_host,
                user=self.db_user,
                password=self.db_password,
                database=self.db_name,
                charset="utf8mb4",
                cursorclass=pymysql.cursors.DictCursor,
                autocommit=False,  # Use transactions for performance
            )
            logger.info(f"✓ Connected to OpenEMR database at {self.db_host}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to database: {e}")
            return False

    def disconnect(self):
        """Close database connection"""
        if self.connection:
            self.connection.close()
            logger.debug("Database connection closed")

    def _get_next_pid(self) -> int:
        """Get the next patient ID (pid)"""
        try:
            with self.connection.cursor() as cursor:
                cursor.execute("SELECT MAX(pid) as max_pid FROM patient_data")
                result = cursor.fetchone()
                max_pid = result["max_pid"] if result and result["max_pid"] else 0
                return max_pid + 1
        except Exception as e:
            logger.error(f"Failed to get next PID: {e}")
            raise

    def _generate_uuid(self) -> bytes:
        """Generate UUID for patient (binary format)"""
        return uuid.uuid4().bytes

    def import_patient(
        self,
        person_data: Dict,
        conditions: Optional[List[Dict]] = None,
        medications: Optional[List[Dict]] = None,
        observations: Optional[List[Dict]] = None,
    ) -> Optional[int]:
        """
        Import a patient directly into OpenEMR database

        Args:
            person_data: OMOP PERSON table data
            conditions: List of condition_occurrence records
            medications: List of drug_exposure records
            observations: List of observation records

        Returns:
            Patient ID (pid) if successful, None otherwise
        """
        if not self.connection:
            logger.error("Database not connected")
            return None

        conditions = conditions or []
        medications = medications or []
        observations = observations or []

        try:
            pid = self._get_next_pid()
            patient_uuid = self._generate_uuid()

            # Extract patient data from OMOP format
            # OMOP uses: year_of_birth, month_of_birth, day_of_birth
            birth_year = int(person_data.get("YEAR_OF_BIRTH", 1900))
            birth_month = int(person_data.get("MONTH_OF_BIRTH", 1))
            birth_day = int(person_data.get("DAY_OF_BIRTH", 1))

            try:
                dob = date(birth_year, birth_month, birth_day)
            except ValueError:
                # Invalid date, use default
                dob = date(1900, 1, 1)

            # Gender mapping: OMOP uses 8507 (M), 8532 (F), 8570 (Other)
            gender_code = person_data.get("GENDER_CONCEPT_ID", "")
            if gender_code == "8507":
                sex = "Male"
            elif gender_code == "8532":
                sex = "Female"
            else:
                sex = "Other"

            # Race/ethnicity mapping (simplified)
            # Note: race_concept_id and ethnicity_concept_id are available but not used
            # in current implementation - kept for future use
            _ = person_data.get("RACE_CONCEPT_ID", "")
            _ = person_data.get("ETHNICITY_CONCEPT_ID", "")

            # Insert patient_data record using INSERT (for new patients)
            # OpenEMR uses REPLACE INTO in newPatientData(), but we use INSERT since we're creating new patients
            with self.connection.cursor() as cursor:
                # Get default price level (required by OpenEMR)
                cursor.execute(
                    "SELECT option_id FROM list_options WHERE list_id = 'pricelevel' "
                    "AND activity = 1 ORDER BY is_default DESC, seq ASC LIMIT 1"
                )
                pricelevel_result = cursor.fetchone()
                pricelevel = (
                    pricelevel_result["option_id"] if pricelevel_result else "standard"
                )

                # Extract name (OMOP doesn't have names, so we'll use person_id as placeholder)
                person_id = person_data.get("PERSON_ID", str(pid))
                fname = f"Patient{person_id[:6]}"  # Use person_id for name
                lname = "Import"

                # Format DOB as YYYY-MM-DD string (OpenEMR format)
                dob_str = dob.strftime("%Y-%m-%d") if dob else ""
                regdate_str = datetime.now().strftime("%Y-%m-%d")
                date_now = datetime.now()

                # Use INSERT INTO matching OpenEMR's patient_data table structure
                # Note: 'id' is auto-increment, so we don't set it
                # UUID will be set by OpenEMR's UuidRegistry if not provided, but we set it for consistency
                insert_sql = """
                    INSERT INTO patient_data (
                        uuid, pid, title, fname, lname, mname, sex, DOB,
                        street, postal_code, city, state, country_code,
                        phone_home, phone_biz, phone_contact, phone_cell,
                        status, date, regdate, pubpid, language, financial, pricelevel
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s,
                        %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s
                    )
                """

                cursor.execute(
                    insert_sql,
                    (
                        patient_uuid,
                        pid,
                        "",
                        fname,
                        lname,
                        "",
                        sex,
                        dob_str,
                        "",
                        "",
                        "",
                        "",
                        "US",
                        "",
                        "",
                        "",
                        "",
                        "active",
                        date_now,
                        regdate_str,
                        str(person_id),
                        "English",
                        "1",
                        pricelevel,
                    ),
                )

                # Get the inserted ID
                inserted_id = cursor.lastrowid

                # Verify UUID was set (OpenEMR sets UUID if empty, but we set it)
                cursor.execute(
                    "SELECT uuid FROM patient_data WHERE id = %s", (inserted_id,)
                )
                result = cursor.fetchone()
                if result and not result["uuid"]:
                    # UUID wasn't set, update it (matching OpenEMR's behavior)
                    cursor.execute(
                        "UPDATE patient_data SET uuid = %s WHERE id = %s",
                        (patient_uuid, inserted_id),
                    )

                # Import conditions (diagnoses)
                for condition in conditions:
                    self._import_condition(cursor, pid, condition)

                # Import medications
                for medication in medications:
                    self._import_medication(cursor, pid, medication)

                # Import observations (as notes or other data)
                for observation in observations:
                    self._import_observation(cursor, pid, observation)

                # Commit transaction
                self.connection.commit()
                logger.debug(f"✓ Imported patient {pid} ({fname} {lname})")
                return pid

        except Exception as e:
            self.connection.rollback()
            logger.error(f"Failed to import patient: {e}", exc_info=True)
            return None

    def _import_condition(self, cursor, pid: int, condition: Dict):
        """Import a condition/diagnosis into lists table"""
        try:
            # OMOP condition_occurrence fields
            condition_start_date = condition.get("CONDITION_START_DATE")
            condition_concept_id = condition.get("CONDITION_CONCEPT_ID", "")

            # Map to OpenEMR lists table (type = 'medical_problem' or 'allergy')
            # For now, use 'medical_problem'
            insert_sql = """
                INSERT INTO lists (
                    pid, type, title, begdate, enddate, diagnosis, activity
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s
                )
            """

            # Parse date
            begdate = None
            if condition_start_date:
                try:
                    begdate = datetime.strptime(condition_start_date, "%Y-%m-%d").date()
                except (ValueError, TypeError):
                    pass

            cursor.execute(
                insert_sql,
                (
                    pid,
                    "medical_problem",
                    f"Condition {condition_concept_id}",
                    begdate,
                    None,
                    condition_concept_id,
                    1,
                ),
            )
        except Exception as e:
            logger.debug(f"Failed to import condition: {e}")

    def _import_medication(self, cursor, pid: int, medication: Dict):
        """Import a medication into lists table"""
        try:
            # OMOP drug_exposure fields
            drug_exposure_start_date = medication.get("DRUG_EXPOSURE_START_DATE")
            drug_concept_id = medication.get("DRUG_CONCEPT_ID", "")

            insert_sql = """
                INSERT INTO lists (
                    pid, type, title, begdate, enddate, diagnosis, activity
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s
                )
            """

            # Parse date
            begdate = None
            if drug_exposure_start_date:
                try:
                    begdate = datetime.strptime(
                        drug_exposure_start_date, "%Y-%m-%d"
                    ).date()
                except (ValueError, TypeError):
                    pass

            cursor.execute(
                insert_sql,
                (
                    pid,
                    "medication",
                    f"Medication {drug_concept_id}",
                    begdate,
                    None,
                    drug_concept_id,
                    1,
                ),
            )
        except Exception as e:
            logger.debug(f"Failed to import medication: {e}")

    def _import_observation(self, cursor, pid: int, observation: Dict):
        """Import an observation (can be stored in various ways)"""
        # For now, observations can be stored as notes or in custom tables
        # This is a placeholder - can be expanded based on needs
        pass

    def import_batch(self, patients: List[Dict]) -> Dict:
        """
        Import a batch of patients

        Args:
            patients: List of patient dictionaries with person_data, conditions, medications, observations

        Returns:
            Statistics dictionary
        """
        stats = {"processed": 0, "imported": 0, "failed": 0}

        for patient in patients:
            try:
                pid = self.import_patient(
                    person_data=patient.get("person_data", {}),
                    conditions=patient.get("conditions", []),
                    medications=patient.get("medications", []),
                    observations=patient.get("observations", []),
                )
                if pid:
                    stats["imported"] += 1
                else:
                    stats["failed"] += 1
                stats["processed"] += 1
            except Exception as e:
                logger.error(f"Error importing patient: {e}")
                stats["failed"] += 1
                stats["processed"] += 1

        return stats
