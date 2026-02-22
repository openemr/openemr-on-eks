#!/bin/bash

# =============================================================================
# OMOP Dataset Count Verification Script
# =============================================================================
#
# Purpose:
#   Verifies the record counts in the OMOP CDM dataset files match the numbers
#   documented in the Warp README.md benchmark results.
#
# Usage:
#   ./verify-counts.sh [DATA_DIR] [--keep-downloaded-data]
#
# Arguments:
#   DATA_DIR                 Optional. Directory containing the OMOP dataset files.
#                            Defaults to current directory.
#   --keep-downloaded-data   Optional. Keep downloaded data files after verification.
#                            By default, data files are deleted after successful verification.
#
# Prerequisites:
#   - AWS CLI (for downloading files from public S3 bucket)
#   - bzcat or bunzip2 (for decompressing .bz2 files)
#   - wc (for counting lines)
#   - No AWS credentials required (uses public bucket with --no-sign-request)
#
# Expected Results (from Warp README.md):
#   - PERSON: 1,000 records
#   - CONDITION_OCCURRENCE: 160,322 records
#   - DRUG_EXPOSURE: 49,542 records
#   - OBSERVATION: 13,481 records
#   - Total: 224,345 records
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# shellcheck disable=SC2329,SC2317
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $level - $message" >&2
}

# Function to download dataset files from S3
download_dataset_files() {
    local data_dir="$1"
    local s3_bucket="s3://synpuf-omop/cmsdesynpuf1k"
    local region="us-west-2"
    
    echo "Downloading dataset files from S3..."
    echo ""
    
    # Check if AWS CLI is available
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}ERROR: AWS CLI is not installed or not in PATH${NC}"
        echo "Please install AWS CLI to download dataset files."
        exit 1
    fi
    
    # File names
    local files=(
        "CDM_PERSON.csv.bz2"
        "CDM_CONDITION_OCCURRENCE.csv.bz2"
        "CDM_DRUG_EXPOSURE.csv.bz2"
        "CDM_OBSERVATION.csv.bz2"
    )
    
    # Download each file (using --no-sign-request for public bucket access)
    for file in "${files[@]}"; do
        echo -n "Downloading $file... "
        if aws s3 cp "$s3_bucket/$file" "$data_dir/$file" --region "$region" --no-sign-request --quiet 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            echo "ERROR: Failed to download $file from S3"
            echo "Please check your network connectivity."
            exit 1
        fi
    done
    
    echo ""
    echo -e "${GREEN}✓ All dataset files downloaded successfully${NC}"
    echo ""
}

# Function to clean up existing data files
cleanup_existing_files() {
    local data_dir="$1"
    
    # File names
    local files=(
        "CDM_PERSON.csv.bz2"
        "CDM_CONDITION_OCCURRENCE.csv.bz2"
        "CDM_DRUG_EXPOSURE.csv.bz2"
        "CDM_OBSERVATION.csv.bz2"
    )
    
    local found_files=0
    for file in "${files[@]}"; do
        if [ -f "$data_dir/$file" ]; then
            found_files=1
            break
        fi
    done
    
    if [ $found_files -eq 1 ]; then
        echo "Removing existing dataset files..."
        for file in "${files[@]}"; do
            if [ -f "$data_dir/$file" ]; then
                rm -f "$data_dir/$file"
            fi
        done
        echo -e "${GREEN}✓ Existing files removed${NC}"
        echo ""
    fi
}

# Function to count records in a compressed CSV file
count_records() {
    local file="$1"
    local name="$2"
    
    if [ ! -f "$file" ]; then
        echo "ERROR: File not found: $file"
        return 1
    fi
    
    # Count lines excluding header (tail -n +2 skips first line)
    if command -v bzcat &> /dev/null; then
        local count=$(bzcat "$file" | tail -n +2 | wc -l | tr -d ' ')
    elif command -v bunzip2 &> /dev/null; then
        local temp_file=$(mktemp)
        bunzip2 -c "$file" > "$temp_file"
        local count=$(tail -n +2 "$temp_file" | wc -l | tr -d ' ')
        rm -f "$temp_file"
    else
        echo "ERROR: Neither bzcat nor bunzip2 found. Please install one."
        return 1
    fi
    
    echo "$count"
}

# Parse arguments
KEEP_DATA=false
DATA_DIR="."

# Parse command-line arguments
for arg in "$@"; do
    case $arg in
        --keep-downloaded-data)
            KEEP_DATA=true
            ;;
        *)
            if [ -d "$arg" ]; then
                DATA_DIR="$arg"
            fi
            ;;
    esac
done

# Change to data directory
cd "$DATA_DIR" || {
    echo "ERROR: Cannot access directory: $DATA_DIR"
    exit 1
}

echo "============================================================================="
echo "OMOP Dataset Count Verification"
echo "============================================================================="
echo ""
echo "Data directory: $(pwd)"
echo ""

# Clean up any existing files and download fresh copies
cleanup_existing_files "$(pwd)"
download_dataset_files "$(pwd)"

# Expected counts (from Warp README.md)
EXPECTED_PERSON=1000
EXPECTED_CONDITION=160322
EXPECTED_MEDICATION=49542
EXPECTED_OBSERVATION=13481
EXPECTED_TOTAL=224345

# File names
PERSON_FILE="CDM_PERSON.csv.bz2"
CONDITION_FILE="CDM_CONDITION_OCCURRENCE.csv.bz2"
MEDICATION_FILE="CDM_DRUG_EXPOSURE.csv.bz2"
OBSERVATION_FILE="CDM_OBSERVATION.csv.bz2"

# Verify files exist (they should exist after download, but check anyway)
MISSING_FILES=0
for file in "$PERSON_FILE" "$CONDITION_FILE" "$MEDICATION_FILE" "$OBSERVATION_FILE"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}✗${NC} Missing file: $file"
        MISSING_FILES=1
    fi
done

if [ $MISSING_FILES -eq 1 ]; then
    echo ""
    echo "ERROR: One or more required files are missing after download."
    echo "Please check your AWS credentials and network connectivity."
    exit 1
fi

# Count records
echo "Counting records..."
echo ""

# PERSON
echo -n "PERSON records: "
PERSON_COUNT=$(count_records "$PERSON_FILE" "PERSON")
echo "$PERSON_COUNT"
if [ "$PERSON_COUNT" -eq "$EXPECTED_PERSON" ]; then
    echo -e "  ${GREEN}✓${NC} Matches expected: $EXPECTED_PERSON"
else
    echo -e "  ${RED}✗${NC} Expected: $EXPECTED_PERSON, Got: $PERSON_COUNT"
fi
echo ""

# CONDITION_OCCURRENCE
echo -n "CONDITION_OCCURRENCE records: "
CONDITION_COUNT=$(count_records "$CONDITION_FILE" "CONDITION_OCCURRENCE")
echo "$CONDITION_COUNT"
if [ "$CONDITION_COUNT" -eq "$EXPECTED_CONDITION" ]; then
    echo -e "  ${GREEN}✓${NC} Matches expected: $EXPECTED_CONDITION"
else
    echo -e "  ${RED}✗${NC} Expected: $EXPECTED_CONDITION, Got: $CONDITION_COUNT"
fi
echo ""

# DRUG_EXPOSURE
echo -n "DRUG_EXPOSURE records: "
MEDICATION_COUNT=$(count_records "$MEDICATION_FILE" "DRUG_EXPOSURE")
echo "$MEDICATION_COUNT"
if [ "$MEDICATION_COUNT" -eq "$EXPECTED_MEDICATION" ]; then
    echo -e "  ${GREEN}✓${NC} Matches expected: $EXPECTED_MEDICATION"
else
    echo -e "  ${RED}✗${NC} Expected: $EXPECTED_MEDICATION, Got: $MEDICATION_COUNT"
fi
echo ""

# OBSERVATION
echo -n "OBSERVATION records: "
OBSERVATION_COUNT=$(count_records "$OBSERVATION_FILE" "OBSERVATION")
echo "$OBSERVATION_COUNT"
if [ "$OBSERVATION_COUNT" -eq "$EXPECTED_OBSERVATION" ]; then
    echo -e "  ${GREEN}✓${NC} Matches expected: $EXPECTED_OBSERVATION"
else
    echo -e "  ${RED}✗${NC} Expected: $EXPECTED_OBSERVATION, Got: $OBSERVATION_COUNT"
fi
echo ""

# Calculate total
TOTAL=$((PERSON_COUNT + CONDITION_COUNT + MEDICATION_COUNT + OBSERVATION_COUNT))
echo "Total records: $TOTAL"
if [ "$TOTAL" -eq "$EXPECTED_TOTAL" ]; then
    echo -e "  ${GREEN}✓${NC} Matches expected total: $EXPECTED_TOTAL"
else
    echo -e "  ${RED}✗${NC} Expected total: $EXPECTED_TOTAL, Got: $TOTAL"
fi
echo ""

# Summary
echo "============================================================================="
if [ "$PERSON_COUNT" -eq "$EXPECTED_PERSON" ] && \
   [ "$CONDITION_COUNT" -eq "$EXPECTED_CONDITION" ] && \
   [ "$MEDICATION_COUNT" -eq "$EXPECTED_MEDICATION" ] && \
   [ "$OBSERVATION_COUNT" -eq "$EXPECTED_OBSERVATION" ] && \
   [ "$TOTAL" -eq "$EXPECTED_TOTAL" ]; then
    echo -e "${GREEN}✓ All counts match the documented values in Warp README.md${NC}"
    echo ""
    echo "Breakdown:"
    echo "  - Patients: $PERSON_COUNT"
    echo "  - Conditions: $CONDITION_COUNT"
    echo "  - Medications: $MEDICATION_COUNT"
    echo "  - Observations: $OBSERVATION_COUNT"
    echo "  - Total: $TOTAL records"
    echo ""
    
    # Clean up data files unless --keep-downloaded-data flag is set
    if [ "$KEEP_DATA" = false ]; then
        echo "Cleaning up downloaded data files..."
        if rm -f "$PERSON_FILE" "$CONDITION_FILE" "$MEDICATION_FILE" "$OBSERVATION_FILE"; then
            echo -e "${GREEN}✓ Data files removed${NC}"
        else
            echo -e "${YELLOW}⚠ Warning: Some files could not be removed${NC}"
        fi
    else
        echo -e "${YELLOW}ℹ Data files preserved (--keep-downloaded-data flag set)${NC}"
    fi
    
    exit 0
else
    echo -e "${RED}✗ Some counts do not match the documented values${NC}"
    echo ""
    echo "Please verify the dataset files are correct."
    echo ""
    
    # Don't delete files if verification failed
    if [ "$KEEP_DATA" = false ]; then
        echo -e "${YELLOW}ℹ Data files preserved due to verification failure${NC}"
    fi
    
    exit 1
fi

