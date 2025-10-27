#!/bin/bash

# =============================================================================
# OpenEMR EKS Backup Script
# =============================================================================
#
# Purpose:
#   Performs comprehensive backup of an OpenEMR deployment on Amazon EKS,
#   including RDS database snapshots, Kubernetes configurations, secrets,
#   and application data from EFS volumes. Creates both machine-readable
#   metadata and human-readable reports for disaster recovery operations.
#
# Key Features:
#   - RDS Aurora cluster snapshot creation with availability verification
#   - Kubernetes namespace export (deployments, services, secrets, configmaps, PVCs, PVs)
#   - Application data backup from EFS volumes
#   - S3 backup bucket creation with versioning and encryption
#   - Comprehensive metadata generation for restore operations
#   - Human-readable backup reports with verification steps
#   - Error handling and rollback capabilities
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - kubectl configured to access the EKS cluster
#   - Terraform state available for infrastructure discovery
#   - Sufficient AWS permissions for RDS, S3, and EFS operations
#
# Usage:
#   ./backup.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME     EKS cluster name (default: openemr-eks)
#   --source-region REGION  AWS region where resources are located (default: us-west-2)
#   --backup-region REGION  AWS region for backup storage (default: us-west-2)
#   --namespace NAMESPACE   Kubernetes namespace (default: openemr)
#   --help                  Show this help message
#
# Environment Variables:
#   CLUSTER_NAME                  EKS cluster name (default: openemr-eks)
#   AWS_REGION                    AWS region for source resources (default: us-west-2)
#   BACKUP_REGION                 AWS region for backup storage (default: same as AWS_REGION)
#   NAMESPACE                     Kubernetes namespace (default: openemr)
#   BACKUP_STRATEGY               Backup strategy: same-region, cross-region, cross-account (default: same-region)
#   TARGET_ACCOUNT_ID             Target AWS account ID for cross-account backups (optional)
#   KMS_KEY_ID                    KMS key ID for encrypted snapshots (optional, uses default if empty)
#   COPY_TAGS                     Whether to copy tags to backup snapshots (default: true)
#   CLUSTER_AVAILABILITY_TIMEOUT  RDS cluster availability timeout in seconds (default: 1800)
#   SNAPSHOT_AVAILABILITY_TIMEOUT RDS snapshot availability timeout in seconds (default: 1800)
#   POLLING_INTERVAL              Polling interval in seconds for status checks (default: 30)
#
# Examples:
#   ./backup.sh
#   ./backup.sh --cluster-name my-eks --namespace production
#   ./backup.sh --backup-region us-east-1
#
# =============================================================================

set -e

# Color codes for terminal output - provides visual feedback during backup operations
# These colors help distinguish between different types of messages (info, success, warnings, errors)
RED='\033[0;31m'      # Error messages and critical failures
GREEN='\033[0;32m'    # Success messages and completed operations
YELLOW='\033[1;33m'   # Warning messages and non-critical issues
BLUE='\033[0;34m'     # Information messages and progress updates
NC='\033[0m'          # No Color - reset to default terminal color

# Configuration variables with defaults
# These can be overridden via command-line arguments or environment variables
CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}           # EKS cluster name for resource discovery
AWS_REGION=${AWS_REGION:-"us-west-2"}                 # AWS region where OpenEMR resources are deployed
BACKUP_REGION=${BACKUP_REGION:-"$AWS_REGION"}         # AWS region where backup data will be stored (defaults to source region)
NAMESPACE=${NAMESPACE:-"openemr"}                     # Kubernetes namespace containing OpenEMR resources

# Enhanced backup configuration for new RDS cross-Region/cross-account capabilities
BACKUP_STRATEGY=${BACKUP_STRATEGY:-"same-region"}    # Backup strategy: same-region, cross-region, cross-account
TARGET_ACCOUNT_ID=${TARGET_ACCOUNT_ID:-""}           # Target AWS account ID for cross-account backups (optional)
KMS_KEY_ID=${KMS_KEY_ID:-""}                         # KMS key ID for encrypted snapshots (optional, uses default if empty)
COPY_TAGS=${COPY_TAGS:-"true"}                       # Whether to copy tags to backup snapshots

# Backup identification and organization
TIMESTAMP=$(date +%Y%m%d-%H%M%S)                     # Timestamp for backup identification and organization
BACKUP_ID="openemr-backup-${TIMESTAMP}"              # Unique identifier for this backup operation

# Polling configuration for AWS resource availability checks
# These timeouts prevent the script from hanging indefinitely while waiting for AWS resources
CLUSTER_AVAILABILITY_TIMEOUT=${CLUSTER_AVAILABILITY_TIMEOUT:-1800}    # 30 minutes - max wait for RDS cluster to be available
SNAPSHOT_AVAILABILITY_TIMEOUT=${SNAPSHOT_AVAILABILITY_TIMEOUT:-1800}  # 30 minutes - max wait for snapshot to be available
POLLING_INTERVAL=${POLLING_INTERVAL:-30}                              # 30 seconds - interval between availability checks

# Help function - displays comprehensive usage information and examples
# This function provides users with clear guidance on how to use the backup script
# including available options, environment variables, and what gets backed up
show_help() {
    echo "OpenEMR EKS Backup Script"
    echo "=========================="
    echo ""
    echo "Comprehensive backup solution for OpenEMR on Amazon EKS"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --cluster-name NAME     EKS cluster name (default: openemr-eks)"
    echo "  --source-region REGION  Source AWS region (default: us-west-2)"
    echo "  --backup-region REGION  Backup AWS region (default: same as source)"
    echo "  --namespace NAMESPACE   Kubernetes namespace (default: openemr)"
    echo "  --strategy STRATEGY     Backup strategy: same-region, cross-region, cross-account (default: same-region)"
    echo "  --target-account ID     Target AWS account ID for cross-account backups"
    echo "  --kms-key-id KEY        KMS key ID for encrypted snapshots (optional)"
    echo "  --no-copy-tags          Don't copy tags to backup snapshots"
    echo "  --help                  Show this help message"
    echo ""
    echo "Environment Variables for Timeouts:"
    echo "  CLUSTER_AVAILABILITY_TIMEOUT  Timeout for RDS cluster availability (default: 1800s = 30m)"
    echo "  SNAPSHOT_AVAILABILITY_TIMEOUT Timeout for RDS snapshot availability (default: 1800s = 30m)"
    echo "  POLLING_INTERVAL              Polling interval in seconds (default: 30s)"
    echo ""
    echo "What Gets Backed Up:"
    echo "  ✅ RDS Aurora cluster snapshots (database state)"
    echo "  ✅ Kubernetes configurations and secrets (deployment state)"
    echo "  ✅ Application data from EFS volumes (file system state)"
    echo "  ✅ Backup metadata and restore instructions (recovery guidance)"
    echo ""
    echo "Backup Strategies:"
    echo "  📍 same-region     - Backup in same region (fastest, lowest cost)"
    echo "  🌍 cross-region    - Backup to different region (disaster recovery)"
    echo "  🏢 cross-account   - Backup to different AWS account (compliance/sharing)"
    echo ""
    echo "Backup Process:"
    echo "  1. Validate prerequisites and AWS connectivity"
    echo "  2. Create S3 backup bucket with encryption and versioning"
    echo "  3. Create RDS Aurora cluster snapshot"
    echo "  4. Copy snapshot using new RDS cross-Region/cross-account capabilities"
    echo "  5. Export Kubernetes namespace resources"
    echo "  6. Backup application data from EFS volumes"
    echo "  7. Generate comprehensive metadata and reports"
    echo ""
    echo "Examples:"
    echo "  # Same region backup (default)"
    echo "  $0 --strategy same-region"
    echo ""
    echo "  # Cross-region disaster recovery"
    echo "  $0 --strategy cross-region --backup-region us-east-1"
    echo ""
    echo "  # Cross-account backup for compliance"
    echo "  $0 --strategy cross-account --target-account 123456789012 --backup-region us-east-1"
    echo ""
    echo "⚠️  WARNING: This script will create AWS resources (S3 buckets, RDS snapshots)"
    echo "   Ensure you have proper AWS credentials and permissions."
    echo "   Backup costs will be incurred for S3 storage and RDS snapshot storage."
    exit 0
}

# Parse command line arguments
# This section processes command-line options and overrides default configuration values
# Each option updates the corresponding configuration variable for the backup operation
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name)
            CLUSTER_NAME="$2"      # Override default EKS cluster name
            shift 2
            ;;
        --source-region)
            AWS_REGION="$2"        # Override default AWS region for source resources
            shift 2
            ;;
        --backup-region)
            BACKUP_REGION="$2"     # Override default AWS region for backup storage
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"         # Override default Kubernetes namespace
            shift 2
            ;;
        --strategy)
            BACKUP_STRATEGY="$2"   # Set backup strategy (same-region, cross-region, cross-account)
            shift 2
            ;;
        --target-account)
            TARGET_ACCOUNT_ID="$2" # Set target AWS account ID for cross-account backups
            shift 2
            ;;
        --kms-key-id)
            KMS_KEY_ID="$2"        # Set KMS key ID for encrypted snapshots
            shift 2
            ;;
        --no-copy-tags)
            COPY_TAGS="false"      # Disable tag copying to backup snapshots
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Logging functions - provide consistent, color-coded output for different message types
# These functions ensure all backup operations have clear, timestamped feedback
# Each function uses appropriate colors and emojis for visual distinction

log_info() {
    # Display informational messages in blue with info emoji
    # Used for progress updates, status information, and general feedback
    echo -e "${BLUE}[$(date '+%H:%M:%S')] ℹ️  $1${NC}"
}

log_success() {
    # Display success messages in green with checkmark emoji
    # Used when operations complete successfully or milestones are reached
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $1${NC}"
}

log_warning() {
    # Display warning messages in yellow with warning emoji
    # Used for non-critical issues that don't stop the backup process
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
    # Display error messages in red with X emoji and exit the script
    # Used for critical failures that prevent backup completion
    echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $1${NC}"
    exit 1
}

# Polling functions - wait for AWS resources to reach desired states
# These functions prevent the script from proceeding before resources are ready
# They provide progress feedback and handle timeouts gracefully

wait_for_cluster_availability() {
    # Wait for an RDS Aurora cluster to become available before proceeding
    # This ensures the cluster is in a stable state before creating snapshots
    local cluster_id=$1      # RDS cluster identifier to monitor
    local region=$2          # AWS region where the cluster is located
    local timeout=$3         # Maximum time to wait in seconds
    local start_time
    start_time=$(date +%s)   # Record start time for timeout calculation
    local elapsed=0

    log_info "Waiting for RDS cluster '$cluster_id' to be available in $region..."

    while [ $elapsed -lt "$timeout" ]; do
        # Query the current status of the RDS cluster
        local status
        status=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$cluster_id" \
            --region "$region" \
            --query 'DBClusters[0].Status' \
            --output text 2>/dev/null || echo "unknown")

        # Check if cluster is available (ready for snapshot operations)
        if [ "$status" = "available" ]; then
            log_success "RDS cluster '$cluster_id' is now available"
            return 0
        fi

        # Calculate elapsed time and remaining timeout
        elapsed=$(($(date +%s) - start_time))
        local remaining=$((timeout - elapsed))

        # Check for timeout condition
        if [ $elapsed -ge "$timeout" ]; then
            log_warning "Timeout waiting for cluster availability after ${timeout}s"
            return 1
        fi

        # Provide progress feedback and wait before next check
        log_info "Cluster status: $status (${remaining}s remaining)"
        sleep "$POLLING_INTERVAL"
    done

    return 1
}

wait_for_snapshot_availability() {
    # Wait for an RDS Aurora cluster snapshot to become available
    # This ensures the snapshot is complete and ready for restore operations
    local snapshot_id=$1     # RDS cluster snapshot identifier to monitor
    local region=$2          # AWS region where the snapshot is located
    local timeout=$3         # Maximum time to wait in seconds
    local start_time
    start_time=$(date +%s)   # Record start time for timeout calculation
    local elapsed=0

    log_info "Waiting for RDS snapshot '$snapshot_id' to be available in $region..."

    while [ $elapsed -lt "$timeout" ]; do
        # Query the current status of the RDS cluster snapshot
        local status
        status=$(aws rds describe-db-cluster-snapshots \
            --db-cluster-snapshot-identifier "$snapshot_id" \
            --region "$region" \
            --query 'DBClusterSnapshots[0].Status' \
            --output text 2>/dev/null || echo "unknown")

        # Check if snapshot is available (ready for restore operations)
        if [ "$status" = "available" ]; then
            log_success "RDS snapshot '$snapshot_id' is now available"
            return 0
        fi

        # Calculate elapsed time and remaining timeout
        elapsed=$(($(date +%s) - start_time))
        local remaining=$((timeout - elapsed))

        # Check for timeout condition
        if [ $elapsed -ge "$timeout" ]; then
            log_warning "Timeout waiting for snapshot availability after ${timeout}s"
            return 1
        fi

        log_info "Snapshot status: $status (${remaining}s remaining)"
        sleep "$POLLING_INTERVAL"
    done

    return 1
}

# Initialize backup
echo -e "${GREEN}🚀 OpenEMR Backup Starting${NC}"
echo -e "${BLUE}=========================${NC}"
echo -e "${BLUE}Backup ID: ${BACKUP_ID}${NC}"
echo -e "${BLUE}Source Region: ${AWS_REGION}${NC}"
echo -e "${BLUE}Backup Region: ${BACKUP_REGION}${NC}"
echo -e "${BLUE}Cluster: ${CLUSTER_NAME}${NC}"
echo ""

# Check dependencies
check_dependencies() {
    local missing_deps=()

    # Check AWS CLI
    if ! command -v aws >/dev/null 2>&1; then
        missing_deps+=("aws")
    fi

    # Check kubectl
    if ! command -v kubectl >/dev/null 2>&1; then
        missing_deps+=("kubectl")
    fi

    # Check tar
    if ! command -v tar >/dev/null 2>&1; then
        missing_deps+=("tar")
    fi

    # Check gzip
    if ! command -v gzip >/dev/null 2>&1; then
        missing_deps+=("gzip")
    fi

    # Check jq (required for metadata generation)
    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install: ${missing_deps[*]}"
        exit 1
    fi
}

# Function to validate backup strategy configuration
# This function ensures the backup strategy is properly configured and validates required parameters
validate_backup_strategy() {
    log_info "Validating backup strategy: $BACKUP_STRATEGY"
    
    case "$BACKUP_STRATEGY" in
        "same-region")
            # Same region backup - no additional validation needed
            log_info "Using same-region backup strategy"
            ;;
        "cross-region")
            # Cross-region backup - validate regions are different
            if [ "$AWS_REGION" = "$BACKUP_REGION" ]; then
                log_error "Cross-region backup requires different source and backup regions"
                log_info "Current: source=$AWS_REGION, backup=$BACKUP_REGION"
                exit 1
            fi
            log_info "Using cross-region backup strategy: $AWS_REGION -> $BACKUP_REGION"
            ;;
        "cross-account")
            # Cross-account backup - validate target account ID and regions
            if [ -z "$TARGET_ACCOUNT_ID" ]; then
                log_error "Cross-account backup requires --target-account parameter"
                exit 1
            fi
            
            # Validate account ID format (12 digits)
            if ! [[ "$TARGET_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
                log_error "Invalid AWS account ID format: $TARGET_ACCOUNT_ID (must be 12 digits)"
                exit 1
            fi
            
            if [ "$AWS_REGION" = "$BACKUP_REGION" ]; then
                log_warning "Cross-account backup with same region - consider using different region for better disaster recovery"
            fi
            
            log_info "Using cross-account backup strategy: account $TARGET_ACCOUNT_ID, region $BACKUP_REGION"
            ;;
        *)
            log_error "Invalid backup strategy: $BACKUP_STRATEGY"
            log_info "Valid strategies: same-region, cross-region, cross-account"
            exit 1
            ;;
    esac
    
    log_success "Backup strategy validated"
}

# Check prerequisites
log_info "Checking prerequisites..."

# Check dependencies
check_dependencies

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS credentials not configured"
    exit 1
fi

# Check regions
for region in "$AWS_REGION" "$BACKUP_REGION"; do
    if ! aws ec2 describe-regions --region-names "$region" >/dev/null 2>&1; then
        log_error "Cannot access region: $region"
        exit 1
    fi
done

# Validate backup strategy
validate_backup_strategy

log_success "Prerequisites verified"

# Create backup bucket
BACKUP_BUCKET="openemr-backups-$(aws sts get-caller-identity --query Account --output text)-${CLUSTER_NAME}-$(date +%Y%m%d)"

log_info "Creating backup bucket: s3://${BACKUP_BUCKET}"

if ! aws s3 ls "s3://${BACKUP_BUCKET}" --region "$BACKUP_REGION" >/dev/null 2>&1; then
    aws s3 mb "s3://${BACKUP_BUCKET}" --region "$BACKUP_REGION"

    # Enable versioning and encryption
    aws s3api put-bucket-versioning \
        --bucket "$BACKUP_BUCKET" \
        --region "$BACKUP_REGION" \
        --versioning-configuration Status=Enabled

    aws s3api put-bucket-encryption \
        --bucket "$BACKUP_BUCKET" \
        --region "$BACKUP_REGION" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'

    log_success "Backup bucket created and configured"
else
    log_info "Backup bucket already exists"
fi

# Initialize backup results
BACKUP_RESULTS=""
BACKUP_SUCCESS=true

# Function to add result
add_result() {
    local component=$1
    local status=$2
    local details=$3

    BACKUP_RESULTS="${BACKUP_RESULTS}${component}: ${status}"
    if [ -n "$details" ]; then
        BACKUP_RESULTS="${BACKUP_RESULTS} (${details})"
    fi
    BACKUP_RESULTS="${BACKUP_RESULTS}\n"

    if [ "$status" = "FAILED" ]; then
        BACKUP_SUCCESS=false
    fi
}

# Backup RDS Aurora cluster
log_info "🗄️  Backing up RDS Aurora cluster..."

# Get cluster ID from Terraform or discover
AURORA_CLUSTER_ID=""
if [ -f "terraform/terraform.tfstate" ]; then
    AURORA_CLUSTER_ID=$(cd terraform && terraform output -raw aurora_cluster_id 2>/dev/null | grep -E '^[a-zA-Z0-9-]+$' | head -1 || echo "")
fi

if [ -z "$AURORA_CLUSTER_ID" ]; then
    # Try to discover cluster
    AURORA_CLUSTER_ID=$(aws rds describe-db-clusters \
        --region "$AWS_REGION" \
        --query "DBClusters[?contains(DBClusterIdentifier, '${CLUSTER_NAME}')].DBClusterIdentifier" \
        --output text 2>/dev/null | head -1)
fi

if [ -n "$AURORA_CLUSTER_ID" ] && [ "$AURORA_CLUSTER_ID" != "None" ]; then
    log_info "Found Aurora cluster: ${AURORA_CLUSTER_ID}"

    # Wait for cluster to be available before creating snapshot
    if wait_for_cluster_availability "$AURORA_CLUSTER_ID" "$AWS_REGION" "$CLUSTER_AVAILABILITY_TIMEOUT"; then
        # Create snapshot
        SNAPSHOT_ID="${AURORA_CLUSTER_ID}-backup-${TIMESTAMP}"
        log_info "Creating snapshot: ${SNAPSHOT_ID}"

        if aws rds create-db-cluster-snapshot \
            --region "$AWS_REGION" \
            --db-cluster-identifier "$AURORA_CLUSTER_ID" \
            --db-cluster-snapshot-identifier "$SNAPSHOT_ID" >/dev/null 2>&1; then

            log_success "Aurora snapshot created: ${SNAPSHOT_ID}"

            # Enhanced snapshot copying using new RDS cross-Region/cross-account capabilities
            if [ "$BACKUP_STRATEGY" != "same-region" ]; then
                log_info "Enhanced backup strategy detected - using new RDS cross-Region/cross-account capabilities"

                # Generate backup snapshot name
                BACKUP_SNAPSHOT_ID="${SNAPSHOT_ID}-${BACKUP_REGION}"
                if [ "$BACKUP_STRATEGY" = "cross-account" ]; then
                    BACKUP_SNAPSHOT_ID="${SNAPSHOT_ID}-${TARGET_ACCOUNT_ID}-${BACKUP_REGION}"
                fi

                # Build copy command with new RDS capabilities
                COPY_CMD="aws rds copy-db-cluster-snapshot"
                COPY_CMD="$COPY_CMD --source-db-cluster-snapshot-identifier \"arn:aws:rds:${AWS_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):cluster-snapshot:${SNAPSHOT_ID}\""
                COPY_CMD="$COPY_CMD --target-db-cluster-snapshot-identifier \"${BACKUP_SNAPSHOT_ID}\""
                COPY_CMD="$COPY_CMD --source-region \"${AWS_REGION}\""
                COPY_CMD="$COPY_CMD --region \"${BACKUP_REGION}\""

                # Add cross-account destination if specified
                if [ "$BACKUP_STRATEGY" = "cross-account" ]; then
                    COPY_CMD="$COPY_CMD --destination-region \"${BACKUP_REGION}\""
                    COPY_CMD="$COPY_CMD --destination-account-id \"${TARGET_ACCOUNT_ID}\""
                    log_info "Cross-account copy: source account -> account $TARGET_ACCOUNT_ID"
                fi

                # Handle KMS key for encrypted snapshots
                KMS_KEY_PARAM=""
                if [ -n "$KMS_KEY_ID" ]; then
                    # Use specified KMS key
                    KMS_KEY_PARAM="--kms-key-id $KMS_KEY_ID"
                    log_info "Using specified KMS key: $KMS_KEY_ID"
                elif aws rds describe-db-cluster-snapshots \
                    --region "$AWS_REGION" \
                    --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
                    --query 'DBClusterSnapshots[0].StorageEncrypted' \
                    --output text 2>/dev/null | grep -q "True"; then
                    # Auto-detect KMS key for encrypted snapshots
                    log_info "RDS cluster is encrypted - auto-detecting KMS key"
                    
                    if [ "$BACKUP_STRATEGY" = "cross-account" ]; then
                        # For cross-account, use default KMS key in target account
                        DEFAULT_KMS_KEY=$(aws kms list-aliases \
                            --region "$BACKUP_REGION" \
                            --query "Aliases[?AliasName==\`alias/aws/rds\`].TargetKeyId" \
                            --output text 2>/dev/null || echo "")
                    else
                        # For cross-region, use default KMS key in backup region
                        DEFAULT_KMS_KEY=$(aws kms list-aliases \
                            --region "$BACKUP_REGION" \
                            --query "Aliases[?AliasName==\`alias/aws/rds\`].TargetKeyId" \
                            --output text 2>/dev/null || echo "")
                    fi

                    if [ -n "$DEFAULT_KMS_KEY" ]; then
                        KMS_KEY_PARAM="--kms-key-id $DEFAULT_KMS_KEY"
                        log_info "Using auto-detected KMS key: $DEFAULT_KMS_KEY"
                    else
                        log_warning "No default KMS key found in backup region - copy may fail"
                    fi
                fi

                # Add copy tags if enabled
                if [ "$COPY_TAGS" = "true" ]; then
                    COPY_CMD="$COPY_CMD --copy-tags"
                    log_info "Copying tags to backup snapshot"
                fi

                # Wait for snapshot to be available before copying
                log_info "Waiting for source snapshot to be available before copying..."
                if wait_for_snapshot_availability "$SNAPSHOT_ID" "$AWS_REGION" "$SNAPSHOT_AVAILABILITY_TIMEOUT"; then
                    # Execute the enhanced copy command
                    log_info "Executing enhanced snapshot copy..."
                    log_info "Command: $COPY_CMD $KMS_KEY_PARAM"
                    
                    if eval "$COPY_CMD $KMS_KEY_PARAM" >/dev/null 2>&1; then
                        log_success "Enhanced snapshot copy initiated: ${BACKUP_SNAPSHOT_ID}"

                        # Wait for copy to complete using polling function
                        log_info "Waiting for enhanced snapshot copy to complete..."
                        if wait_for_snapshot_availability "$BACKUP_SNAPSHOT_ID" "$BACKUP_REGION" "$SNAPSHOT_AVAILABILITY_TIMEOUT"; then
                            log_success "Enhanced snapshot copy completed successfully"
                            SNAPSHOT_ID="$BACKUP_SNAPSHOT_ID"  # Use the copied snapshot ID
                            
                            # Update result based on strategy
                            case "$BACKUP_STRATEGY" in
                                "cross-region")
                                    add_result "Aurora RDS" "SUCCESS" "$SNAPSHOT_ID (cross-region copy completed)"
                                    ;;
                                "cross-account")
                                    add_result "Aurora RDS" "SUCCESS" "$SNAPSHOT_ID (cross-account copy completed)"
                                    ;;
                            esac
                        else
                            log_warning "Enhanced snapshot copy did not complete within timeout"
                            add_result "Aurora RDS" "WARNING" "$SNAPSHOT_ID (copy timeout)"
                        fi
                    else
                        log_warning "Failed to initiate enhanced snapshot copy"
                        log_info "Snapshot exists in source region but enhanced copy failed"
                        log_info "Manual copy command:"
                        echo ""
                        echo "$COPY_CMD $KMS_KEY_PARAM"
                        echo ""
                        add_result "Aurora RDS" "WARNING" "$SNAPSHOT_ID (enhanced copy failed)"
                    fi
                else
                    log_warning "Source snapshot did not become available within timeout"
                    add_result "Aurora RDS" "WARNING" "$SNAPSHOT_ID (source snapshot timeout)"
                fi
            else
                add_result "Aurora RDS" "SUCCESS" "$SNAPSHOT_ID"
            fi
        else
            log_warning "Failed to create Aurora snapshot"
            add_result "Aurora RDS" "FAILED" "Snapshot creation failed"
        fi
    else
        # Get actual cluster status for the error message
        CLUSTER_STATUS=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$AURORA_CLUSTER_ID" \
            --region "$AWS_REGION" \
            --query 'DBClusters[0].Status' \
            --output text 2>/dev/null || echo "unknown")
        log_warning "Aurora cluster not available (status: ${CLUSTER_STATUS})"
        add_result "Aurora RDS" "SKIPPED" "Cluster not available (status: ${CLUSTER_STATUS})"
    fi
else
    log_warning "No Aurora cluster found"
    add_result "Aurora RDS" "SKIPPED" "No cluster found"
fi

# Backup Kubernetes configurations
log_info "⚙️  Backing up Kubernetes configurations..."

if kubectl cluster-info >/dev/null 2>&1; then
    log_info "Kubernetes cluster accessible"

    # Create backup directory
    K8S_BACKUP_DIR="k8s-backup-${TIMESTAMP}"
    mkdir -p "$K8S_BACKUP_DIR"

    # Export all resources
    kubectl get all -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/all-resources.yaml" 2>/dev/null || true
    kubectl get secrets -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/secrets.yaml" 2>/dev/null || true
    kubectl get configmaps -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/configmaps.yaml" 2>/dev/null || true
    kubectl get pvc -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/pvc.yaml" 2>/dev/null || true
    kubectl get ingress -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/ingress.yaml" 2>/dev/null || true
    kubectl get hpa -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/hpa.yaml" 2>/dev/null || true
    kubectl get storageclass -o yaml > "$K8S_BACKUP_DIR/storage.yaml" 2>/dev/null || true

    # Create archive
    tar -czf "${K8S_BACKUP_DIR}.tar.gz" "$K8S_BACKUP_DIR"

    # Upload to S3
    if aws s3 cp "${K8S_BACKUP_DIR}.tar.gz" "s3://${BACKUP_BUCKET}/kubernetes/" --region "$BACKUP_REGION"; then
        log_success "Kubernetes configurations backed up"
        add_result "Kubernetes Config" "SUCCESS" "${K8S_BACKUP_DIR}.tar.gz"
    else
        log_warning "Failed to upload Kubernetes backup"
        add_result "Kubernetes Config" "FAILED" "Upload failed"
    fi

    # Cleanup
    rm -rf "$K8S_BACKUP_DIR" "${K8S_BACKUP_DIR}.tar.gz"
else
    log_warning "Kubernetes cluster not accessible"
    add_result "Kubernetes Config" "SKIPPED" "Cluster not accessible"
fi

# Helper function: Wait for a Ready OpenEMR pod with EFS volume mounted
wait_for_ready_pod_with_efs() {
    local max_attempts=30  # 5 minutes (30 * 10 seconds)
    local attempt=1
    
    # Redirect logs to stderr so only pod name goes to stdout
    log_info "Waiting for a Ready OpenEMR pod with EFS volume mounted and swarm mode complete..." >&2
    
    while [ $attempt -le $max_attempts ]; do
        # Get ALL running pods, not just the first one
        local pod_names
        pod_names=$(kubectl get pods -n "$NAMESPACE" -l app=openemr \
            -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null)
        
        # Check each pod to find one that's ready
        for pod_name in $pod_names; do
            if [ -n "$pod_name" ]; then
                # Check if pod is Ready
                local ready
                ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" \
                    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
                
                if [ "$ready" = "True" ]; then
                # Check if sites directory exists (indicates EFS is mounted and initialized)
                if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- \
                   sh -c "test -d /var/www/localhost/htdocs/openemr/sites" 2>/dev/null; then
                    
                    # CRITICAL: Verify container is fully initialized by checking for tar utility
                    # This prevents race conditions where pod is "Ready" but container init isn't complete
                    if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- \
                       sh -c "command -v tar" >/dev/null 2>&1; then
                        
                        # CRITICAL: Verify OpenEMR swarm mode initialization is complete for THIS pod
                        # Check /root/instance-swarm-ready (container-local) not docker-completed (EFS-shared)
                        # This ensures THIS specific pod has completed swarm init, not just a previous pod
                        local instance_swarm_ready
                        instance_swarm_ready=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- \
                           sh -c "test -f /root/instance-swarm-ready && echo 'yes' || echo 'no'" 2>/dev/null || echo 'no')
                        
                        if [ "$instance_swarm_ready" = "yes" ]; then
                            log_success "Found Ready pod with EFS mounted, container initialized, and swarm mode complete: $pod_name" >&2
                            echo "$pod_name"
                            return 0
                        else
                            log_info "Pod $pod_name is Ready but swarm mode still initializing (instance-swarm-ready not found)" >&2
                        fi
                    else
                        log_info "Pod $pod_name is Ready but container not fully initialized yet (tar not available)" >&2
                    fi
                else
                    log_info "Pod $pod_name is Ready but EFS sites directory not mounted yet" >&2
                fi
            else
                log_info "Pod $pod_name is Running but not Ready yet" >&2
            fi
        fi
        done
        
        log_info "Waiting for Ready pod with swarm mode complete (attempt $attempt/$max_attempts)..." >&2
        sleep 10
        ((attempt++))
    done
    
    log_error "No Ready pod with EFS mounted and swarm mode complete found within 5 minutes" >&2
    return 1
}

# Note: We no longer wait for sites/default to exist, as in fresh OpenEMR installations
# this directory is created during the setup wizard. We'll back up whatever exists in
# the sites/ directory, which is sufficient for backup/restore operations.

# Backup application data
log_info "📦 Backing up application data..."

if kubectl cluster-info >/dev/null 2>&1; then
    # Wait for a Ready OpenEMR pod with EFS mounted
    POD_NAME=$(wait_for_ready_pod_with_efs)

    if [ -n "$POD_NAME" ]; then
        log_info "Using OpenEMR pod for backup: ${POD_NAME}"
        
        # Re-verify pod is still running before backup
        pod_phase=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        
        if [ "$pod_phase" != "Running" ]; then
            log_error "Pod $POD_NAME is no longer running (status: $pod_phase)"
            log_error "Pod may have been terminated between selection and backup"
            add_result "Application Data" "FAILED" "Pod terminated before backup"
        else
            log_success "Pod confirmed running - proceeding with backup"

        # Create application data backup (backs up entire sites/ directory)
        # Note: This will back up whatever exists in sites/, even if sites/default
        # hasn't been fully initialized yet (which is normal for fresh installations)
        APP_BACKUP_FILE="app-data-backup-${TIMESTAMP}.tar.gz"

        # Note: tar utility availability was already verified in wait_for_ready_pod_with_efs()
        log_info "Container verified as fully initialized with tar utility available"

        # Check if sites directory exists at all (with detailed error handling)
        log_info "Verifying sites directory exists on pod $POD_NAME..."
        sites_check_output=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c openemr -- sh -c "test -d /var/www/localhost/htdocs/openemr/sites && echo 'EXISTS' || echo 'NOT_FOUND'" 2>&1)
        sites_check_exit=$?
        
        log_info "Sites directory check result: exit=$sites_check_exit, output='$sites_check_output'"
        
        if [ $sites_check_exit -eq 0 ] && [[ "$sites_check_output" == *"EXISTS"* ]]; then
            log_success "Sites directory confirmed accessible"
            
            # Create tar archive with error capture
            log_info "Creating tar archive of sites/ directory..."
            tar_output=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c openemr -- sh -c "tar -czf /tmp/${APP_BACKUP_FILE} -C /var/www/localhost/htdocs/openemr sites/" 2>&1)
            tar_exit=$?
            
            log_info "Tar creation result: exit=$tar_exit"
            
            if [ $tar_exit -eq 0 ]; then
                log_success "Tar archive created successfully"
                
                # Copy from pod
                log_info "Copying tar archive from pod..."
                kubectl cp "${NAMESPACE}/${POD_NAME}:/tmp/${APP_BACKUP_FILE}" "./${APP_BACKUP_FILE}" -c openemr 2>/dev/null

                # Upload to S3
                if aws s3 cp "${APP_BACKUP_FILE}" "s3://${BACKUP_BUCKET}/application-data/" --region "$BACKUP_REGION"; then
                    log_success "Application data backed up"
                    add_result "Application Data" "SUCCESS" "$APP_BACKUP_FILE"
                else
                    log_warning "Failed to upload application data"
                    add_result "Application Data" "FAILED" "Upload failed"
                fi

                # Cleanup
                rm -f "${APP_BACKUP_FILE}"
                kubectl exec -n "$NAMESPACE" "$POD_NAME" -c openemr -- sh -c "rm -f /tmp/${APP_BACKUP_FILE}" 2>/dev/null || true
            else
                log_error "Failed to create tar archive"
                log_error "Tar error output: $tar_output"
                add_result "Application Data" "FAILED" "Tar archive creation failed"
            fi
        else
            log_error "Sites directory not accessible on pod $POD_NAME"
            log_error "Check exit code: $sites_check_exit, output: '$sites_check_output'"
            add_result "Application Data" "FAILED" "Sites directory not found"
        fi
        fi  # Close the else block from pod running check
    else
        log_warning "No Ready OpenEMR pod with EFS mounted found"
        add_result "Application Data" "FAILED" "No Ready pod with EFS available"
    fi
else
    log_warning "Kubernetes cluster not accessible"
    add_result "Application Data" "SKIPPED" "Cluster not accessible"
fi

# Create backup metadata
log_info "📋 Creating backup metadata..."

# Get database configuration details for automatic restore
DB_CONFIG="{}"
if [ -n "$AURORA_CLUSTER_ID" ]; then
    log_info "Capturing database configuration for automatic restore..."

    # Get cluster details
    CLUSTER_DETAILS=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$AURORA_CLUSTER_ID" \
        --region "$AWS_REGION" \
        --query 'DBClusters[0].{EngineMode:EngineMode,ServerlessV2ScalingConfiguration:ServerlessV2ScalingConfiguration,DBSubnetGroup:DBSubnetGroup,VpcSecurityGroups:VpcSecurityGroups}' \
        --output json 2>/dev/null || echo "{}")

    # Get instance details
    INSTANCE_DETAILS=$(aws rds describe-db-instances \
        --region "$AWS_REGION" \
        --filters "Name=db-cluster-id,Values=$AURORA_CLUSTER_ID" \
        --query 'DBInstances[0].{DBInstanceClass:DBInstanceClass,Engine:Engine}' \
        --output json 2>/dev/null || echo "{}")

    # Get VPC and subnet information
    SUBNET_GROUP_NAME=$(echo "$CLUSTER_DETAILS" | jq -r '.DBSubnetGroup' 2>/dev/null || echo "")

    VPC_ID=""
    VPC_CIDR=""
    if [ -n "$SUBNET_GROUP_NAME" ]; then
        VPC_ID=$(aws rds describe-db-subnet-groups \
            --db-subnet-group-name "$SUBNET_GROUP_NAME" \
            --region "$AWS_REGION" \
            --query 'DBSubnetGroups[0].VpcId' \
            --output text 2>/dev/null || echo "")

        if [ -n "$VPC_ID" ]; then
            VPC_CIDR=$(aws ec2 describe-vpcs \
                --vpc-ids "$VPC_ID" \
                --region "$AWS_REGION" \
                --query 'Vpcs[0].CidrBlock' \
                --output text 2>/dev/null || echo "")
        fi
    fi

    # Get security group rules
    SECURITY_GROUP_ID=$(echo "$CLUSTER_DETAILS" | jq -r '.VpcSecurityGroups[0].VpcSecurityGroupId' 2>/dev/null || echo "")
    SECURITY_GROUP_RULES="[]"
    if [ -n "$SECURITY_GROUP_ID" ]; then
        SECURITY_GROUP_RULES=$(aws ec2 describe-security-groups \
            --group-ids "$SECURITY_GROUP_ID" \
            --region "$AWS_REGION" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json 2>/dev/null || echo "[]")
    fi

    # Combine all database configuration
    DB_CONFIG=$(jq -n \
        --arg vpc_id "$VPC_ID" \
        --arg vpc_cidr "$VPC_CIDR" \
        --arg subnet_group_name "$SUBNET_GROUP_NAME" \
        --arg security_group_id "$SECURITY_GROUP_ID" \
        --argjson cluster_config "$CLUSTER_DETAILS" \
        --argjson instance_config "$INSTANCE_DETAILS" \
        --argjson security_group_rules "$SECURITY_GROUP_RULES" \
        '{
            cluster_config: $cluster_config,
            instance_config: $instance_config,
            vpc_id: $vpc_id,
            vpc_cidr: $vpc_cidr,
            subnet_group_name: $subnet_group_name,
            security_group_id: $security_group_id,
            security_group_rules: $security_group_rules
        }' 2>/dev/null || echo "{}")
fi

METADATA_FILE="backup-metadata-${TIMESTAMP}.json"
cat > "$METADATA_FILE" << EOF
{
    "backup_id": "${BACKUP_ID}",
    "timestamp": "${TIMESTAMP}",
    "source_region": "${AWS_REGION}",
    "backup_region": "${BACKUP_REGION}",
    "cluster_name": "${CLUSTER_NAME}",
    "namespace": "${NAMESPACE}",
    "backup_bucket": "${BACKUP_BUCKET}",
    "aurora_cluster_id": "${AURORA_CLUSTER_ID:-"none"}",
    "aurora_snapshot_id": "${SNAPSHOT_ID:-"none"}",
    "backup_success": ${BACKUP_SUCCESS},
    "backup_strategy": "${BACKUP_STRATEGY}",
    "target_account_id": "${TARGET_ACCOUNT_ID:-"none"}",
    "kms_key_id": "${KMS_KEY_ID:-"auto-detected"}",
    "copy_tags": ${COPY_TAGS},
    "components": {
        "aurora_rds": $([ -n "$SNAPSHOT_ID" ] && echo "true" || echo "false"),
        "kubernetes_config": true,
        "application_data": true
    },
    "database_config": $DB_CONFIG,
    "restore_command": "./restore.sh ${BACKUP_BUCKET} ${SNAPSHOT_ID:-none} ${BACKUP_REGION}",
    "created_by": "$(aws sts get-caller-identity --query Arn --output text)",
    "aws_account": "$(aws sts get-caller-identity --query Account --output text)"
}
EOF

# Upload metadata
aws s3 cp "$METADATA_FILE" "s3://${BACKUP_BUCKET}/metadata/" --region "$BACKUP_REGION"

# Create human-readable report
REPORT_FILE="backup-report-${TIMESTAMP}.txt"
cat > "$REPORT_FILE" << EOF
OpenEMR Backup Report
=====================
Date: $(date)
Backup ID: ${BACKUP_ID}
Source Region: ${AWS_REGION}
Backup Region: ${BACKUP_REGION}
Cluster: ${CLUSTER_NAME}
Namespace: ${NAMESPACE}
Backup Bucket: s3://${BACKUP_BUCKET}
Backup Strategy: ${BACKUP_STRATEGY}
$([ -n "$TARGET_ACCOUNT_ID" ] && echo "Target Account: ${TARGET_ACCOUNT_ID}")
$([ -n "$KMS_KEY_ID" ] && echo "KMS Key: ${KMS_KEY_ID}" || echo "KMS Key: Auto-detected")
Copy Tags: ${COPY_TAGS}

Backup Results:
$(echo -e "$BACKUP_RESULTS")

Overall Status: $([ "$BACKUP_SUCCESS" = true ] && echo "SUCCESS ✅" || echo "PARTIAL FAILURE ⚠️")

Enhanced Features Used:
$([ "$BACKUP_STRATEGY" = "cross-region" ] && echo "✅ Cross-Region Snapshot Copy (New RDS Feature)")
$([ "$BACKUP_STRATEGY" = "cross-account" ] && echo "✅ Cross-Account Snapshot Copy (New RDS Feature)")
$([ "$BACKUP_STRATEGY" = "same-region" ] && echo "✅ Same-Region Backup (Standard)")

Restore Instructions:
1. Run: ./restore.sh ${BACKUP_BUCKET} ${SNAPSHOT_ID:-none} ${BACKUP_REGION}
2. The restore script will automatically:
   - Use the stored database configuration (VPC, subnet groups, security groups)
   - Apply Serverless v2 scaling configuration
   - Configure security group rules for database access
   - Create the appropriate Aurora instance
   - Reset the master password to match existing credentials
   - Handle cross-region/cross-account snapshot restoration
3. Verify data integrity after restore

Next Steps:
- Test restore procedures regularly
- Monitor backup bucket costs
- Update retention policies as needed
- Document any custom configurations
- Consider automated backup scheduling with different strategies

Support:
- Check logs in S3 bucket for detailed information
- Verify snapshots in RDS console
- Test Kubernetes restore in non-production environment
- Review cross-account permissions if using cross-account strategy
EOF

# Upload report
aws s3 cp "$REPORT_FILE" "s3://${BACKUP_BUCKET}/reports/" --region "$BACKUP_REGION"

# Cleanup local files
rm -f "$METADATA_FILE" "$REPORT_FILE"

# Final summary
echo ""
if [ "$BACKUP_SUCCESS" = true ]; then
    echo -e "${GREEN}🎉 Backup Completed Successfully!${NC}"
else
    echo -e "${YELLOW}⚠️  Backup Completed with Warnings${NC}"
fi

echo -e "${BLUE}=================================${NC}"
echo -e "${GREEN}✅ Backup ID: ${BACKUP_ID}${NC}"
echo -e "${GREEN}✅ Backup Bucket: s3://${BACKUP_BUCKET}${NC}"
echo -e "${GREEN}✅ Backup Region: ${BACKUP_REGION}${NC}"
echo -e "${GREEN}✅ Backup Strategy: ${BACKUP_STRATEGY}${NC}"
if [ -n "$TARGET_ACCOUNT_ID" ]; then
    echo -e "${GREEN}✅ Target Account: ${TARGET_ACCOUNT_ID}${NC}"
fi
if [ -n "$SNAPSHOT_ID" ]; then
    echo -e "${GREEN}✅ Aurora Snapshot: ${SNAPSHOT_ID}${NC}"
fi
echo ""
echo -e "${BLUE}📋 Backup Results:${NC}"
echo -e "$BACKUP_RESULTS"
echo -e "${BLUE}🔄 Restore Command:${NC}"
echo -e "${BLUE}   ./restore.sh ${BACKUP_BUCKET} ${SNAPSHOT_ID:-none} ${BACKUP_REGION}${NC}"
echo ""
echo -e "${BLUE}🚀 Enhanced Features Used:${NC}"
case "$BACKUP_STRATEGY" in
    "cross-region")
        echo -e "${GREEN}✅ Cross-Region Snapshot Copy (New RDS Feature)${NC}"
        ;;
    "cross-account")
        echo -e "${GREEN}✅ Cross-Account Snapshot Copy (New RDS Feature)${NC}"
        ;;
    "same-region")
        echo -e "${GREEN}✅ Same-Region Backup (Standard)${NC}"
        ;;
esac
echo ""

log_success "Backup process completed"
