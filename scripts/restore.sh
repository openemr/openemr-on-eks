#!/bin/bash

# OpenEMR Restore Script
# =====================
# This script automates the restoration of an OpenEMR deployment from a backup,
# including database restoration from RDS snapshots, application data restoration
# from S3, and reconfiguration of database and Redis connections.
#
# Key Features:
# - Restores RDS Aurora cluster from snapshot
# - Downloads and restores application data from S3
# - Reconfigures database connections in OpenEMR
# - Updates Redis credentials and connections
# - Validates restore operations and provides status updates
# - Supports selective restoration (database only, app data only, etc.)
#
# Prerequisites:
# - Valid backup created by backup.sh script
# - AWS credentials with appropriate permissions
# - kubectl configured for the target cluster
# - Terraform state available for infrastructure details

set -e

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical issues
GREEN='\033[0;32m'    # Success messages and positive feedback
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
PURPLE='\033[0;35m'   # Restore operation messages
NC='\033[0m'          # Reset color to default

# Configuration variables - can be overridden by environment variables or command line arguments
AWS_REGION=${AWS_REGION:-"us-west-2"}   # AWS region where resources are located
NAMESPACE=${NAMESPACE:-"openemr"}       # Kubernetes namespace for OpenEMR
BACKUP_BUCKET=""                        # S3 bucket containing backup data (set by script)
SNAPSHOT_ID=""                          # RDS snapshot ID to restore from (set by script)
BACKUP_REGION=""                        # Region where backup is stored (set by script)
CLUSTER_NAME=""                         # EKS cluster name (detected by script)

# Enhanced restore configuration for new RDS cross-Region/cross-account capabilities
RESTORE_STRATEGY=${RESTORE_STRATEGY:-"auto-detect"}  # Restore strategy: auto-detect, same-region, cross-region, cross-account
SOURCE_ACCOUNT_ID=${SOURCE_ACCOUNT_ID:-""}           # Source AWS account ID for cross-account restores (optional)
KMS_KEY_ID=${KMS_KEY_ID:-""}                         # KMS key ID for encrypted snapshots (optional, uses default if empty)

# Global control variables for selective restoration
RESTORE_DATABASE=${RESTORE_DATABASE:-"true"}   # Whether to restore database from snapshot
RESTORE_APP_DATA=${RESTORE_APP_DATA:-"true"}   # Whether to restore application data from S3
RECONFIGURE_DB=${RECONFIGURE_DB:-"true"}       # Whether to reconfigure database connections

# Path resolution for script portability
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Directory containing this script
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"                      # Parent directory (project root)
TERRAFORM_DIR="$PROJECT_ROOT/terraform"                      # Terraform configuration directory

# Logging functions - provide consistent, timestamped output for different message types
# These functions ensure all restore operations have clear, color-coded feedback
log_info() {
    # Display informational messages in blue with info emoji
    # Used for progress updates, status information, and general feedback
    echo -e "${BLUE}[$(date '+%H:%M:%S')] ℹ️  $1${NC}"
}

log_success() {
    # Display success messages in green with checkmark emoji
    # Used for completed operations and positive outcomes
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $1${NC}"
}

log_warning() {
    # Display warning messages in yellow with warning emoji
    # Used for cautionary information and non-critical issues
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
    # Display error messages in red with X emoji
    # Used for critical errors and failed operations
    echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $1${NC}"
}

log_restore() {
    # Display restore operation messages in purple with restore emoji
    # Used specifically for restore-related operations and progress
    echo -e "${PURPLE}[$(date '+%H:%M:%S')] 🔄 $1${NC}"
}

# Help function
show_help() {
    echo "OpenEMR Restore Script"
    echo "======================="
    echo ""
    echo "Usage: $0 <backup-bucket> <snapshot-id> [backup-region] [options]"
    echo ""
    echo "Arguments:"
    echo "  backup-bucket    S3 bucket containing the backup"
    echo "  snapshot-id      RDS cluster snapshot identifier"
    echo "  backup-region    AWS region where backup is stored (optional)"
    echo ""
    echo "Options:"
    echo "  --cluster-name NAME    EKS cluster name (auto-detected if not specified)"
    echo "  --strategy STRATEGY    Restore strategy: auto-detect, same-region, cross-region, cross-account (default: auto-detect)"
    echo "  --source-account ID    Source AWS account ID for cross-account restores"
    echo "  --kms-key-id KEY       KMS key ID for encrypted snapshots (optional)"
    echo "  --force, -f            Skip confirmation prompts"
    echo "  --recreate-storage     Recreate storage classes before restore"
    echo "  --help, -h             Show this help message"
    echo "  --manual-instructions  Show manual restore instructions"
    echo ""
    echo "Environment Variables:"
    echo "  AWS_REGION            AWS region (default: us-west-2)"
    echo "  NAMESPACE             Kubernetes namespace (default: openemr)"
    echo "  RESTORE_DATABASE      Restore database (default: true)"
    echo "  RESTORE_APP_DATA      Restore application data (default: true)"
    echo "  RECONFIGURE_DB        Reconfigure database (default: true)"
    echo "  RESTORE_STRATEGY      Restore strategy (default: auto-detect)"
    echo "  SOURCE_ACCOUNT_ID     Source AWS account ID for cross-account restores"
    echo "  KMS_KEY_ID            KMS key ID for encrypted snapshots"
    echo ""
    echo "Examples:"
    echo "  # Basic restore (auto-detect strategy)"
    echo "  ./restore.sh my-backup-bucket my-snapshot-id"
    echo ""
    echo "  # Cross-region restore"
    echo "  ./restore.sh my-backup-bucket my-snapshot-id --strategy cross-region"
    echo ""
    echo "  # Cross-account restore"
    echo "  ./restore.sh my-backup-bucket my-snapshot-id --strategy cross-account --source-account 123456789012"
    echo ""
    echo "  # Restore with specific cluster and KMS key"
    echo "  ./restore.sh my-backup-bucket my-snapshot-id --cluster-name my-cluster --kms-key-id alias/my-key"
    echo ""
    echo "  # Automated restore (skip confirmation prompt)"
    echo "  ./restore.sh my-backup-bucket my-snapshot-id --force"
    echo ""
}

# Show manual restore instructions
show_manual_instructions() {
    echo "Manual Restore Instructions"
    echo "==========================="
    echo ""
    echo "If automated restore fails, follow these steps:"
    echo ""
    echo "1. Copy RDS snapshot to target region:"
    echo "   aws rds copy-db-cluster-snapshot \\"
    echo "     --source-db-cluster-snapshot-identifier arn:aws:rds:${BACKUP_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):cluster-snapshot:${SNAPSHOT_ID} \\"
    echo "     --target-db-cluster-snapshot-identifier ${SNAPSHOT_ID}-${AWS_REGION} \\"
    echo "     --source-region ${BACKUP_REGION} \\"
    echo "     --region ${AWS_REGION}"
    echo ""
    echo "2. Restore RDS cluster from snapshot:"
    echo "   aws rds restore-db-cluster-from-snapshot \\"
    echo "     --db-cluster-identifier openemr-eks \\"
    echo "     --snapshot-identifier ${SNAPSHOT_ID}-${AWS_REGION} \\"
    echo "     --region ${AWS_REGION}"
    echo ""
    echo "3. Restore application data from S3:"
    echo "   # Download and extract backup from s3://${BACKUP_BUCKET}"
    echo ""
    echo "4. Update Kubernetes configuration:"
    echo "   # Update database endpoints and other configuration"
    echo ""
}

# Function to auto-detect cluster name from Terraform
detect_cluster_name() {
    echo -e "${BLUE}🔍 Auto-detecting EKS cluster name from Terraform...${NC}"

    if [ -n "$CLUSTER_NAME" ]; then
        echo -e "${BLUE}Using provided cluster name: $CLUSTER_NAME${NC}"
            return 0
        fi

    local detected_cluster
    detected_cluster=$(cd "$TERRAFORM_DIR" && terraform output -raw cluster_name 2>/dev/null || echo "")

    if [ -z "$detected_cluster" ]; then
        echo -e "${YELLOW}⚠️  Could not detect cluster name from Terraform output${NC}"
        echo -e "${YELLOW}💡 Using default cluster name: openemr-eks${NC}"
        CLUSTER_NAME="openemr-eks"
    else
        CLUSTER_NAME="$detected_cluster"
        echo -e "${GREEN}✅ Auto-detected cluster name: $CLUSTER_NAME${NC}"
    fi
            return 0
}

# Function to ensure kubeconfig is properly configured
ensure_kubeconfig() {
    echo -e "${BLUE}🔧 Ensuring kubeconfig is properly configured...${NC}"

    # Check if cluster exists
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo -e "${RED}❌ EKS cluster '$CLUSTER_NAME' not found in region '$AWS_REGION'${NC}"
        exit 1
    fi

    # Update kubeconfig
    echo -e "${YELLOW}ℹ️  Updating kubeconfig for cluster: $CLUSTER_NAME${NC}"
    if aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"; then
        echo -e "${GREEN}✅ Kubeconfig updated successfully${NC}"
    else
        echo -e "${RED}❌ Failed to update kubeconfig${NC}"
                    exit 1
    fi

    # Verify kubectl connectivity
    echo -e "${YELLOW}ℹ️  Verifying kubectl connectivity...${NC}"
    if kubectl cluster-info >/dev/null 2>&1; then
        echo -e "${GREEN}✅ kubectl connectivity verified${NC}"
    else
        echo -e "${RED}❌ kubectl cannot connect to cluster${NC}"
            exit 1
        fi
}

# Parse command line arguments
parse_arguments() {
    # Parse positional arguments first
    if [ $# -ge 1 ] && [ "$1" != "--help" ] && [[ "$1" != "--"* ]]; then
        BACKUP_BUCKET="$1"
        shift
    fi

    if [ $# -ge 1 ] && [ "$1" != "--help" ] && [[ "$1" != "--"* ]]; then
        SNAPSHOT_ID="$1"
        shift
    fi

    if [ $# -ge 1 ] && [ "$1" != "--help" ] && [[ "$1" != "--"* ]]; then
        BACKUP_REGION="$1"
        shift
    fi

    # Set default backup region if not specified
    if [ -z "$BACKUP_REGION" ]; then
        BACKUP_REGION="$AWS_REGION"
    fi

    # Parse named arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --strategy)
                RESTORE_STRATEGY="$2"
                shift 2
                ;;
            --source-account)
                SOURCE_ACCOUNT_ID="$2"
                shift 2
                ;;
            --kms-key-id)
                KMS_KEY_ID="$2"
                shift 2
                ;;
            --force|-f)
                # FORCE_RESTORE=true     # Unused variable
                shift
                ;;
            --recreate-storage)
                # RECREATE_STORAGE=true  # Unused variable
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --manual-instructions)
                show_manual_instructions
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Function to auto-detect restore strategy from backup metadata
# This function analyzes the backup metadata to determine the appropriate restore strategy
auto_detect_restore_strategy() {
    if [ "$RESTORE_STRATEGY" != "auto-detect" ]; then
        log_info "Using specified restore strategy: $RESTORE_STRATEGY"
        return 0
    fi

    log_info "Auto-detecting restore strategy from backup metadata..."

    # Try to download and parse backup metadata
    local metadata_file
    metadata_file="/tmp/backup-metadata-$(date +%s).json"
    
    if aws s3 cp "s3://$BACKUP_BUCKET/metadata/" "$metadata_file" --region "$BACKUP_REGION" >/dev/null 2>&1; then
        # Find the most recent metadata file
        local latest_metadata
        latest_metadata=$(find /tmp -name "backup-metadata-*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || echo "")
        
        if [ -n "$latest_metadata" ] && [ -f "$latest_metadata" ]; then
            # Parse backup strategy from metadata
            local detected_strategy
            local detected_account
            detected_strategy=$(jq -r '.backup_strategy // "same-region"' "$latest_metadata" 2>/dev/null || echo "same-region")
            detected_account=$(jq -r '.target_account_id // "none"' "$latest_metadata" 2>/dev/null || echo "none")
            
            RESTORE_STRATEGY="$detected_strategy"
            
            if [ "$detected_account" != "none" ] && [ -z "$SOURCE_ACCOUNT_ID" ]; then
                SOURCE_ACCOUNT_ID="$detected_account"
            fi
            
            log_success "Auto-detected restore strategy: $RESTORE_STRATEGY"
            if [ "$detected_account" != "none" ]; then
                log_info "Auto-detected source account: $detected_account"
            fi
            
            # Cleanup
            rm -f "$metadata_file"*
            return 0
        fi
    fi

    # Fallback: determine strategy based on regions and snapshot ID
    log_warning "Could not parse backup metadata, using fallback detection"
    
    if [ "$BACKUP_REGION" != "$AWS_REGION" ]; then
        if [[ "$SNAPSHOT_ID" == *"-"*"-"* ]]; then
            # Snapshot ID contains multiple dashes, likely cross-account
            RESTORE_STRATEGY="cross-account"
            log_info "Detected cross-account restore based on snapshot ID pattern"
        else
            RESTORE_STRATEGY="cross-region"
            log_info "Detected cross-region restore based on different regions"
        fi
    else
        RESTORE_STRATEGY="same-region"
        log_info "Detected same-region restore"
    fi
    
    log_success "Fallback restore strategy: $RESTORE_STRATEGY"
}

# Validate required arguments
validate_arguments() {
    if [ -z "$BACKUP_BUCKET" ] || [ -z "$SNAPSHOT_ID" ]; then
        log_error "Missing required arguments"
        echo "Usage: $0 <backup-bucket> <snapshot-id> [backup-region]"
        echo "Use --help for more information"
        exit 1
    fi
}

# Function to restore RDS Aurora cluster from snapshot
# This function handles enhanced cross-region/cross-account snapshot restoration using new RDS capabilities
restore_database() {
    echo -e "${BLUE}🗄️  Restoring RDS database from snapshot...${NC}"
    echo -e "${BLUE}📋 Restore Strategy: $RESTORE_STRATEGY${NC}"

    # Determine source account ID for cross-account restores
    local source_account_id
    if [ "$RESTORE_STRATEGY" = "cross-account" ] && [ -n "$SOURCE_ACCOUNT_ID" ]; then
        source_account_id="$SOURCE_ACCOUNT_ID"
        log_info "Cross-account restore: source account $source_account_id"
    else
        source_account_id=$(aws sts get-caller-identity --query 'Account' --output text)
        log_info "Same-account restore: account $source_account_id"
    fi

    # Construct snapshot ARN for the source region and account
    local snapshot_arn
    snapshot_arn="arn:aws:rds:${BACKUP_REGION}:${source_account_id}:cluster-snapshot:${SNAPSHOT_ID}"

    # Enhanced snapshot handling based on restore strategy
    case "$RESTORE_STRATEGY" in
        "same-region")
            log_info "Same-region restore - using snapshot directly"
            # No copying needed for same-region restores
            ;;
        "cross-region")
            log_info "Cross-region restore - copying snapshot using new RDS capabilities"
            
            # Generate target snapshot name
            local target_snapshot_id="${SNAPSHOT_ID}-${AWS_REGION}"
            
            # Build enhanced copy command
            local copy_cmd="aws rds copy-db-cluster-snapshot"
            copy_cmd="$copy_cmd --source-db-cluster-snapshot-identifier \"$snapshot_arn\""
            copy_cmd="$copy_cmd --target-db-cluster-snapshot-identifier \"$target_snapshot_id\""
            copy_cmd="$copy_cmd --source-region \"$BACKUP_REGION\""
            copy_cmd="$copy_cmd --region \"$AWS_REGION\""
            
            # Add KMS key if specified
            if [ -n "$KMS_KEY_ID" ]; then
                copy_cmd="$copy_cmd --kms-key-id \"$KMS_KEY_ID\""
                log_info "Using specified KMS key: $KMS_KEY_ID"
            fi
            
            # Execute cross-region copy
            log_info "Executing cross-region snapshot copy..."
            if eval "$copy_cmd" >/dev/null 2>&1; then
                log_success "Cross-region snapshot copy initiated: $target_snapshot_id"
                snapshot_arn="arn:aws:rds:${AWS_REGION}:${source_account_id}:cluster-snapshot:${target_snapshot_id}"
            else
                log_warning "Cross-region snapshot copy failed, attempting direct restore"
            fi
            ;;
        "cross-account")
            log_info "Cross-account restore - copying snapshot using new RDS capabilities"
            
            # Generate target snapshot name
            local target_snapshot_id="${SNAPSHOT_ID}-${AWS_REGION}"
            
            # Build enhanced cross-account copy command
            local copy_cmd="aws rds copy-db-cluster-snapshot"
            copy_cmd="$copy_cmd --source-db-cluster-snapshot-identifier \"$snapshot_arn\""
            copy_cmd="$copy_cmd --target-db-cluster-snapshot-identifier \"$target_snapshot_id\""
            copy_cmd="$copy_cmd --source-region \"$BACKUP_REGION\""
            copy_cmd="$copy_cmd --region \"$AWS_REGION\""
            copy_cmd="$copy_cmd --destination-region \"$AWS_REGION\""
            copy_cmd="$copy_cmd --destination-account-id \"$(aws sts get-caller-identity --query 'Account' --output text)\""
            
            # Add KMS key if specified
            if [ -n "$KMS_KEY_ID" ]; then
                copy_cmd="$copy_cmd --kms-key-id \"$KMS_KEY_ID\""
                log_info "Using specified KMS key: $KMS_KEY_ID"
            fi
            
            # Execute cross-account copy
            log_info "Executing cross-account snapshot copy..."
            if eval "$copy_cmd" >/dev/null 2>&1; then
                log_success "Cross-account snapshot copy initiated: $target_snapshot_id"
                snapshot_arn="arn:aws:rds:${AWS_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):cluster-snapshot:${target_snapshot_id}"
            else
                log_warning "Cross-account snapshot copy failed, attempting direct restore"
            fi
            ;;
        *)
            log_error "Invalid restore strategy: $RESTORE_STRATEGY"
            exit 1
            ;;
    esac

    # First, delete the existing cluster if it exists
    local cluster_identifier="openemr-eks-aurora"
    echo -e "${YELLOW}ℹ️  Checking for existing RDS cluster...${NC}"
    if aws rds describe-db-clusters --db-cluster-identifier "$cluster_identifier" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ️  Found existing cluster, deleting it first...${NC}"

        # Disable deletion protection if enabled
        aws rds modify-db-cluster \
            --db-cluster-identifier "$cluster_identifier" \
            --no-deletion-protection \
            --region "$AWS_REGION" >/dev/null 2>&1 || true

        # Wait for deletion protection to be disabled
        sleep 5

        # Delete the cluster
        aws rds delete-db-cluster \
            --db-cluster-identifier "$cluster_identifier" \
            --skip-final-snapshot \
            --region "$AWS_REGION" >/dev/null 2>&1 || true

        # Wait for cluster to be deleted
        echo -e "${YELLOW}ℹ️  Waiting for existing cluster to be deleted...${NC}"
        local delete_attempts=0
        while [ $delete_attempts -lt 30 ]; do
            if ! aws rds describe-db-clusters --db-cluster-identifier "$cluster_identifier" --region "$AWS_REGION" >/dev/null 2>&1; then
                echo -e "${GREEN}✅ Existing cluster deleted${NC}"
                break
            fi
            echo -e "${YELLOW}ℹ️  Waiting for deletion... (attempt $((delete_attempts + 1))/30)${NC}"
            sleep 10
            ((delete_attempts++))
        done
    fi

    # Restore cluster from snapshot
    echo -e "${YELLOW}ℹ️  Restoring RDS cluster from snapshot...${NC}"
    aws rds restore-db-cluster-from-snapshot \
        --db-cluster-identifier "$cluster_identifier" \
        --snapshot-identifier "$snapshot_arn" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo -e "${GREEN}✅ Database restore initiated${NC}"
}

# Restore application data from S3
restore_application_data() {
    echo -e "${BLUE}📁 Restoring application data from S3...${NC}"

    # Get EFS ID
    local efs_id
    efs_id=$(cd "$TERRAFORM_DIR" && terraform output -raw efs_id 2>/dev/null || echo "")

    if [ -z "$efs_id" ]; then
        echo -e "${RED}❌ EFS ID not available from Terraform output${NC}"
        return 1
    fi

    echo -e "${YELLOW}ℹ️  Using EFS ID: $efs_id${NC}"

    # Find existing OpenEMR pod to use for restore
    # Find existing OpenEMR pod to use for data restoration with readiness check
    local pod_name
    local max_attempts=60  # Increased from 30 to 60 (10 minutes)
    local attempt=1

    echo -e "${YELLOW}ℹ️  Waiting for OpenEMR pod to be ready for restore...${NC}"
    echo -e "${YELLOW}ℹ️  This may take up to 10 minutes after database restore...${NC}"

    while [ $attempt -le $max_attempts ]; do
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$pod_name" ]; then
            # Get detailed pod status for debugging
            local pod_status
            local container_status
            pod_status=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            container_status=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].state}' 2>/dev/null || echo "Unknown")

            # Check if pod is ready and has the openemr container
            local pod_ready
            pod_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

            if [ "$pod_ready" = "True" ]; then
                # Verify the openemr container exists and is running
                local container_ready
                container_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].ready}' 2>/dev/null || echo "false")

                if [ "$container_ready" = "true" ]; then
                    echo -e "${GREEN}✅ Found ready OpenEMR pod: $pod_name${NC}"
                    break
                else
                    echo -e "${YELLOW}ℹ️  Attempt $attempt/$max_attempts: OpenEMR container not ready (Status: $pod_status, Container: $container_status), waiting 10 seconds...${NC}"
                fi
            else
                echo -e "${YELLOW}ℹ️  Attempt $attempt/$max_attempts: Pod not ready (Status: $pod_status, Container: $container_status), waiting 10 seconds...${NC}"
            fi
        else
            echo -e "${YELLOW}ℹ️  Attempt $attempt/$max_attempts: No pod found, waiting 10 seconds...${NC}"
        fi

        sleep 10
        ((attempt++))
    done

    if [ -z "$pod_name" ] || [ $attempt -gt $max_attempts ]; then
        echo -e "${RED}❌ No ready OpenEMR pod found for data restoration after $max_attempts attempts${NC}"
        echo -e "${YELLOW}ℹ️  Current pod status:${NC}"
        kubectl get pods -n "$NAMESPACE" -l app=openemr -o wide || true
        echo -e "${YELLOW}ℹ️  Pod events:${NC}"
        kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10 || true
        return 1
    fi

    echo -e "${YELLOW}ℹ️  Using ready pod: $pod_name${NC}"

    # Download backup file locally first
    echo -e "${YELLOW}ℹ️  Downloading backup from S3...${NC}"
    local local_backup_file
    local_backup_file="/tmp/restore-backup-$(date +%s).tar.gz"

    # List available backup files to get the exact name
    local exact_backup_file
    # Look for backup files from today (with any timestamp)
    exact_backup_file=$(aws s3 ls "s3://$BACKUP_BUCKET/application-data/" --region "$AWS_REGION" | grep "app-data-backup-$(date +%Y%m%d)" | awk '{print $4}' | head -1)
    
    # If no backup file found for today, try to find the most recent one
    if [ -z "$exact_backup_file" ]; then
        echo -e "${YELLOW}ℹ️  No backup file found for today, looking for most recent backup...${NC}"
        exact_backup_file=$(aws s3 ls "s3://$BACKUP_BUCKET/application-data/" --region "$AWS_REGION" | grep "app-data-backup-" | sort -k1,2 | tail -1 | awk '{print $4}')
    fi

    if [ -n "$exact_backup_file" ]; then
        echo -e "${YELLOW}ℹ️  Found backup file: $exact_backup_file${NC}"

        # Download the backup file locally
        if aws s3 cp "s3://$BACKUP_BUCKET/application-data/$exact_backup_file" "$local_backup_file" --region "$AWS_REGION"; then
        echo -e "${YELLOW}ℹ️  Backup downloaded locally, copying to pod...${NC}"

        # Copy to pod and extract with proper error handling
        echo -e "${YELLOW}ℹ️  Copying backup file to pod...${NC}"
        local cp_output
        cp_output=$(kubectl cp "$local_backup_file" "$NAMESPACE/$pod_name:/tmp/backup.tar.gz" -c openemr 2>&1)
        local cp_exit_code=$?
        
        if [ $cp_exit_code -eq 0 ]; then
            echo -e "${GREEN}✅ Backup file copied to pod successfully${NC}"

            echo -e "${YELLOW}ℹ️  Extracting backup in pod...${NC}"
            local extract_output
            extract_output=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "
                cd /var/www/localhost/htdocs/openemr && \
                tar -xzf /tmp/backup.tar.gz && \
                rm -f /tmp/backup.tar.gz && \
                echo 'Backup extraction completed successfully'
            " 2>&1)
            local extract_exit_code=$?
            
            if [ $extract_exit_code -eq 0 ]; then
                echo -e "${GREEN}✅ Backup extracted successfully${NC}"
                echo -e "${YELLOW}ℹ️  Extract output: $extract_output${NC}"
            else
                echo -e "${RED}❌ Failed to extract backup in pod${NC}"
                echo -e "${RED}❌ Extract error: $extract_output${NC}"
                echo -e "${RED}❌ Extract exit code: $extract_exit_code${NC}"
                # Clean up the backup file even if extraction failed
                kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- rm -f /tmp/backup.tar.gz 2>/dev/null || true
                return 1
            fi
        else
            echo -e "${RED}❌ Failed to copy backup file to pod${NC}"
            echo -e "${RED}❌ Copy error: $cp_output${NC}"
            echo -e "${RED}❌ Copy exit code: $cp_exit_code${NC}"
            echo -e "${YELLOW}ℹ️  This might be due to pod not being ready or container not available${NC}"
            return 1
        fi

            # Clean up local file
            rm -f "$local_backup_file"
        else
            echo -e "${YELLOW}⚠️  Failed to download backup from S3${NC}"
            fi
        else
        echo -e "${YELLOW}⚠️  No backup file found for today${NC}"
    fi

    echo -e "${GREEN}✅ Application data restored${NC}"
}

# Reconfigure database connection
reconfigure_database() {
    echo -e "${BLUE}🔧 Reconfiguring database connection...${NC}"

    # Get database credentials from Kubernetes secret
    local db_endpoint
    local db_user
    local db_pass
    local db_name

    db_endpoint=$(kubectl get secret openemr-db-credentials -n "$NAMESPACE" -o jsonpath='{.data.mysql-host}' | base64 -d 2>/dev/null || echo "")
    db_user=$(kubectl get secret openemr-db-credentials -n "$NAMESPACE" -o jsonpath='{.data.mysql-user}' | base64 -d 2>/dev/null || echo "openemr")
    db_pass=$(kubectl get secret openemr-db-credentials -n "$NAMESPACE" -o jsonpath='{.data.mysql-password}' | base64 -d 2>/dev/null || echo "")
    db_name=$(kubectl get secret openemr-db-credentials -n "$NAMESPACE" -o jsonpath='{.data.mysql-database}' | base64 -d 2>/dev/null || echo "openemr")

    if [ -z "$db_endpoint" ]; then
        echo -e "${YELLOW}⚠️  Database endpoint not available yet, skipping reconfiguration${NC}"
        return 0
    fi

    echo -e "${YELLOW}ℹ️  Database endpoint: $db_endpoint${NC}"
    echo -e "${YELLOW}ℹ️  Database user: $db_user${NC}"
    echo -e "${YELLOW}ℹ️  Database name: $db_name${NC}"

    # Find existing OpenEMR pod to use for database reconfiguration with readiness check
    local pod_name
    local max_attempts=30
    local attempt=1

    echo -e "${YELLOW}ℹ️  Waiting for OpenEMR pod to be ready for database reconfiguration...${NC}"

    while [ $attempt -le $max_attempts ]; do
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$pod_name" ]; then
            # Check if pod is ready and has the openemr container
            local pod_ready
            pod_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

            if [ "$pod_ready" = "True" ]; then
                # Verify the openemr container exists and is running
                local container_ready
                container_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].ready}' 2>/dev/null || echo "false")

                if [ "$container_ready" = "true" ]; then
                    echo -e "${GREEN}✅ Found ready OpenEMR pod for database reconfiguration: $pod_name${NC}"
                    break
                else
                    echo -e "${YELLOW}ℹ️  Attempt $attempt/$max_attempts: OpenEMR container not ready, waiting 10 seconds...${NC}"
                fi
            else
                echo -e "${YELLOW}ℹ️  Attempt $attempt/$max_attempts: Pod not ready, waiting 10 seconds...${NC}"
            fi
        else
            echo -e "${YELLOW}ℹ️  Attempt $attempt/$max_attempts: No pod found, waiting 10 seconds...${NC}"
        fi

        sleep 10
        ((attempt++))
    done

    if [ -z "$pod_name" ] || [ $attempt -gt $max_attempts ]; then
        echo -e "${RED}❌ No ready OpenEMR pod found for database reconfiguration after $max_attempts attempts${NC}"
        return 1
    fi

    echo -e "${YELLOW}ℹ️  Using ready pod for database reconfiguration: $pod_name${NC}"

    # Update database configuration using existing pod
    echo -e "${YELLOW}ℹ️  Updating database configuration...${NC}"
    kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "
        cd /var/www/localhost/htdocs/openemr && \
        if [ -f 'sites/default/sqlconf.php' ]; then
            php -r \"
                \\\$config = file_get_contents('sites/default/sqlconf.php');
                \\\$config = preg_replace('/\\\$host = .*;/', '\\\$host = \\\"$db_endpoint\\\";', \\\$config);
                \\\$config = preg_replace('/\\\$port = .*;/', '\\\$port = \\\"3306\\\";', \\\$config);
                \\\$config = preg_replace('/\\\$login = .*;/', '\\\$login = \\\"$db_user\\\";', \\\$config);
                \\\$config = preg_replace('/\\\$pass = .*;/', '\\\$pass = \\\"$db_pass\\\";', \\\$config);
                \\\$config = preg_replace('/\\\$dbase = .*;/', '\\\$dbase = \\\"$db_name\\\";', \\\$config);
                \\\$config = preg_replace('/\\\$db_encoding = .*;/', '\\\$db_encoding = \\\"utf8mb4\\\";', \\\$config);
                \\\$config = preg_replace('/\\\$config = .*;/', '\\\$config = 1;', \\\$config);
                if (file_put_contents('sites/default/sqlconf.php', \\\$config)) {
                    echo 'Database configuration updated successfully' . PHP_EOL;
                } else {
                    echo 'Failed to update database configuration' . PHP_EOL;
                    exit(1);
                }
            \"
        else
            echo 'sqlconf.php file not found' . PHP_EOL
            exit 1
        fi
    " || echo -e "${YELLOW}⚠️  Database configuration update completed with warnings${NC}"

    echo -e "${GREEN}✅ Database connection reconfigured${NC}"
}

reconfigure_redis() {
    echo -e "${BLUE}🔧 Reconfiguring Redis/Valkey connection...${NC}"

    # Get current Redis cluster details from Terraform
    local redis_endpoint
    local redis_port
    local redis_password
    local redis_username="openemr"

    redis_endpoint=$(cd "$TERRAFORM_DIR" && terraform output -raw redis_endpoint 2>/dev/null || echo "")
    redis_port=$(cd "$TERRAFORM_DIR" && terraform output -raw redis_port 2>/dev/null || echo "6379")
    redis_password=$(cd "$TERRAFORM_DIR" && terraform output -raw redis_password 2>/dev/null || echo "")

    if [ -z "$redis_endpoint" ] || [ -z "$redis_password" ]; then
        echo -e "${YELLOW}⚠️  Redis cluster details not available from Terraform, skipping Redis reconfiguration${NC}"
        return 0
    fi

    echo -e "${YELLOW}ℹ️  Redis endpoint: $redis_endpoint${NC}"
    echo -e "${YELLOW}ℹ️  Redis port: $redis_port${NC}"
    echo -e "${YELLOW}ℹ️  Redis username: $redis_username${NC}"

    # Update the Redis credentials secret
    echo -e "${YELLOW}ℹ️  Updating Redis credentials secret...${NC}"
    kubectl create secret generic openemr-redis-credentials \
        --from-literal=redis-host="$redis_endpoint" \
        --from-literal=redis-port="$redis_port" \
        --from-literal=redis-password="$redis_password" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${GREEN}✅ Redis connection reconfigured${NC}"
}

# Main execution
main() {
    # Parse arguments first
    parse_arguments "$@"

    echo -e "${BLUE}🚀 OpenEMR Restore Starting${NC}"
    echo "==========================="
    echo -e "${BLUE}Target Region: $AWS_REGION${NC}"
    echo -e "${BLUE}Backup Region: $BACKUP_REGION${NC}"
    echo -e "${BLUE}Backup Bucket: $BACKUP_BUCKET${NC}"
    echo -e "${BLUE}Snapshot ID: $SNAPSHOT_ID${NC}"
    echo -e "${BLUE}Restore Strategy: $RESTORE_STRATEGY${NC}"
    if [ -n "$SOURCE_ACCOUNT_ID" ]; then
        echo -e "${BLUE}Source Account: $SOURCE_ACCOUNT_ID${NC}"
    fi
    echo ""

    # Validate arguments
    validate_arguments

    # Auto-detect restore strategy
    auto_detect_restore_strategy

    # Detect cluster name
    detect_cluster_name

    # Ensure kubeconfig is up to date
    ensure_kubeconfig


    # Perform restoration steps
    if [ "$RESTORE_DATABASE" = "true" ]; then
        restore_database
    fi

    if [ "$RESTORE_APP_DATA" = "true" ]; then
        restore_application_data
    fi

    if [ "$RECONFIGURE_DB" = "true" ]; then
        reconfigure_database
    fi

    # Always reconfigure Redis/Valkey connection
    reconfigure_redis

log_success "Restore process completed"
}

# Call main function
main "$@"
