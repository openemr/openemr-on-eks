"""
High-performance uploader with parallel processing

Uses direct database import - the ONLY supported method for uploading data.
This provides maximum speed and reliability by bypassing the API/web interface.
"""

import logging
import os
import time
from typing import Optional, Dict, Any
from concurrent.futures import ThreadPoolExecutor, as_completed

logger = logging.getLogger(__name__)


class Uploader:
    """
    High-performance uploader with parallel processing

    Designed to run in Kubernetes with generous resources for maximum throughput.
    Uses direct database import - the ONLY supported method for uploading data.
    No API/web interface fallback is available or supported.
    """

    def __init__(
        self,
        converter,
        db_importer,
        batch_size: int = 100,
        workers: Optional[int] = None,
    ):
        """
        Initialize uploader

        Args:
            converter: OMOP to CCDA converter instance
            db_importer: Direct database importer (required - this is the ONLY supported method)
            batch_size: Records per batch
            workers: Number of parallel workers (default: CPU count)
        """
        if not db_importer:
            raise ValueError(
                "db_importer is required - direct database import is the only supported method"
            )

        self.converter = converter
        self.db_importer = db_importer
        self.batch_size = batch_size
        self.workers = workers or os.cpu_count() or 1

        logger.info(
            f"Uploader initialized with {self.workers} workers (DIRECT DATABASE MODE)"
        )

    def process_and_upload(
        self,
        max_records: Optional[int] = None,
        start_from: int = 0,
        dry_run: bool = False,
    ) -> Dict:
        """
        Process and upload data with parallel processing

        Returns:
            Dictionary with processing statistics
        """
        start_time = time.time()
        stats: Dict[str, Any] = {
            "processed": 0,
            "uploaded": 0,
            "failed": 0,
            "skipped": 0,
        }

        try:
            # Load data
            logger.info("Loading OMOP data...")
            data = self.converter.load_data(
                max_records=max_records, start_from=start_from
            )

            total_records = len(data["persons"])
            logger.info(
                f"Processing {total_records} records with {self.workers} workers..."
            )

            # Process in parallel batches
            with ThreadPoolExecutor(max_workers=self.workers) as executor:
                futures = []

                # Submit batches
                for i in range(0, total_records, self.batch_size):
                    batch = data["persons"][i : i + self.batch_size]
                    future = executor.submit(self._process_batch, batch, data, dry_run)
                    futures.append(future)

                # Collect results
                for future in as_completed(futures):
                    try:
                        batch_stats = future.result()
                        stats["processed"] += batch_stats["processed"]
                        stats["uploaded"] += batch_stats["uploaded"]
                        stats["failed"] += batch_stats["failed"]
                        stats["skipped"] += batch_stats["skipped"]
                    except Exception as e:
                        logger.error(f"Batch processing error: {e}")
                        stats["failed"] += self.batch_size

            stats["duration"] = int(time.time() - start_time)
            return stats

        except Exception as e:
            logger.error(f"Fatal error during processing: {e}", exc_info=True)
            stats["duration"] = int(time.time() - start_time)
            raise

    def _process_batch(self, batch, data, dry_run: bool) -> Dict:
        """Process a single batch of records"""
        batch_stats = {"processed": 0, "uploaded": 0, "failed": 0, "skipped": 0}

        for person in batch:
            try:
                # Handle both lowercase and uppercase keys from CSV
                person_id = person.get("person_id") or person.get("PERSON_ID")

                # Get related data (handle both case variations)
                conditions = [
                    c
                    for c in data.get("conditions", [])
                    if (c.get("person_id") or c.get("PERSON_ID")) == person_id
                ]
                medications = [
                    m
                    for m in data.get("medications", [])
                    if (m.get("person_id") or m.get("PERSON_ID")) == person_id
                ]
                observations = [
                    o
                    for o in data.get("observations", [])
                    if (o.get("person_id") or o.get("PERSON_ID")) == person_id
                ]

                if dry_run:
                    logger.debug(f"Dry run: Would import person {person_id}")
                    batch_stats["uploaded"] += 1
                else:
                    # Direct database import (the ONLY supported method)
                    pid = self.db_importer.import_patient(
                        person_data=person,
                        conditions=conditions,
                        medications=medications,
                        observations=observations,
                    )
                    if pid:
                        batch_stats["uploaded"] += 1
                    else:
                        batch_stats["failed"] += 1

                batch_stats["processed"] += 1

            except Exception as e:
                logger.error(f"Error processing person {person.get('person_id')}: {e}")
                batch_stats["failed"] += 1
                batch_stats["processed"] += 1

        return batch_stats
