#!/bin/bash

# =============================================================================
# AWS INFRASTRUCTURE CLEANUP SCRIPT
# =============================================================================
# This script handles AWS-level cleanup issues that prevent terraform destroy
# from working properly. It focuses on the problems that actually matter:
# - RDS deletion protection and snapshots
# - S3 bucket versioning issues
# - Orphaned AWS resources
# 
# Usage: ./scripts/destroy.sh [--force]
#
# Note: Kubernetes resources are automatically cleaned up when the EKS cluster
# is destroyed by terraform destroy. This script only handles AWS-level issues.

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
    
    local snapshots
    snapshots=$(aws rds describe-db-cluster-snapshots \
        --region "$AWS_REGION" \
        --query "DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, '$CLUSTER_NAME') && Status=='available' && SnapshotType=='manual'].DBClusterSnapshotIdentifier" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$snapshots" ]; then
        local snapshot_count
        snapshot_count=$(echo "$snapshots" | wc -w)
        log_info "Found $snapshot_count snapshots to delete"
        
        for snapshot_id in $snapshots; do
            # Clean up any whitespace around the snapshot ID
            snapshot_id=$(echo "$snapshot_id" | xargs)
            
            # Skip empty snapshot IDs
            if [ -z "$snapshot_id" ] || [ "$snapshot_id" = "" ]; then
                continue
            fi
            
            safe_aws "delete snapshot: $snapshot_id" \
                aws rds delete-db-cluster-snapshot \
                    --db-cluster-snapshot-identifier "$snapshot_id" \
                    --region "$AWS_REGION" \
                    --no-cli-pager
        done
        
        log_success "RDS snapshots cleaned up"
    else
        log_info "No RDS snapshots found"
    fi
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
            log_info "Configuring cluster for deletion: $cluster_id"
            
            # Disable deletion protection and set minimal backup retention
            aws rds modify-db-cluster \
                --db-cluster-identifier "$cluster_id" \
                --no-deletion-protection \
                --backup-retention-period 1 \
                --apply-immediately \
                --region "$AWS_REGION" \
                --no-cli-pager || log_warning "Failed to configure cluster for deletion: $cluster_id"
        done
        
        log_success "RDS deletion protection and automatic backups disabled"
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



# =============================================================================
# TERRAFORM CLEANUP
# =============================================================================

terraform_destroy() {
    log_step "Running Terraform destroy..."
    
    cd "$TERRAFORM_DIR"
    
    if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
        log_warning "No Terraform state found, skipping Terraform destroy"
        return 0
    fi
    
    # Initialize Terraform
    terraform init -upgrade -no-color
    
    # Destroy with force if requested
    local destroy_args=("-auto-approve")
    if [ "$FORCE" = true ]; then
        destroy_args+=("-refresh=false")
    fi
    destroy_args+=("-var=cluster_name=$CLUSTER_NAME" "-var=aws_region=$AWS_REGION" "-no-color")
    
    terraform destroy "${destroy_args[@]}" || {
        log_warning "Terraform destroy failed, but continuing with manual cleanup"
    }
    
    log_success "Terraform destroy completed"
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
    disable_rds_deletion_protection
    cleanup_s3_buckets
    terraform_destroy
    
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






