# Benchmark Data Directory

This directory contains tools and documentation for verifying the OMOP dataset record counts referenced in the Warp README.md benchmark results.

## Contents

- **`README.md`** - This file, describing the directory contents and how to use it
- **`verify-counts.sh`** - Shell script to verify record counts match documented values

## Purpose

The Warp README.md documents benchmark results using the `synpuf-omop` 1k dataset with specific record counts:
- **1,000 patients** (PERSON table)
- **160,322 conditions** (CONDITION_OCCURRENCE table)
- **49,542 medications** (DRUG_EXPOSURE table)
- **13,481 observations** (OBSERVATION table)
- **Total: 224,345 records**

This directory provides tools to verify these counts are accurate.

## Dataset Source

The benchmark uses the **CMS DE-SynPUF 1k** dataset from AWS Open Data:
- **S3 Bucket**: `s3://synpuf-omop/cmsdesynpuf1k/`
- **Dataset URL**: https://registry.opendata.aws/cmsdesynpuf-omop/
- **License**: Public domain (CMS data)

## Downloading the Dataset

The `verify-counts.sh` script automatically downloads the dataset files from S3 at the beginning of each run. **No AWS credentials are required** - the script uses `--no-sign-request` to access the public S3 bucket.

If you want to manually download the dataset files:

```bash
# Navigate to this directory
cd warp/benchmark-data

# Download the required files (no credentials needed for public bucket)
aws s3 cp s3://synpuf-omop/cmsdesynpuf1k/CDM_PERSON.csv.bz2 . --region us-west-2 --no-sign-request
aws s3 cp s3://synpuf-omop/cmsdesynpuf1k/CDM_CONDITION_OCCURRENCE.csv.bz2 . --region us-west-2 --no-sign-request
aws s3 cp s3://synpuf-omop/cmsdesynpuf1k/CDM_DRUG_EXPOSURE.csv.bz2 . --region us-west-2 --no-sign-request
aws s3 cp s3://synpuf-omop/cmsdesynpuf1k/CDM_OBSERVATION.csv.bz2 . --region us-west-2 --no-sign-request
```

**Note**: The actual dataset files are **not** included in this repository due to licensing and size considerations. The script downloads them automatically when run.

## Verifying Record Counts

### Using the Verification Script

The `verify-counts.sh` script automatically verifies all record counts:

```bash
# Make the script executable
chmod +x verify-counts.sh

# Run verification (assumes files are in current directory)
# By default, data files are deleted after successful verification
./verify-counts.sh

# Keep data files after verification
./verify-counts.sh --keep-downloaded-data

# Specify a different directory
./verify-counts.sh /path/to/dataset/files

# Specify directory and keep files
./verify-counts.sh /path/to/dataset/files --keep-downloaded-data
```

The script will:
1. **Delete any existing dataset files** in the directory
2. **Download fresh copies** of all dataset files from S3 (no AWS credentials required)
3. Count records in each file (excluding headers)
4. Compare counts against documented values
5. Calculate and verify the total
6. Report success or failure with color-coded output
7. **Delete data files after successful verification** (unless `--keep-downloaded-data` flag is used)

**Note**: 
- The script automatically downloads fresh data files at the start of each run, ensuring you're always working with the latest dataset.
- Data files are automatically deleted after successful verification to save disk space. Use the `--keep-downloaded-data` flag if you want to preserve the files for further analysis.
- Files are preserved if verification fails.
- No AWS credentials are required - the script uses `--no-sign-request` to access the public S3 bucket.

### Manual Verification

You can also manually count records using command-line tools:

```bash
# Count PERSON records (excluding header)
bzcat CDM_PERSON.csv.bz2 | tail -n +2 | wc -l
# Expected: 1000

# Count CONDITION_OCCURRENCE records
bzcat CDM_CONDITION_OCCURRENCE.csv.bz2 | tail -n +2 | wc -l
# Expected: 160322

# Count DRUG_EXPOSURE records
bzcat CDM_DRUG_EXPOSURE.csv.bz2 | tail -n +2 | wc -l
# Expected: 49542

# Count OBSERVATION records
bzcat CDM_OBSERVATION.csv.bz2 | tail -n +2 | wc -l
# Expected: 13481
```

## Expected Results

When you run the verification script, you should see:

```
✓ PERSON records: 1000
✓ CONDITION_OCCURRENCE records: 160322
✓ DRUG_EXPOSURE records: 49542
✓ OBSERVATION records: 13481
✓ Total records: 224345
```

All counts should match the values documented in `warp/README.md`.

## Prerequisites

- **AWS CLI**: For downloading files from S3
- **bzcat or bunzip2**: For decompressing `.bz2` files
- **wc**: For counting lines (standard Unix tool)
- **bash**: For running the verification script

## File Sizes

The compressed dataset files are approximately:
- `CDM_PERSON.csv.bz2`: ~16 KB
- `CDM_CONDITION_OCCURRENCE.csv.bz2`: ~2.2 MB
- `CDM_DRUG_EXPOSURE.csv.bz2`: ~847 KB
- `CDM_OBSERVATION.csv.bz2`: ~163 KB

**Total**: ~3.2 MB compressed

## Notes

- The dataset files are compressed using bzip2 (`.bz2` format)
- Each CSV file has a header row that is excluded from the count
- The counts represent the actual number of data records, not including headers
- These counts are used in the Warp README.md benchmark documentation

## Related Documentation

- **Warp README.md**: Main documentation with benchmark results
- **Warp DEVELOPER.md**: Developer guide and architecture details
- **Dataset Documentation**: https://registry.opendata.aws/cmsdesynpuf-omop/

