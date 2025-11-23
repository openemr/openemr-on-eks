#!/usr/bin/env python3
"""
Warp CLI - Main entry point
"""

import sys
import argparse
import logging

from warp.commands.ccda_data_upload import CCDADataUploadCommand

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def main():
    """Main CLI entry point"""
    parser = argparse.ArgumentParser(
        prog="warp",
        description="Warp - OpenEMR Data Upload Accelerator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  warp ccda_data_upload --data-source s3://bucket/path --max-records 100
  warp ccda_data_upload --db-host hostname --db-user user --db-password pass --data-source s3://bucket/path
  warp ccda_data_upload --help
        """,
    )

    parser.add_argument("--version", action="version", version="%(prog)s 0.1.0")

    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable verbose logging"
    )

    # Subcommands
    subparsers = parser.add_subparsers(
        dest="command", help="Available commands", metavar="COMMAND"
    )

    # CCDA data upload command
    ccda_parser = subparsers.add_parser(
        "ccda_data_upload",
        help="Upload CCDA data to OpenEMR from OMOP datasets",
        description="Upload CCDA documents to OpenEMR from OMOP format datasets",
    )
    CCDADataUploadCommand.add_arguments(ccda_parser)

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Execute command
    try:
        if args.command == "ccda_data_upload":
            command = CCDADataUploadCommand()
            exit_code = command.execute(args)
            sys.exit(exit_code or 0)
        else:
            logger.error(f"Unknown command: {args.command}")
            sys.exit(1)
    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        sys.exit(130)
    except Exception as e:
        logger.error(f"Error: {e}", exc_info=args.verbose)
        sys.exit(1)


if __name__ == "__main__":
    main()
