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
    
    # Verify AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS credentials not configured or invalid"
        log_error "Please configure AWS credentials and try again"
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

# Get AWS account ID
get_aws_account_id() {
    aws sts get-caller-identity --query Account --output text 2>/dev/null || {
        log_error "Failed to get AWS account ID. Check your AWS credentials."
        exit 1
    }
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
            terraform_cluster_name=$(terraform output -raw cluster_name 2>/dev/null | grep -v "Warning:" | head -1 || echo "")
            cd - >/dev/null
            
            if [ -n "$terraform_cluster_name" ] && [ "$terraform_cluster_name" != "╷" ]; then
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
                ((attempt++))
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
            ((attempt++))
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
                        ((modify_attempt++))
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
                        ((modify_attempt++))
                    else
                        log_warning "Modification failed: $error_output"
                        sleep 10
                        ((modify_attempt++))
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

cleanup_s3_buckets() {
    log_step "Cleaning up S3 buckets..."
    
    local buckets
    buckets=$(aws s3api list-buckets \
        --query "Buckets[?contains(Name, '$CLUSTER_NAME')].Name" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$buckets" ]; then
        for bucket in $buckets; do
            # Skip backup buckets - they should be preserved for restore operations
            if [[ "$bucket" == *"backup"* ]] || [[ "$bucket" == *"openemr-backups"* ]]; then
                log_info "Skipping backup bucket: $bucket (preserved for restore operations)"
                continue
            fi
            
            log_info "Processing bucket: $bucket"
            
            # Empty the bucket completely
            empty_s3_bucket "$bucket"
            
            # Delete the bucket
            aws s3api delete-bucket --bucket "$bucket" --no-cli-pager 2>/dev/null || log_warning "Failed to delete bucket: $bucket"
        done
        
        log_success "S3 buckets cleaned up (backup buckets preserved)"
    else
        log_info "No S3 buckets found"
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
    destroy_args+=("-var=cluster_name=$CLUSTER_NAME" "-var=aws_region=$AWS_REGION" "-no-color")
    
    # Retry logic for Terraform destroy (handles AWS API eventual consistency issues)
    local max_attempts=3
    local attempt=1
    local destroy_success=false
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Terraform destroy attempt $attempt/$max_attempts..."
        
        if terraform destroy "${destroy_args[@]}"; then
            log_success "Terraform destroy completed successfully"
            destroy_success=true
            
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
                ((attempt++))
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
    
    # Get AWS account ID for verification
    local aws_account_id
    aws_account_id=$(get_aws_account_id)
    
    # Get cluster name from Terraform or use default
    get_cluster_name
    
    log_info "AWS Account ID: $aws_account_id"
    log_info "AWS Region: $AWS_REGION"
    log_info "Cluster Name: $CLUSTER_NAME"
    log_info "Force Mode: $FORCE"
    
    # Execute cleanup steps - only handle critical issues that prevent terraform destroy
    check_prerequisites
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
    
    cleanup_s3_buckets
    cleanup_cloudwatch_logs
    
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






