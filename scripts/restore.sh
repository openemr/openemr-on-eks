#!/bin/bash

# =============================================================================
# OpenEMR Restore Script - Streamlined Process
# =============================================================================
#
# This script implements a streamlined restore process:
# 1. Run clean deployment (removes all OpenEMR resources)
# 2. Destroy existing RDS cluster
# 3. Restore RDS cluster from backup
# 4. Launch temp pod to restore only app data
# 5. Deploy OpenEMR with restore-defaults.sh and deploy.sh
#
# Usage: ./restore.sh <backup-bucket> <snapshot-id>
#
# Environment Variables (Timeout Configuration):
#   DB_CLUSTER_WAIT_TIMEOUT=1200        # 20 minutes for cluster operations
#   DB_INSTANCE_DELETE_TIMEOUT=1200     # 20 minutes for instance deletion
#   POD_READY_WAIT_TIMEOUT=600          # 10 minutes for pod readiness
#   TEMP_POD_START_TIMEOUT=300          # 5 minutes for temp pod startup
#   TEMP_POD_COMPLETION_TIMEOUT=300     # 5 minutes for temp pod completion
#   TEMP_POD_CHECK_INTERVAL=5           # 5 seconds between temp pod checks
#   DB_CONNECTION_CHECK_INTERVAL=2      # 2 seconds between DB connection checks
#   STATUS_CHECK_INTERVAL=30            # 30 seconds between status checks
#   EFS_PROPAGATION_WAIT=30             # 30 seconds for EFS propagation
#   HEALTH_CHECK_INTERVAL=10            # 10 seconds between health checks
#   VERIFICATION_TIMEOUT=300            # 5 minutes for final verification polling
#   VERIFICATION_INTERVAL=10            # 10 seconds between verification checks
#   VERIFICATION_MAX_ATTEMPTS=3         # 3 attempts for verification with crypto key cleanup retry
#
# Environment Variables (Temp Pod Resource Configuration):
#   TEMP_POD_MEMORY_REQUEST=1Gi         # Memory request for temp pod
#   TEMP_POD_MEMORY_LIMIT=2Gi           # Memory limit for temp pod
#   TEMP_POD_CPU_REQUEST=500m           # CPU request for temp pod
#   TEMP_POD_CPU_LIMIT=1000m            # CPU limit for temp pod
#   TEMP_POD_STORAGE_REQUEST=2Gi        # Ephemeral storage request for temp pod
#   TEMP_POD_STORAGE_LIMIT=5Gi          # Ephemeral storage limit for temp pod
#
# =============================================================================

set -euo pipefail

# Disable AWS CLI pager to prevent interactive editors from opening
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# =============================================================================
# CONFIGURATION
# =============================================================================

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Configurable timeout constants (can be overridden via environment variables)
readonly DB_CLUSTER_WAIT_TIMEOUT=${DB_CLUSTER_WAIT_TIMEOUT:-1200}        # 20 minutes
readonly DB_INSTANCE_DELETE_TIMEOUT=${DB_INSTANCE_DELETE_TIMEOUT:-1200}  # 20 minutes
readonly POD_READY_WAIT_TIMEOUT=${POD_READY_WAIT_TIMEOUT:-600}           # 10 minutes
readonly TEMP_POD_START_TIMEOUT=${TEMP_POD_START_TIMEOUT:-300}           # 5 minutes
readonly TEMP_POD_COMPLETION_TIMEOUT=${TEMP_POD_COMPLETION_TIMEOUT:-300} # 5 minutes
readonly TEMP_POD_CHECK_INTERVAL=${TEMP_POD_CHECK_INTERVAL:-5}           # 5 seconds
readonly DB_CONNECTION_CHECK_INTERVAL=${DB_CONNECTION_CHECK_INTERVAL:-2} # 2 seconds
readonly STATUS_CHECK_INTERVAL=${STATUS_CHECK_INTERVAL:-30}              # 30 seconds
readonly EFS_PROPAGATION_WAIT=${EFS_PROPAGATION_WAIT:-30}                # 30 seconds
readonly HEALTH_CHECK_INTERVAL=${HEALTH_CHECK_INTERVAL:-10}              # 10 seconds
readonly VERIFICATION_TIMEOUT=${VERIFICATION_TIMEOUT:-300}               # 5 minutes for final verification
readonly VERIFICATION_INTERVAL=${VERIFICATION_INTERVAL:-10}              # 10 seconds between verification checks
readonly VERIFICATION_MAX_ATTEMPTS=${VERIFICATION_MAX_ATTEMPTS:-6}       # 6 attempts with crypto key cleanup retry

# Temp pod resource configuration
readonly TEMP_POD_MEMORY_REQUEST=${TEMP_POD_MEMORY_REQUEST:-1Gi}   # Memory request
readonly TEMP_POD_MEMORY_LIMIT=${TEMP_POD_MEMORY_LIMIT:-2Gi}       # Memory limit
readonly TEMP_POD_CPU_REQUEST=${TEMP_POD_CPU_REQUEST:-500m}        # CPU request
readonly TEMP_POD_CPU_LIMIT=${TEMP_POD_CPU_LIMIT:-1000m}           # CPU limit
readonly TEMP_POD_STORAGE_REQUEST=${TEMP_POD_STORAGE_REQUEST:-2Gi} # Storage request
readonly TEMP_POD_STORAGE_LIMIT=${TEMP_POD_STORAGE_LIMIT:-5Gi}     # Storage limit

# Default configuration values
readonly DEFAULT_NAMESPACE="openemr"
readonly DEFAULT_AWS_REGION="us-west-2"
readonly DEFAULT_OPENEMR_VERSION="8.0.0"

# Script directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"
readonly TERRAFORM_DIR
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly PROJECT_ROOT
BACKUP_BUCKET=""
SNAPSHOT_ID=""
POD_SPEC_FILE=""              # Global variable to track pod spec file for cleanup
EARLY_DB_RESTORE_NEEDED=false # Flag to indicate if early database restore is needed
CLUSTER_NAME=""
NAMESPACE="$DEFAULT_NAMESPACE"
AWS_REGION="$DEFAULT_AWS_REGION"
CUSTOM_KMS_KEY=""  # Optional custom KMS key for RDS restore

# =============================================================================
# RETRY AND ERROR HANDLING FUNCTIONS
# =============================================================================

# Retry configuration
readonly MAX_RETRIES=${MAX_RETRIES:-3}
readonly RETRY_DELAY=${RETRY_DELAY:-5}

# Execute AWS command with retry logic
aws_with_retry() {
    local max_attempts="$MAX_RETRIES"
    local attempt=1
    
    while [ "$attempt" -le "$max_attempts" ]; do
        # Capture stderr to a temp file to show errors on failure, let stdout pass through
        local temp_error_file
        temp_error_file=$(mktemp)
        
        if aws "$@" 2>"$temp_error_file"; then
            rm -f "$temp_error_file"
            return 0
        else
            local exit_code=$?
            echo -e "${YELLOW}⚠️  AWS command failed (attempt $attempt/$max_attempts, exit code: $exit_code)${NC}" >&2
            # Show the error message
            if [ -s "$temp_error_file" ]; then
                echo -e "${RED}   Error: $(cat "$temp_error_file")${NC}" >&2
            fi
            rm -f "$temp_error_file"
            
            if [ "$attempt" -lt "$max_attempts" ]; then
                echo -e "${BLUE}   Retrying in ${RETRY_DELAY} seconds...${NC}" >&2
                sleep "$RETRY_DELAY"
            fi
            
            attempt=$((attempt + 1))
        fi
    done
    
    echo -e "${RED}❌ AWS command failed after $max_attempts attempts: aws $*${NC}" >&2
    return 1
}

# Execute kubectl command with retry logic
kubectl_with_retry() {
    local max_attempts="$MAX_RETRIES"
    local attempt=1
    
    while [ "$attempt" -le "$max_attempts" ]; do
        if kubectl "$@" 2>/dev/null; then
            return 0
        else
            local exit_code=$?
            echo -e "${YELLOW}⚠️  kubectl command failed (attempt $attempt/$max_attempts, exit code: $exit_code)${NC}"
            
            if [ "$attempt" -lt "$max_attempts" ]; then
                echo -e "${BLUE}   Retrying in ${RETRY_DELAY} seconds...${NC}"
                sleep "$RETRY_DELAY"
            fi
            
            attempt=$((attempt + 1))
        fi
    done
    
    echo -e "${RED}❌ kubectl command failed after $max_attempts attempts: kubectl $*${NC}" >&2
    return 1
}

# Execute terraform command with retry logic
terraform_with_retry() {
    local max_attempts="$MAX_RETRIES"
    local attempt=1
    
    while [ "$attempt" -le "$max_attempts" ]; do
        if terraform -chdir="$TERRAFORM_DIR" "$@" 2>/dev/null; then
            return 0
        else
            local exit_code=$?
            echo -e "${YELLOW}⚠️  Terraform command failed (attempt $attempt/$max_attempts, exit code: $exit_code)${NC}"
            
            if [ "$attempt" -lt "$max_attempts" ]; then
                echo -e "${BLUE}   Retrying in ${RETRY_DELAY} seconds...${NC}"
                sleep "$RETRY_DELAY"
            fi
            
            attempt=$((attempt + 1))
        fi
    done
    
    echo -e "${RED}❌ Terraform command failed after $max_attempts attempts: terraform -chdir=\"$TERRAFORM_DIR\" $*${NC}" >&2
    return 1
}

# Wait for AWS resource with exponential backoff
wait_for_aws_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local expected_status="$3"
    local max_wait_time="${4:-600}"
    local check_interval="${5:-30}"
    
    local elapsed=0
    local last_status=""
    
    echo -e "${YELLOW}⏳ Waiting for $resource_type '$resource_id' to reach status '$expected_status'...${NC}"
    
    while [ $elapsed -lt "$max_wait_time" ]; do
        local current_status
        case $resource_type in
            "db-cluster")
                if [ "$expected_status" = "deleted" ]; then
                    # For deletion, check if cluster exists - if not, it's deleted
                    if aws rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$resource_id" >/dev/null 2>&1; then
                        current_status="deleting"
                    else
                        current_status="deleted"
                    fi
                else
                    current_status=$(aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$resource_id" --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "unknown")
                fi
                ;;
            "db-instance")
                if [ "$expected_status" = "deleted" ]; then
                    # For deletion, check if instance exists - if not, it's deleted
                    if aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$resource_id" >/dev/null 2>&1; then
                        current_status="deleting"
                    else
                        current_status="deleted"
                    fi
                else
                    current_status=$(aws_with_retry rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$resource_id" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")
                fi
                ;;
            "snapshot")
                current_status=$(aws_with_retry rds describe-db-cluster-snapshots --region "$AWS_REGION" --db-cluster-snapshot-identifier "$resource_id" --query 'DBClusterSnapshots[0].Status' --output text 2>/dev/null || echo "unknown")
                ;;
            *)
                echo -e "${RED}❌ Unknown resource type: $resource_type${NC}" >&2
                return 1
                ;;
        esac
        
        if [ "$current_status" = "$expected_status" ]; then
            echo -e "${GREEN}✅ $resource_type '$resource_id' reached status '$expected_status'${NC}"
            return 0
        fi
        
        # Only show status if it changed to avoid spam
        if [ "$current_status" != "$last_status" ]; then
            echo -e "${BLUE}   Current status: $current_status${NC}"
            last_status="$current_status"
        fi
        
        echo -e "${BLUE}   Progress: ${elapsed}s / ${max_wait_time}s${NC}"
        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done
    
    echo -e "${RED}❌ Timeout waiting for $resource_type '$resource_id' to reach status '$expected_status'${NC}" >&2
    return 1
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Display help information
show_help() {
    cat << EOF
OpenEMR Restore Script - Streamlined Process

USAGE:
    $0 <backup-bucket> <snapshot-id> [options]

ARGUMENTS:
    backup-bucket    S3 bucket containing the backup data
    snapshot-id      RDS snapshot identifier to restore from

OPTIONS:
    -h, --help           Show this help message
    -c, --cluster        EKS cluster name (auto-detected if not provided)
    -n, --namespace      Kubernetes namespace (default: openemr)
    -r, --region         AWS region (default: us-west-2)
    --kms-key            Custom KMS key ARN for RDS restore (optional)
                         By default, the snapshot's original KMS key is used
    --latest-snapshot    Automatically use the most recent available snapshot

ENVIRONMENT VARIABLES (Timeout Configuration):
    DB_CLUSTER_WAIT_TIMEOUT        Database cluster wait timeout in seconds (default: 1200)
    DB_INSTANCE_DELETE_TIMEOUT     Database instance deletion timeout in seconds (default: 1200)
    POD_READY_WAIT_TIMEOUT         Pod readiness wait timeout in seconds (default: 600)
    TEMP_POD_START_TIMEOUT         Temporary pod startup timeout in seconds (default: 300)
    TEMP_POD_COMPLETION_TIMEOUT    Temporary pod completion timeout in seconds (default: 300)
    TEMP_POD_CHECK_INTERVAL        Temporary pod check interval in seconds (default: 5)
    DB_CONNECTION_CHECK_INTERVAL   Database connection check interval in seconds (default: 2)
    STATUS_CHECK_INTERVAL          Status check interval in seconds (default: 30)
    EFS_PROPAGATION_WAIT           EFS propagation wait time in seconds (default: 30)
    HEALTH_CHECK_INTERVAL          Health check interval in seconds (default: 10)
    MAX_RETRIES                    Maximum number of retries for AWS/kubectl commands (default: 3)
    RETRY_DELAY                    Delay between retries in seconds (default: 5)
    DB_CLEANUP_MAX_ATTEMPTS       Maximum attempts to wait for database cleanup pod completion (default: 12)

EXAMPLES:
    # Basic restore (uses snapshot's original KMS key)
    $0 my-backup-bucket my-snapshot-id

    # Restore with latest snapshot
    $0 my-backup-bucket --latest-snapshot

    # Restore with custom KMS key (e.g., copied key)
    $0 my-backup-bucket my-snapshot-id --kms-key arn:aws:kms:us-west-2:123456789012:key/abcd1234-5678-90ef-ghij-klmnopqrstuv

    # Restore with custom timeouts
    DB_CLUSTER_WAIT_TIMEOUT=1800 POD_READY_WAIT_TIMEOUT=900 $0 my-backup-bucket my-snapshot-id

    # Restore with custom cluster and namespace
    $0 my-backup-bucket my-snapshot-id --cluster my-cluster --namespace my-namespace

DESCRIPTION:
    This script implements a streamlined restore process:
    1. Run clean deployment (removes all OpenEMR resources)
    2. Destroy existing RDS cluster
    3. Restore RDS cluster from backup
    4. Launch temp pod to restore only app data
    5. Fix OpenEMR configuration (database settings and startup files)
    6. Deploy OpenEMR with restore-defaults.sh and deploy.sh

    The script provides detailed status tracking and progress indicators
    and automatically handles OpenEMR configuration issues that can occur
    during restore operations, including:
    - Fixing database connection settings in sqlconf.php
    - Creating comprehensive config.php with all necessary global variables
    - Removing docker-leader and docker-initiated files that prevent startup
    - Setting proper configuration flags to skip setup
    - Verifying configuration files are created/removed correctly
    throughout the restoration process.

EOF
}

# Parse command line arguments
parse_arguments() {
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -r|--region)
                AWS_REGION="$2"
                shift 2
                ;;
            --kms-key)
                CUSTOM_KMS_KEY="$2"
                shift 2
                ;;
            --latest-snapshot)
                USE_LATEST_SNAPSHOT=true
                shift
                ;;
            -*)
                echo -e "${RED}❌ Unknown option: $1${NC}" >&2
                show_help
                exit 1
                ;;
            *)
                if [ -z "$BACKUP_BUCKET" ]; then
                    BACKUP_BUCKET="$1"
                    # Remove s3:// prefix if present
                    BACKUP_BUCKET="${BACKUP_BUCKET#s3://}"
                elif [ -z "$SNAPSHOT_ID" ]; then
                    SNAPSHOT_ID="$1"
                else
                    echo -e "${RED}❌ Too many arguments${NC}" >&2
                show_help
                exit 1
                fi
                shift
                ;;
        esac
    done
}

# Get AWS region from environment or Terraform state
get_aws_region() {
    # Priority 1: Try to get region from Terraform state file (existing deployment takes precedence)
    if [ -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
        cd "$TERRAFORM_DIR"
        local terraform_region
        
        # Extract region directly from state file JSON
        terraform_region=$(grep -o '"region"[[:space:]]*:[[:space:]]*"[^"]*"' terraform.tfstate 2>/dev/null | \
            head -1 | \
            sed 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
        
        cd - >/dev/null
        
        # Validate region format
        if [ -n "$terraform_region" ] && [[ "$terraform_region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            AWS_REGION="$terraform_region"
            echo -e "${BLUE}ℹ️  Found AWS region from Terraform state: $AWS_REGION${NC}"
            return 0
        fi
    fi
    
    # Priority 2: If AWS_REGION is explicitly set via environment AND it's not the default, use it
    if [ -n "${AWS_REGION:-}" ] && [ "$AWS_REGION" != "us-west-2" ]; then
        # Validate it's a real region format (e.g., us-west-2, eu-west-1, ap-southeast-1)
        if [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            echo -e "${BLUE}ℹ️  Using AWS region from environment: $AWS_REGION${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  Invalid AWS_REGION format in environment: $AWS_REGION${NC}"
        fi
    fi
    
    # Priority 3: Fall back to default
    AWS_REGION="us-west-2"
    echo -e "${YELLOW}⚠️  Could not determine AWS region, using default: $AWS_REGION${NC}"
}

# Validate required arguments
validate_arguments() {
    if [ -z "$BACKUP_BUCKET" ]; then
        echo -e "${RED}❌ Backup bucket is required${NC}" >&2
        show_help
        exit 1
    fi

    if [ -z "$SNAPSHOT_ID" ]; then
        if [ "$USE_LATEST_SNAPSHOT" = "true" ]; then
            echo -e "${YELLOW}🔍 Auto-detecting latest snapshot...${NC}"
            auto_detect_latest_snapshot
        else
            echo -e "${RED}❌ Snapshot ID is required${NC}" >&2
            echo -e "${YELLOW}💡 Tip: You can use --latest-snapshot to automatically use the most recent snapshot${NC}" >&2
            suggest_available_snapshots
            show_help
            exit 1
        fi
    fi
}

# Auto-detect the latest snapshot for the current cluster
auto_detect_latest_snapshot() {
    # Get current cluster identifier from Terraform
    local cluster_identifier
    cluster_identifier=$(terraform_with_retry output -raw cluster_name 2>/dev/null || echo "")
    
    # If cluster_name is just "openemr-eks", we need to get the actual RDS cluster identifier
    if [ "$cluster_identifier" = "openemr-eks" ]; then
        cluster_identifier=$(terraform_with_retry output -raw aurora_cluster_id 2>/dev/null || echo "")
    fi
    
    if [ -z "$cluster_identifier" ]; then
        echo -e "${RED}❌ Could not determine cluster name from Terraform${NC}" >&2
        return 1
    fi
    
    # Get the most recent available snapshot
    local latest_snapshot
    latest_snapshot=$(aws_with_retry rds describe-db-cluster-snapshots \
        --region "$AWS_REGION" \
        --db-cluster-identifier "$cluster_identifier" \
        --snapshot-type manual \
        --query "DBClusterSnapshots[?Status==\`available\`] | sort_by(@, &SnapshotCreateTime) | [-1].DBClusterSnapshotIdentifier" \
        --output text 2>/dev/null)
    
    if [ -n "$latest_snapshot" ] && [ "$latest_snapshot" != "None" ]; then
        SNAPSHOT_ID="$latest_snapshot"
        echo -e "${GREEN}✅ Using latest snapshot: $SNAPSHOT_ID${NC}"
        
        # Also suggest the corresponding backup bucket
        local snapshot_date
        snapshot_date=$(echo "$latest_snapshot" | grep -o '[0-9]\{8\}-[0-9]\{6\}' || echo "")
        if [ -n "$snapshot_date" ]; then
            local suggested_bucket
            suggested_bucket="openemr-backups-$(aws_with_retry sts get-caller-identity --query Account --output text 2>/dev/null)-openemr-eks-${snapshot_date:0:8}"
            echo -e "${CYAN}💡 Suggested backup bucket: $suggested_bucket${NC}"
        fi
    else
        echo -e "${RED}❌ No available snapshots found for cluster '$cluster_identifier'${NC}" >&2
        echo -e "${YELLOW}💡 You may need to create a backup first using ./scripts/backup.sh${NC}" >&2
        return 1
    fi
}

# Auto-detect cluster name from Terraform
auto_detect_cluster_name() {
    if [ -z "$CLUSTER_NAME" ]; then
        CLUSTER_NAME=$(terraform_with_retry output -raw cluster_name 2>/dev/null || echo "openemr-eks")
        echo -e "${YELLOW}ℹ️  Auto-detected cluster: $CLUSTER_NAME${NC}"
    fi
}

# Ensure kubectl is configured and cluster is accessible
ensure_kubeconfig() {
    echo -e "${YELLOW}ℹ️  Ensuring kubeconfig is configured...${NC}"
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "${RED}❌ kubectl is not configured or cluster is not accessible${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✅ kubectl is configured${NC}"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validate Terraform state and required outputs
validate_terraform_state() {
    echo -e "${YELLOW}🔍 Validating Terraform state...${NC}"
    
    # Check if Terraform is initialized
    if [ ! -d "$TERRAFORM_DIR/.terraform" ]; then
        echo -e "${RED}❌ Terraform not initialized. Run 'terraform init' first${NC}" >&2
        return 1
    fi
    
    # Check if Terraform state exists
    if ! terraform_with_retry state list; then
        echo -e "${RED}❌ Terraform state not accessible${NC}" >&2
        return 1
    fi
    
    # Verify required outputs exist
    local required_outputs=("cluster_name" "aurora_cluster_id" "aurora_db_subnet_group_name")
    for output in "${required_outputs[@]}"; do
        if ! terraform_with_retry output -raw "$output" >/dev/null 2>&1; then
            echo -e "${RED}❌ Required Terraform output '$output' not found${NC}" >&2
            return 1
        fi
    done
    
    echo -e "${GREEN}✅ Terraform state validation passed${NC}"
    return 0
}

# Validate backup bucket exists and contains required data
validate_backup_bucket() {
    echo -e "${YELLOW}🔍 Validating backup bucket...${NC}"
    
    # Check if bucket exists
    if ! aws_with_retry s3 ls "s3://$BACKUP_BUCKET"; then
        echo -e "${RED}❌ Backup bucket '$BACKUP_BUCKET' does not exist or is not accessible${NC}" >&2
        suggest_available_backup_buckets
        return 1
    fi
    
    # Check if bucket has application-data folder
    if ! aws_with_retry s3 ls "s3://$BACKUP_BUCKET/application-data/"; then
        echo -e "${RED}❌ Backup bucket does not contain 'application-data' folder${NC}" >&2
        echo -e "${YELLOW}   💡 This bucket may not be a valid OpenEMR backup bucket${NC}" >&2
        suggest_available_backup_buckets
        return 1
    fi
    
    echo -e "${GREEN}✅ Backup bucket validation passed${NC}"
    return 0
}

# Suggest available backup buckets
suggest_available_backup_buckets() {
    echo -e "${BLUE}🔍 Looking for available OpenEMR backup buckets...${NC}" >&2
    
    # Get account ID for bucket naming pattern
    local account_id
    account_id=$(aws_with_retry sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    
    if [ -z "$account_id" ]; then
        echo -e "${YELLOW}   ⚠️  Could not determine AWS account ID${NC}" >&2
        return 1
    fi
    
    # Look for OpenEMR backup buckets
    local backup_buckets
    backup_buckets=$(aws_with_retry s3 ls --region "$AWS_REGION" 2>/dev/null | \
        grep "openemr-backups-$account_id-openemr-eks-" | \
        awk '{print $3}' | sort -r | head -5)
    
    if [ -n "$backup_buckets" ]; then
        echo -e "${GREEN}   📋 Available OpenEMR backup buckets:${NC}" >&2
        echo -e "${GREEN}   ┌─────────────────────────────────────────────────────────────┐${NC}" >&2
        echo -e "${GREEN}   │ Bucket Name                                                │${NC}" >&2
        echo -e "${GREEN}   ├─────────────────────────────────────────────────────────────┤${NC}" >&2
        
        while IFS= read -r bucket_name; do
            if [ -n "$bucket_name" ]; then
                printf "${GREEN}   │ %-59s │${NC}\n" "$bucket_name" >&2
            fi
        done <<< "$backup_buckets"
        
        echo -e "${GREEN}   └─────────────────────────────────────────────────────────────┘${NC}" >&2
        
        # Suggest the most recent bucket
        local most_recent_bucket
        most_recent_bucket=$(echo "$backup_buckets" | head -1)
        
        if [ -n "$most_recent_bucket" ]; then
            echo -e "${CYAN}   💡 Most recent backup bucket: $most_recent_bucket${NC}" >&2
            echo -e "${CYAN}   💡 You can use this bucket with the appropriate snapshot ID${NC}" >&2
        fi
    else
        echo -e "${YELLOW}   ⚠️  No OpenEMR backup buckets found in account $account_id${NC}" >&2
        echo -e "${YELLOW}   💡 You may need to create a backup first using ./scripts/backup.sh${NC}" >&2
    fi
}

# Validate RDS snapshot exists and is available
validate_snapshot() {
    echo -e "${YELLOW}🔍 Validating RDS snapshot...${NC}"
    
    # Check if snapshot exists
    local snapshot_info
    snapshot_info=$(aws_with_retry rds describe-db-cluster-snapshots \
        --region "$AWS_REGION" \
        --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
        --query 'DBClusterSnapshots[0]' \
        --output json 2>/dev/null || echo "{}")
    
    if [ "$snapshot_info" = "{}" ] || [ "$snapshot_info" = "null" ]; then
        echo -e "${RED}❌ Snapshot '$SNAPSHOT_ID' does not exist${NC}" >&2
        suggest_available_snapshots
        return 1
    fi
    
    # Check snapshot status
    local snapshot_status
    snapshot_status=$(echo "$snapshot_info" | jq -r '.Status' 2>/dev/null || echo "unknown")
    
    if [ "$snapshot_status" = "available" ]; then
        echo -e "${GREEN}✅ Snapshot '$SNAPSHOT_ID' is available${NC}"
        return 0
    elif [ "$snapshot_status" = "creating" ]; then
        echo -e "${YELLOW}⏳ Snapshot '$SNAPSHOT_ID' is still being created. Waiting for availability...${NC}"
        if wait_for_aws_resource "snapshot" "$SNAPSHOT_ID" "available" 1800; then
            echo -e "${GREEN}✅ Snapshot '$SNAPSHOT_ID' is now available${NC}"
            return 0
        else
            echo -e "${RED}❌ Snapshot '$SNAPSHOT_ID' did not become available within timeout${NC}" >&2
            suggest_available_snapshots
            return 1
        fi
    else
        echo -e "${RED}❌ Snapshot '$SNAPSHOT_ID' is in state '$snapshot_status'${NC}" >&2
        explain_snapshot_status "$snapshot_status"
        suggest_available_snapshots
        return 1
    fi
}

# Explain what a snapshot status means
explain_snapshot_status() {
    local status="$1"
    case "$status" in
        "unknown")
            echo -e "${YELLOW}   💡 'unknown' status usually means the snapshot was deleted or expired${NC}" >&2
            ;;
        "deleted")
            echo -e "${YELLOW}   💡 This snapshot has been deleted and cannot be used${NC}" >&2
            ;;
        "failed")
            echo -e "${YELLOW}   💡 This snapshot creation failed and cannot be used${NC}" >&2
            ;;
        "cancelled")
            echo -e "${YELLOW}   💡 This snapshot creation was cancelled and cannot be used${NC}" >&2
            ;;
        *)
            echo -e "${YELLOW}   💡 Status '$status' indicates the snapshot is not ready for restore${NC}" >&2
            ;;
    esac
}

# Suggest available snapshots for the current cluster
suggest_available_snapshots() {
    echo -e "${BLUE}🔍 Looking for available snapshots for this cluster...${NC}" >&2
    
    # Get current cluster identifier from Terraform
    local cluster_identifier
    cluster_identifier=$(terraform_with_retry output -raw cluster_name 2>/dev/null || echo "")
    
    # If cluster_name is just "openemr-eks", we need to get the actual RDS cluster identifier
    if [ "$cluster_identifier" = "openemr-eks" ]; then
        cluster_identifier=$(terraform_with_retry output -raw aurora_cluster_id 2>/dev/null || echo "")
    fi
    
    if [ -z "$cluster_identifier" ]; then
        echo -e "${YELLOW}   ⚠️  Could not determine cluster name from Terraform${NC}" >&2
        return 1
    fi
    
    # Get available snapshots for this cluster
    local available_snapshots
    available_snapshots=$(aws_with_retry rds describe-db-cluster-snapshots \
        --region "$AWS_REGION" \
        --db-cluster-identifier "$cluster_identifier" \
        --snapshot-type manual \
        --query "DBClusterSnapshots[?Status==\`available\`].[DBClusterSnapshotIdentifier,SnapshotCreateTime]" \
        --output text 2>/dev/null | sort -k2 -r | head -5)
    
    if [ -n "$available_snapshots" ]; then
        echo -e "${GREEN}   📋 Available snapshots for cluster '$cluster_identifier':${NC}" >&2
        echo -e "${GREEN}   ┌─────────────────────────────────────────────────────────────┐${NC}" >&2
        echo -e "${GREEN}   │ Snapshot ID                                    │ Created        │${NC}" >&2
        echo -e "${GREEN}   ├─────────────────────────────────────────────────────────────┤${NC}" >&2
        
        while IFS=$'\t' read -r snapshot_id create_time; do
            if [ -n "$snapshot_id" ] && [ -n "$create_time" ]; then
                # Format the timestamp for better readability
                local formatted_time
                formatted_time=$(date -d "$create_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$create_time")
                printf "${GREEN}   │ %-47s │ %-13s │${NC}\n" "$snapshot_id" "$formatted_time" >&2
            fi
        done <<< "$available_snapshots"
        
        echo -e "${GREEN}   └─────────────────────────────────────────────────────────────┘${NC}" >&2
        
        # Suggest the most recent snapshot
        local most_recent_snapshot
        most_recent_snapshot=$(echo "$available_snapshots" | head -1 | cut -f1)
        
        if [ -n "$most_recent_snapshot" ]; then
            echo -e "${CYAN}   💡 Suggested command:${NC}" >&2
            echo -e "${CYAN}   ./scripts/restore.sh $BACKUP_BUCKET $most_recent_snapshot --region $AWS_REGION${NC}" >&2
        fi
    else
        echo -e "${YELLOW}   ⚠️  No available snapshots found for cluster '$cluster_identifier'${NC}" >&2
        echo -e "${YELLOW}   💡 You may need to create a backup first using ./scripts/backup.sh${NC}" >&2
    fi
}

# Validate Kubernetes resources exist (optional for clean state)
validate_kubernetes_resources() {
    echo -e "${YELLOW}🔍 Validating Kubernetes resources...${NC}"
    
    # Check if namespace exists (optional - may not exist after clean deployment)
    if kubectl_with_retry get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Namespace '$NAMESPACE' exists${NC}"
        
        # Check if PVC exists (only if namespace exists)
        if kubectl_with_retry get pvc openemr-sites-pvc -n "$NAMESPACE" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ PVC 'openemr-sites-pvc' exists${NC}"
        else
            echo -e "${YELLOW}⚠️  PVC 'openemr-sites-pvc' does not exist (expected after clean deployment)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Namespace '$NAMESPACE' does not exist (expected after clean deployment)${NC}"
    fi
    
    # Check if EFS storage class exists and is properly configured
    # Note: Storage classes are recreated during deployment, so this check is optional
    if kubectl_with_retry get storageclass efs-sc >/dev/null 2>&1; then
        echo -e "${GREEN}✅ EFS storage class exists${NC}"
        
        # Get EFS ID from Terraform and validate storage class configuration
        local efs_id
        efs_id=$(terraform_with_retry output -raw efs_id 2>/dev/null || echo "")
        if [ -n "$efs_id" ]; then
            echo -e "${BLUE}   EFS ID: $efs_id${NC}"
            
            # Check if storage class has correct EFS ID
            local current_efs_id
            current_efs_id=$(kubectl get storageclass efs-sc -o jsonpath='{.parameters.fileSystemId}' 2>/dev/null || echo "")
            if [ "$current_efs_id" = "$efs_id" ]; then
                echo -e "${GREEN}   ✅ EFS storage class correctly configured${NC}"
            else
                echo -e "${YELLOW}⚠️  EFS storage class has different EFS ID: $current_efs_id (expected: $efs_id)${NC}"
                echo -e "${YELLOW}   This will be corrected during deployment${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️  Could not retrieve EFS ID from Terraform${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  EFS storage class not found (will be created during deployment)${NC}"
    fi
    
    return 0
}

# Function to get OpenEMR role ARN from Terraform
get_openemr_role_arn() {
    echo -e "${BLUE}   Getting OpenEMR role ARN from Terraform...${NC}" >&2
    
    local role_arn
    role_arn=$(terraform -chdir="$PROJECT_ROOT/terraform" output -raw openemr_role_arn 2>/dev/null)
    
    if [ -z "$role_arn" ] || [ "$role_arn" = "null" ]; then
        echo -e "${RED}❌ Failed to get OpenEMR role ARN from Terraform${NC}" >&2
        echo -e "${RED}   Please ensure Terraform state is available and the role exists${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}   ✅ OpenEMR role ARN: $role_arn${NC}" >&2
    # Only output the clean role ARN to stdout (last line)
    echo "$role_arn"
}

# Ensure EFS storage class is properly configured
ensure_efs_storage_class() {
    echo -e "${YELLOW}🔧 Ensuring EFS storage class is properly configured...${NC}"
    
    # Get EFS ID from Terraform
    local efs_id
    efs_id=$(terraform_with_retry output -raw efs_id 2>/dev/null || echo "")
    if [ -z "$efs_id" ]; then
        echo -e "${RED}❌ Could not retrieve EFS ID from Terraform${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}   EFS ID: $efs_id${NC}"
    
    # Check if storage class exists and has correct EFS ID
    if kubectl get storageclass efs-sc >/dev/null 2>&1; then
        local current_efs_id
        current_efs_id=$(kubectl get storageclass efs-sc -o jsonpath='{.parameters.fileSystemId}' 2>/dev/null || echo "")
        
        if [ "$current_efs_id" = "$efs_id" ]; then
            echo -e "${GREEN}   ✅ EFS storage class is correctly configured${NC}"
            return 0
        else
            echo -e "${YELLOW}   ⚠️  EFS storage class has incorrect EFS ID: $current_efs_id${NC}"
            echo -e "${BLUE}   🔄 Updating EFS storage class...${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠️  EFS storage class not found${NC}"
        echo -e "${BLUE}   🔄 Creating EFS storage class...${NC}"
    fi
    
    # Create or update storage class with correct EFS ID
    if cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $efs_id
  directoryPerms: "0755"
  basePath: "/openemr"
volumeBindingMode: WaitForFirstConsumer
EOF
    then
        echo -e "${GREEN}   ✅ EFS storage class configured successfully${NC}"
        return 0
    else
        echo -e "${RED}   ❌ Failed to configure EFS storage class${NC}" >&2
        return 1
    fi
}

# Parse backup metadata to understand backup strategy and configuration
parse_backup_metadata() {
    echo -e "${YELLOW}🔍 Parsing backup metadata...${NC}"
    
    # Download metadata file
    local metadata_file="/tmp/backup-metadata-${SNAPSHOT_ID}.json"
    local metadata_downloaded=false
    
    # Try timestamp-based filename first (backup-metadata-TIMESTAMP.json)
    local metadata_files
    metadata_files=$(aws_with_retry s3 ls "s3://$BACKUP_BUCKET/metadata/" --region "$AWS_REGION" 2>/dev/null | grep -o "backup-metadata-[0-9]*-[0-9]*\.json" | head -1)
    
    if [ -n "$metadata_files" ]; then
        echo -e "${BLUE}   Found metadata file: $metadata_files${NC}"
        if aws_with_retry s3 cp "s3://$BACKUP_BUCKET/metadata/$metadata_files" "$metadata_file" 2>/dev/null; then
            metadata_downloaded=true
        fi
    fi
    
    if [ "$metadata_downloaded" = false ]; then
        echo -e "${YELLOW}⚠️  Could not download backup metadata, using defaults${NC}"
        echo -e "${BLUE}   Backup strategy: same-region (default)${NC}"
        echo -e "${BLUE}   Components backed up:${NC}"
        echo -e "${BLUE}     - Aurora RDS: true${NC}"
        echo -e "${BLUE}     - Kubernetes config: true${NC}"
        echo -e "${BLUE}     - Application data: true${NC}"
        echo -e "${GREEN}✅ Backup metadata parsing completed (using defaults)${NC}"
        return 0
    fi
    
    # Parse backup strategy
    local backup_strategy
    backup_strategy=$(jq -r '.backup_strategy // "same-region"' "$metadata_file" 2>/dev/null)
    echo -e "${BLUE}   Backup strategy: $backup_strategy${NC}"
    
    # Parse backup region
    local backup_region
    backup_region=$(jq -r '.backup_region // empty' "$metadata_file" 2>/dev/null)
    if [ -n "$backup_region" ] && [ "$backup_region" != "$AWS_REGION" ]; then
        echo -e "${BLUE}   Cross-region backup detected: $backup_region${NC}"
        # Update AWS_REGION for restore operations
        AWS_REGION="$backup_region"
    fi
    
    # Parse target account (for cross-account restores)
    local target_account
    target_account=$(jq -r '.target_account_id // empty' "$metadata_file" 2>/dev/null)
    if [ -n "$target_account" ] && [ "$target_account" != "none" ]; then
        echo -e "${BLUE}   Cross-account backup detected: $target_account${NC}"
        # Note: Cross-account restore would require additional AWS credential setup
    fi
    
    # Parse components backed up
    local aurora_backed_up
    aurora_backed_up=$(jq -r '.components.aurora_rds // false' "$metadata_file" 2>/dev/null)
    local k8s_backed_up
    k8s_backed_up=$(jq -r '.components.kubernetes_config // false' "$metadata_file" 2>/dev/null)
    local app_data_backed_up
    app_data_backed_up=$(jq -r '.components.application_data // false' "$metadata_file" 2>/dev/null)
    
    echo -e "${BLUE}   Components backed up:${NC}"
    echo -e "${BLUE}     - Aurora RDS: $aurora_backed_up${NC}"
    echo -e "${BLUE}     - Kubernetes config: $k8s_backed_up${NC}"
    echo -e "${BLUE}     - Application data: $app_data_backed_up${NC}"
    
    # Clean up metadata file
    rm -f "$metadata_file"
    
    echo -e "${GREEN}✅ Backup metadata parsed successfully${NC}"
    return 0
}

# Validate AWS credentials and service access
validate_aws_credentials() {
    echo -e "${YELLOW}🔍 Validating AWS credentials...${NC}"
    
    # Check AWS credentials
    if ! aws_with_retry sts get-caller-identity; then
        echo -e "${RED}❌ AWS credentials not configured or invalid${NC}" >&2
            return 1
    fi
    
    # Check if we can access RDS
    if ! aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --max-items 1; then
        echo -e "${RED}❌ Cannot access RDS service in region '$AWS_REGION'${NC}" >&2
        return 1
    fi
    
    # Check if we can access S3
    if ! aws_with_retry s3 ls --region "$AWS_REGION"; then
        echo -e "${RED}❌ Cannot access S3 service in region '$AWS_REGION'${NC}" >&2
            return 1
    fi
    
    echo -e "${GREEN}✅ AWS credentials validation passed${NC}"
    return 0
}

# Check if the correct database exists and handle early restore if needed
check_and_prepare_database() {
    echo -e "${YELLOW}🔍 Checking database existence and configuration...${NC}"
    
    # Get expected cluster identifier from Terraform
    local expected_cluster_id
    expected_cluster_id=$(terraform_with_retry output -raw aurora_cluster_id 2>/dev/null || echo "")
    expected_cluster_id=$(echo "$expected_cluster_id" | tr -d '\r\n%')
    
    if [ -z "$expected_cluster_id" ]; then
        echo -e "${RED}❌ Could not get expected cluster ID from Terraform${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}   Expected cluster ID: $expected_cluster_id${NC}"
    
    # Check if the expected cluster exists
    local cluster_exists=false
    local cluster_status=""
    local cluster_valid=false
    
    if aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$expected_cluster_id" >/dev/null 2>&1; then
        cluster_exists=true
        cluster_status=$(aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$expected_cluster_id" --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "unknown")
        echo -e "${BLUE}   Found existing cluster with status: $cluster_status${NC}"
        
        # Check if cluster has the correct instances
        if [ "$cluster_status" = "available" ]; then
            echo -e "${BLUE}   Validating cluster instances...${NC}"
            
            # Get expected instance identifiers based on Terraform naming pattern
            # Instances are named: ${cluster_name}-aurora-${count.index} (0 and 1)
            local cluster_name
            cluster_name=$(terraform_with_retry output -raw cluster_name 2>/dev/null || echo "")
            cluster_name=$(echo "$cluster_name" | tr -d '\r\n%')
            
            if [ -n "$cluster_name" ]; then
                local expected_instance_1="${cluster_name}-aurora-0"
                local expected_instance_2="${cluster_name}-aurora-1"
                
                echo -e "${BLUE}   Expected instances: $expected_instance_1, $expected_instance_2${NC}"
                
                # Check if both expected instances exist and are available
                local instance_1_exists=false
                local instance_2_exists=false
                local instance_1_status=""
                local instance_2_status=""
                
                if aws_with_retry rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$expected_instance_1" >/dev/null 2>&1; then
                    instance_1_exists=true
                    instance_1_status=$(aws_with_retry rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$expected_instance_1" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")
                    echo -e "${BLUE}   Instance 1 ($expected_instance_1): $instance_1_status${NC}"
                else
                    echo -e "${YELLOW}   Instance 1 ($expected_instance_1): not found${NC}"
                fi
                
                if aws_with_retry rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$expected_instance_2" >/dev/null 2>&1; then
                    instance_2_exists=true
                    instance_2_status=$(aws_with_retry rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$expected_instance_2" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")
                    echo -e "${BLUE}   Instance 2 ($expected_instance_2): $instance_2_status${NC}"
                else
                    echo -e "${YELLOW}   Instance 2 ($expected_instance_2): not found${NC}"
                fi
                
                # Validate cluster configuration
                if [ "$instance_1_exists" = true ] && [ "$instance_2_exists" = true ] && [ "$instance_1_status" = "available" ] && [ "$instance_2_status" = "available" ]; then
                    cluster_valid=true
                    echo -e "${GREEN}   ✅ Cluster has correct instances and all are available${NC}"
                else
                    echo -e "${YELLOW}   ⚠️  Cluster instances are missing or not available${NC}"
                    if [ "$instance_1_exists" = false ] || [ "$instance_1_status" != "available" ]; then
                        echo -e "${YELLOW}      Instance 1 issue: exists=$instance_1_exists, status=$instance_1_status${NC}"
                    fi
                    if [ "$instance_2_exists" = false ] || [ "$instance_2_status" != "available" ]; then
                        echo -e "${YELLOW}      Instance 2 issue: exists=$instance_2_exists, status=$instance_2_status${NC}"
                    fi
                fi
            else
                echo -e "${YELLOW}   ⚠️  Could not get cluster name from Terraform${NC}"
            fi
        else
            echo -e "${YELLOW}   ⚠️  Cluster exists but is not available (status: $cluster_status)${NC}"
        fi
    else
        echo -e "${BLUE}   No existing cluster found${NC}"
    fi
    
    # Check if there are any other RDS clusters that might conflict
    local other_clusters
    other_clusters=$(aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --query "DBClusters[?DBClusterIdentifier!=\`$expected_cluster_id\`].DBClusterIdentifier" --output text 2>/dev/null || echo "")
    
    if [ -n "$other_clusters" ] && [ "$other_clusters" != "None" ]; then
        echo -e "${YELLOW}⚠️  Found other RDS clusters that may conflict:${NC}"
        echo -e "${BLUE}   $other_clusters${NC}"
        echo -e "${YELLOW}   These will be cleaned up during the restore process${NC}"
    fi
    
    # Determine if we need early database restore
    if [ "$cluster_exists" = false ] || [ "$cluster_status" != "available" ] || [ "$cluster_valid" = false ]; then
        echo -e "${YELLOW}ℹ️  Database needs to be restored from snapshot${NC}"
        
        if [ "$cluster_exists" = true ]; then
            if [ "$cluster_status" != "available" ]; then
                echo -e "${YELLOW}   Existing cluster is not available (status: $cluster_status)${NC}"
            elif [ "$cluster_valid" = false ]; then
                echo -e "${YELLOW}   Existing cluster has incorrect instances or configuration${NC}"
            fi
            echo -e "${YELLOW}   Will destroy and recreate from snapshot${NC}"
        else
            echo -e "${YELLOW}   No existing cluster found${NC}"
            echo -e "${YELLOW}   Will create new cluster from snapshot${NC}"
        fi
        
        # Set flag to indicate we need early database restore
        EARLY_DB_RESTORE_NEEDED=true
    else
        echo -e "${GREEN}✅ Correct database cluster exists and is available${NC}"
        echo -e "${GREEN}✅ All instances are properly configured${NC}"
        EARLY_DB_RESTORE_NEEDED=false
    fi
    
    return 0
}

# Run comprehensive pre-flight validation
pre_flight_validation() {
    echo -e "${BLUE}🔍 Pre-flight Validation${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local validation_failed=false
    
    # Run all validations
    validate_terraform_state || validation_failed=true
    validate_backup_bucket || validation_failed=true
    validate_snapshot || validation_failed=true
    parse_backup_metadata || validation_failed=true
    validate_kubernetes_resources || validation_failed=true
    validate_aws_credentials || validation_failed=true
    check_and_prepare_database || validation_failed=true
    
    if [ "$validation_failed" = true ]; then
        echo -e "${RED}❌ Pre-flight validation failed${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}✅ All pre-flight validations passed${NC}"
    return 0
}

# =============================================================================
# RESTORE STEP FUNCTIONS
# =============================================================================

# Run clean deployment script to remove existing resources
run_clean_deployment() {
    echo -e "${YELLOW}🧹 Running clean deployment to remove existing resources...${NC}"
    
    if ! "$PROJECT_ROOT/scripts/clean-deployment.sh" --force; then
        echo -e "${RED}❌ Clean deployment failed${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}✅ Clean deployment completed successfully${NC}"
    
    # Add a small delay to ensure EFS cleanup is fully propagated
    echo -e "${BLUE}   Waiting for EFS cleanup to propagate...${NC}"
    sleep 10
    
    # Restart EFS CSI driver to ensure it's fresh and ready
    echo -e "${BLUE}   Restarting EFS CSI driver to ensure fresh state...${NC}"
    kubectl rollout restart daemonset/efs-csi-node -n kube-system >/dev/null 2>&1
    kubectl rollout restart deployment/efs-csi-controller -n kube-system >/dev/null 2>&1
    
    # Wait for EFS CSI driver to be fully ready after restart
    echo -e "${BLUE}   Waiting for EFS CSI driver to be ready...${NC}"
    kubectl rollout status daemonset/efs-csi-node -n kube-system --timeout=120s
    kubectl rollout status deployment/efs-csi-controller -n kube-system --timeout=120s
    
    # Additional wait to ensure CSI driver is fully operational
    echo -e "${BLUE}   Ensuring EFS CSI driver is operational...${NC}"
    sleep 30
    
    return 0
}

# Destroy existing RDS cluster and instances
destroy_rds_cluster() {
    echo -e "${YELLOW}🗑️  Destroying existing RDS cluster...${NC}"
    
    # Get cluster identifier from Terraform
    local cluster_identifier
    cluster_identifier=$(terraform_with_retry output -raw aurora_cluster_id 2>/dev/null || echo "")
    
    if [ -z "$cluster_identifier" ]; then
        echo -e "${RED}❌ Could not get cluster identifier from Terraform${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}   Cluster: $cluster_identifier${NC}"
    
    # Check if cluster exists
    if ! aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier"; then
        echo -e "${YELLOW}ℹ️  RDS cluster not found, skipping destruction${NC}"
        return 0
    fi
    
    # Disable deletion protection
    echo -e "${BLUE}   Disabling deletion protection...${NC}"
    aws_with_retry rds modify-db-cluster --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" --no-deletion-protection || true
    echo -e "${GREEN}   ✅ Deletion protection disabled${NC}"
    
    # Delete instances first
    local instances
    instances=$(aws_with_retry rds describe-db-instances --region "$AWS_REGION" --query "DBInstances[?DBClusterIdentifier=='$cluster_identifier'].DBInstanceIdentifier" --output text 2>/dev/null || echo "")
    
    if [ -n "$instances" ]; then
        echo -e "${YELLOW}🗑️  Deleting database instances...${NC}"
        for instance in $instances; do
            echo -e "${BLUE}   Deleting instance: $instance${NC}"
            aws_with_retry rds delete-db-instance --region "$AWS_REGION" --db-instance-identifier "$instance" --skip-final-snapshot || true
            echo -e "${GREEN}   ✅ Deletion initiated for: $instance${NC}"
        done
        
        # Wait for instances to be deleted with progress tracking
        echo -e "${YELLOW}⏳ Waiting for instances to be deleted...${NC}"
        local max_wait=$DB_INSTANCE_DELETE_TIMEOUT
        local elapsed=0
        local last_status=""
        
        while [ $elapsed -lt "$max_wait" ]; do
            local remaining_instances
            remaining_instances=$(aws rds describe-db-instances --region "$AWS_REGION" --query "DBInstances[?DBClusterIdentifier=='$cluster_identifier' && DBInstanceStatus!='deleting'].DBInstanceIdentifier" --output text 2>/dev/null || echo "")
            
            if [ -z "$remaining_instances" ]; then
                echo -e "${GREEN}✅ All instances deleted successfully${NC}"
            break
        fi
        
            # Show detailed status for each remaining instance
            local status_info=""
            for instance in $remaining_instances; do
                local instance_status
                instance_status=$(aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$instance" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")
                status_info="$status_info $instance($instance_status)"
            done
            
            # Only show status if it changed to avoid spam
            if [ "$status_info" != "$last_status" ]; then
                echo -e "${BLUE}   Remaining instances:$status_info${NC}"
                last_status="$status_info"
            fi
            
            echo -e "${BLUE}   Progress: ${elapsed}s / ${max_wait}s${NC}"
            sleep "$STATUS_CHECK_INTERVAL"
            elapsed=$((elapsed + STATUS_CHECK_INTERVAL))
        done
        
        if [ $elapsed -ge "$max_wait" ]; then
            echo -e "${RED}❌ Timeout waiting for instances to be deleted${NC}" >&2
        return 1
        fi
    fi
    
    # Delete cluster
    echo -e "${YELLOW}🗑️  Deleting cluster: $cluster_identifier${NC}"
    aws_with_retry rds delete-db-cluster --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" --skip-final-snapshot || true
    echo -e "${GREEN}   ✅ Cluster deletion initiated${NC}"
    
    # Wait for cluster deletion with longer timeout
    wait_for_aws_resource "db-cluster" "$cluster_identifier" "deleted" 1200 "$STATUS_CHECK_INTERVAL" || {
        echo -e "${RED}❌ Timeout waiting for cluster deletion${NC}" >&2
        return 1
    }
    
    return 0
}

# Destroy existing RDS cluster before restore
destroy_existing_rds_cluster() {
    echo -e "${YELLOW}🗑️  Destroying existing RDS cluster...${NC}"
    
    # Get cluster identifier from Terraform
    local cluster_identifier
    cluster_identifier=$(terraform_with_retry output -raw aurora_cluster_id 2>/dev/null || echo "")
    
    if [ -z "$cluster_identifier" ]; then
        echo -e "${RED}❌ Could not get cluster identifier from Terraform${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}   Cluster: $cluster_identifier${NC}"
    
    # Check if cluster exists
    if ! aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" >/dev/null 2>&1; then
        echo -e "${GREEN}   ✅ Cluster does not exist, nothing to destroy${NC}"
        return 0
    fi
    
    # Get cluster status
    local cluster_status
    cluster_status=$(aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "unknown")
    echo -e "${BLUE}   Current cluster status: $cluster_status${NC}"
    
    # List and delete all instances in the cluster
    echo -e "${YELLOW}🗑️  Deleting database instances...${NC}"
    local instances
    instances=$(aws_with_retry rds describe-db-instances --region "$AWS_REGION" --query "DBInstances[?DBClusterIdentifier=='$cluster_identifier'].DBInstanceIdentifier" --output text 2>/dev/null || echo "")
    
    if [ -n "$instances" ]; then
        for instance in $instances; do
            echo -e "${BLUE}   Deleting instance: $instance${NC}"
            aws_with_retry rds delete-db-instance --region "$AWS_REGION" --db-instance-identifier "$instance" --skip-final-snapshot || {
                echo -e "${RED}❌ Failed to delete instance: $instance${NC}" >&2
                return 1
            }
        done
        
        # Wait for all instances to be deleted
        echo -e "${YELLOW}⏳ Waiting for instances to be deleted...${NC}"
        for instance in $instances; do
            wait_for_aws_resource "db-instance" "$instance" "deleted" "$DB_INSTANCE_DELETE_TIMEOUT" "$STATUS_CHECK_INTERVAL" || {
                echo -e "${RED}❌ Timeout waiting for instance $instance to be deleted${NC}" >&2
                return 1
            }
        done
        echo -e "${GREEN}   ✅ All database instances deleted${NC}"
    else
        echo -e "${BLUE}   No instances found in cluster${NC}"
    fi
    
    # Check if deletion protection is enabled and disable it if needed
    echo -e "${BLUE}   Checking for deletion protection...${NC}"
    local deletion_protection
    deletion_protection=$(aws_with_retry rds describe-db-clusters --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" --query 'DBClusters[0].DeletionProtection' --output text 2>/dev/null || echo "false")
    # Convert to lowercase for comparison
    deletion_protection=$(echo "$deletion_protection" | tr '[:upper:]' '[:lower:]')
    
    if [ "$deletion_protection" = "true" ]; then
        echo -e "${YELLOW}⚠️  Deletion protection is enabled, disabling it...${NC}"
        if ! aws_with_retry rds modify-db-cluster --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" --no-deletion-protection; then
            echo -e "${RED}❌ Failed to disable deletion protection${NC}" >&2
            return 1
        fi
        echo -e "${GREEN}   ✅ Deletion protection disabled${NC}"
        
        # Wait for modification to complete
        echo -e "${YELLOW}⏳ Waiting for deletion protection to be disabled...${NC}"
        wait_for_aws_resource "db-cluster" "$cluster_identifier" "available" 300 "$STATUS_CHECK_INTERVAL" || {
            echo -e "${RED}❌ Timeout waiting for cluster to be modified${NC}" >&2
            return 1
        }
    else
        echo -e "${GREEN}   ✅ Deletion protection is disabled${NC}"
    fi
    
    # Delete the cluster
    echo -e "${YELLOW}🗑️  Deleting database cluster...${NC}"
    aws_with_retry rds delete-db-cluster --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" --skip-final-snapshot || {
        echo -e "${RED}❌ Failed to delete cluster${NC}" >&2
        return 1
    }
    
    # Wait for cluster to be deleted
    echo -e "${YELLOW}⏳ Waiting for cluster to be deleted...${NC}"
    wait_for_aws_resource "db-cluster" "$cluster_identifier" "deleted" "$DB_CLUSTER_WAIT_TIMEOUT" "$STATUS_CHECK_INTERVAL" || {
        echo -e "${RED}❌ Timeout waiting for cluster to be deleted${NC}" >&2
        return 1
    }
    
    echo -e "${GREEN}   ✅ Database cluster destroyed successfully${NC}"
    return 0
}

# Check and recover KMS key if needed
# If the snapshot's KMS key is in PendingDeletion state, cancel deletion and re-enable it
check_and_recover_snapshot_kms_key() {
    echo -e "${YELLOW}🔍 Checking snapshot's KMS key status...${NC}"
    
    # Get the KMS key ID from the snapshot
    local snapshot_kms_key
    snapshot_kms_key=$(aws_with_retry rds describe-db-cluster-snapshots --region "$AWS_REGION" --db-cluster-snapshot-identifier "$SNAPSHOT_ID" --query 'DBClusterSnapshots[0].KmsKeyId' --output text 2>/dev/null || echo "")
    
    if [ -z "$snapshot_kms_key" ] || [ "$snapshot_kms_key" = "None" ]; then
        echo -e "${BLUE}   Snapshot is not encrypted or KMS key not found${NC}"
        return 0
    fi
    
    echo -e "${BLUE}   Snapshot KMS key: $snapshot_kms_key${NC}"
    
    # Check the key state
    local key_state enabled
    key_state=$(aws kms describe-key --region "$AWS_REGION" --key-id "$snapshot_kms_key" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "")
    enabled=$(aws kms describe-key --region "$AWS_REGION" --key-id "$snapshot_kms_key" --query 'KeyMetadata.Enabled' --output text 2>/dev/null || echo "")
    
    if [ -z "$key_state" ]; then
        echo -e "${RED}❌ Could not determine KMS key state${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}   KMS key state: $key_state, Enabled: $enabled${NC}"
    
    # If key is pending deletion, cancel it
    if [ "$key_state" = "PendingDeletion" ]; then
        echo -e "${YELLOW}⚠️  KMS key is pending deletion - canceling deletion...${NC}"
        if ! aws kms cancel-key-deletion --region "$AWS_REGION" --key-id "$snapshot_kms_key" >/dev/null 2>&1; then
            echo -e "${RED}❌ Failed to cancel KMS key deletion${NC}" >&2
            return 1
        fi
        echo -e "${GREEN}   ✅ KMS key deletion canceled${NC}"
        
        # Update key state after cancellation
        key_state="Disabled"
    fi
    
    # If key is disabled, enable it
    if [ "$enabled" = "false" ] || [ "$enabled" = "False" ]; then
        echo -e "${YELLOW}⚠️  KMS key is disabled - enabling it...${NC}"
        if ! aws kms enable-key --region "$AWS_REGION" --key-id "$snapshot_kms_key" >/dev/null 2>&1; then
            echo -e "${RED}❌ Failed to enable KMS key${NC}" >&2
            return 1
        fi
        echo -e "${GREEN}   ✅ KMS key enabled${NC}"
    fi
    
    # Verify key is now enabled and available
    key_state=$(aws kms describe-key --region "$AWS_REGION" --key-id "$snapshot_kms_key" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "")
    enabled=$(aws kms describe-key --region "$AWS_REGION" --key-id "$snapshot_kms_key" --query 'KeyMetadata.Enabled' --output text 2>/dev/null || echo "")
    
    # Key must be in Enabled state AND have Enabled=true
    # Note: After canceling deletion, KeyState may still be "Disabled" briefly before transitioning to "Enabled"
    if [ "$enabled" != "true" ] && [ "$enabled" != "True" ]; then
        echo -e "${RED}❌ KMS key is not enabled after recovery${NC}" >&2
        echo -e "${RED}   State: $key_state, Enabled: $enabled${NC}" >&2
        return 1
    fi
    
    # Check that key is not in an unusable state
    if [ "$key_state" = "PendingDeletion" ] || [ "$key_state" = "PendingImport" ] || [ "$key_state" = "Unavailable" ]; then
        echo -e "${RED}❌ KMS key is in an unusable state: $key_state${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}   ✅ KMS key is available for use${NC}"
    return 0
}

# Reset RDS master password to match Terraform state
# This is necessary because restored snapshots inherit the password from when they were created,
# but Terraform may have generated a new password in its current state
reset_rds_master_password() {
    local cluster_identifier="$1"
    local max_attempts=3
    local attempt=0
    local wait_time=10
    
    echo -e "${YELLOW}🔑 Resetting RDS master password to match Terraform state...${NC}"
    
    # Get the current password from Terraform
    local terraform_password
    terraform_password=$(terraform_with_retry output -raw aurora_password 2>/dev/null || echo "")
    
    if [ -z "$terraform_password" ]; then
        echo -e "${RED}❌ Could not get password from Terraform${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}   Updating master password for cluster: $cluster_identifier${NC}"
    
    # Reset the password with retry logic
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        echo -e "${BLUE}   Attempt $attempt/$max_attempts${NC}"
        
        if aws_with_retry rds modify-db-cluster \
            --region "$AWS_REGION" \
            --db-cluster-identifier "$cluster_identifier" \
            --master-user-password "$terraform_password" \
            --apply-immediately \
            --query 'DBCluster.{Status:Status}' \
            --output text > /dev/null 2>&1; then
            
            echo -e "${GREEN}   ✅ Master password reset successfully${NC}"
            echo -e "${BLUE}   Waiting ${wait_time} seconds for password change to propagate...${NC}"
            sleep "$wait_time"
            
            # Verify the password change took effect by attempting a connection test
            echo -e "${BLUE}   Verifying password change...${NC}"
            local db_endpoint
            db_endpoint=$(terraform_with_retry output -raw aurora_endpoint 2>/dev/null || echo "")
            
            if [ -n "$db_endpoint" ]; then
                # Get a pod to test connection from
                local test_pod
                test_pod=$(kubectl get pods -n openemr -l app=openemr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                
                if [ -n "$test_pod" ]; then
                    if kubectl exec "$test_pod" -n openemr -c openemr -- mysql -h "$db_endpoint" -u openemr -p"$terraform_password" -e "SELECT 1;" > /dev/null 2>&1; then
                        echo -e "${GREEN}   ✅ Password change verified - database connection successful${NC}"
                        return 0
                    else
                        echo -e "${YELLOW}   ⚠️  Connection test failed, but password reset command succeeded${NC}"
                        echo -e "${YELLOW}   ⚠️  Continuing anyway - pods may need time to restart${NC}"
                        return 0
                    fi
                fi
            fi
            
            # If we can't verify, assume success since the AWS command succeeded
            echo -e "${GREEN}   ✅ Password reset command succeeded${NC}"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo -e "${YELLOW}   ⚠️  Password reset failed, retrying in 5 seconds...${NC}"
            sleep 5
        fi
    done
    
    echo -e "${RED}❌ Failed to reset master password after $max_attempts attempts${NC}" >&2
    return 1
}

# Restore RDS cluster from snapshot
restore_rds_cluster_from_snapshot() {
    echo -e "${YELLOW}🔄 Restoring RDS cluster from snapshot...${NC}"
    
    # Check and recover the snapshot's KMS key if needed
    if ! check_and_recover_snapshot_kms_key; then
        echo -e "${RED}❌ Failed to prepare snapshot's KMS key${NC}" >&2
        return 1
    fi
    
    # First destroy existing cluster if it exists
    if ! destroy_existing_rds_cluster; then
        echo -e "${RED}❌ Failed to destroy existing cluster${NC}" >&2
        return 1
    fi
    
    # Get cluster identifier from Terraform
    local cluster_identifier
    cluster_identifier=$(terraform_with_retry output -raw aurora_cluster_id 2>/dev/null || echo "")
    
    if [ -z "$cluster_identifier" ]; then
        echo -e "${RED}❌ Could not get cluster identifier from Terraform${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}   Cluster: $cluster_identifier${NC}"
    echo -e "${BLUE}   Snapshot: $SNAPSHOT_ID${NC}"
    
    # Get snapshot details
    local engine port
    engine=$(aws_with_retry rds describe-db-cluster-snapshots --region "$AWS_REGION" --db-cluster-snapshot-identifier "$SNAPSHOT_ID" --query 'DBClusterSnapshots[0].Engine' --output text 2>/dev/null || echo "aurora-mysql")
    port=$(aws_with_retry rds describe-db-cluster-snapshots --region "$AWS_REGION" --db-cluster-snapshot-identifier "$SNAPSHOT_ID" --query 'DBClusterSnapshots[0].Port' --output text 2>/dev/null || echo "3306")
    
    if [ "$port" = "0" ] || [ -z "$port" ]; then
        port="3306"
    fi
    
    # Get configuration from Terraform
    local db_subnet_group_name vpc_security_group_ids engine_version
    db_subnet_group_name=$(terraform_with_retry output -raw aurora_db_subnet_group_name 2>/dev/null || echo "")
    engine_version=$(terraform_with_retry output -raw aurora_engine_version 2>/dev/null || echo "8.0.mysql_aurora.3.11.1")
    
    # Log the engine version being used
    echo -e "${BLUE}   Using engine version: $engine_version${NC}"
    
    # Get security group ID from Terraform state
    vpc_security_group_ids=$(terraform_with_retry show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type == "aws_security_group" and .name == "rds") | .values.id' 2>/dev/null || echo "")
    
    # KMS Key handling:
    # - By default, we do NOT specify --kms-key-id during restore
    # - The snapshot is already encrypted and AWS will automatically use the snapshot's original KMS key
    # - Users can optionally provide a custom KMS key via --kms-key flag (e.g., if they copied the original key)
    # - Specifying an incorrect KMS key would cause a KMSKeyNotAccessibleFault error
    
    echo -e "${BLUE}   Master username/password will be inherited from snapshot${NC}"
    
    if [ -n "$CUSTOM_KMS_KEY" ]; then
        echo -e "${BLUE}   KMS encryption will use custom key: $CUSTOM_KMS_KEY${NC}"
    else
        echo -e "${BLUE}   KMS encryption will use snapshot's original key (default)${NC}"
    fi
    
    # Build restore command (master username/password are inherited from snapshot)
    local restore_cmd
    restore_cmd="aws rds restore-db-cluster-from-snapshot --region \"$AWS_REGION\" --db-cluster-identifier \"$cluster_identifier\" --snapshot-identifier \"$SNAPSHOT_ID\" --engine \"$engine\" --engine-version \"$engine_version\" --port \"$port\""
    
    if [ -n "$db_subnet_group_name" ]; then
        restore_cmd="$restore_cmd --db-subnet-group-name \"$db_subnet_group_name\""
        echo -e "${BLUE}   Using subnet group: $db_subnet_group_name${NC}"
    fi
    
    if [ -n "$vpc_security_group_ids" ]; then
        restore_cmd="$restore_cmd --vpc-security-group-ids \"$vpc_security_group_ids\""
        echo -e "${BLUE}   Using security groups: $vpc_security_group_ids${NC}"
    fi
    
    # Add custom KMS key if provided
    if [ -n "$CUSTOM_KMS_KEY" ]; then
        restore_cmd="$restore_cmd --kms-key-id \"$CUSTOM_KMS_KEY\""
    fi
    
    # Execute restore command
    echo -e "${BLUE}   Executing restore command...${NC}"
    echo -e "${BLUE}   Command: $restore_cmd${NC}"
    if ! eval "$restore_cmd"; then
        echo -e "${RED}❌ Failed to restore cluster from snapshot${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}   ✅ Restore command executed successfully${NC}"
    
    # Wait for cluster to be available
    wait_for_aws_resource "db-cluster" "$cluster_identifier" "available" "$DB_CLUSTER_WAIT_TIMEOUT" "$STATUS_CHECK_INTERVAL" || {
        echo -e "${RED}❌ Timeout waiting for cluster to be available${NC}" >&2
            return 1
    }
    
    # Apply serverless scaling configuration
    echo -e "${YELLOW}⚙️  Applying serverless scaling configuration...${NC}"
    local min_capacity max_capacity
    min_capacity=$(terraform_with_retry show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type == "aws_rds_cluster" and .name == "openemr") | .values.serverless_v2_scaling_configuration[0].min_capacity' 2>/dev/null || echo "0.5")
    max_capacity=$(terraform_with_retry show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type == "aws_rds_cluster" and .name == "openemr") | .values.serverless_v2_scaling_configuration[0].max_capacity' 2>/dev/null || echo "16")
    
    # Handle null values from Terraform
    if [ "$min_capacity" = "null" ] || [ -z "$min_capacity" ]; then
        min_capacity="0.5"
    fi
    if [ "$max_capacity" = "null" ] || [ -z "$max_capacity" ]; then
        max_capacity="16"
    fi
    
    echo -e "${BLUE}   Min capacity: ${min_capacity} ACU, Max capacity: ${max_capacity} ACU${NC}"
    aws_with_retry rds modify-db-cluster --region "$AWS_REGION" --db-cluster-identifier "$cluster_identifier" \
        --serverless-v2-scaling-configuration MinCapacity="$min_capacity",MaxCapacity="$max_capacity"
    echo -e "${GREEN}   ✅ Serverless scaling configuration applied${NC}"
    
    # Create database instances
    echo -e "${YELLOW}🏗️  Creating database instances...${NC}"
    local instance_count
    # Get the count of cluster instances from Terraform state
    instance_count=$(terraform_with_retry show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type == "aws_rds_cluster_instance" and .name == "openemr")' | jq -s 'length' 2>/dev/null || echo "2")
    
    # Handle null values and ensure we have a valid number
    if [ "$instance_count" = "null" ] || [ -z "$instance_count" ] || ! echo "$instance_count" | grep -q '^[0-9]\+$'; then
        instance_count=2
    fi
    
    echo -e "${BLUE}   Creating $instance_count instances${NC}"
    
    # Get the cluster name from Terraform to match the expected instance naming pattern
    local cluster_name
    cluster_name=$(terraform_with_retry output -raw cluster_name 2>/dev/null || echo "openemr-eks")
    
    for ((i=0; i<instance_count; i++)); do
        local instance_identifier="${cluster_name}-aurora-${i}"
        echo -e "${BLUE}   Creating instance: $instance_identifier${NC}"
        
        aws_with_retry rds create-db-instance --region "$AWS_REGION" \
            --db-instance-identifier "$instance_identifier" \
            --db-cluster-identifier "$cluster_identifier" \
            --db-instance-class "db.serverless" \
            --engine "$engine" || {
            echo -e "${RED}❌ Failed to create instance $instance_identifier${NC}" >&2
            return 1
        }
    done
    
    # Wait for all instances to be available
    echo -e "${YELLOW}⏳ Waiting for database instances to be available...${NC}"
    for ((i=0; i<instance_count; i++)); do
        local instance_identifier="${cluster_name}-aurora-${i}"
        echo -e "${BLUE}   Waiting for instance: $instance_identifier${NC}"
        
        wait_for_aws_resource "db-instance" "$instance_identifier" "available" 1200 30 || {
            echo -e "${RED}❌ Instance $instance_identifier failed to become available${NC}" >&2
            return 1
        }
    done
    
    echo -e "${GREEN}✅ All database instances are available${NC}"
    
    # Reset the master password to match Terraform state
    # This is necessary because the snapshot has the old password
    if ! reset_rds_master_password "$cluster_identifier"; then
        echo -e "${RED}❌ Failed to reset master password${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}✅ RDS cluster restored successfully${NC}"
    return 0
}

# Restore application data and update configuration for new database endpoint
restore_application_data() {
    echo -e "${YELLOW}📁 Restoring application data and updating configuration...${NC}"
    
    
    # Get OpenEMR version from Terraform
    local openemr_version
    openemr_version=$(terraform_with_retry output -json 2>/dev/null | jq -r '.openemr_version.value // empty' 2>/dev/null || echo "$DEFAULT_OPENEMR_VERSION")
    
    if [ -z "$openemr_version" ] || [ "$openemr_version" = "null" ]; then
        openemr_version="$DEFAULT_OPENEMR_VERSION"
    fi
    
    echo -e "${BLUE}   Using OpenEMR version: $openemr_version${NC}"
    
    # Extract timestamp from snapshot ID for backup file naming
    # Snapshot ID format: openemr-eks-aurora-61a909e9-backup-20251019-131840
    # Backup file format: app-data-backup-20251019-131840.tar.gz
    local timestamp
    # shellcheck disable=SC2001
    timestamp=$(echo "$SNAPSHOT_ID" | sed 's/.*backup-\([0-9]\{8\}-[0-9]\{6\}\).*/\1/')
    
    if [ -z "$timestamp" ] || [ "$timestamp" = "$SNAPSHOT_ID" ]; then
        echo -e "${RED}❌ Could not extract timestamp from snapshot ID: $SNAPSHOT_ID${NC}" >&2
        echo -e "${RED}   Expected format: openemr-eks-aurora-61a909e9-backup-YYYYMMDD-HHMMSS${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}   Extracted timestamp: $timestamp${NC}"
    
    # Use the existing openemr namespace which already has IRSA configured
    local temp_namespace
    temp_namespace="openemr"
    
    # Note: EFS storage class is already configured by deploy.sh
    
    # Get OpenEMR role ARN from Terraform
    echo -e "${BLUE}   Getting OpenEMR role ARN for IRSA...${NC}"
    local openemr_role_arn
    
    # Call the function - the function handles its own output to stderr
    # and returns only the clean role ARN on stdout (last line)
    if ! openemr_role_arn=$(get_openemr_role_arn); then
        echo -e "${RED}❌ Failed to get OpenEMR role ARN${NC}" >&2
        return 1
    fi
    
    # The function returns the role ARN on the last line, so extract it
    openemr_role_arn=$(echo "$openemr_role_arn" | tail -n 1)
    
    echo -e "${GREEN}   ✅ Got OpenEMR role ARN: $openemr_role_arn${NC}"
    
    # Get database credentials from Terraform
    echo -e "${BLUE}   Getting database credentials from Terraform...${NC}"
    local db_endpoint db_user db_pass db_name
    db_endpoint=$(terraform_with_retry output -raw aurora_endpoint 2>/dev/null || echo "")
    # Clean the endpoint by removing trailing % and other shell artifacts
    db_endpoint=$(echo "$db_endpoint" | tr -d '\r\n%')
    db_user="openemr"  # Default username for Aurora
    db_pass=$(terraform_with_retry output -raw aurora_password 2>/dev/null || echo "")
    # Clean the password by removing trailing % and other shell artifacts
    db_pass=$(echo "$db_pass" | tr -d '\r\n%')
    db_name="openemr"  # Default database name
    
    if [ -z "$db_endpoint" ] || [ -z "$db_pass" ]; then
        echo -e "${RED}❌ Failed to get database credentials from Terraform${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}   ✅ Got database credentials${NC}"
    
    # Use existing openemr namespace (already has IRSA configured)
    echo -e "${BLUE}   Using existing openemr namespace with IRSA...${NC}"
    echo -e "${BLUE}   Using existing PVC and service account...${NC}"
    
    # Delete existing pod if it exists to avoid update conflicts
    echo -e "${BLUE}   Cleaning up any existing restore pod...${NC}"
    kubectl delete pod temp-data-restore -n "$temp_namespace" --ignore-not-found=true --timeout=30s 2>/dev/null || true
    
    # Create temporary restore pod with resource limits
    echo -e "${BLUE}   Creating temporary restore pod...${NC}"
    
    # Create pod spec in a temporary file to avoid YAML parsing issues
    POD_SPEC_FILE="/tmp/temp-restore-pod.yaml"
    
    # Write YAML template with placeholders
    cat > "$POD_SPEC_FILE" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: temp-data-restore
  namespace: $temp_namespace
spec:
  serviceAccountName: openemr-sa
  tolerations:
  - key: "CriticalAddonsOnly"
    operator: "Exists"
    effect: "NoSchedule"
  containers:
  - name: restore
    image: openemr/openemr:OPENEMR_VERSION_PLACEHOLDER
    resources:
      requests:
        memory: "MEMORY_REQUEST_PLACEHOLDER"
        cpu: "CPU_REQUEST_PLACEHOLDER"
      limits:
        memory: "MEMORY_LIMIT_PLACEHOLDER"
        cpu: "CPU_LIMIT_PLACEHOLDER"
    command: ['sh', '-c']
    args:
    - |
      echo "Starting temporary OpenEMR container for data restoration..."
      echo "OpenEMR version: OPENEMR_VERSION_PLACEHOLDER"
      
      # Install required tools
      echo "Installing required tools..."
      # OpenEMR 8.0.0 uses Alpine Linux, so we use apk
      echo "Installing AWS CLI..."
      apk add --no-cache aws-cli
      
      # Verify AWS CLI installation
      echo "Verifying AWS CLI installation..."
      aws --version || {
        echo "ERROR: AWS CLI installation failed"
        exit 1
      }
      
      # Using timestamp from environment variable: \$timestamp
      
      # Test S3 access first
      echo "Testing S3 access..."
      aws s3 ls "s3://\$BACKUP_BUCKET/application-data/" | head -5
      
      # Download and extract application data
      echo "Downloading application data from S3..."
      if ! aws s3 cp "s3://\$BACKUP_BUCKET/application-data/app-data-backup-\$TIMESTAMP.tar.gz" /tmp/app-data.tar.gz; then
        echo "ERROR: Failed to download application data from S3"
        echo "Please check:"
        echo "1. AWS credentials are properly configured"
        echo "2. S3 bucket '\$BACKUP_BUCKET' exists and is accessible"
        echo "3. File 'application-data/app-data-backup-\$TIMESTAMP.tar.gz' exists in the bucket"
        exit 1
      fi
      
      # Check download size
      echo "Downloaded file size:"
      ls -lh /tmp/app-data.tar.gz
      
      # Extract to EFS mount point
      # Note: The tar was created with "tar -czf ... -C /path/to/openemr sites/"
      # This means the archive contains paths like "sites/default/..."
      # We need to extract and strip the "sites/" prefix since EFS is mounted at .../sites
      echo "Extracting application data to EFS..."
      tar -xzf /tmp/app-data.tar.gz -C /mnt/efs/ --strip-components=1
      
      # Verify extraction
      echo "Verifying data extraction..."
      ls -la /mnt/efs/default/
      
      # Check current sqlconf.php
      echo "Current sqlconf.php content:"
      if [ -f "/mnt/efs/default/sqlconf.php" ]; then
        cat /mnt/efs/default/sqlconf.php
      else
        echo "sqlconf.php not found!"
      fi
      
      # Fix OpenEMR configuration after restore
      echo "Fixing OpenEMR configuration..."
      
      # Get database credentials from environment variables
      # These should be set by the pod's environment
      DB_ENDPOINT="\${DB_ENDPOINT:-}"
      DB_USER="\${DB_USER:-}"
      DB_PASS="\${DB_PASS:-}"
      DB_NAME="\${DB_NAME:-}"
      
      if [ -z "\$DB_ENDPOINT" ] || [ -z "\$DB_PASS" ]; then
        echo "ERROR: Missing database credentials"
        exit 1
      fi
      
        # Update sqlconf.php for new database endpoint (OpenEMR already created proper config files)
        echo "Updating sqlconf.php for new database endpoint..."
        if [ -f "/mnt/efs/default/sqlconf.php" ]; then
          # Backup the original
          cp /mnt/efs/default/sqlconf.php /mnt/efs/default/sqlconf.php.backup
          
          # Update database endpoint (cluster ID changes after restore)
          echo "Before update:"
          grep -E "\\\$host|\\\$config" /mnt/efs/default/sqlconf.php
          
          # Use printf to create a robust sqlconf.php with new credentials
          printf '<?php\n//  OpenEMR\n//  MySQL Config\n\nglobal \$disable_utf8_flag;\n\$disable_utf8_flag = false;\n\n\$host   = '\''%s'\'';\n\$port   = '\''3306'\'';\n\$login  = '\''%s'\'';\n\$pass   = '\''%s'\'';\n\$dbase  = '\''%s'\'';\n\$db_encoding = '\''utf8mb4'\'';\n\n\$config = 1;\n' "\$DB_ENDPOINT" "\$DB_USER" "\$DB_PASS" "\$DB_NAME" > /mnt/efs/default/sqlconf.php
          
          echo "After update:"
          grep -E "\\\\\\\$host|\\\\\\\$config" /mnt/efs/default/sqlconf.php
          
          echo "✅ Updated sqlconf.php with new database endpoint: \$DB_ENDPOINT"
          echo "✅ Set config=1 to prevent setup from running"
        else
          echo "❌ ERROR: sqlconf.php not found - OpenEMR should have created this during deployment"
          exit 1
        fi
      
      # Verify config.php exists (OpenEMR should have created it during fresh install)
      echo "Verifying config.php exists..."
      if [ -f "/mnt/efs/default/config.php" ]; then
        echo "✅ config.php exists (created by OpenEMR during fresh install)"
      else
        echo "❌ ERROR: config.php not found - OpenEMR should have created this during deployment"
        exit 1
      fi
      
      # Remove docker-leader and docker-initiated files (CRITICAL: must be done after config.php)
      echo "Removing docker-leader and docker-initiated files..."
      rm -f /mnt/efs/default/docker-leader
      rm -f /mnt/efs/default/docker-initiated
      touch /mnt/efs/default/docker-completed
      echo "✅ Removed docker-leader and docker-initiated files"
      echo "✅ Created docker-completed file"
      
      # Verify the files were created/removed correctly
      echo "Verifying configuration files..."
      if [ -f "/mnt/efs/default/config.php" ]; then
        echo "✅ config.php exists"
      else
        echo "❌ ERROR: config.php was not created"
        exit 1
      fi
      
      if [ ! -f "/mnt/efs/default/docker-initiated" ]; then
        echo "✅ docker-initiated file successfully removed"
      else
        echo "❌ ERROR: docker-initiated file still exists"
        exit 1
      fi
      
      if [ -f "/mnt/efs/default/docker-completed" ]; then
        echo "✅ docker-completed file created"
      else
        echo "❌ ERROR: docker-completed file was not created"
        exit 1
      fi
      
      echo ""
      echo "=== FINAL VERIFICATION ==="
      echo "sqlconf.php status:"
      if [ -f "/mnt/efs/default/sqlconf.php" ]; then
        echo "✅ sqlconf.php exists"
        echo "sqlconf.php content:"
        cat /mnt/efs/default/sqlconf.php
      else
        echo "❌ ERROR: sqlconf.php was not created - this will cause OpenEMR to run setup!"
        exit 1
      fi
      echo ""
      echo "config.php content (first 20 lines):"
      head -20 /mnt/efs/default/config.php
      echo ""
      echo "Docker files status:"
      ls -la /mnt/efs/docker-*
      
      echo ""
      echo "🎉 Data restoration and configuration fixing completed successfully!"
    volumeMounts:
    - name: efs-volume
      mountPath: /mnt/efs
    env:
    - name: AWS_DEFAULT_REGION
      value: "AWS_REGION_PLACEHOLDER"
    - name: AWS_REGION
      value: "AWS_REGION_PLACEHOLDER"
    - name: AWS_WEB_IDENTITY_TOKEN_FILE
      value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
    - name: AWS_ROLE_ARN
      value: "ROLE_ARN_PLACEHOLDER"
    - name: BACKUP_BUCKET
      value: "BACKUP_BUCKET_PLACEHOLDER"
    - name: TIMESTAMP
      value: "TIMESTAMP_PLACEHOLDER"
    - name: DB_ENDPOINT
      value: "DB_ENDPOINT_PLACEHOLDER"
    - name: DB_USER
      value: "DB_USER_PLACEHOLDER"
    - name: DB_PASS
      value: "DB_PASS_PLACEHOLDER"
    - name: DB_NAME
      value: "DB_NAME_PLACEHOLDER"
  volumes:
  - name: efs-volume
    persistentVolumeClaim:
      claimName: openemr-sites-pvc
  restartPolicy: Never
EOF
    
    # Substitute placeholders with actual values
    sed -i '' "s|AWS_REGION_PLACEHOLDER|$AWS_REGION|g" "$POD_SPEC_FILE"
    sed -i '' "s|ROLE_ARN_PLACEHOLDER|$openemr_role_arn|g" "$POD_SPEC_FILE"
    sed -i '' "s|BACKUP_BUCKET_PLACEHOLDER|$BACKUP_BUCKET|g" "$POD_SPEC_FILE"
    sed -i '' "s|TIMESTAMP_PLACEHOLDER|$timestamp|g" "$POD_SPEC_FILE"
    sed -i '' "s|DB_ENDPOINT_PLACEHOLDER|$db_endpoint|g" "$POD_SPEC_FILE"
    sed -i '' "s|DB_USER_PLACEHOLDER|$db_user|g" "$POD_SPEC_FILE"
    sed -i '' "s|DB_PASS_PLACEHOLDER|$db_pass|g" "$POD_SPEC_FILE"
    sed -i '' "s|DB_NAME_PLACEHOLDER|$db_name|g" "$POD_SPEC_FILE"
    sed -i '' "s|OPENEMR_VERSION_PLACEHOLDER|$openemr_version|g" "$POD_SPEC_FILE"
    sed -i '' "s|MEMORY_REQUEST_PLACEHOLDER|$TEMP_POD_MEMORY_REQUEST|g" "$POD_SPEC_FILE"
    sed -i '' "s|CPU_REQUEST_PLACEHOLDER|$TEMP_POD_CPU_REQUEST|g" "$POD_SPEC_FILE"
    sed -i '' "s|MEMORY_LIMIT_PLACEHOLDER|$TEMP_POD_MEMORY_LIMIT|g" "$POD_SPEC_FILE"
    sed -i '' "s|CPU_LIMIT_PLACEHOLDER|$TEMP_POD_CPU_LIMIT|g" "$POD_SPEC_FILE"
    
    # Check for any remaining placeholders
    if grep -q "PLACEHOLDER" "$POD_SPEC_FILE"; then
        echo -e "${RED}❌ ERROR: Unsubstituted placeholders found in pod spec:${NC}" >&2
        grep "PLACEHOLDER" "$POD_SPEC_FILE" >&2
        exit 1
    fi
    
    # Debug: Show resource section
    echo "   Debug: Resource section after substitution:"
    grep -A 10 -B 2 "resources:" "$POD_SPEC_FILE"
    
    # Apply the pod spec
    if ! kubectl apply -f "$POD_SPEC_FILE"; then
        echo -e "${RED}❌ Failed to create temporary restore pod${NC}" >&2
        echo -e "${RED}   Pod spec file: $POD_SPEC_FILE${NC}" >&2
        echo -e "${YELLOW}   Pod spec preserved for debugging: $POD_SPEC_FILE${NC}" >&2
        echo -e "${YELLOW}   You can inspect it with: cat $POD_SPEC_FILE${NC}" >&2
        return 1
    fi
    
    # Pod spec file will be cleaned up after pod completion
    
    # Wait for PVC to be bound (will happen when pod is created due to WaitForFirstConsumer)
    echo -e "${BLUE}   Waiting for PVC to be bound...${NC}"
    
    # Wait for PVC to be bound with a more robust approach
    local pvc_bound=false
    local wait_time=0
    local max_wait=120
    
    while [ $wait_time -lt $max_wait ]; do
        local pvc_status
        pvc_status=$(kubectl get pvc openemr-sites-pvc -n "$temp_namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        
        if [ "$pvc_status" = "Bound" ]; then
            echo -e "${GREEN}   ✅ PVC is bound${NC}"
            pvc_bound=true
            break
        fi
        
        echo -e "${BLUE}   PVC status: $pvc_status (${wait_time}s / ${max_wait}s)${NC}"
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    if [ "$pvc_bound" = false ]; then
        echo -e "${RED}❌ PVC failed to bind within timeout${NC}" >&2
        kubectl describe pvc openemr-sites-pvc -n "$temp_namespace" || true
        return 1
    fi
    
    # Wait for pod to start and complete
    echo -e "${BLUE}   Waiting for temporary pod to start and complete...${NC}"
    
    # Wait for pod to be scheduled and running
    local pod_started=false
    local wait_time=0
    local max_start_wait=300  # 5 minutes for pod to start
    
    while [ $wait_time -lt $max_start_wait ]; do
        if kubectl get pod temp-data-restore -n "$temp_namespace" >/dev/null 2>&1; then
            local pod_status
            pod_status=$(kubectl get pod temp-data-restore -n "$temp_namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [ "$pod_status" = "Running" ] || [ "$pod_status" = "Succeeded" ] || [ "$pod_status" = "Failed" ]; then
                echo -e "${GREEN}   ✅ Pod is $pod_status${NC}"
                pod_started=true
                break
            fi
            
            echo -e "${BLUE}   Pod status: $pod_status (${wait_time}s / ${max_start_wait}s)${NC}"
        else
            echo -e "${BLUE}   Pod not found yet (${wait_time}s / ${max_start_wait}s)${NC}"
        fi
        
        sleep 10
        wait_time=$((wait_time + 10))
    done
    
    if [ "$pod_started" = false ]; then
        echo -e "${RED}❌ Pod failed to start within timeout${NC}" >&2
        kubectl get events -n "$temp_namespace" --sort-by='.lastTimestamp' | tail -10 || true
        echo -e "${YELLOW}   Pod spec preserved for debugging: $POD_SPEC_FILE${NC}" >&2
        echo -e "${YELLOW}   You can inspect it with: cat $POD_SPEC_FILE${NC}" >&2
        return 1
    fi
    
    # Wait for pod to complete (Succeeded or Failed)
    echo -e "${BLUE}   Waiting for data restoration to complete...${NC}"
    local pod_completed=false
    local completion_wait_time=0
    local max_completion_wait=600  # 10 minutes for pod to complete
    
    while [ $completion_wait_time -lt $max_completion_wait ]; do
        if kubectl get pod temp-data-restore -n "$temp_namespace" >/dev/null 2>&1; then
            local pod_status
            pod_status=$(kubectl get pod temp-data-restore -n "$temp_namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [ "$pod_status" = "Succeeded" ]; then
                echo -e "${GREEN}   ✅ Pod completed successfully${NC}"
                pod_completed=true
                break
            elif [ "$pod_status" = "Failed" ]; then
                echo -e "${RED}❌ Pod failed${NC}" >&2
                echo -e "${YELLOW}   Pod logs:${NC}"
                kubectl logs temp-data-restore -n "$temp_namespace" || true
                echo -e "${YELLOW}   Pod spec preserved for debugging: $POD_SPEC_FILE${NC}" >&2
                echo -e "${YELLOW}   You can inspect it with: cat $POD_SPEC_FILE${NC}" >&2
                return 1
            fi
            
            echo -e "${BLUE}   Pod status: $pod_status (${completion_wait_time}s / ${max_completion_wait}s)${NC}"
        else
            # Pod might have completed and been cleaned up
            echo -e "${GREEN}   ✅ Pod completed and was cleaned up${NC}"
            pod_completed=true
            break
        fi
        
        sleep 15
        completion_wait_time=$((completion_wait_time + 15))
    done
    
    if [ "$pod_completed" = false ]; then
        echo -e "${YELLOW}⚠️  Pod did not complete within timeout, checking logs...${NC}"
        kubectl logs temp-data-restore -n "$temp_namespace" || true
    fi
    
    # Check if pod completed successfully
    local pod_status
    pod_status=$(kubectl get pod temp-data-restore -n "$temp_namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    if [ "$pod_status" = "Succeeded" ]; then
        echo -e "${GREEN}   ✅ Data restoration completed successfully${NC}"
    else
        echo -e "${YELLOW}⚠️  Pod status: $pod_status${NC}"
        echo -e "${YELLOW}   Final pod logs:${NC}"
        kubectl logs temp-data-restore -n "$temp_namespace" || true
        echo -e "${YELLOW}   Pod events:${NC}"
        kubectl get events -n "$temp_namespace" --field-selector involvedObject.name=temp-data-restore || true
    fi
    
    # Clean up temporary restore pod (but keep the openemr namespace)
    echo -e "${YELLOW}ℹ️  Cleaning up temporary restore pod...${NC}"
    kubectl delete pod temp-data-restore -n "$temp_namespace" --timeout=30s 2>/dev/null || true
    
    return 0
}

# Deploy OpenEMR with defaults and deployment
deploy_openemr() {
    echo -e "${YELLOW}🚀 Deploying OpenEMR with defaults and deployment...${NC}"
    
    # Run restore-defaults.sh with force flag
    echo -e "${BLUE}   Running restore-defaults.sh --force...${NC}"
    if ! "$PROJECT_ROOT/scripts/restore-defaults.sh" --force; then
        echo -e "${RED}❌ restore-defaults.sh failed${NC}" >&2
            return 1
        fi
    echo -e "${GREEN}   ✅ restore-defaults.sh completed${NC}"
    
    # Run deploy.sh
    echo -e "${BLUE}   Running deploy.sh...${NC}"
    if ! "$PROJECT_ROOT/k8s/deploy.sh"; then
        echo -e "${RED}❌ deploy.sh failed${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}   ✅ deploy.sh completed${NC}"
    
    echo -e "${GREEN}✅ OpenEMR deployment completed successfully${NC}"
    return 0
}

# Clean up crypto key cache files after deployment
cleanup_crypto_keys() {
    echo -e "${YELLOW}🔑 Cleaning up crypto key cache files...${NC}"
    
    # Wait a moment for pods to be running
    echo -e "${BLUE}   Waiting for pods to be running...${NC}"
    sleep 10
    
    # Get all pod names
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$pods" ]; then
        echo -e "${YELLOW}⚠️  No OpenEMR pods found to clean crypto keys${NC}"
        return 0
    fi
    
    # Delete sixa/sixb from each pod
    for pod in $pods; do
        echo -e "${BLUE}   Cleaning crypto keys from pod: $pod${NC}"
        kubectl exec -n "$NAMESPACE" "$pod" -c openemr -- sh -c "find /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/methods/ -name '*six*' -type f -delete 2>/dev/null || true" 2>/dev/null || true
        echo -e "${GREEN}   ✅ Cleaned crypto keys from $pod${NC}"
    done
    
    # Wait for OpenEMR to regenerate keys and stabilize
    echo -e "${BLUE}   Waiting 30 seconds for OpenEMR to regenerate keys...${NC}"
    sleep 30
    
    echo -e "${GREEN}✅ Crypto key cleanup completed${NC}"
    return 0
}

# Verify restore success with retry logic
verify_restore_success() {
    echo -e "${YELLOW}🔍 Verifying restore success (max attempts: ${VERIFICATION_MAX_ATTEMPTS})...${NC}"
    
    local attempt=1
    
    while [ "$attempt" -le "$VERIFICATION_MAX_ATTEMPTS" ]; do
        echo -e "${BLUE}   Verification attempt $attempt/$VERIFICATION_MAX_ATTEMPTS${NC}"
        
        # Poll for pods to be ready with timeout
        echo -e "${BLUE}   Waiting for pods to be ready (timeout: ${VERIFICATION_TIMEOUT}s, interval: ${VERIFICATION_INTERVAL}s)...${NC}"
        local elapsed=0
        local ready_count=0
        local desired_count=0
        
        while [ "$elapsed" -lt "$VERIFICATION_TIMEOUT" ]; do
            ready_count=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            desired_count=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            
            # Check if deployment exists
            if [ "$desired_count" -eq 0 ]; then
                echo -e "${RED}❌ OpenEMR deployment not found or has 0 replicas${NC}" >&2
                return 1
            fi
            
            if [ "$ready_count" = "$desired_count" ] && [ "$ready_count" -gt 0 ]; then
                echo -e "${GREEN}✅ All $ready_count/$desired_count pods are ready${NC}"
                return 0
            fi
            
            echo -e "${YELLOW}   ⏳ Pods: $ready_count/$desired_count ready (elapsed: ${elapsed}s)${NC}"
            sleep "$VERIFICATION_INTERVAL"
            elapsed=$((elapsed + VERIFICATION_INTERVAL))
        done
        
        # If this is not the last attempt, clean crypto keys and retry
        if [ "$attempt" -lt "$VERIFICATION_MAX_ATTEMPTS" ]; then
            echo -e "${YELLOW}⚠️  Verification attempt $attempt failed: Only $ready_count/$desired_count pods are ready${NC}"
            echo -e "${BLUE}   Cleaning crypto keys and retrying...${NC}"
            
            # Clean crypto keys from all pods
            local pods
            pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
            
            for pod in $pods; do
                echo -e "${BLUE}   Cleaning crypto keys from pod: $pod${NC}"
                kubectl exec -n "$NAMESPACE" "$pod" -c openemr -- sh -c "find /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/methods/ -name '*six*' -type f -delete 2>/dev/null || true" 2>/dev/null || true
            done
            
            echo -e "${BLUE}   Waiting 30 seconds for pods to regenerate keys and stabilize...${NC}"
            sleep 30
        else
            # Final attempt failed
            echo -e "${RED}❌ All $VERIFICATION_MAX_ATTEMPTS verification attempts failed: Only $ready_count/$desired_count pods are ready${NC}" >&2
            return 1
        fi
        
        attempt=$((attempt + 1))
    done
    
    return 1
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    echo -e "${BLUE}🔄 OpenEMR Restore Script - Streamlined Process${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "This script performs a complete restore of OpenEMR from backup:"
    echo ""
    echo "1. 🔄 Restore Database    - Creates database from snapshot (if needed)"
    echo "2. 🧹 Clean Deployment    - Removes existing resources and database"
    echo "3. 🚀 Deploy OpenEMR      - Fresh install (creates proper config files)"
    echo "4. 📁 Restore Data        - Extracts backup files + updates configuration"
    echo ""
    echo "The script automatically detects if the database exists and adjusts the order accordingly."
    echo "OpenEMR automatically starts working once database and config are ready."
    echo ""
        
    # Parse and validate arguments
    parse_arguments "$@"
    
    # Detect AWS region from Terraform state if not explicitly set via --region
    get_aws_region
    
    validate_arguments

    # Auto-detect cluster name and ensure kubeconfig
    auto_detect_cluster_name
    ensure_kubeconfig

    # Run pre-flight validation
    pre_flight_validation

    # Execute restore steps
    # Step 1: Clean deployment - removes existing OpenEMR resources and database
    # Step 2: Deploy OpenEMR - fresh install (pods fail initially due to missing database, but create proper config files)
    # Step 3: Restore RDS cluster - creates new database from snapshot
    # Step 4: Restore application data - downloads/extracts backup files + updates config for new DB endpoint
    #         OpenEMR pods automatically recover and start working once database and config are ready
    
    # Build steps array based on whether early database restore is needed
    local steps=()
    
    # Add early database restore if needed
    if [ "$EARLY_DB_RESTORE_NEEDED" = true ]; then
        steps+=("restore_rds_cluster_from_snapshot:🔄 STEP 1: Restoring Database from Snapshot (Early)")
        steps+=("run_clean_deployment:🧹 STEP 2: Running Clean Deployment")
        steps+=("deploy_openemr:🚀 STEP 3: Deploying OpenEMR (Fresh Install)")
        steps+=("restore_rds_cluster_from_snapshot:🔄 STEP 4: Restoring Database from Snapshot")
        steps+=("restore_application_data:📁 STEP 5: Restoring Application Data & Updating Configuration")
    else
        steps+=("run_clean_deployment:🧹 STEP 1: Running Clean Deployment")
        steps+=("deploy_openemr:🚀 STEP 2: Deploying OpenEMR (Fresh Install)")
        steps+=("restore_rds_cluster_from_snapshot:🔄 STEP 3: Restoring RDS Cluster from Snapshot")
        steps+=("restore_application_data:📁 STEP 4: Restoring Application Data & Updating Configuration")
    fi
    
    for step_info in "${steps[@]}"; do
        local step_function="${step_info%%:*}"
        local step_title="${step_info##*:}"
        
        echo -e "${BLUE}$step_title${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        if ! "$step_function"; then
            echo -e "${RED}❌ Failed: $step_title${NC}" >&2
                    exit 1
                fi
        
        echo -e "${GREEN}✅ $step_title completed successfully${NC}"
        echo ""
    done
    
    # Clean up crypto key cache files after restore
    echo -e "${BLUE}🔑 Crypto Key Cleanup${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if ! cleanup_crypto_keys; then
        echo -e "${YELLOW}⚠️  Crypto key cleanup had issues, but continuing...${NC}"
    fi
    echo ""
    
    # Final verification
    echo -e "${BLUE}🔍 Final Verification${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if ! verify_restore_success; then
        echo -e "${RED}❌ Restore verification failed${NC}" >&2
        exit 1
    fi
    
    # Clean up pod spec file only if entire restore process succeeded
    if [ -n "$POD_SPEC_FILE" ] && [ -f "$POD_SPEC_FILE" ]; then
        echo -e "${YELLOW}ℹ️  Cleaning up pod spec file...${NC}"
        rm -f "$POD_SPEC_FILE"
    fi
    
    echo -e "${GREEN}🎉 OpenEMR has been restored from backup!${NC}"
}

# Execute main function
main "$@"
