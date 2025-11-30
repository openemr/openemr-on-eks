<div align="center">

<img src="logo/warp_logo.png" alt="Warp Logo" width="300">

# 🌀 ⚡ Warp ⚡ 🌀

## OpenEMR Data Upload Accelerator

**High-performance direct database and file system import for OpenEMR on EKS**

[![CI/CD Tests](https://github.com/openemr/openemr-on-eks/actions/workflows/ci-cd-tests.yml/badge.svg)](https://github.com/jm-openemr-dev-namespace/openemr-on-eks/actions/workflows/ci-cd-tests.yml)
[![Version](https://img.shields.io/badge/version-0.1.2-blue)](../warp/setup.py#L12)

</div>

> **⚠️ Beta Status**: Warp is currently in **beta** (version 0.1.2) and should **not be considered production-ready**. While we welcome development contributions and feedback, please use this tool with caution in non-production environments. The project is actively being developed and may undergo significant changes. **Warp will be considered production-ready upon the release of version 1.0.0.**

<div align="center">

<img src="../images/deploy-training-setup-warp-data-upload.png" alt="Warp uploading 100 patients in under 100 minutes" width="600">

*Warp importing 100 patients to OpenEMR in <1 min.*

<img src="../images/deploy-training-setup-patient-finder.png" alt="Warp uploading 100 patients in under 100 minutes" width="600">

*Patients uploaded by Warp displayed in OpenEMR's Patient Finder*

</div>

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Credential Auto-Discovery](#credential-auto-discovery)
- [Architecture](#architecture)
- [Performance](#performance)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Advanced Topics](#advanced-topics)
- [License](#license)

## Overview

Warp is a high-performance tool for uploading data to OpenEMR installations. It bypasses APIs and web interfaces entirely, writing directly to the database and filesystem for maximum speed and reliability.

### Why Warp?

Warp provides horizontally scalable accelerated imports to OpenEMR by:
- Writing directly to OpenEMR's MySQL database
- No API authentication or web session overhead
- Parallel processing with optimized batch sizes

## Features

- **🚀 Direct Database Import**: Writes directly to OpenEMR database (ONLY METHOD)
- **⚡ Maximum Performance**: Horizontally scalable workers write directly to the database
- **🔒 Reliable**: No API authentication or web session dependencies
- **📦 Kubernetes-Native**: Designed to run as a resource-intensive pod
- **🌐 Multiple Data Sources**: Supports S3, local files, and other sources
- **🔧 Auto-Discovery**: Automatically finds credentials from Kubernetes/Terraform
- **📊 OMOP CDM Support**: Loads OMOP Common Data Model data for direct database import
- **🔄 Parallel Processing**: Multi-worker architecture for maximum throughput

## Installation

### Prerequisites

- Python 3.8 or higher (3.14 recommended)
- Access to OpenEMR database (required for direct database import)
- AWS credentials (for S3 data sources)

### Install from Source

```bash
# Clone the repository
git clone https://github.com/openemr/openemr-on-eks-dev.git
cd openemr-on-eks-dev/warp

# Install dependencies
pip install -r requirements.txt

# Or install warp as a package
pip install -e .
```

### Verify Installation

```bash
warp --version
warp --help
```

## Quick Start

### Automatic Mode (Recommended)

Warp automatically discovers credentials from Kubernetes secrets or Terraform:

```bash
# No credentials needed - auto-discovered!
warp ccda_data_upload \
  --data-source s3://synpuf-omop/cmsdesynpuf1k/ \
  --max-records 100
```

### Manual Mode

If auto-discovery fails, provide database credentials manually:

```bash
warp ccda_data_upload \
  --db-host aurora-cluster.region.rds.amazonaws.com \
  --db-user openemr \
  --db-password password \
  --data-source s3://synpuf-omop/cmsdesynpuf1k/ \
  --max-records 100
```

## Usage

Warp uses direct database import exclusively. It writes directly to OpenEMR's MySQL database, matching the exact structure used by OpenEMR's internal functions.

#### Automatic Credential Discovery

Warp automatically discovers database credentials from:

1. **Kubernetes Secrets**: `openemr-db-credentials` secret in the `openemr` namespace
2. **Terraform Outputs**: Aurora endpoint and password from Terraform state
3. **Environment Variables**: `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`

```bash
# Auto-discover all credentials
warp ccda_data_upload \
  --data-source s3://synpuf-omop/cmsdesynpuf1k/ \
  --max-records 1000
```

#### Manual Database Credentials

```bash
# Set via environment variables
export DB_HOST="aurora-cluster.region.rds.amazonaws.com"
export DB_USER="openemr"
export DB_PASSWORD="password"
export DB_NAME="openemr"

warp ccda_data_upload \
  --data-source s3://synpuf-omop/cmsdesynpuf1k/ \
  --max-records 1000
```

#### Performance Tuning

```bash
# Increase batch size for better performance
warp ccda_data_upload \
  --data-source s3://synpuf-omop/cmsdesynpuf1k/ \
  --batch-size 500 \
  --workers 8 \
  --max-records 10000
```

## Credential Auto-Discovery

Warp can automatically discover database credentials from multiple sources, eliminating the need to manually provide them.

### Discovery Sources (in order)

1. **Kubernetes Secrets** (highest priority)
   - Secret: `openemr-db-credentials` in namespace `openemr`
   - Keys: `mysql-host`, `mysql-user`, `mysql-password`, `mysql-database`

2. **Terraform Outputs**
   - Aurora endpoint: `aurora_endpoint` output
   - Database password: `aurora_password` output

3. **Environment Variables**
   - `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`

### Usage Examples

```bash
# Fully automatic (recommended)
warp ccda_data_upload --data-source s3://bucket/path

# Partial override
warp ccda_data_upload \
  --db-user openemr \
  --data-source s3://bucket/path

# Manual override (disables auto-discovery)
warp ccda_data_upload \
  --db-host aurora-cluster.region.rds.amazonaws.com \
  --db-user openemr \
  --db-password password \
  --data-source s3://bucket/path
```

## Architecture

Warp writes directly to OpenEMR's MySQL database using:

- **Direct SQL**: Uses `INSERT INTO` matching OpenEMR's `newPatientData()` function
- **Schema-Aware**: Understands OpenEMR's database schema from source code
- **Transaction-Safe**: Uses transactions for atomic operations
- **Parallel Processing**: Multiple workers writing concurrently

#### Database Schema Mapping

| OMOP Table | OMOP Field | OpenEMR Table | OpenEMR Field |
|------------|------------|---------------|----------------|
| PERSON | person_id | patient_data | pid |
| PERSON | year_of_birth | patient_data | DOB (year) |
| PERSON | gender_concept_id | patient_data | sex |
| CONDITION_OCCURRENCE | condition_concept_id | lists | diagnosis |
| CONDITION_OCCURRENCE | condition_start_date | lists | begdate |
| DRUG_EXPOSURE | drug_concept_id | lists | diagnosis |
| DRUG_EXPOSURE | drug_exposure_start_date | lists | begdate |

### Data Flow

1. **Load OMOP Data**: Reads from S3 or local filesystem
2. **Direct Database Write**: Writes directly to OpenEMR database tables
3. **Parallel Processing**: Multiple workers process batches concurrently

**Note**: Warp writes directly to OpenEMR database tables - no CCDA conversion or intermediate formats are used.

## Performance

### Benchmark Results

**Full Dataset Import (synpuf-omop 1k dataset)**:
- **Dataset**: 1,000 patients with 160,322 conditions, 49,542 medications, 13,481 observations
- **Configuration**: Single worker, batch size 100
- **Results**:
  - Patients successfully uploaded: 1,000 (100% success rate)
  - Failed: 0
  - **Total duration**: 132.96 seconds (~2.22 minutes)
  - **Processing rate**: ~7.5 records/second
  - **Total data imported**: 224,345 records (1,000 patients + 160,322 conditions + 49,542 medications + 13,481 observations)

**Performance Notes**:
- Single worker configuration provides stable, reliable imports
- Multi-worker configuration can achieve higher throughput but requires careful database connection management
- Processing time includes data loading from S3, transformation, and database insertion

### Kubernetes Resource Recommendations

**Standard Configuration** (tested benchmark):
```yaml
resources:
  requests:
    cpu: "2"
    memory: "4Gi"
  limits:
    cpu: "4"
    memory: "8Gi"
```
- **Performance**: ~7.5 patients imported per second
- **Tested**: Successfully imported 1,000 patients in 2.22 minutes

## End-to-End Testing

For comprehensive testing of the complete Warp deployment and data import workflow, use the automated end-to-end test script:

```bash
# Full end-to-end test (deploys infrastructure, OpenEMR, and imports 1000 records)
cd ../scripts
./test-warp-end-to-end.sh

# Import 500 records instead
./test-warp-end-to-end.sh --max-records 500

# Use existing infrastructure
./test-warp-end-to-end.sh --skip-terraform --skip-openemr
```

**What the End-to-End Test Does:**
1. Deploys Terraform infrastructure (EKS, RDS, Redis, EFS, etc.)
2. Deploys OpenEMR on EKS
3. Installs Warp via ConfigMap
4. Imports test data using Warp
5. Prints OpenEMR login URL and credentials
6. Waits a default of 5 minutes while the user verifies successful data import
7. Deletes all infrastructure with `destroy.sh`

See `scripts/README.md` for complete documentation of the end-to-end test script.

## Kubernetes Deployment

Warp is designed to run as a Kubernetes Job with generous resources. There are two deployment approaches:

### S3 Access via IRSA (IAM Roles for Service Accounts)

**How it works**: Warp uses **IRSA** (IAM Roles for Service Accounts) to access S3 buckets securely without hardcoded credentials.

1. **Service Account**: The Kubernetes Job uses the `openemr-sa` service account
2. **IAM Role Binding**: The service account is annotated with an AWS IAM role ARN
3. **Automatic Credential Discovery**: When `boto3` runs in the pod, it automatically discovers credentials from:
   - The mounted service account token at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
   - AWS SDK automatically uses IRSA credentials (no manual configuration needed)
4. **IAM Permissions**: The IAM role must have S3 read permissions for your dataset buckets

**Required IAM Permissions**:

The IAM role (configured in `terraform/iam.tf`) needs S3 permissions for dataset buckets. **For security, these permissions are commented out by default** to prevent accidental access.

**Enabling S3 Access**:

1. **Edit `terraform/iam.tf`** and locate the "S3 permissions for Warp dataset access" section
2. **Uncomment** the Resource array entries and specify your bucket ARNs:

```hcl
{
  # S3 permissions for Warp dataset access (OMOP/CCDA data sources)
  Effect = "Allow"
  Action = [
    "s3:GetObject",
    "s3:ListBucket"
  ]
  Resource = [
    # Uncomment and specify your bucket ARNs:
    "arn:aws:s3:::synpuf-omop",
    "arn:aws:s3:::synpuf-omop/*"
  ]
}
```

3. **Apply Terraform changes**:

```bash
cd terraform
terraform apply
```

**Security Best Practice**: Only grant access to specific buckets that Warp needs. Never use wildcards (`*`) for bucket names in production environments.

**Note**: The job does **NOT** use the cluster's node IAM role. It uses IRSA for pod-level, least-privilege access.

### Architecture Choice: Build Inside Pod (Recommended)

**Why**: This approach uses an off-the-shelf Python 3.14 image and builds warp inside the pod from a ConfigMap. This eliminates the need to:
- Build and maintain custom Docker images
- Push images to container registries
- Deal with image versioning and updates
- Require public repository access

**How it works**:
1. Warp code is packaged as a tarball and stored in a Kubernetes ConfigMap
2. Pod uses `python:3.14-slim` base image
3. On startup, the pod extracts the code from ConfigMap and installs warp
4. Warp runs with direct database access from within the cluster

**Setup**:

```bash
# 1. Package warp code
cd warp
tar czf /tmp/warp-code.tar.gz warp/ setup.py requirements.txt README.md

# 2. Create ConfigMap
kubectl create configmap warp-code \
  --from-file=warp-code.tar.gz=/tmp/warp-code.tar.gz \
  -n openemr

# 3. Deploy job (see k8s-job-test.yaml)
kubectl apply -f k8s-job-test.yaml
```

**Example Job**:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: warp-ccda-upload-test
  namespace: openemr
spec:
  template:
    spec:
      containers:
      - name: warp
        # Python image version is managed in versions.yaml under applications.python
        # The version automatically tracks the latest Python 3.xx release
        # To use a specific version, replace with: python:3.14-slim
        image: python:3.14-slim
        command: ["/bin/bash"]
        args:
        - -c
        - |
          apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
          pip install --no-cache-dir pymysql>=1.1.0 boto3>=1.28.0
          tar xzf /warp-code/warp-code.tar.gz
          cd warp && pip install --no-cache-dir -e .
          warp ccda_data_upload --db-host "$DB_HOST" ...
        volumeMounts:
        - name: warp-code
          mountPath: /warp-code
          readOnly: true
      volumes:
      - name: warp-code
        configMap:
          name: warp-code
```

**Python Version Management**:

The Python Docker image version is centrally managed in `versions.yaml`:
- **Location**: `applications.python.current` (defaults to `3.14`)
- **Auto-detection**: When `auto_detect_latest: true`, the version manager automatically checks Docker Hub for the latest Python 3.xx release
- **Script**: Use `scripts/get-python-image-version.sh` to get the current version programmatically
- **Updates**: The monthly version check workflow will notify when newer Python 3.xx versions are available

### Alternative: Custom Docker Image

If you prefer a pre-built image, you can build and push a custom Docker image:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: warp-import
  namespace: openemr
spec:
  template:
    spec:
      containers:
      - name: warp
        image: openemr/warp:latest
        command: ["warp", "ccda_data_upload"]
        args:
          - "--data-source"
          - "s3://synpuf-omop/cmsdesynpuf1k/"
          - "--max-records"
          - "10000"
        resources:
          requests:
            cpu: "4"
            memory: "8Gi"
          limits:
            cpu: "8"
            memory: "16Gi"
      restartPolicy: Never
```

See `k8s-job.yaml` and `k8s-job-test.yaml` for complete examples.

## Configuration

### Command-Line Options

#### `ccda_data_upload` Command

Uploads patient data to OpenEMR from OMOP format datasets using direct database import.

| Option | Description | Default |
|--------|-------------|---------|
| `--db-host` | Database host | Auto-discovered |
| `--db-user` | Database username | Auto-discovered |
| `--db-password` | Database password | Auto-discovered |
| `--db-name` | Database name | openemr |
| `--data-source` | Data source (S3 path or local directory) | Required |
| `--batch-size` | Records per batch | Auto-calculated |
| `--workers` | Number of parallel workers (for a single task) | CPU count |
| `--max-records` | Maximum records to process | All records |
| `--start-from` | Start processing from record number | 0 |
| `--dry-run` | Dry run mode (no actual import) | False |
| `--aws-region` | AWS region for S3 access | Auto-detected |
| `--namespace` | Kubernetes namespace | openemr |
| `--terraform-dir` | Terraform directory path | Auto-detected |

### Environment Variables

```bash
# Database Configuration (required)
export DB_HOST="aurora-cluster.region.rds.amazonaws.com"
export DB_USER="openemr"
export DB_PASSWORD="password"
export DB_NAME="openemr"

# AWS Configuration
export AWS_REGION="us-west-2"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
```

## Troubleshooting

### Common Issues

#### Auto-Discovery Fails

**Problem**: Warp cannot find credentials automatically.

**Solution**:
1. Check Kubernetes secrets exist: `kubectl get secret openemr-db-credentials -n openemr`
2. Verify Terraform outputs: `terraform output -json`
3. Provide database credentials manually using `--db-host`, `--db-user`, `--db-password`

#### Database Connection Fails

**Problem**: Cannot connect to OpenEMR database.

**Solution**:
```bash
# Test database connectivity
kubectl exec -n openemr <pod> -- mysql -h <db-host> -u <user> -p<password> -e "SELECT 1"

# Check network connectivity
kubectl exec -n openemr <pod> -- nc -zv <db-host> 3306
```

#### Performance Issues

**Problem**: Import is slower than expected.

**Solution**:
- Experiment with changing batch size
- Experiment with changing worker count
- Monitor database CPU/memory usage
- Verify network latency to database

#### Data Import Errors

**Problem**: Some records fail to import.

**Solution**:
- Enable verbose logging: `warp -v ccda_data_upload ...`
- Check logs for specific error messages
- Verify OMOP data format matches expected schema
- Review OpenEMR database constraints
- Check for duplicate patient IDs

### Debug Mode

Enable verbose logging for detailed debugging:

```bash
warp -v ccda_data_upload \
  --data-source s3://bucket/path \
  --max-records 10
```

## Development

### Setup

```bash
# Install development dependencies
pip install -r requirements.txt
pip install pytest pytest-cov flake8 black mypy

# Install warp in development mode
pip install -e .
```

### Running Tests

```bash
# Run all tests
pytest tests/ -v

# Run with coverage
pytest tests/ -v --cov=warp --cov-report=html

# Run specific test file
pytest tests/test_omop_to_ccda.py -v
```

### Code Quality

```bash
# Linting
flake8 warp/ --max-line-length=127

# Formatting
black warp/ tests/ --line-length 127

# Type checking
mypy warp/ --ignore-missing-imports
```

### CI/CD

The project uses GitHub Actions for CI/CD (integrated into main CI/CD pipeline):
- **Pinned versions test**: Automatically validates that Python package versions match versions.yaml
- Automated testing with pytest
- Code quality checks (flake8, black, mypy)
- Security scanning (Trivy)
- Coverage reporting

The CI/CD pipeline includes a step (`test-warp-pinned-versions.sh`) that:
- Reads Python package versions from `versions.yaml`
- Installs exact pinned versions
- Verifies versions match expectations
- Runs all Warp tests with pinned versions
- Ensures consistency between versions.yaml and actual dependencies

This ensures that the versions specified in `versions.yaml` are always tested and validated before code is merged.

## Advanced Topics

For advanced development topics, architecture details, and contributing guidelines, see [DEVELOPER.md](DEVELOPER.md).

## License

MIT License
