"""
CCDA Data Upload Command

Uses direct database import - the ONLY supported method for uploading data.
No API/web interface fallback is available or supported.
"""

import argparse
import logging
import os

from warp.core.omop_to_ccda import OMOPToCCDAConverter
from warp.core.db_importer import OpenEMRDBImporter
from warp.core.uploader import Uploader
from warp.core.credential_discovery import CredentialDiscovery

logger = logging.getLogger(__name__)


class CCDADataUploadCommand:
    """Command for uploading CCDA data to OpenEMR"""

    @staticmethod
    def add_arguments(parser: argparse.ArgumentParser):
        """Add command-line arguments"""
        # Database connection (required - direct database import is the ONLY method)
        parser.add_argument(
            "--db-host",
            required=False,
            default=None,
            help="Database host (e.g., aurora-cluster.region.rds.amazonaws.com). Auto-discovered if not provided.",
        )
        parser.add_argument(
            "--db-user",
            required=False,
            default=None,
            help="Database username. Auto-discovered if not provided.",
        )
        parser.add_argument(
            "--db-password",
            required=False,
            default=None,
            help="Database password. Auto-discovered if not provided.",
        )
        parser.add_argument(
            "--db-name",
            required=False,
            default="openemr",
            help="Database name (default: openemr)",
        )
        parser.add_argument(
            "--namespace",
            default="openemr",
            help="Kubernetes namespace for credential discovery (default: openemr)",
        )
        parser.add_argument(
            "--terraform-dir",
            default=None,
            help="Terraform directory for credential discovery (default: auto-detect)",
        )

        # Data source
        parser.add_argument(
            "--data-source",
            required=True,
            help="Data source: S3 path (s3://bucket/path) or local directory",
        )

        # Processing options
        parser.add_argument(
            "--batch-size",
            type=int,
            default=None,
            help="Records per batch (default: auto-optimized)",
        )
        parser.add_argument(
            "--max-records",
            type=int,
            default=None,
            help="Maximum records to process (default: all)",
        )
        parser.add_argument(
            "--start-from",
            type=int,
            default=0,
            help="Start processing from record number (default: 0)",
        )
        parser.add_argument(
            "--workers",
            type=int,
            default=None,
            help="Number of parallel workers (default: CPU count)",
        )

        # AWS configuration
        parser.add_argument(
            "--aws-region",
            default=os.environ.get("AWS_REGION", "us-east-1"),
            help="AWS region for S3 access (default: us-east-1)",
        )

        # Output options
        parser.add_argument(
            "--dry-run", action="store_true", help="Validate data without uploading"
        )

    def execute(self, args):
        """Execute the command"""
        logger.info("Warp CCDA Data Upload")
        logger.info("=" * 60)
        logger.info("🚀 Direct Database Import Only")
        logger.info("=" * 60)

        # Discover database credentials
        discovery = CredentialDiscovery(
            namespace=args.namespace, terraform_dir=args.terraform_dir
        )

        # Get database credentials (auto-discover or use provided)
        db_host = args.db_host
        db_user = args.db_user
        db_password = args.db_password
        db_name = args.db_name

        if not db_host or not db_user or not db_password:
            logger.info("Auto-discovering database credentials...")
            db_creds = discovery.get_db_credentials()

            if not db_creds:
                logger.error("Could not auto-discover database credentials.")
                logger.error("Please provide --db-host, --db-user, and --db-password")
                logger.error(
                    "Or ensure Kubernetes secrets or Terraform outputs are available"
                )
                return 1

            if not db_host:
                db_host = db_creds["host"]
            if not db_user:
                db_user = db_creds["user"]
            if not db_password:
                db_password = db_creds["password"]
            if not db_name:
                db_name = db_creds.get("database", "openemr")

            logger.info("✓ Discovered database credentials")
            logger.info(f"  Host: {db_host}")
            logger.info(f"  User: {db_user}")
            logger.info(f"  Database: {db_name}")

        # Initialize database importer
        if not args.dry_run:
            db_importer = OpenEMRDBImporter(
                db_host=db_host,
                db_user=db_user,
                db_password=db_password,
                db_name=db_name,
            )

            if not db_importer.connect():
                logger.error("Failed to connect to OpenEMR database")
                logger.error(
                    "Please verify database credentials and network connectivity"
                )
                return 1

            logger.info("✓ Connected to OpenEMR database")
        else:
            db_importer = None

        # Initialize converter
        logger.info("Initializing OMOP to CCDA converter")
        converter = OMOPToCCDAConverter(
            data_source=args.data_source,
            aws_region=args.aws_region,
        )

        # Determine optimal batch size and workers
        batch_size = args.batch_size or self._calculate_optimal_batch_size()
        workers = args.workers or os.cpu_count() or 1

        logger.info("Configuration:")
        logger.info(f"  Batch size: {batch_size}")
        logger.info(f"  Workers: {workers}")
        logger.info(f"  Max records: {args.max_records or 'all'}")

        # Initialize uploader (direct database import - the ONLY supported method)
        # For dry-run, create a dummy importer (won't actually connect)
        if args.dry_run:
            db_importer = OpenEMRDBImporter(
                db_host=db_host or "localhost",
                db_user=db_user or "openemr",
                db_password=db_password or "dummy",
                db_name=db_name,
            )

        if not db_importer:
            logger.error("Database importer is required")
            return 1

        uploader = Uploader(
            converter=converter,
            db_importer=db_importer,
            batch_size=batch_size,
            workers=workers,
        )

        # Process and upload
        logger.info(f"Starting data processing from {args.data_source}")
        stats = uploader.process_and_upload(
            max_records=args.max_records,
            start_from=args.start_from,
            dry_run=args.dry_run,
        )

        # Cleanup database connection
        if db_importer:
            db_importer.disconnect()

        # Print summary
        if not args.dry_run and stats["uploaded"] > 0:
            logger.info("")
            logger.info("✓ Patients created directly in database")

        logger.info("=" * 60)
        logger.info("Processing Summary")
        logger.info("=" * 60)
        logger.info(f"Total records processed: {stats['processed']}")
        logger.info(f"Successfully uploaded: {stats['uploaded']}")
        logger.info(f"Failed: {stats['failed']}")
        logger.info(f"Skipped: {stats['skipped']}")
        logger.info(f"Duration: {stats.get('duration', 0):.2f} seconds")

        if stats["failed"] > 0:
            logger.warning("Some records failed. Check logs for details.")
            return 1

        logger.info("✓ Processing completed successfully!")
        if not args.dry_run and stats["uploaded"] > 0:
            logger.info("")
            logger.info("📋 Next Steps:")
            logger.info("   1. Login to OpenEMR")
            logger.info("   2. Navigate to Patients → Patient List")
            logger.info("   3. Verify imported patients appear")
        return 0

    def _calculate_optimal_batch_size(self) -> int:
        """Calculate optimal batch size based on available resources"""
        # Default: 100 records per batch
        # Can be optimized based on memory, CPU, network
        return 100
