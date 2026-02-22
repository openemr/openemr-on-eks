#!/bin/bash

# =============================================================================
# AWS Infrastructure Cleanup Script 
# =============================================================================
#
# Purpose:
#   Handles AWS-level cleanup issues that prevent terraform destroy from
#   working properly. Intelligently manages RDS deletion protection with
#   enhanced retry logic, pre-destroy verification, handles S3 bucket
#   versioning, and cleans orphaned resources with improved reliability.
#
# Key Features:
#   - ✅ Enhanced RDS deletion protection disabling (30s propagation wait)
#   - ✅ Pre-destroy verification (ensures Terraform can see RDS as deletable)
#   - ✅ Terraform destroy retry logic (3 attempts with 30s between each)
#   - ✅ Intelligent state management (preserved on failure, deleted on success)
#   - ✅ RDS snapshot cleanup to prevent automatic restoration
#   - ✅ S3 bucket versioning issues handling (delete markers, versions)
#   - ✅ Orphaned AWS resource cleanup
#   - ✅ Comprehensive verification and reporting
#   - ✅ AWS API propagation handling (accounts for eventual consistency)
#
# Robustness Improvements (v2.0):
#   - Extended propagation wait time: 15s → 30s (covers AWS API + Terraform)
#   - Added pre-destroy verification with terraform plan -destroy
#   - Implemented 3-attempt retry logic for terraform destroy
#   - State files now preserved on failure for debugging and retry
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - Terraform installed and initialized
#   - Sufficient permissions for RDS, S3, EKS, and VPC operations
#
# Usage:
#   ./destroy.sh [OPTIONS]
#
# Options:
#   --force    Skip confirmation prompts and use force mode
#   --help     Show this help message
#
# Environment Variables:
#   PRESERVE_BACKUP_SNAPSHOTS   Set to "true" to preserve RDS backup snapshots
#                               during cleanup (useful for backup/restore testing)
#                               Default: false
#   BACKUP_JOB_WAIT_TIMEOUT     Maximum seconds to wait for active backup jobs
#                               to complete before attempting vault deletion.
#                               Some resource types (like Aurora) cannot be stopped.
#                               Default: 180 (3 minutes)
#   BACKUP_JOB_POLL_INTERVAL    Seconds between checks for backup job completion.
#                               Default: 15
#
# Notes:
#   ⚠️  WARNING: This action completely destroys all AWS infrastructure and
#   cannot be undone! All resources including Terraform state, RDS clusters,
#   snapshots, and S3 buckets will be permanently deleted.
#
#   🔄 RETRY LOGIC: If terraform destroy fails, the script will:
#      - Preserve Terraform state files for debugging
#      - Allow manual retry without cleanup
#      - Automatically retry up to 3 times with 30s between attempts
#
#   Note: Kubernetes resources are automatically cleaned up when the EKS
#   cluster is destroyed by terraform destroy.
#
# Examples:
#   ./destroy.sh                # Interactive with confirmation prompts
#   ./destroy.sh --force        # Automated (CI/CD) with no prompts
#
# Related Documentation:
#   - ROBUSTNESS_IMPROVEMENTS.md - Full details of enhancements
#   - docs/TROUBLESHOOTING.md - Manual intervention guidance
#
# =============================================================================

set -euo pipefail

# Disable AWS CLI pager to prevent interactive editors from opening
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# =============================================================================
# CONFIGURATION
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
# K8S_DIR="$PROJECT_ROOT/k8s"  # Not used in this script

# Default values
FORCE=false
CLUSTER_NAME=""
AWS_REGION="us-west-2"

# Backup job handling configuration (some jobs like Aurora cannot be stopped)
BACKUP_JOB_WAIT_TIMEOUT="${BACKUP_JOB_WAIT_TIMEOUT:-180}"  # Max seconds to wait for backup jobs
BACKUP_JOB_POLL_INTERVAL="${BACKUP_JOB_POLL_INTERVAL:-15}" # Seconds between job status checks

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_step() {
    echo -e "\n${BLUE}🔄 $1${NC}"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check if required tools are available
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing_tools=()
    
    for tool in terraform aws jq; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again"
        exit 1
    fi
    
    # Verify AWS credentials with helpful error messages
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS credentials not configured or invalid"
        echo ""
        log_info "To configure AWS credentials, you can:"
        log_info "  1. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
        log_info "  2. Configure AWS CLI: aws configure"
        log_info "  3. Use AWS SSO: aws sso login"
        log_info "  4. Use IAM roles (if running on EC2/ECS/Lambda)"
        echo ""
        
        # Check if there's any Terraform state - if not, maybe credentials aren't needed
        if [ ! -f "$TERRAFORM_DIR/terraform.tfstate" ] && [ ! -f "$TERRAFORM_DIR/.terraform/terraform.tfstate" ]; then
            log_warning "No Terraform state found - there may be no infrastructure to destroy"
            log_info "If you're sure there's no infrastructure, you can skip this check"
            log_info "Otherwise, please configure AWS credentials and try again"
        else
            log_error "Terraform state exists - AWS credentials are required to destroy infrastructure"
        fi
        
        exit 1
    fi
    
    # Verify Terraform is initialized if state exists
    if [ -f "$TERRAFORM_DIR/terraform.tfstate" ] || [ -f "$TERRAFORM_DIR/.terraform/terraform.tfstate" ]; then
        cd "$TERRAFORM_DIR"
        if ! terraform validate &>/dev/null; then
            log_warning "Terraform configuration validation failed, but continuing..."
        fi
        cd - >/dev/null
    fi
    
    log_success "All required tools found and configured"
}

# Get AWS account ID with better error handling
get_aws_account_id() {
    local account_id
    local error_output
    
    # Try to get account ID and capture any errors
    account_id=$(aws sts get-caller-identity --query Account --output text 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        error_output=$(echo "$account_id" | grep -i "error\|invalid\|credentials" || echo "$account_id")
        log_error "Failed to get AWS account ID"
        log_error "Error: $error_output"
        echo ""
        log_info "Common causes:"
        log_info "  • AWS credentials not configured (run 'aws configure')"
        log_info "  • AWS credentials expired (run 'aws sso login' if using SSO)"
        log_info "  • Insufficient permissions (check IAM policies)"
        log_info "  • Wrong AWS region configured"
        echo ""
        exit 1
    fi
    
    echo "$account_id"
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
            log_info "Found AWS region from Terraform state: $AWS_REGION"
            return 0
        fi
    fi
    
    # Priority 2: If AWS_REGION is explicitly set via environment AND it's not the default, use it
    if [ -n "${AWS_REGION:-}" ] && [ "$AWS_REGION" != "us-west-2" ]; then
        # Validate it's a real region format (e.g., us-west-2, eu-west-1, ap-southeast-1)
        if [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            log_info "Using AWS region from environment: $AWS_REGION"
            return 0
        else
            log_warning "Invalid AWS_REGION format in environment: $AWS_REGION"
        fi
    fi
    
    # Priority 3: Fall back to default
    AWS_REGION="us-west-2"
    log_warning "Could not determine AWS region, using default: $AWS_REGION"
}

# Get cluster name from Terraform, fallback to default
get_cluster_name() {
    if [ -z "$CLUSTER_NAME" ]; then
        log_info "Getting cluster name from Terraform..."
        
        # Try to get cluster name from Terraform output
        if [ -f "$TERRAFORM_DIR/terraform.tfstate" ] || [ -f "$TERRAFORM_DIR/.terraform/terraform.tfstate" ]; then
            cd "$TERRAFORM_DIR"
            local terraform_cluster_name
            # Suppress terraform warnings and only capture the actual output
            terraform_cluster_name=$(terraform output -raw cluster_name 2>/dev/null | \
                grep -v "Warning:" | \
                grep -v "No outputs found" | \
                grep -v "^╷" | \
                grep -v "^│" | \
                grep -v "^╵" | \
                xargs || echo "")
            cd - >/dev/null
            
            # Validate cluster name is valid (not empty, not null, and doesn't contain terraform warning characters)
            if [ -n "$terraform_cluster_name" ] && \
               [ "$terraform_cluster_name" != "null" ] && \
               [ "$terraform_cluster_name" != "" ] && \
               [[ ! "$terraform_cluster_name" == *"Warning"* ]] && \
               [[ ! "$terraform_cluster_name" == *"No outputs found"* ]] && \
               [[ ! "$terraform_cluster_name" == *"╷"* ]] && \
               [[ ! "$terraform_cluster_name" == *"│"* ]]; then
                CLUSTER_NAME="$terraform_cluster_name"
                log_info "Found cluster name from Terraform: $CLUSTER_NAME"
            else
                CLUSTER_NAME="openemr-eks"
                log_info "Could not get cluster name from Terraform, using default: $CLUSTER_NAME"
            fi
        else
            CLUSTER_NAME="openemr-eks"
            log_info "No Terraform state found, using default cluster name: $CLUSTER_NAME"
        fi
    else
        log_info "Using provided cluster name: $CLUSTER_NAME"
    fi
}

# Execute AWS command with retry logic
aws_with_retry() {
    local max_attempts=3
    local delay=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                log_warning "AWS command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
                sleep $delay
                ((attempt += 1))
            else
                log_error "AWS command failed after $max_attempts attempts"
                return 1
            fi
        fi
    done
}

# Safe AWS command execution with error handling
safe_aws() {
    local description="$1"
    shift
    
    log_info "$description"
    if aws_with_retry "$@"; then
        return 0
    else
        log_warning "Failed to $description, but continuing..."
        return 1
    fi
}

# =============================================================================
# RDS CLEANUP
# =============================================================================

cleanup_rds_snapshots() {
    log_step "Cleaning up RDS snapshots..."
    
    # Check if we should preserve backup snapshots (for testing)
    local preserve_backups=${PRESERVE_BACKUP_SNAPSHOTS:-false}
    
    local snapshots
    snapshots=$(aws rds describe-db-cluster-snapshots \
        --region "$AWS_REGION" \
        --query "DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, '$CLUSTER_NAME') && Status=='available' && SnapshotType=='manual'].DBClusterSnapshotIdentifier" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$snapshots" ]; then
        local snapshot_count
        snapshot_count=$(echo "$snapshots" | wc -w)
        log_info "Found $snapshot_count snapshots"
        
        for snapshot_id in $snapshots; do
            # Clean up any whitespace around the snapshot ID
            snapshot_id=$(echo "$snapshot_id" | xargs)
            
            # Skip empty snapshot IDs
            if [ -z "$snapshot_id" ] || [ "$snapshot_id" = "" ]; then
                continue
            fi
            
            # Skip backup snapshots if preserve flag is set
            if [ "$preserve_backups" = "true" ] && [[ "$snapshot_id" == *"-backup-"* ]]; then
                log_info "Preserving backup snapshot: $snapshot_id"
                continue
            fi
            
            safe_aws "delete snapshot: $snapshot_id" \
                aws rds delete-db-cluster-snapshot \
                    --db-cluster-snapshot-identifier "$snapshot_id" \
                    --region "$AWS_REGION" \
                    --no-cli-pager
        done
        
        log_success "RDS snapshots cleaned up (backups preserved: $preserve_backups)"
    else
        log_info "No RDS snapshots found"
    fi
}

wait_for_rds_available() {
    local cluster_id="$1"
    local max_wait=600  # 10 minutes
    local elapsed=0
    local check_interval=10
    
    log_info "Waiting for cluster $cluster_id to be available..."
    
    while [ $elapsed -lt $max_wait ]; do
        local status
        status=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$cluster_id" \
            --region "$AWS_REGION" \
            --query "DBClusters[0].Status" \
            --output text 2>/dev/null || echo "not-found")
        
        if [ "$status" = "available" ]; then
            log_success "Cluster $cluster_id is available"
            return 0
        elif [ "$status" = "not-found" ]; then
            log_info "Cluster $cluster_id not found (may have been deleted)"
            return 0
        else
            log_info "Cluster status: $status (waiting...)"
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
        fi
    done
    
    log_warning "Timeout waiting for cluster $cluster_id to be available"
    return 1
}

verify_deletion_protection_disabled() {
    local cluster_id="$1"
    local max_attempts=30  # 5 minutes with 10 second intervals
    local attempt=1
    
    log_info "Verifying deletion protection is disabled for $cluster_id..."
    
    while [ $attempt -le $max_attempts ]; do
        local protection_status
        protection_status=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$cluster_id" \
            --region "$AWS_REGION" \
            --query "DBClusters[0].DeletionProtection" \
            --output text 2>/dev/null || echo "unknown")
        
        if [ "$protection_status" = "False" ] || [ "$protection_status" = "false" ]; then
            log_success "Deletion protection disabled for $cluster_id"
            return 0
        elif [ "$protection_status" = "unknown" ]; then
            log_info "Cluster $cluster_id not found (may have been deleted)"
            return 0
        else
            log_info "Deletion protection status: $protection_status (attempt $attempt/$max_attempts)"
            sleep 10
            ((attempt += 1))
        fi
    done
    
    log_warning "Could not verify deletion protection was disabled for $cluster_id"
    return 1
}

disable_rds_deletion_protection() {
    log_step "Disabling RDS deletion protection and automatic backups..."
    
    local clusters
    clusters=$(aws rds describe-db-clusters \
        --region "$AWS_REGION" \
        --query "DBClusters[?contains(DBClusterIdentifier, '$CLUSTER_NAME')].DBClusterIdentifier" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$clusters" ]; then
        for cluster_id in $clusters; do
            log_info "Processing cluster: $cluster_id"
            
            # Check current deletion protection status
            local current_protection
            current_protection=$(aws rds describe-db-clusters \
                --db-cluster-identifier "$cluster_id" \
                --region "$AWS_REGION" \
                --query "DBClusters[0].DeletionProtection" \
                --output text 2>/dev/null || echo "unknown")
            
            if [ "$current_protection" = "False" ] || [ "$current_protection" = "false" ]; then
                log_info "Deletion protection already disabled for $cluster_id"
                continue
            fi
            
            # Wait for cluster to be in available state before modifying
            if ! wait_for_rds_available "$cluster_id"; then
                log_warning "Cluster $cluster_id not available, attempting modification anyway..."
            fi
            
            # Attempt to disable deletion protection with retry logic
            local max_modify_attempts=5
            local modify_attempt=1
            local modify_success=false
            
            while [ $modify_attempt -le $max_modify_attempts ]; do
                log_info "Disabling deletion protection (attempt $modify_attempt/$max_modify_attempts)..."
                
                if aws rds modify-db-cluster \
                    --db-cluster-identifier "$cluster_id" \
                    --no-deletion-protection \
                    --backup-retention-period 1 \
                    --apply-immediately \
                    --region "$AWS_REGION" \
                    --no-cli-pager 2>&1 | tee /tmp/rds_modify_output.txt; then
                    
                    # Wait a moment for the change to propagate
                    sleep 5
                    
                    # Verify the change was applied
                    if verify_deletion_protection_disabled "$cluster_id"; then
                        modify_success=true
                        break
                    else
                        log_warning "Modification command succeeded but verification failed, retrying..."
                        sleep 15
                        ((modify_attempt += 1))
                    fi
                else
                    local error_output
                    error_output=$(cat /tmp/rds_modify_output.txt 2>/dev/null || echo "")
                    
                    if echo "$error_output" | grep -q "InvalidDBClusterStateFault"; then
                        log_warning "Cluster in invalid state, waiting 30s before retry..."
                        sleep 30
                        if ! wait_for_rds_available "$cluster_id"; then
                            log_warning "Still not available, but continuing..."
                        fi
                        ((modify_attempt += 1))
                    else
                        log_warning "Modification failed: $error_output"
                        sleep 10
                        ((modify_attempt += 1))
                    fi
                fi
            done
            
            rm -f /tmp/rds_modify_output.txt
            
            if [ "$modify_success" = true ]; then
                log_success "Successfully disabled deletion protection for $cluster_id"
            else
                log_error "Failed to disable deletion protection for $cluster_id after $max_modify_attempts attempts"
                log_error "Terraform destroy may fail. You may need to manually disable deletion protection in the AWS console."
                return 1
            fi
        done
        
        # Add extra wait time to ensure AWS API has fully propagated the change
        # 30 seconds accounts for:
        #   - AWS CLI → AWS API propagation: 5-10 seconds
        #   - AWS API → Terraform Provider propagation: 10-20 seconds
        #   - Safety buffer: 5-10 seconds
        log_info "Waiting 30 seconds for deletion protection changes to propagate fully across AWS API..."
        sleep 30
        
        # Final verification that all clusters have deletion protection disabled
        log_info "Performing final verification of deletion protection status..."
        local verification_failed=false
        for cluster_id in $clusters; do
            local final_status
            final_status=$(aws rds describe-db-clusters \
                --db-cluster-identifier "$cluster_id" \
                --region "$AWS_REGION" \
                --query "DBClusters[0].DeletionProtection" \
                --output text 2>/dev/null || echo "unknown")
            
            if [ "$final_status" = "True" ] || [ "$final_status" = "true" ]; then
                log_error "Final verification failed: Cluster $cluster_id still has deletion protection enabled"
                verification_failed=true
            else
                log_info "Final verification passed: Cluster $cluster_id deletion protection is disabled"
            fi
        done
        
        if [ "$verification_failed" = true ]; then
            log_error "One or more clusters still have deletion protection enabled"
            log_error "Please manually disable deletion protection in the AWS console"
            return 1
        fi
        
        log_success "RDS deletion protection disabled and verified for all clusters"
    else
        log_info "No RDS clusters found"
    fi
}


# =============================================================================
# S3 CLEANUP
# =============================================================================

empty_s3_bucket() {
    local bucket="$1"
    
    log_info "Emptying bucket: $bucket"
    
    # First try to remove all objects recursively
    aws s3 rm "s3://$bucket" --recursive --no-cli-pager 2>/dev/null || true
    
    # Delete object versions in batches to avoid "Argument list too long" errors
    local temp_file
    temp_file=$(mktemp)
    
    # Get all object versions and delete them in batches
    aws s3api list-object-versions \
        --bucket "$bucket" \
        --query 'Versions[].{Key:Key,VersionId:VersionId}' \
        --output json 2>/dev/null > "$temp_file" || echo '[]' > "$temp_file"
    
    # Process versions in batches of 1000 (AWS limit)
    if [ -s "$temp_file" ] && [ "$(cat "$temp_file")" != "[]" ]; then
        local batch_file
        batch_file=$(mktemp)
        
        # Split into batches and delete each batch
        jq -c '. | _nwise(1000)' "$temp_file" | while read -r batch; do
            echo "{\"Objects\": $batch}" > "$batch_file"
            aws s3api delete-objects \
                --bucket "$bucket" \
                --delete "file://$batch_file" \
                --no-cli-pager 2>/dev/null || true
        done
        
        rm -f "$batch_file"
    fi
    
    # Delete delete markers in batches
    aws s3api list-object-versions \
        --bucket "$bucket" \
        --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
        --output json 2>/dev/null > "$temp_file" || echo '[]' > "$temp_file"
    
    if [ -s "$temp_file" ] && [ "$(cat "$temp_file")" != "[]" ]; then
        local batch_file
        batch_file=$(mktemp)
        
        jq -c '. | _nwise(1000)' "$temp_file" | while read -r batch; do
            echo "{\"Objects\": $batch}" > "$batch_file"
            aws s3api delete-objects \
                --bucket "$bucket" \
                --delete "file://$batch_file" \
                --no-cli-pager 2>/dev/null || true
        done
        
        rm -f "$batch_file"
    fi
    
    rm -f "$temp_file"
}

cleanup_cloudtrail() {
    log_step "Cleaning up CloudTrail (required before S3 bucket deletion)..."
    
    # CloudTrail must be deleted before its S3 bucket can be deleted
    # CloudTrail buckets cannot be deleted while CloudTrail is still logging to them
    
    local cloudtrail_name="${CLUSTER_NAME}-cloudtrail"
    
    # Check if CloudTrail exists
    if aws cloudtrail get-trail --name "$cloudtrail_name" --region "$AWS_REGION" --no-cli-pager >/dev/null 2>&1; then
        log_info "Found CloudTrail: $cloudtrail_name"
        
        # Stop logging first (required before deletion)
        log_info "Stopping CloudTrail logging..."
        safe_aws "stop CloudTrail logging: $cloudtrail_name" \
            aws cloudtrail stop-logging \
                --name "$cloudtrail_name" \
                --region "$AWS_REGION" \
                --no-cli-pager
        
        # Wait a moment for the stop operation to propagate
        sleep 5
        
        # Delete the CloudTrail
        log_info "Deleting CloudTrail: $cloudtrail_name"
        safe_aws "delete CloudTrail: $cloudtrail_name" \
            aws cloudtrail delete-trail \
                --name "$cloudtrail_name" \
                --region "$AWS_REGION" \
                --no-cli-pager
        
        log_success "CloudTrail deleted successfully"
    else
        log_info "No CloudTrail found with name: $cloudtrail_name"
    fi
}

cleanup_s3_buckets() {
    log_step "Cleaning up Terraform-managed S3 buckets..."
    
    # Get bucket names from Terraform state (more reliable than outputs)
    local terraform_buckets=()
    cd "$TERRAFORM_DIR" || {
        log_warning "Cannot access Terraform directory, skipping S3 bucket cleanup"
        cd - >/dev/null
        return 0
    }
    
    # Get bucket names from Terraform state directly
    # Check if Terraform state exists
    if [ -f "terraform.tfstate" ] || [ -f ".terraform/terraform.tfstate" ]; then
        # Get bucket names from Terraform state directly
        local s3_resources
        s3_resources=$(terraform state list 2>/dev/null | grep "aws_s3_bucket\." || echo "")
        
        if [ -n "$s3_resources" ]; then
            for resource in $s3_resources; do
                # Get bucket name from state
                local bucket_name
                bucket_name=$(terraform state show "$resource" 2>/dev/null | \
                    grep -E "^\s*bucket\s*=" | \
                    awk -F'"' '{print $2}' | \
                    xargs || echo "")
                
                if [ -n "$bucket_name" ] && [ "$bucket_name" != "" ]; then
                    # Skip backup buckets - they should be preserved for restore operations
                    if [[ "$bucket_name" == *"backup"* ]] || [[ "$bucket_name" == *"openemr-backups"* ]]; then
                        log_info "Skipping backup bucket: $bucket_name (preserved for restore operations)"
                        continue
                    fi
                    
                    terraform_buckets+=("$bucket_name")
                    log_info "Found S3 bucket from Terraform state: $bucket_name"
                fi
            done
        fi
    fi
    
    # Fallback: Try to get from outputs if state method didn't work
    if [ ${#terraform_buckets[@]} -eq 0 ]; then
        log_info "No buckets found in state, trying Terraform outputs..."
        
        # Get ALB logs bucket
        local alb_bucket
        alb_bucket=$(terraform output -raw alb_logs_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$alb_bucket" ] && [ "$alb_bucket" != "null" ] && [ "$alb_bucket" != "" ]; then
            terraform_buckets+=("$alb_bucket")
            log_info "Found ALB logs bucket from Terraform output: $alb_bucket"
        fi
        
        # Get WAF logs bucket (may not exist if WAF is disabled)
        local waf_bucket
        waf_bucket=$(terraform output -raw waf_logs_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$waf_bucket" ] && [ "$waf_bucket" != "null" ] && [ "$waf_bucket" != "" ]; then
            terraform_buckets+=("$waf_bucket")
            log_info "Found WAF logs bucket from Terraform output: $waf_bucket"
        fi
        
        # Get Loki storage bucket
        local loki_bucket
        loki_bucket=$(terraform output -raw loki_s3_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$loki_bucket" ] && [ "$loki_bucket" != "null" ] && [ "$loki_bucket" != "" ]; then
            terraform_buckets+=("$loki_bucket")
            log_info "Found Loki storage bucket from Terraform output: $loki_bucket"
        fi
        
        # Get Tempo storage bucket
        local tempo_bucket
        tempo_bucket=$(terraform output -raw tempo_s3_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$tempo_bucket" ] && [ "$tempo_bucket" != "null" ] && [ "$tempo_bucket" != "" ]; then
            terraform_buckets+=("$tempo_bucket")
            log_info "Found Tempo storage bucket from Terraform output: $tempo_bucket"
        fi
        
        # Get Mimir blocks storage bucket
        local mimir_blocks_bucket
        mimir_blocks_bucket=$(terraform output -raw mimir_blocks_s3_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || \
            terraform output -raw mimir_s3_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$mimir_blocks_bucket" ] && [ "$mimir_blocks_bucket" != "null" ] && [ "$mimir_blocks_bucket" != "" ]; then
            terraform_buckets+=("$mimir_blocks_bucket")
            log_info "Found Mimir blocks storage bucket from Terraform output: $mimir_blocks_bucket"
        fi
        
        # Get Mimir ruler storage bucket
        local mimir_ruler_bucket
        mimir_ruler_bucket=$(terraform output -raw mimir_ruler_s3_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$mimir_ruler_bucket" ] && [ "$mimir_ruler_bucket" != "null" ] && [ "$mimir_ruler_bucket" != "" ]; then
            terraform_buckets+=("$mimir_ruler_bucket")
            log_info "Found Mimir ruler storage bucket from Terraform output: $mimir_ruler_bucket"
        fi
        
        # Get AlertManager storage bucket
        local alertmanager_bucket
        alertmanager_bucket=$(terraform output -raw alertmanager_s3_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$alertmanager_bucket" ] && [ "$alertmanager_bucket" != "null" ] && [ "$alertmanager_bucket" != "" ]; then
            terraform_buckets+=("$alertmanager_bucket")
            log_info "Found AlertManager storage bucket from Terraform output: $alertmanager_bucket"
        fi
        
        # Get CloudTrail logs bucket
        local cloudtrail_bucket
        cloudtrail_bucket=$(terraform output -raw cloudtrail_s3_bucket_name 2>/dev/null | \
            grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
        if [ -n "$cloudtrail_bucket" ] && [ "$cloudtrail_bucket" != "null" ] && [ "$cloudtrail_bucket" != "" ]; then
            terraform_buckets+=("$cloudtrail_bucket")
            log_info "Found CloudTrail logs bucket from Terraform output: $cloudtrail_bucket"
        fi
    fi
    
    cd - >/dev/null
    
    if [ ${#terraform_buckets[@]} -gt 0 ]; then
        log_info "Found ${#terraform_buckets[@]} Terraform-managed S3 bucket(s) to clean up"
        
        for bucket in "${terraform_buckets[@]}"; do
            # Skip backup buckets - they should be preserved for restore operations
            if [[ "$bucket" == *"backup"* ]] || [[ "$bucket" == *"openemr-backups"* ]]; then
                log_info "Skipping backup bucket: $bucket (preserved for restore operations)"
                continue
            fi
            
            log_info "Processing Terraform-managed bucket: $bucket"
            
            # Verify bucket exists before attempting cleanup
            if ! aws s3api head-bucket --bucket "$bucket" --no-cli-pager 2>/dev/null; then
                log_warning "Bucket $bucket does not exist (may have been already deleted), skipping"
                continue
            fi
            
            # Empty the bucket completely (handles versioned buckets including Loki storage)
            # This includes: ALB logs, WAF logs, and Loki storage buckets
            empty_s3_bucket "$bucket"
            
            # Delete the bucket
            # Note: Terraform will also attempt to delete these buckets,
            # but pre-emptively emptying them helps avoid versioning-related issues
            if aws s3api delete-bucket --bucket "$bucket" --no-cli-pager 2>/dev/null; then
                log_success "Deleted bucket: $bucket"
            else
                log_warning "Failed to delete bucket: $bucket (Terraform will attempt to delete it)"
            fi
        done
        
        log_success "Terraform-managed S3 buckets cleaned up (backup buckets preserved)"
        log_info "Cleaned buckets include: ALB logs, WAF logs, Loki, Tempo, Mimir (blocks and ruler), and AlertManager storage buckets"
    else
        log_info "No Terraform-managed S3 buckets found in Terraform outputs"
        log_info "This is expected if Terraform has not been applied yet or state is unavailable"
    fi
}

cleanup_cloudwatch_logs() {
    log_step "Cleaning up CloudWatch log groups..."
    
    # This prevents "log group already exists" errors on subsequent terraform apply
    # CloudWatch log groups persist after Terraform destroy, causing conflicts
    
    local log_groups
    log_groups=$(aws logs describe-log-groups \
        --region "$AWS_REGION" \
        --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
        --query "logGroups[].logGroupName" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$log_groups" ]; then
        log_info "Found CloudWatch log groups to clean up"
        for log_group in $log_groups; do
            log_info "Deleting log group: $log_group"
            if aws logs delete-log-group \
                --log-group-name "$log_group" \
                --region "$AWS_REGION" \
                --no-cli-pager 2>/dev/null; then
                log_success "Deleted log group: $log_group"
            else
                log_warning "Failed to delete log group: $log_group (may not exist)"
            fi
        done
        log_success "CloudWatch log groups cleaned up"
    else
        log_info "No CloudWatch log groups found"
    fi
}

# =============================================================================
# AWS BACKUP CLEANUP
# =============================================================================

cleanup_aws_backup_resources() {
    log_step "Cleaning up AWS Backup resources..."
    
    # Get backup vault name from Terraform output
    local backup_vault_name
    cd "$TERRAFORM_DIR" || {
        log_warning "Cannot access Terraform directory, skipping AWS Backup cleanup"
        cd - >/dev/null
        return 0
    }
    
    # Get terraform output, suppressing warnings and checking for valid output
    backup_vault_name=$(terraform output -raw backup_vault_name 2>/dev/null | grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
    cd - >/dev/null
    
    # Check if output is valid (not empty, not null, and doesn't contain terraform warning characters)
    if [ -z "$backup_vault_name" ] || \
       [ "$backup_vault_name" = "null" ] || \
       [[ "$backup_vault_name" == *"Warning"* ]] || \
       [[ "$backup_vault_name" == *"No outputs found"* ]] || \
       [[ "$backup_vault_name" == *"╷"* ]] || \
       [[ "$backup_vault_name" == *"│"* ]]; then
        log_info "No AWS Backup vault found in Terraform outputs, skipping AWS Backup cleanup"
        log_info "This is expected if no infrastructure has been deployed or Terraform state is empty"
        return 0
    fi
    
    # Verify the vault actually exists in AWS (Terraform state may be stale)
    if ! aws backup describe-backup-vault --backup-vault-name "$backup_vault_name" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Backup vault $backup_vault_name not found in AWS (may have been already deleted)"
        log_info "Skipping AWS Backup cleanup - vault does not exist"
        return 0
    fi
    
    log_info "Found backup vault: $backup_vault_name"
    
    # Get backup plan IDs from Terraform
    cd "$TERRAFORM_DIR"
    local daily_plan_id
    local weekly_plan_id
    local monthly_plan_id
    
    # Get plan IDs, filtering out terraform warnings and invalid output
    daily_plan_id=$(terraform output -raw backup_plan_daily_id 2>/dev/null | grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
    weekly_plan_id=$(terraform output -raw backup_plan_weekly_id 2>/dev/null | grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
    monthly_plan_id=$(terraform output -raw backup_plan_monthly_id 2>/dev/null | grep -v "Warning:" | grep -v "No outputs found" | grep -v "^╷" | grep -v "^│" | grep -v "^╵" | xargs || echo "")
    cd - >/dev/null
    
    # Validate plan IDs are not empty or invalid
    local valid_plans=0
    for plan_id in "$daily_plan_id" "$weekly_plan_id" "$monthly_plan_id"; do
        if [ -n "$plan_id" ] && \
           [ "$plan_id" != "null" ] && \
           [ "$plan_id" != "" ] && \
           [[ ! "$plan_id" == *"Warning"* ]] && \
           [[ ! "$plan_id" == *"No outputs found"* ]] && \
           [[ ! "$plan_id" == *"╷"* ]]; then
            ((valid_plans += 1))
        fi
    done
    
    if [ $valid_plans -eq 0 ]; then
        log_info "No valid backup plans found in Terraform outputs, skipping AWS Backup cleanup"
        return 0
    fi
    
    # Delete backup selections first (they reference plans)
    log_info "Deleting backup selections..."
    
    # List all backup selections for the plans
    for plan_id in "$daily_plan_id" "$weekly_plan_id" "$monthly_plan_id"; do
        if [ -n "$plan_id" ] && [ "$plan_id" != "null" ] && [ "$plan_id" != "" ]; then
            # Get selection IDs for this plan
            local selection_ids
            selection_ids=$(aws backup list-backup-selections \
                --backup-plan-id "$plan_id" \
                --region "$AWS_REGION" \
                --query "BackupSelectionsList[].SelectionId" \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$selection_ids" ]; then
                for selection_id in $selection_ids; do
                    # Clean up whitespace
                    selection_id=$(echo "$selection_id" | xargs)
                    
                    if [ -n "$selection_id" ] && [ "$selection_id" != "" ]; then
                        # Get selection name for logging
                        local selection_name
                        selection_name=$(aws backup list-backup-selections \
                            --backup-plan-id "$plan_id" \
                            --region "$AWS_REGION" \
                            --query "BackupSelectionsList[?SelectionId=='$selection_id'].SelectionName" \
                            --output text 2>/dev/null | head -1 || echo "$selection_id")
                        
                        log_info "Deleting backup selection: $selection_name (ID: $selection_id)"
                        safe_aws "delete backup selection: $selection_name" \
                            aws backup delete-backup-selection \
                                --backup-plan-id "$plan_id" \
                                --selection-id "$selection_id" \
                                --region "$AWS_REGION" \
                                --no-cli-pager
                    fi
                done
            fi
        fi
    done
    
    # Delete backup plans (they reference vaults)
    log_info "Deleting backup plans..."
    
    for plan_id in "$daily_plan_id" "$weekly_plan_id" "$monthly_plan_id"; do
        if [ -n "$plan_id" ] && [ "$plan_id" != "null" ] && [ "$plan_id" != "" ]; then
            # Get plan name
            local plan_name
            plan_name=$(aws backup get-backup-plan \
                --backup-plan-id "$plan_id" \
                --region "$AWS_REGION" \
                --query "BackupPlan.BackupPlanName" \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$plan_name" ]; then
                log_info "Deleting backup plan: $plan_name"
                safe_aws "delete backup plan: $plan_name" \
                    aws backup delete-backup-plan \
                        --backup-plan-id "$plan_id" \
                        --region "$AWS_REGION" \
                        --no-cli-pager
            fi
        fi
    done
    
    # Stop or wait for active backup jobs - vault cannot be deleted while jobs are running
    # Note: Some resource types (like Aurora) don't support stopping backup jobs
    log_info "Checking for active backup jobs..."
    
    local max_wait_time="$BACKUP_JOB_WAIT_TIMEOUT"
    local wait_interval="$BACKUP_JOB_POLL_INTERVAL"
    local waited=0
    
    while [ "$waited" -lt "$max_wait_time" ]; do
        local has_active_jobs=false
        
        for state in "RUNNING" "PENDING" "CREATED"; do
            local jobs
            jobs=$(aws backup list-backup-jobs \
                --by-backup-vault-name "$backup_vault_name" \
                --by-state "$state" \
                --region "$AWS_REGION" \
                --query "BackupJobs[].BackupJobId" \
                --output text 2>/dev/null || echo "")
            
            for job_id in $jobs; do
                if [ -n "$job_id" ] && [ "$job_id" != "None" ]; then
                    has_active_jobs=true
                    log_info "Found active backup job: $job_id (state: $state) - attempting to stop..."
                    
                    # Try to stop the job (may fail for certain resource types like Aurora)
                    if aws backup stop-backup-job --backup-job-id "$job_id" --region "$AWS_REGION" 2>/dev/null; then
                        log_success "Stopped backup job: $job_id"
                    else
                        log_warning "Cannot stop job $job_id (resource type may not support stopping)"
                    fi
                fi
            done
        done
        
        if [ "$has_active_jobs" = false ]; then
            log_success "No active backup jobs - vault is ready for deletion"
            break
        fi
        
        # Wait and check again
        log_info "Waiting for backup jobs to complete... (${waited}s/${max_wait_time}s)"
        sleep "$wait_interval"
        waited=$((waited + wait_interval))
    done
    
    if [ "$waited" -ge "$max_wait_time" ]; then
        log_warning "Timed out waiting for backup jobs after ${max_wait_time}s"
        log_info "Will attempt to delete vault anyway - may fail if jobs are still running"
    fi
    
    # Delete recovery points in the vault (if any exist)
    # Must handle composite recovery points specially - they need to be disassociated first
    log_info "Deleting recovery points in vault: $backup_vault_name"
    
    # List all recovery points in the vault with full details (need to check for composite/parent status)
    local recovery_points_json
    recovery_points_json=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$backup_vault_name" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo '{"RecoveryPoints":[]}')
    
    local recovery_point_count
    recovery_point_count=$(echo "$recovery_points_json" | jq '.RecoveryPoints | length')
    
    if [ "$recovery_point_count" -gt 0 ]; then
        log_info "Found $recovery_point_count recovery point(s) to delete"
        
        # First pass: Identify and disassociate composite (parent) recovery points
        # Note: Some composite recovery points (like EKS) may not support disassociation
        # or may need to be deleted directly. We'll try disassociation but continue if it fails.
        log_info "Checking for composite recovery points that need disassociation..."
        local composite_arns
        composite_arns=$(echo "$recovery_points_json" | jq -r '.RecoveryPoints[] | select(.IsParent == true or .CompositeMemberIdentifier != null) | .RecoveryPointArn' 2>/dev/null || echo "")
        
        if [ -n "$composite_arns" ]; then
            log_info "Found composite recovery points - attempting disassociation..."
            for recovery_point_arn in $composite_arns; do
                if [ -n "$recovery_point_arn" ] && [ "$recovery_point_arn" != "null" ]; then
                    # Get resource type to determine if disassociation is supported
                    local resource_type
                    resource_type=$(echo "$recovery_points_json" | jq -r ".RecoveryPoints[] | select(.RecoveryPointArn == \"$recovery_point_arn\") | .ResourceType" 2>/dev/null || echo "")
                    
                    log_info "Attempting to disassociate composite recovery point: $recovery_point_arn (ResourceType: $resource_type)"
                    
                    # Try disassociation, but don't fail if it doesn't work
                    # Some resource types (like EKS composite) may not support disassociation
                    # For EBS snapshots, disassociation often hangs - skip it and delete directly
                    if echo "$recovery_point_arn" | grep -q "snapshot/snap-"; then
                        log_info "EBS snapshot detected - skipping disassociation (often hangs), will delete directly: $recovery_point_arn"
                        local disassociate_output="Skipped disassociation for EBS snapshot (will delete directly)"
                        local disassociate_exit_code=1
                    else
                        # Add timeout to prevent hanging (30 seconds should be enough)
                        local disassociate_output
                        local disassociate_exit_code=0
                        if command -v timeout >/dev/null 2>&1; then
                            disassociate_output=$(timeout 30 aws backup disassociate-recovery-point \
                                --backup-vault-name "$backup_vault_name" \
                                --recovery-point-arn "$recovery_point_arn" \
                                --region "$AWS_REGION" \
                                --no-cli-pager 2>&1)
                            disassociate_exit_code=$?
                            # Timeout returns 124 on timeout
                            if [ $disassociate_exit_code -eq 124 ]; then
                                disassociate_output="Command timed out after 30 seconds"
                            fi
                        else
                            # Fallback if timeout command is not available - use background process with kill
                            local pid_file="/tmp/disassociate_$$.pid"
                            (aws backup disassociate-recovery-point \
                                --backup-vault-name "$backup_vault_name" \
                                --recovery-point-arn "$recovery_point_arn" \
                                --region "$AWS_REGION" \
                                --no-cli-pager > "$pid_file.out" 2>&1) &
                            local bg_pid=$!
                            echo $bg_pid > "$pid_file"
                            
                            # Wait up to 30 seconds
                            local waited=0
                            while [ $waited -lt 30 ]; do
                                if ! kill -0 $bg_pid 2>/dev/null; then
                                    # Process finished
                                    break
                                fi
                                sleep 1
                                waited=$((waited + 1))
                            done
                            
                            if kill -0 $bg_pid 2>/dev/null; then
                                # Still running, kill it
                                kill $bg_pid 2>/dev/null
                                disassociate_output="Command timed out after 30 seconds"
                                disassociate_exit_code=124
                            else
                                # Process finished, get output
                                disassociate_output=$(cat "$pid_file.out" 2>/dev/null || echo "")
                                # Temporarily disable set -e to capture exit code without script exiting
                                set +e
                                wait $bg_pid
                                disassociate_exit_code=$?
                                set -e
                            fi
                            rm -f "$pid_file" "$pid_file.out" 2>/dev/null
                        fi
                    fi
                    
                    if [ $disassociate_exit_code -eq 0 ]; then
                        log_success "Successfully disassociated composite recovery point: $recovery_point_arn"
                    else
                        # Check if error is about invalid parameter (some composites don't support disassociation)
                        if echo "$disassociate_output" | grep -q "InvalidParameterValueException\|InvalidParameterException"; then
                            log_info "Disassociation not supported for this recovery point type - will attempt direct deletion: $recovery_point_arn"
                        else
                            log_warning "Could not disassociate $recovery_point_arn: $disassociate_output"
                            log_info "Will attempt direct deletion instead"
                        fi
                    fi
                fi
            done
            # Wait for disassociation to propagate (if any succeeded)
            log_info "Waiting 10 seconds for disassociation to propagate..."
            sleep 10
        fi
        
        # Second pass: Delete all NON-COMPOSITE recovery points first
        # For composite recovery points, we must delete all nested/non-composite recovery points
        # before we can delete the composite parent
        log_info "Deleting non-composite recovery points first (required before deleting composite parent)..."
        
        # Get all recovery points that are NOT composite parents
        local non_composite_arns
        non_composite_arns=$(echo "$recovery_points_json" | jq -r '.RecoveryPoints[] | select(.IsParent != true) | .RecoveryPointArn' 2>/dev/null || echo "")
        
        if [ -n "$non_composite_arns" ]; then
            local failed_deletions=()
            for recovery_point_arn in $non_composite_arns; do
                if [ -n "$recovery_point_arn" ] && [ "$recovery_point_arn" != "null" ]; then
                    log_info "Deleting non-composite recovery point: $recovery_point_arn"
                    
                    # Check if this is an EBS snapshot (needs special handling)
                    if echo "$recovery_point_arn" | grep -q "snapshot/snap-"; then
                        local snapshot_id
                        snapshot_id=$(echo "$recovery_point_arn" | sed 's/.*snapshot\/\(snap-[^ ]*\).*/\1/')
                        log_info "Detected EBS snapshot: $snapshot_id"
                    fi
                    
                    local delete_output
                    if delete_output=$(aws backup delete-recovery-point \
                        --backup-vault-name "$backup_vault_name" \
                        --recovery-point-arn "$recovery_point_arn" \
                        --region "$AWS_REGION" \
                        --no-cli-pager 2>&1); then
                        log_success "Successfully deleted: $recovery_point_arn"
                        # Small delay between successful deletions
                        sleep 2
                    else
                        # Check if error is about composite dependency
                        if echo "$delete_output" | grep -q "cannot be deleted until all other nested recovery points"; then
                            log_warning "Recovery point is nested under composite - will retry after other nested points: $recovery_point_arn"
                            failed_deletions+=("$recovery_point_arn")
                        elif echo "$recovery_point_arn" | grep -q "snapshot/snap-"; then
                            # For EBS snapshots, try deleting via EC2 API as fallback
                            local snapshot_id
                            snapshot_id=$(echo "$recovery_point_arn" | sed 's/.*snapshot\/\(snap-[^ ]*\).*/\1/')
                            log_info "Backup API deletion failed, trying EC2 API for snapshot: $snapshot_id"
                            if aws ec2 delete-snapshot --snapshot-id "$snapshot_id" --region "$AWS_REGION" 2>/dev/null; then
                                log_success "Deleted EBS snapshot via EC2 API: $snapshot_id"
                            else
                                log_warning "Could not delete EBS snapshot: $delete_output"
                                failed_deletions+=("$recovery_point_arn")
                            fi
                        else
                            log_warning "Could not delete $recovery_point_arn: $delete_output"
                            failed_deletions+=("$recovery_point_arn")
                        fi
                    fi
                fi
            done
            
            # Retry failed deletions (they might have been waiting for other nested points)
            if [ ${#failed_deletions[@]} -gt 0 ]; then
                log_info "Retrying ${#failed_deletions[@]} failed deletion(s)..."
                sleep 5
                for recovery_point_arn in "${failed_deletions[@]}"; do
                    log_info "Retrying deletion: $recovery_point_arn"
                    if aws backup delete-recovery-point \
                        --backup-vault-name "$backup_vault_name" \
                        --recovery-point-arn "$recovery_point_arn" \
                        --region "$AWS_REGION" \
                        --no-cli-pager 2>/dev/null; then
                        log_success "Successfully deleted on retry: $recovery_point_arn"
                    else
                        log_warning "Still could not delete: $recovery_point_arn"
                    fi
                    sleep 2
                done
            fi
            
            # Wait for deletions to propagate
            log_info "Waiting 15 seconds for non-composite recovery point deletions to propagate..."
            sleep 15
        fi
        
        # Third pass: Delete composite parent recovery points (must be last)
        log_info "Deleting composite parent recovery points (after all nested points are deleted)..."
        local composite_parent_arns
        composite_parent_arns=$(echo "$recovery_points_json" | jq -r '.RecoveryPoints[] | select(.IsParent == true) | .RecoveryPointArn' 2>/dev/null || echo "")
        
        if [ -n "$composite_parent_arns" ]; then
            for recovery_point_arn in $composite_parent_arns; do
                if [ -n "$recovery_point_arn" ] && [ "$recovery_point_arn" != "null" ]; then
                    log_info "Deleting composite parent recovery point: $recovery_point_arn"
                    local delete_output
                    if delete_output=$(aws backup delete-recovery-point \
                        --backup-vault-name "$backup_vault_name" \
                        --recovery-point-arn "$recovery_point_arn" \
                        --region "$AWS_REGION" \
                        --no-cli-pager 2>&1); then
                        log_success "Successfully deleted composite parent: $recovery_point_arn"
                    else
                        log_warning "Could not delete composite parent $recovery_point_arn: $delete_output"
                        log_warning "This may indicate that nested recovery points still exist"
                    fi
                    # Delay between composite deletions
                    sleep 3
                fi
            done
            
            # Wait for composite deletion to propagate
            log_info "Waiting 15 seconds for composite parent deletions to propagate..."
            sleep 15
        fi
        
        # Fourth pass: Delete any remaining standalone recovery points (fallback)
        local parent_and_standalone_arns
        parent_and_standalone_arns=$(echo "$recovery_points_json" | jq -r '.RecoveryPoints[] | select(.ParentRecoveryPointArn == null and .IsParent != true) | .RecoveryPointArn' 2>/dev/null || echo "")
        
        if [ -z "$parent_and_standalone_arns" ]; then
            # Fallback: if jq filter didn't work, get all ARNs
            parent_and_standalone_arns=$(echo "$recovery_points_json" | jq -r '.RecoveryPoints[].RecoveryPointArn' 2>/dev/null || echo "")
        fi
        
        for recovery_point_arn in $parent_and_standalone_arns; do
            if [ -n "$recovery_point_arn" ] && [ "$recovery_point_arn" != "null" ]; then
                log_info "Deleting recovery point: $recovery_point_arn"
                
                # Check if this is an EBS snapshot (needs special handling)
                if echo "$recovery_point_arn" | grep -q "snapshot/snap-"; then
                    local snapshot_id
                    snapshot_id=$(echo "$recovery_point_arn" | sed 's/.*snapshot\/\(snap-[^ ]*\).*/\1/')
                    log_info "Detected EBS snapshot - attempting deletion via Backup API first: $snapshot_id"
                fi
                
                local delete_output
                if delete_output=$(aws backup delete-recovery-point \
                    --backup-vault-name "$backup_vault_name" \
                    --recovery-point-arn "$recovery_point_arn" \
                    --region "$AWS_REGION" \
                    --no-cli-pager 2>&1); then
                    log_success "Successfully deleted recovery point: $recovery_point_arn"
                else
                    # Check if it's a "resource in use" error that might resolve with time
                    if echo "$delete_output" | grep -q "ResourceInUseException\|InvalidStateException"; then
                        log_warning "Recovery point $recovery_point_arn is in use - will retry later: $delete_output"
                    elif echo "$recovery_point_arn" | grep -q "snapshot/snap-"; then
                        # For EBS snapshots, try deleting via EC2 API as fallback
                        local snapshot_id
                        snapshot_id=$(echo "$recovery_point_arn" | sed 's/.*snapshot\/\(snap-[^ ]*\).*/\1/')
                        log_info "Backup API deletion failed, trying EC2 API for snapshot: $snapshot_id"
                        local ec2_delete_output
                        if ec2_delete_output=$(aws ec2 delete-snapshot --snapshot-id "$snapshot_id" --region "$AWS_REGION" 2>&1); then
                            log_success "Deleted EBS snapshot via EC2 API: $snapshot_id"
                        else
                            log_warning "Could not delete EBS snapshot via EC2 API: $ec2_delete_output"
                        fi
                    else
                        log_warning "Could not delete $recovery_point_arn: $delete_output"
                    fi
                fi
            fi
        done
        
        # Wait for deletions to complete
        log_info "Waiting 15 seconds for recovery point deletions to complete..."
        sleep 15
        
        # Verify all recovery points are deleted with retry logic
        # Use more aggressive retry with longer waits for AWS API propagation
        local max_retries=5
        local retry_count=0
        local remaining
        
        while [ $retry_count -lt $max_retries ]; do
            # Get fresh list of remaining recovery points
            remaining=$(aws backup list-recovery-points-by-backup-vault \
                --backup-vault-name "$backup_vault_name" \
                --region "$AWS_REGION" \
                --query "RecoveryPoints[].RecoveryPointArn" \
                --output text 2>/dev/null || echo "")
            
            # Check if empty or just whitespace/None
            remaining=$(echo "$remaining" | xargs)
            
            if [ -z "$remaining" ] || [ "$remaining" = "None" ] || [ "$remaining" = "" ]; then
                log_success "All recovery points have been deleted"
                break
            fi
            
            retry_count=$((retry_count + 1))
            log_info "Found $(echo "$remaining" | wc -w | xargs) recovery point(s) still remaining (check $retry_count/$max_retries)"
            
            if [ $retry_count -lt $max_retries ]; then
                log_warning "Some recovery points still exist. Retrying deletion..."
                
                # Try deleting remaining recovery points again with detailed error handling
                for recovery_point_arn in $remaining; do
                    if [ -n "$recovery_point_arn" ] && [ "$recovery_point_arn" != "null" ] && [ "$recovery_point_arn" != "None" ]; then
                        log_info "Retrying deletion of recovery point: $recovery_point_arn"
                        
                        local delete_error
                        if delete_error=$(aws backup delete-recovery-point \
                            --backup-vault-name "$backup_vault_name" \
                            --recovery-point-arn "$recovery_point_arn" \
                            --region "$AWS_REGION" \
                            --no-cli-pager 2>&1); then
                            log_success "Successfully deleted: $recovery_point_arn"
                        else
                            log_warning "Delete attempt failed for $recovery_point_arn: $delete_error"
                            
                            # For EBS snapshots, they might need to be deleted via EC2 API
                            if echo "$recovery_point_arn" | grep -q "snapshot/snap-"; then
                                local snapshot_id
                                snapshot_id=$(echo "$recovery_point_arn" | sed 's/.*snapshot\/\(snap-[^ ]*\).*/\1/')
                                log_info "Attempting to delete EBS snapshot directly: $snapshot_id"
                                if aws ec2 delete-snapshot --snapshot-id "$snapshot_id" --region "$AWS_REGION" 2>/dev/null; then
                                    log_success "Deleted EBS snapshot: $snapshot_id"
                                else
                                    log_warning "Could not delete EBS snapshot: $snapshot_id"
                                fi
                            fi
                        fi
                    fi
                done
                
                # Longer wait for AWS API propagation (recovery point deletions can take time)
                local wait_time=$((20 + retry_count * 10))
                log_info "Waiting ${wait_time} seconds for deletions to propagate..."
                sleep "$wait_time"
            else
                log_error "Some recovery points could not be deleted after $max_retries attempts"
                log_error "Remaining recovery points: $remaining"
                log_error "Vault deletion will fail - recovery points must be deleted first"
                return 1
            fi
        done
        
        # Final verification before proceeding
        remaining=$(aws backup list-recovery-points-by-backup-vault \
            --backup-vault-name "$backup_vault_name" \
            --region "$AWS_REGION" \
            --query "RecoveryPoints[].RecoveryPointArn" \
            --output text 2>/dev/null || echo "")
        remaining=$(echo "$remaining" | xargs)
        
        if [ -n "$remaining" ] && [ "$remaining" != "None" ] && [ "$remaining" != "" ]; then
            log_error "Recovery points still exist after all retry attempts: $remaining"
            log_error "Cannot delete backup vault while recovery points exist"
            return 1
        fi
        
        # Final check - if recovery points still exist, we cannot delete the vault
        local final_check
        final_check=$(aws backup list-recovery-points-by-backup-vault \
            --backup-vault-name "$backup_vault_name" \
            --region "$AWS_REGION" \
            --query "RecoveryPoints[].RecoveryPointArn" \
            --output text 2>/dev/null || echo "")
        final_check=$(echo "$final_check" | xargs)
        
        if [ -n "$final_check" ] && [ "$final_check" != "None" ] && [ "$final_check" != "" ]; then
            log_error "Recovery points still exist - cannot delete vault"
            log_error "Remaining: $final_check"
            return 1
        fi
        
        log_success "Recovery points cleanup completed"
    else
        log_info "No recovery points found in vault"
    fi
    
    # Final verification before deleting vault
    log_info "Verifying vault is empty before deletion..."
    local vault_check
    vault_check=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$backup_vault_name" \
        --region "$AWS_REGION" \
        --query "RecoveryPoints[].RecoveryPointArn" \
        --output text 2>/dev/null || echo "")
    vault_check=$(echo "$vault_check" | xargs)
    
    if [ -n "$vault_check" ] && [ "$vault_check" != "None" ] && [ "$vault_check" != "" ]; then
        log_error "Cannot delete backup vault - recovery points still exist: $vault_check"
        return 1
    fi
    
    # Delete backup vault
    log_info "Deleting backup vault: $backup_vault_name"
    safe_aws "delete backup vault: $backup_vault_name" \
        aws backup delete-backup-vault \
            --backup-vault-name "$backup_vault_name" \
            --region "$AWS_REGION" \
            --no-cli-pager
    
    # Clean up IAM role and policies
    # Get IAM role name from Terraform (if available)
    log_info "Cleaning up AWS Backup IAM role..."
    
    # List IAM roles with backup in the name
    local backup_role_names
    backup_role_names=$(aws iam list-roles \
        --query "Roles[?contains(RoleName, '$CLUSTER_NAME') && contains(RoleName, 'backup')].RoleName" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$backup_role_names" ]; then
        for role_name in $backup_role_names; do
            log_info "Cleaning up IAM role: $role_name"
            
            # Detach managed policies
            local attached_policies
            attached_policies=$(aws iam list-attached-role-policies \
                --role-name "$role_name" \
                --query "AttachedPolicies[].PolicyArn" \
                --output text 2>/dev/null || echo "")
            
            for policy_arn in $attached_policies; do
                log_info "Detaching policy: $policy_arn"
                safe_aws "detach policy from role: $role_name" \
                    aws iam detach-role-policy \
                        --role-name "$role_name" \
                        --policy-arn "$policy_arn" \
                        --no-cli-pager
            done
            
            # Delete inline policies
            local inline_policies
            inline_policies=$(aws iam list-role-policies \
                --role-name "$role_name" \
                --query "PolicyNames" \
                --output text 2>/dev/null || echo "")
            
            for policy_name in $inline_policies; do
                log_info "Deleting inline policy: $policy_name"
                safe_aws "delete inline policy: $policy_name" \
                    aws iam delete-role-policy \
                        --role-name "$role_name" \
                        --policy-name "$policy_name" \
                        --no-cli-pager
            done
            
            # Delete the role
            log_info "Deleting IAM role: $role_name"
            safe_aws "delete IAM role: $role_name" \
                aws iam delete-role \
                    --role-name "$role_name" \
                    --no-cli-pager
        done
    else
        log_info "No AWS Backup IAM roles found"
    fi
    
    log_success "AWS Backup resources cleaned up"
}

# =============================================================================
# TERRAFORM CLEANUP
# =============================================================================

verify_terraform_can_destroy_rds() {
    log_step "Verifying Terraform can destroy RDS clusters..."
    
    cd "$TERRAFORM_DIR"
    
    if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
        log_info "No Terraform state found, skipping RDS verification"
        cd - >/dev/null
        return 0
    fi
    
    # Check if there are any RDS clusters in the state
    local rds_resources
    rds_resources=$(terraform state list 2>/dev/null | grep -E "aws_rds_cluster\.|aws_db_instance\." || echo "")
    
    if [ -z "$rds_resources" ]; then
        log_info "No RDS resources found in Terraform state"
        cd - >/dev/null
        return 0
    fi
    
    log_info "Found RDS resources in state, verifying deletion protection status..."
    
    # Run terraform plan -destroy to check for any issues
    # This will fail if there are protected resources
    local plan_output
    plan_output=$(terraform plan -destroy \
        -var=cluster_name="$CLUSTER_NAME" \
        -var=aws_region="$AWS_REGION" \
        -var=rds_deletion_protection="false" \
        -no-color 2>&1)
    local plan_exit_code=$?
    
    if [ $plan_exit_code -eq 0 ]; then
        log_success "Terraform can successfully plan RDS cluster destruction"
        cd - >/dev/null
        return 0
    else
        # Check if the error is related to deletion protection
        if echo "$plan_output" | grep -qi "deletion.protection\|cannot delete protected"; then
            log_error "Terraform detected RDS deletion protection is still enabled"
            log_error "This should not happen - the disable_rds_deletion_protection() function may need adjustment"
            cd - >/dev/null
            return 1
        else
            log_warning "Terraform plan encountered an issue, but not related to deletion protection"
            log_warning "Proceeding with destroy anyway..."
            cd - >/dev/null
            return 0
        fi
    fi
}

terraform_destroy() {
    log_step "Running Terraform destroy..."
    
    cd "$TERRAFORM_DIR"
    
    if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
        log_warning "No Terraform state found, skipping Terraform destroy"
        cd - >/dev/null
        return 0
    fi
    
    # Initialize Terraform
    if ! terraform init -upgrade -no-color; then
        log_error "Terraform init failed"
        cd - >/dev/null
        return 1
    fi
    
    # Destroy with force if requested
    local destroy_args=("-auto-approve")
    if [ "$FORCE" = true ]; then
        destroy_args+=("-refresh=false")
    fi
    # CRITICAL: Override rds_deletion_protection to false for destroy
    # This ensures Terraform doesn't try to re-enable deletion protection during destroy
    destroy_args+=("-var=cluster_name=$CLUSTER_NAME" "-var=aws_region=$AWS_REGION" "-var=rds_deletion_protection=false" "-no-color")
    
    # Retry logic for Terraform destroy (handles AWS API eventual consistency issues)
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Terraform destroy attempt $attempt/$max_attempts..."
        
        if terraform destroy "${destroy_args[@]}"; then
            log_success "Terraform destroy completed successfully"
            
            # Only clean up state files if destroy succeeded
            log_info "Cleaning up Terraform state files..."
            rm -f terraform.tfstate* .terraform.lock.hcl
            log_info "Terraform state files cleaned up - random IDs will regenerate on next run"
            
            cd - >/dev/null
            return 0
        else
            local destroy_exit_code=$?
            log_error "Terraform destroy attempt $attempt failed with exit code: $destroy_exit_code"
            
            if [ $attempt -lt $max_attempts ]; then
                log_warning "Waiting 30 seconds before retry (allows AWS API propagation)..."
                log_warning "This delay helps resolve eventual consistency issues with RDS deletion protection"
                sleep 30
                ((attempt += 1))
            else
                log_error "Terraform destroy failed after $max_attempts attempts"
                log_warning "Preserving Terraform state files for debugging and potential manual retry"
                log_warning "You can manually retry with: cd terraform && terraform destroy"
                cd - >/dev/null
                return 1
            fi
        fi
    done
    
    cd - >/dev/null
    return 1
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_cleanup() {
    log_step "Verifying cleanup..."
    
    local remaining_resources=()
    
    # Check for remaining EKS clusters
    if aws eks list-clusters --region "$AWS_REGION" --query "clusters[?contains(@, '$CLUSTER_NAME')]" --output text 2>/dev/null | grep -q .; then
        remaining_resources+=("EKS clusters")
    fi
    
    # Check for remaining RDS clusters
    if aws rds describe-db-clusters --region "$AWS_REGION" --query "DBClusters[?contains(DBClusterIdentifier, '$CLUSTER_NAME')].DBClusterIdentifier" --output text 2>/dev/null | grep -q .; then
        remaining_resources+=("RDS clusters")
    fi
    
    # Check for remaining S3 buckets (only those with specific cluster name, excluding backup buckets)
    local remaining_buckets
    remaining_buckets=$(aws s3api list-buckets --query "Buckets[?contains(Name, '$CLUSTER_NAME')].Name" --output text 2>/dev/null | grep -v -E "(backup|openemr-backups)" || echo "")
    if [ -n "$remaining_buckets" ]; then
        remaining_resources+=("S3 buckets")
    fi
    
    if [ ${#remaining_resources[@]} -gt 0 ]; then
        log_warning "Some resources may still exist:"
        for resource in "${remaining_resources[@]}"; do
            log_warning "  - $resource"
        done
        log_warning "Check the AWS console for manual cleanup if needed"
        return 1
    else
        log_success "All resources have been successfully cleaned up!"
        return 0
    fi
}

# Show help information
show_help() {
    echo "OpenEMR EKS AWS Infrastructure Cleanup Script"
    echo ""
    echo "USAGE:"
    echo "    $0 [OPTIONS]"
    echo ""
    echo "DESCRIPTION:"
    echo "    Handles AWS-level cleanup issues that prevent terraform destroy from working."
    echo "    Focuses on the problems that actually matter: RDS deletion protection,"
    echo "    snapshots, S3 bucket versioning, and orphaned AWS resources."
    echo ""
    echo "OPTIONS:"
    echo "    --force                 Skip confirmation prompts and use force mode"
    echo "    --help, -h              Show this help message"
    echo ""
    echo "WHAT THIS SCRIPT DOES:"
    echo "    • Deletes all snapshots to prevent automatic restoration"
    echo "    • Disables RDS deletion protection for clean terraform destroy"
    echo "    • Handles S3 bucket versioning issues (delete markers, versions)"
    echo "    • Cleans up AWS Backup resources (selections, plans, vaults, recovery points, IAM)"
    echo "    • Runs terraform destroy (handles ElastiCache, EKS, and other resources)"
    echo "    • Verifies complete cleanup"
    echo ""
    echo "WHAT THIS SCRIPT DOES NOT DO:"
    echo "    • Kubernetes resource cleanup (handled automatically by EKS cluster deletion)"
    echo ""
    echo "EXAMPLES:"
    echo "    $0                              # Interactive cleanup with confirmation prompts"
    echo "    $0 --force                      # Automated cleanup (CI/CD) - no prompts"
    echo ""
    echo "⚠️  WARNING:"
    echo "    This action completely destroys all AWS infrastructure and cannot be undone!"
    echo "    All resources including Terraform state, RDS clusters, snapshots,"
    echo "    and S3 buckets will be permanently deleted."
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo -e "${BLUE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "💥 COMPLETE INFRASTRUCTURE DESTRUCTION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--force] [--help]"
                exit 1
                ;;
        esac
    done
    
    # Confirmation prompt
    if [ "$FORCE" = false ]; then
        echo -e "${RED}⚠️  WARNING: This will completely destroy all OpenEMR infrastructure!${NC}"
        echo -e "${RED}   This action cannot be undone.${NC}"
        echo
        read -r -p "Are you sure you want to continue? (type 'yes' to confirm): " confirmation
        if [ "$confirmation" != "yes" ]; then
            log_info "Destruction cancelled"
            exit 0
        fi
    fi
    
    # Execute cleanup steps - only handle critical issues that prevent terraform destroy
    # Check prerequisites first (includes AWS credentials check with helpful error messages)
    check_prerequisites
    
    # Get AWS account ID for verification (after credentials are verified)
    local aws_account_id
    aws_account_id=$(get_aws_account_id)
    
    # Get AWS region from Terraform or environment
    get_aws_region
    
    # Get cluster name from Terraform or use default
    get_cluster_name
    
    log_info "AWS Account ID: $aws_account_id"
    log_info "AWS Region: $AWS_REGION"
    log_info "Cluster Name: $CLUSTER_NAME"
    log_info "Force Mode: $FORCE"
    cleanup_rds_snapshots
    
    # Disable RDS deletion protection - this is critical for terraform destroy to succeed
    if ! disable_rds_deletion_protection; then
        log_error "Failed to disable RDS deletion protection"
        log_error "Cannot proceed with Terraform destroy - RDS clusters are still protected"
        log_error "Please manually disable deletion protection in the AWS console and retry"
        exit 1
    fi
    
    # Verify Terraform can see the RDS clusters as deletable
    # This provides an additional safety check before attempting destroy
    if ! verify_terraform_can_destroy_rds; then
        log_error "Terraform verification failed - RDS clusters may still be protected"
        log_error "Waiting additional 30 seconds for AWS API propagation..."
        sleep 30
        
        # Retry verification once more
        if ! verify_terraform_can_destroy_rds; then
            log_error "Verification failed again after additional wait"
            log_error "Please manually check RDS deletion protection in AWS console"
            exit 1
        fi
        
        log_success "Verification succeeded after additional wait"
    fi
    
    # Clean up CloudTrail first (must be deleted before its S3 bucket)
    cleanup_cloudtrail
    
    cleanup_s3_buckets
    cleanup_cloudwatch_logs
    cleanup_aws_backup_resources
    
    # Run terraform destroy - must succeed for cleanup to be considered complete
    if ! terraform_destroy; then
        log_error "Terraform destroy failed"
        log_error "Infrastructure destruction incomplete - some resources may still exist"
        log_error "Terraform state files have been preserved for debugging"
        exit 1
    fi
    
    # Verify cleanup
    if verify_cleanup; then
        echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}🎉 DESTRUCTION COMPLETE!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠️  DESTRUCTION COMPLETED WITH WARNINGS${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 1
    fi
}

# Run main function
main "$@"






