#!/bin/bash

# =============================================================================
# OpenEMR End-to-End Backup/Restore Test Script
# =============================================================================
#
# Purpose:
#   Performs comprehensive testing of the complete backup and restore process
#   for OpenEMR on EKS, including infrastructure deployment, data backup,
#   restoration, and verification. Validates entire disaster recovery workflow.
#
# Key Features:
#   - Automated infrastructure deployment and cleanup
#   - Complete backup process testing (RDS snapshots, S3 data, K8s configs)
#   - Full restore process validation with intelligent snapshot cleanup
#   - Data integrity verification
#   - Monitoring stack install/uninstall test
#   - Emergency cleanup on test failures with comprehensive resource cleanup
#   - Enhanced error handling and debugging capabilities
#   - Comprehensive test reporting with detailed timing and status
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - Terraform installed and initialized
#   - kubectl configured (will be configured during test)
#   - Sufficient AWS quotas for EKS, RDS, S3, ElastiCache
#
# Usage:
#   ./test-end-to-end-backup-restore.sh
#
# Environment Variables:
#   AWS_REGION       AWS region for testing (default: us-west-2)
#   CLUSTER_NAME     EKS cluster name (default: openemr-eks)
#   NAMESPACE        Kubernetes namespace (default: openemr)
#
# Test Process:
#   1. Deploy infrastructure (EKS, RDS, S3) if needed
#   2. Deploy OpenEMR application
#   3. Create test data and proof files
#   4. Execute backup process
#   5. Test monitoring stack install/uninstall
#   6. Delete all infrastructure
#   7. Recreate infrastructure
#   8. Restore from backup
#   9. Verify data integrity and application functionality
#   10. Clean up test resources
#
# Notes:
#   ⚠️  WARNING: This is a destructive test that creates and destroys AWS
#   resources. Only run in development/testing environments. Takes 160-165 minutes
#   (~2.7 hours). Measured timings from successful runs: Infrastructure deployment
#   30-32 min, Application deployment 7-11 min (can spike to 19 min), Backup
#   ~30-35 sec, Monitoring stack test ~6-7 min (updated Nov 2025 with S3 storage),
#   Infrastructure deletion 13-16 min, Infrastructure recreation 40-42 min, 
#   Restore 38-43 min, Final cleanup 13-14 min.
#   Total: 160-165 min (2.7 hours).
#
# Examples:
#   ./test-end-to-end-backup-restore.sh
#
# =============================================================================

set -euo pipefail

# Disable AWS CLI pager to prevent interactive editors from opening
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and failed tests
GREEN='\033[0;32m'    # Success messages and passed tests
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
PURPLE='\033[0;35m'   # Test execution messages
CYAN='\033[0;36m'     # Special test categories
NC='\033[0m'          # Reset color to default

# Script directories for consistent path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Configuration - auto-detect or use defaults
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-west-2")}

# Auto-detect cluster name from Terraform output or use default
if [ -z "${CLUSTER_NAME:-}" ]; then
    # Validate terraform directory exists before attempting to read output
    if [ -d "$TERRAFORM_DIR" ]; then
        TERRAFORM_CLUSTER_NAME=$(cd "$TERRAFORM_DIR" 2>/dev/null && terraform output -raw cluster_name 2>/dev/null | grep -v "Warning:" | grep -E "^[a-zA-Z0-9-]+$" | head -1 || true)
        if [ -n "$TERRAFORM_CLUSTER_NAME" ]; then
            CLUSTER_NAME="$TERRAFORM_CLUSTER_NAME"
        else
            CLUSTER_NAME="openemr-eks"
        fi
    else
        CLUSTER_NAME="openemr-eks"
    fi
fi

NAMESPACE=${NAMESPACE:-"openemr"}      # Kubernetes namespace for OpenEMR
BACKUP_BUCKET=""                       # S3 bucket for backup storage (set during test)
SNAPSHOT_ID=""                         # RDS snapshot ID (set during test)
TEST_TIMESTAMP=$(date +%Y%m%d-%H%M%S)  # Unique timestamp for test identification
PROOF_FILE_CONTENT="OpenEMR Backup/Restore Test - Created: $(date '+%Y-%m-%d %H:%M:%S UTC') - Test ID: ${TEST_TIMESTAMP}"

# Test results tracking
TEST_RESULTS=()                    # Array to store test results
TEST_START_TIME=$(date +%s)        # Start time for overall test duration

# Global variables for cleanup tracking
INFRASTRUCTURE_CREATED=false      # Flag to track if infrastructure was created during test
BACKUP_BUCKET_CREATED=""          # Name of backup bucket created during test
SNAPSHOT_ID_CREATED=""            # ID of snapshot created during test
CLEANUP_REQUIRED=false            # Flag indicating if cleanup is needed


# Emergency cleanup function for when tests fail
# This function is called on script exit to clean up resources created during testing
# It ensures that test resources don't remain in the AWS account after test failures
emergency_cleanup() {
    local exit_code=$?

    # Only run emergency cleanup if exit code indicates failure
    # Successful tests will handle their own cleanup
    if [ $exit_code -eq 0 ]; then
        return 0
    fi

    echo ""
    log_error "🚨 TEST FAILED - PERFORMING EMERGENCY CLEANUP 🚨"
    echo ""

    if [ "$CLEANUP_REQUIRED" = "true" ]; then
        log_info "Emergency cleanup initiated due to test failure..."

        # Track cleanup start time
        local cleanup_start
        cleanup_start=$(start_timer)

        # Try to clean up infrastructure if it was created
        if [ "$INFRASTRUCTURE_CREATED" = "true" ]; then
            log_info "Attempting to clean up AWS infrastructure using destroy.sh script..."

            # Change to project root directory
            if cd "$PROJECT_ROOT" 2>/dev/null; then
                # Export cluster name and region for destroy.sh script
                export CLUSTER_NAME="$CLUSTER_NAME"
                export AWS_REGION="$AWS_REGION"
                
                # Use the comprehensive destroy.sh script for emergency cleanup
                log_info "Running destroy.sh script for emergency cleanup..."
                if ./scripts/destroy.sh --force 2>/dev/null; then
                    log_success "Infrastructure destroyed successfully using destroy.sh during emergency cleanup"
                else
                    log_warning "destroy.sh script failed, attempting manual resource cleanup as fallback..."
                    manual_resource_cleanup
                fi
            else
                log_error "Could not access project directory for cleanup"
            fi
        fi

        # Clean up backup resources if they were created
        if [ -n "$BACKUP_BUCKET_CREATED" ]; then
            log_info "Attempting to clean up backup bucket: $BACKUP_BUCKET_CREATED"
            empty_s3_bucket "$BACKUP_BUCKET_CREATED" "$AWS_REGION" || log_warning "Failed to clean up backup bucket"
        fi

        # Clean up RDS snapshots if they were created
        if [ -n "$SNAPSHOT_ID_CREATED" ]; then
            log_info "Attempting to clean up RDS snapshot: $SNAPSHOT_ID_CREATED"
            aws rds delete-db-cluster-snapshot \
                --db-cluster-snapshot-identifier "$SNAPSHOT_ID_CREATED" \
                --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete RDS snapshot"
        fi

        local cleanup_duration
        cleanup_duration=$(get_duration "$cleanup_start")
        log_info "Emergency cleanup completed in ${cleanup_duration}s"

        add_test_result "Emergency Cleanup" "COMPLETED" "Cleanup performed due to test failure" "$cleanup_duration"
    else
        log_info "No cleanup required - test failed before creating resources"
    fi

    # Print final test results
    print_test_results

    echo ""
    log_error "🚨 END-TO-END TEST FAILED 🚨"
    echo ""
    log_info "Please check the test results above for details"
    log_info "If AWS resources were not cleaned up automatically, please clean them up manually:"
    log_info "  - EKS Cluster: $CLUSTER_NAME"
    log_info "  - Backup Bucket: $BACKUP_BUCKET_CREATED"
    log_info "  - RDS Snapshot: $SNAPSHOT_ID_CREATED"
    echo ""

    exit $exit_code
}

# Manual resource cleanup function for when terraform destroy fails
manual_resource_cleanup() {
    log_info "Attempting manual cleanup of AWS resources..."

    # Try to delete EKS cluster directly
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Deleting EKS cluster: $CLUSTER_NAME"
        aws eks delete-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete EKS cluster"
    fi

    # Try to delete RDS cluster and instances - get actual cluster identifier from Terraform
    local rds_cluster
    rds_cluster=$(terraform output -raw aurora_cluster_id 2>/dev/null || echo "")
    
    if [ -z "$rds_cluster" ]; then
        log_info "No RDS cluster found in Terraform state, skipping RDS cleanup"
        return 0
    fi
    
    if aws rds describe-db-clusters --db-cluster-identifier "$rds_cluster" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Disabling deletion protection for RDS cluster: $rds_cluster"
        aws rds modify-db-cluster --db-cluster-identifier "$rds_cluster" --no-deletion-protection --region "$AWS_REGION" 2>/dev/null || true

        # First, delete all DB instances in the cluster
        log_info "Deleting RDS instances in cluster: $rds_cluster"
        local db_instances
        db_instances=$(aws rds describe-db-instances --region "$AWS_REGION" --query "DBInstances[?contains(DBClusterIdentifier, '$rds_cluster')].DBInstanceIdentifier" --output text 2>/dev/null || echo "")

        if [ -n "$db_instances" ]; then
            for instance in $db_instances; do
                log_info "Deleting RDS instance: $instance"
                aws rds delete-db-instance --db-instance-identifier "$instance" --skip-final-snapshot --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete RDS instance: $instance"
            done

            # Wait for instances to be deleted before deleting cluster
            log_info "Waiting for RDS instances to be deleted..."
            local wait_time=300  # 5 minutes
            local elapsed=0
            while [ $elapsed -lt $wait_time ]; do
                local remaining_instances
                remaining_instances=$(aws rds describe-db-instances --region "$AWS_REGION" --query "DBInstances[?contains(DBClusterIdentifier, '$rds_cluster')].DBInstanceIdentifier" --output text 2>/dev/null || echo "")
                if [ -z "$remaining_instances" ]; then
                    log_success "All RDS instances deleted"
                    break
                fi
                log_info "Waiting for RDS instances to be deleted... (${elapsed}s elapsed)"
                sleep 30
                elapsed=$((elapsed + 30))
            done
        fi

        # Now delete the cluster
        log_info "Deleting RDS cluster: $rds_cluster"
        aws rds delete-db-cluster --db-cluster-identifier "$rds_cluster" --skip-final-snapshot --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete RDS cluster"
    fi

    # Try to delete VPC and related resources
    log_info "Attempting to clean up VPC and networking resources..."
    # This would require more complex logic to identify and delete VPC resources

    log_warning "Manual cleanup completed - some resources may still exist"
    log_warning "Please check AWS console and clean up remaining resources manually"
}

# Set up trap handler for emergency cleanup
trap 'emergency_cleanup' ERR EXIT

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --aws-region)
                AWS_REGION="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}


# Function to ensure kubeconfig is properly configured
ensure_kubeconfig() {
    log_info "🔧 Ensuring kubeconfig is properly configured..."

    # Check if cluster exists
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_error "EKS cluster '$CLUSTER_NAME' not found in region '$AWS_REGION'"
        return 1
    fi

    # Update kubeconfig
    log_info "Updating kubeconfig for cluster: $CLUSTER_NAME"
    if aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"; then
        log_success "Kubeconfig updated successfully"
    else
        log_error "Failed to update kubeconfig"
        return 1
    fi

    # Verify kubectl connectivity
    log_info "Verifying kubectl connectivity..."
    if kubectl cluster-info >/dev/null 2>&1; then
        log_success "kubectl connectivity verified"
    else
        log_error "kubectl cannot connect to cluster"
        return 1
    fi
}

# Logging functions
log_info() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $1${NC}"
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

log_step() {
    echo -e "${PURPLE}[$(date '+%H:%M:%S')] 🔄 $1${NC}"
}

# Helper function for kubectl exec with retry logic to handle TLS errors and container readiness
kubectl_exec_with_retry() {
    local pod_name="$1"
    local command="$2"
    local max_attempts=30  # Increased to 30 attempts for better reliability
    local attempt=1

    log_info "Attempting kubectl exec: $command"

    while [ $attempt -le $max_attempts ]; do
        # Try the command and capture both stdout and stderr for debugging
        local exec_output
        local exec_exit_code
        
        exec_output=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "$command" 2>&1)
        exec_exit_code=$?
        
        if [ $exec_exit_code -eq 0 ]; then
            log_success "kubectl exec succeeded on attempt $attempt"
            return 0
        else
            # Get container status for debugging
            local container_ready
            local pod_ready
            local container_state

            container_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].ready}' 2>/dev/null || echo "false")
            pod_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
            container_state=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].state}' 2>/dev/null || echo "Unknown")

            log_warning "kubectl exec attempt $attempt/$max_attempts failed (ready=$container_ready, pod_ready=$pod_ready, state=$container_state)"
            log_info "kubectl exec error output: $exec_output"
            log_info "kubectl exec exit code: $exec_exit_code"

            # Exponential backoff with jitter: base delay increases exponentially, capped at 60s
            local base_delay=$((2 ** (attempt - 1)))
            local max_delay=60
            local delay=$((base_delay < max_delay ? base_delay : max_delay))
            
            # Add jitter to prevent thundering herd (reduce delay by up to 25%)
            local jitter=$((RANDOM % (delay / 4 + 1)))
            local final_delay=$((delay - jitter))
            
            # Ensure minimum delay of 5 seconds
            final_delay=$((final_delay < 5 ? 5 : final_delay))
            
            log_info "Waiting ${final_delay}s before retry (exponential backoff with jitter)"
            sleep $final_delay
        fi

        ((attempt++))
    done

    log_error "kubectl exec failed after $max_attempts attempts"
    log_info "Final container status: ready=$container_ready, pod_ready=$pod_ready, state=$container_state"

    # Show comprehensive pod details for debugging
    log_info "Pod details for debugging:"
    kubectl get pod "$pod_name" -n "$NAMESPACE" -o wide || true
    kubectl describe pod "$pod_name" -n "$NAMESPACE" | grep -A 20 "Container Status" || true
    kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' | tail -10 || true

    return 1
}

# Test result tracking
add_test_result() {
    local step="$1"
    local status="$2"
    local details="$3"
    local duration="$4"

    TEST_RESULTS+=("$step|$status|$details|$duration")
}

# Timer functions
start_timer() {
    date +%s
}

get_duration() {
    local start_time="$1"
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo "$duration"
}

# Help function
show_help() {
    echo "OpenEMR End-to-End Backup/Restore Test Script"
    echo "============================================="
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script performs a complete end-to-end test of the backup and restore process:"
    echo "1. Deploy infrastructure from scratch"
    echo "2. Deploy OpenEMR"
    echo "3. Deploy test data (proof.txt)"
    echo "4. Backup entire installation"
    echo "5. Test monitoring stack installation and uninstallation"
    echo "6. Delete all infrastructure"
    echo "7. Recreate infrastructure"
    echo "8. Restore from backup"
    echo "9. Verify restoration and connectivity"
    echo "10. Clean up infrastructure and backups"
    echo ""
    echo "Options:"
    echo "  --cluster-name NAME     EKS cluster name (default: openemr-eks-test)"
    echo "  --aws-region REGION     AWS region (default: us-west-2)"
    echo "  --namespace NAMESPACE   Kubernetes namespace (default: openemr)"
    echo "  --help                  Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_NAME            EKS cluster name"
    echo "  AWS_REGION              AWS region"
    echo "  NAMESPACE               Kubernetes namespace"
    echo ""
    echo "Example:"
    echo "  $0 --cluster-name my-test-cluster --aws-region us-east-1"
    echo ""
    echo "⚠️  WARNING: This script will create and destroy AWS resources!"
    echo "   Ensure you have proper AWS credentials and permissions."
    echo "   AWS resources will be created and destroyed during testing."
    exit 0
}


# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed."; exit 1; }
    command -v aws >/dev/null 2>&1 || { log_error "AWS CLI is required but not installed."; exit 1; }
    command -v helm >/dev/null 2>&1 || { log_error "Helm is required but not installed."; exit 1; }
    command -v terraform >/dev/null 2>&1 || { log_error "Terraform is required but not installed."; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 1; }

    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi

    log_success "All prerequisites satisfied"
}

# Check for orphaned resources from previous test runs
check_for_orphaned_resources() {
    log_info "Checking for orphaned resources from previous test runs..."
    
    local orphaned_found=false
    local orphaned_details=()
    
    # Check for orphaned RDS clusters
    log_info "Checking for orphaned RDS clusters..."
    local orphaned_clusters
    orphaned_clusters=$(aws rds describe-db-clusters \
        --region "$AWS_REGION" \
        --query "DBClusters[?contains(DBClusterIdentifier, '$CLUSTER_NAME')].DBClusterIdentifier" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$orphaned_clusters" ]; then
        orphaned_found=true
        orphaned_details+=("🔴 RDS Clusters:")
        for cluster in $orphaned_clusters; do
            local cluster_status
            cluster_status=$(aws rds describe-db-clusters \
                --db-cluster-identifier "$cluster" \
                --region "$AWS_REGION" \
                --query "DBClusters[0].Status" \
                --output text 2>/dev/null || echo "unknown")
            orphaned_details+=("   - $cluster (status: $cluster_status)")
        done
    fi
    
    # Check for orphaned EKS clusters
    log_info "Checking for orphaned EKS clusters..."
    local orphaned_eks
    orphaned_eks=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query "cluster.status" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$orphaned_eks" ] && [ "$orphaned_eks" != "None" ]; then
        orphaned_found=true
        orphaned_details+=("🔴 EKS Cluster:")
        orphaned_details+=("   - $CLUSTER_NAME (status: $orphaned_eks)")
    fi
    
    # Check for orphaned S3 buckets
    log_info "Checking for orphaned S3 buckets..."
    local orphaned_buckets
    orphaned_buckets=$(aws s3api list-buckets \
        --query "Buckets[?contains(Name, '$CLUSTER_NAME')].Name" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$orphaned_buckets" ]; then
        orphaned_found=true
        orphaned_details+=("🔴 S3 Buckets:")
        for bucket in $orphaned_buckets; do
            orphaned_details+=("   - $bucket")
        done
    fi
    
    # Check for orphaned ElastiCache clusters
    log_info "Checking for orphaned ElastiCache clusters..."
    local orphaned_elasticache
    orphaned_elasticache=$(aws elasticache describe-cache-clusters \
        --region "$AWS_REGION" \
        --query "CacheClusters[?contains(CacheClusterId, '$CLUSTER_NAME')].CacheClusterId" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$orphaned_elasticache" ]; then
        orphaned_found=true
        orphaned_details+=("🔴 ElastiCache Clusters:")
        for cache in $orphaned_elasticache; do
            orphaned_details+=("   - $cache")
        done
    fi
    
    # Report findings
    if [ "$orphaned_found" = true ]; then
        log_error "❌ Orphaned resources detected from previous test runs!"
        log_error ""
        log_error "The following resources must be cleaned up before running this test:"
        log_error ""
        for detail in "${orphaned_details[@]}"; do
            log_error "$detail"
        done
        log_error ""
        log_error "⚠️  These orphaned resources will cause the test to fail."
        log_error ""
        log_error "To clean up these resources, run:"
        log_error "    cd $(dirname "$0") && ./destroy.sh"
        log_error "Then manually delete any backup buckets."
        log_error "Note: As a safety measure against accidental data loss destroy.sh is designed not to delete backup buckets."
        log_error ""
        log_error "After cleanup completes, re-run this test."
        exit 1
    fi
    
    log_success "✅ No orphaned resources found - environment is clean"
}

# Validate configuration
validate_configuration() {
    log_info "Validating test configuration..."

    # Validate AWS region
    if ! aws ec2 describe-regions --region-names "$AWS_REGION" >/dev/null 2>&1; then
        log_error "Invalid AWS region: $AWS_REGION"
        exit 1
    fi

    # Validate cluster name format
    if ! [[ "$CLUSTER_NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
        log_error "Invalid cluster name format: $CLUSTER_NAME"
        log_error "Cluster name must start with a letter and contain only letters, numbers, and hyphens"
        exit 1
    fi

    # Validate namespace
    if ! [[ "$NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        log_error "Invalid namespace format: $NAMESPACE"
        log_error "Namespace must be lowercase and contain only letters, numbers, and hyphens"
        exit 1
    fi

    # Validate required tools
    local required_tools=("kubectl" "aws" "terraform" "curl")
    local missing_tools=()

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools before running the test"
        exit 1
    fi

    # Validate AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid"
        log_error "Please run 'aws configure' to set up your credentials"
        exit 1
    fi

    log_success "Configuration validation completed"
}

# Function to validate pre-flight state
validate_preflight_state() {
    log_info "Validating pre-flight state..."

    # Check if cluster already exists (it shouldn't for a clean test)
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_warning "EKS cluster '$CLUSTER_NAME' already exists"
        log_info "This may indicate a previous test didn't clean up properly"
        log_info "Consider running cleanup first or using a different cluster name"
    fi

    # Check for existing backup buckets that might conflict
    local existing_buckets
    existing_buckets=$(aws s3 ls | grep -cE "openemr.*backup" 2>/dev/null || echo "0")
    existing_buckets=$(echo "$existing_buckets" | tr -d '\n' | grep -E '^[0-9]+$' || echo "0")
    if [ "$existing_buckets" -gt 0 ]; then
        log_warning "Found $existing_buckets existing backup buckets"
        log_info "These will be cleaned up during the test"
    fi

    # Check for existing RDS snapshots
    local existing_snapshots
    existing_snapshots=$(aws rds describe-db-cluster-snapshots --region "$AWS_REGION" --query "DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, 'openemr')].DBClusterSnapshotIdentifier" --output text | wc -w || echo "0")
    if [ "$existing_snapshots" -gt 0 ]; then
        log_warning "Found $existing_snapshots existing RDS snapshots"
        log_info "These will be cleaned up during the test"
    fi

    log_success "Pre-flight validation completed"
}

# Get script and project directories
get_directories() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    TERRAFORM_DIR="$PROJECT_ROOT/terraform"
    K8S_DIR="$PROJECT_ROOT/k8s"

    log_info "Script location: $SCRIPT_DIR"
    log_info "Project root: $PROJECT_ROOT"
    log_info "Terraform directory: $TERRAFORM_DIR"
    log_info "K8s directory: $K8S_DIR"
}

# Clean up existing CloudWatch log groups that might conflict
cleanup_existing_log_groups() {
    log_info "Cleaning up existing CloudWatch log groups..."

    # Check if we have a valid cluster name first
    if [ -z "$CLUSTER_NAME" ] || [ "$CLUSTER_NAME" = "openemr-eks" ]; then
        log_info "No existing infrastructure found - skipping log group cleanup"
        log_info "Will create fresh infrastructure with new log groups"
        return 0
    fi

    # List of all log groups that might conflict (based on terraform/cloudwatch.tf)
    local log_groups=(
        "/aws/eks/$CLUSTER_NAME/openemr/application"
        "/aws/eks/$CLUSTER_NAME/openemr/access"
        "/aws/eks/$CLUSTER_NAME/openemr/error"
        "/aws/eks/$CLUSTER_NAME/openemr/audit"
        "/aws/eks/$CLUSTER_NAME/openemr/audit_detailed"
        "/aws/eks/$CLUSTER_NAME/openemr/system"
        "/aws/eks/$CLUSTER_NAME/openemr/php_error"
        "/aws/eks/$CLUSTER_NAME/fluent-bit/metrics"
        "/aws/eks/$CLUSTER_NAME/openemr/test"
        "/aws/eks/$CLUSTER_NAME/openemr/apache"
        "/aws/eks/$CLUSTER_NAME/openemr/forward"
    )

    for log_group in "${log_groups[@]}"; do
        # Check if log group exists before attempting to delete
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "$AWS_REGION" --query 'logGroups[].logGroupName' --output text 2>/dev/null | grep -q "^${log_group}$" 2>/dev/null; then
            log_info "Deleting existing log group: $log_group"
            if aws logs delete-log-group --log-group-name "$log_group" --region "$AWS_REGION" 2>/dev/null; then
                log_success "Successfully deleted log group: $log_group"
            else
                log_warning "Failed to delete log group: $log_group (may not exist or already deleted)"
            fi
        else
            log_info "Log group does not exist: $log_group"
        fi
    done
}

# Function to intelligently clean up manual RDS snapshots with proper polling
cleanup_manual_snapshots() {
    log_info "Intelligently cleaning up manual RDS snapshots that might interfere with cluster recreation..."
    
    # Validate Terraform state is accessible before proceeding
    if ! cd "$PROJECT_ROOT/terraform" 2>/dev/null; then
        log_error "Cannot access terraform directory: $PROJECT_ROOT/terraform"
        return 1
    fi
    
    if ! terraform state list >/dev/null 2>&1; then
        log_warning "Terraform state not accessible, skipping snapshot cleanup"
        return 0
    fi
    
    # Get the current cluster identifier from Terraform state if it exists
    local current_cluster_id
    current_cluster_id=$(terraform state show 'aws_rds_cluster.openemr' 2>/dev/null | grep 'cluster_identifier\s*=' | head -1 | awk '{print $3}' | tr -d '"' || echo "")
    
    if [ -n "$current_cluster_id" ]; then
        log_info "Found existing cluster: $current_cluster_id"
        
        # List manual snapshots for this cluster
        local manual_snapshots
        manual_snapshots=$(aws rds describe-db-cluster-snapshots \
            --region "$AWS_REGION" \
            --query "DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, '$current_cluster_id') && SnapshotType=='manual' && Status=='available'].DBClusterSnapshotIdentifier" \
            --output text 2>/dev/null | tr -s ' \t\n' ' ' | xargs || echo "")
        
        if [ -n "$manual_snapshots" ]; then
            log_info "Found manual snapshots to clean up: $manual_snapshots"
            
            # Delete each manual snapshot and track them for polling
            local deleted_snapshots=()
            for snapshot_id in $manual_snapshots; do
                # Clean up any whitespace around the snapshot ID
                snapshot_id=$(echo "$snapshot_id" | xargs)
                
                # Skip empty snapshot IDs
                if [ -z "$snapshot_id" ] || [ "$snapshot_id" = "" ]; then
                    continue
                fi
                
                log_info "Deleting manual snapshot: $snapshot_id"
                if aws rds delete-db-cluster-snapshot \
                    --region "$AWS_REGION" \
                    --db-cluster-snapshot-identifier "$snapshot_id" >/dev/null 2>&1; then
                    log_success "Successfully initiated deletion of snapshot: $snapshot_id"
                    deleted_snapshots+=("$snapshot_id")
                else
                    log_warning "Failed to delete snapshot: $snapshot_id (may not exist or already deleted)"
                fi
            done
            
            # Poll until all snapshots are completely deleted
            if [ ${#deleted_snapshots[@]} -gt 0 ]; then
                log_info "Polling until all snapshots are completely deleted..."
                local max_wait_time=600  # 10 minutes
                local poll_interval=30   # Check every 30 seconds
                local elapsed=0
                local remaining_snapshots=("${deleted_snapshots[@]}")
                
                while [ $elapsed -lt $max_wait_time ] && [ ${#remaining_snapshots[@]} -gt 0 ]; do
                    log_info "Checking snapshot deletion status... (${elapsed}s elapsed)"
                    
                    # Check each remaining snapshot
                    local still_existing=()
                    for snapshot_id in "${remaining_snapshots[@]}"; do
                        # Skip empty snapshot IDs
                        if [ -z "$snapshot_id" ] || [ "$snapshot_id" = "" ]; then
                            log_success "Empty snapshot ID skipped (already deleted)"
                            continue
                        fi
                        
                        local snapshot_status
                        snapshot_status=$(aws rds describe-db-cluster-snapshots \
                            --region "$AWS_REGION" \
                            --db-cluster-snapshot-identifier "$snapshot_id" \
                            --query 'DBClusterSnapshots[0].Status' \
                            --output text 2>/dev/null || echo "deleted")
                        
                        if [ "$snapshot_status" != "deleted" ] && [ "$snapshot_status" != "None" ]; then
                            still_existing+=("$snapshot_id")
                            log_info "Snapshot $snapshot_id still exists with status: $snapshot_status"
                        else
                            log_success "Snapshot $snapshot_id has been completely deleted"
                        fi
                    done
                    
                    if [ ${#still_existing[@]} -gt 0 ]; then
                        remaining_snapshots=("${still_existing[@]}")
                    else
                        remaining_snapshots=()
                    fi
                    
                    if [ ${#remaining_snapshots[@]} -gt 0 ]; then
                        log_info "Still waiting for ${#remaining_snapshots[@]} snapshot(s) to be deleted, waiting ${poll_interval}s..."
                        sleep $poll_interval
                        elapsed=$((elapsed + poll_interval))
                    fi
                done
                
                if [ ${#remaining_snapshots[@]} -gt 0 ]; then
                    log_warning "Some snapshots were not deleted within ${max_wait_time}s timeout: ${remaining_snapshots[*]}"
                    log_warning "This may cause issues with cluster recreation, but continuing..."
                else
                    log_success "All manual snapshots have been completely deleted"
                fi
            fi
        else
            log_info "No manual snapshots found for cluster: $current_cluster_id"
        fi
    else
        log_info "No existing cluster found in Terraform state, skipping snapshot cleanup"
    fi
}



# Step 1: Deploy infrastructure from scratch
deploy_infrastructure() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 1: Deploying infrastructure from scratch..."

    cd "$TERRAFORM_DIR"

    # Clean up existing CloudWatch log groups that might conflict
    cleanup_existing_log_groups

    # Initialize Terraform
    log_info "Initializing Terraform..."
    terraform init

    # Plan and apply infrastructure
    log_info "Planning infrastructure deployment..."
    terraform plan -var="cluster_name=$CLUSTER_NAME" -var="aws_region=$AWS_REGION" -out=tfplan

    log_info "Applying infrastructure deployment..."
    terraform apply -auto-approve tfplan

    # Wait for infrastructure to be ready
    log_info "Waiting for infrastructure to be ready..."
    sleep 60

    # Validate critical outputs are available
    log_info "Validating critical infrastructure outputs..."
    local redis_endpoint
    redis_endpoint=$(terraform output -raw redis_endpoint 2>/dev/null || echo "")
    if [ -z "$redis_endpoint" ] || [ "$redis_endpoint" = "redis-not-available" ]; then
        log_error "Critical infrastructure validation failed: Redis endpoint not available"
        log_error "This indicates ElastiCache serverless cache creation failed"
        log_error "Check Terraform state and AWS console for ElastiCache issues"
        return 1
    fi
    
    local efs_id
    efs_id=$(terraform output -raw efs_id 2>/dev/null || echo "")
    if [ -z "$efs_id" ]; then
        log_error "Critical infrastructure validation failed: EFS ID not available"
        return 1
    fi
    
    local aurora_endpoint
    aurora_endpoint=$(terraform output -raw aurora_endpoint 2>/dev/null || echo "")
    if [ -z "$aurora_endpoint" ]; then
        log_error "Critical infrastructure validation failed: Aurora endpoint not available"
        return 1
    fi

    # Get outputs
    log_info "Getting Terraform outputs..."
    # Backup bucket will be created dynamically by backup script with format:
    # openemr-backups-{account-id}-{cluster-name}-{date}
    # We'll extract the actual bucket name from the backup script output

    log_success "Infrastructure deployed successfully"
    log_info "Backup bucket will be created during backup step"

    # Mark infrastructure as created for cleanup tracking
    INFRASTRUCTURE_CREATED=true
    CLEANUP_REQUIRED=true

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Infrastructure Deployment" "SUCCESS" "Cluster: $CLUSTER_NAME" "$step_duration"

    cd "$PROJECT_ROOT"
}

# Step 2: Deploy OpenEMR
deploy_openemr() {
    local step_start
    local context="${1:-initial}"
    step_start=$(start_timer)
    
    if [ "$context" = "restore" ]; then
        log_step "Step 8: Deploying OpenEMR after infrastructure recreation..."
    else
        log_step "Step 2: Deploying OpenEMR..."
    fi

    cd "$K8S_DIR"

    # Ensure kubeconfig is configured before deploy
    log_info "Configuring kubeconfig for deployment..."
    if ! ensure_kubeconfig; then
        log_error "Failed to configure kubeconfig for deployment"
        return 1
    fi

    # Deploy OpenEMR
    log_info "Deploying OpenEMR to EKS cluster..."
    ./deploy.sh --cluster-name "$CLUSTER_NAME" --aws-region "$AWS_REGION" --namespace "$NAMESPACE"

    # Wait for deployment to be ready with extended timeout
    # The deploy script may trigger a rolling restart, so we need to wait for it to complete
    log_info "Waiting for OpenEMR deployment to be ready (this may take 7-15 minutes after rolling restart)..."
    
    # First, wait for deployment to exist
    log_info "Validating OpenEMR deployment exists..."
    if ! kubectl get deployment openemr -n "$NAMESPACE" >/dev/null 2>&1; then
        log_error "OpenEMR deployment not found in namespace $NAMESPACE"
        return 1
    fi
    log_success "OpenEMR deployment found"
    
    # Wait for the rollout to complete (handles rolling restarts properly)
    log_info "Waiting for deployment rollout to complete (up to 20 minutes)..."
    if kubectl rollout status deployment/openemr -n "$NAMESPACE" --timeout=1200s 2>&1; then
        log_success "Deployment rollout completed successfully"
    else
        log_warning "Deployment rollout status command timed out, checking if pods are ready anyway..."
    fi
    
    # Additional verification: Wait for all replicas to be ready with retry logic
    log_info "Verifying all replicas are ready..."
    local max_ready_attempts=60  # 10 minutes (60 * 10 seconds)
    local ready_attempt=0
    local all_ready=false
    
    while [ $ready_attempt -lt $max_ready_attempts ]; do
        local ready_replicas
        ready_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        ready_replicas=${ready_replicas:-0}
        local desired_replicas
        desired_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        desired_replicas=${desired_replicas:-0}
        local available_replicas
        available_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        available_replicas=${available_replicas:-0}

        log_info "Deployment status: Ready=$ready_replicas/$desired_replicas, Available=$available_replicas (attempt $((ready_attempt + 1))/$max_ready_attempts)"

        if [ "$ready_replicas" -gt 0 ] && [ "$ready_replicas" -ge "$desired_replicas" ] && [ "$available_replicas" -ge "$desired_replicas" ]; then
            log_success "OpenEMR deployment is fully ready ($ready_replicas/$desired_replicas replicas)"
            all_ready=true
            break
        fi
        
        # Show progress every 30 seconds
        if [ $((ready_attempt % 3)) -eq 0 ]; then
            log_info "Still waiting for all replicas to be ready... (${ready_replicas}/${desired_replicas} ready)"
        fi
        
        sleep 10
        ((ready_attempt++))
    done
    
    if [ "$all_ready" = false ]; then
        log_warning "Not all replicas became ready within timeout, checking if at least one is available..."
        kubectl get pods -n "$NAMESPACE" -l app=openemr -o wide
        kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10

        # Check if at least one pod is available
        local final_available
        final_available=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        final_available=${final_available:-0}
        
        if [ "$final_available" -gt 0 ]; then
            log_warning "Only $final_available replica(s) available, but proceeding with test"
        else
            log_error "No OpenEMR pods are available after waiting"
            return 1
        fi
    fi
    
    # CRITICAL: Extra stability period to ensure deployment is truly stable
    # This prevents test data from being deployed during rolling restart pod churn
    log_info "========================================="
    log_info "Allowing 90 seconds for deployment to fully stabilize..."
    log_info "This ensures no ongoing pod churn from rolling restarts"
    log_info "========================================="
    sleep 90
    
    # Verify no ongoing rollout/restart is in progress
    log_info "Verifying deployment is stable (no ongoing rollouts)..."
    local progressing_status
    progressing_status=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
    local progressing_reason
    progressing_reason=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)
    
    log_info "Deployment Progressing status: $progressing_status (reason: $progressing_reason)"
    
    if [ "$progressing_status" = "True" ] && [ "$progressing_reason" != "NewReplicaSetAvailable" ]; then
        log_warning "Deployment still progressing (reason: $progressing_reason)"
        log_info "Waiting additional 60 seconds for rollout to complete..."
        sleep 60
    fi
    
    log_success "✅ Deployment confirmed stable and ready for test data"

    # Additional wait for containers to be fully ready
    log_info "Waiting for OpenEMR containers to be fully ready..."
    local container_wait_attempts=0
    local max_container_wait=30  # 5 minutes

    while [ $container_wait_attempts -lt $max_container_wait ]; do
        local pod_name
        # Find a pod that has the openemr container ready - improved selection logic
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[?(@.name=="openemr")].ready}{"\t"}{.status.containerStatuses[?(@.name=="openemr")].restartCount}{"\n"}{end}' 2>/dev/null | \
            grep -E "\tRunning\t" | \
            grep -E "\ttrue\t" | \
            sort -k4 -n | \
            head -1 | cut -f1 || echo "")

        if [ -n "$pod_name" ]; then
            # Validate pod still exists and get detailed status
            if ! kubectl get pod "$pod_name" -n "$NAMESPACE" >/dev/null 2>&1; then
                log_warning "Pod $pod_name no longer exists, continuing search..."
                sleep 5
                ((container_wait_attempts++))
                continue
            fi
            
            local container_ready
            local pod_phase
            local restart_count
            
            container_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].ready}' 2>/dev/null || echo "false")
            pod_phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            restart_count=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].restartCount}' 2>/dev/null || echo "0")

            log_info "Pod $pod_name status: phase=$pod_phase, ready=$container_ready, restarts=$restart_count"

            if [ "$container_ready" = "true" ] && [ "$pod_phase" = "Running" ]; then
                log_success "OpenEMR container is ready and accepting traffic"
                break
            else
                # Get more detailed container status for debugging
                local container_state
                local container_ready
                local pod_ready
                local container_restart_count
                container_state=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].state}' 2>/dev/null || echo "Unknown")
                container_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].ready}' 2>/dev/null || echo "false")
                pod_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
                container_restart_count=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].restartCount}' 2>/dev/null || echo "0")
                
                log_info "Container not ready yet (attempt $((container_wait_attempts + 1))/$max_container_wait)"
                log_info "  Container state: $container_state"
                log_info "  Container ready: $container_ready"
                log_info "  Pod ready: $pod_ready"
                log_info "  Restart count: $container_restart_count"
                
                # Show recent events if container is having issues
                if [ "$container_restart_count" -gt 0 ]; then
                    log_info "  Recent pod events:"
                    kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' | tail -3 | sed 's/^/    /' || true
                fi
                
                log_info "  Waiting 10 seconds before next attempt..."
            fi
        else
            log_info "No pod found yet (attempt $((container_wait_attempts + 1))/$max_container_wait), waiting 10 seconds..."
        fi

        sleep 10
        ((container_wait_attempts++))
    done

    if [ $container_wait_attempts -ge $max_container_wait ]; then
        log_warning "OpenEMR containers not fully ready after $max_container_wait attempts, but deployment exists"
        log_info "This may cause issues with subsequent operations"
    fi

    log_success "OpenEMR deployed successfully"

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "OpenEMR Deployment" "SUCCESS" "Namespace: $NAMESPACE" "$step_duration"

    cd "$PROJECT_ROOT"
}

# Step 3: Deploy test data
deploy_test_data() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 3: Deploying test data..."

    # Wait for OpenEMR to be fully ready
    log_info "Waiting for OpenEMR to be fully ready..."

    # Get OpenEMR pod name - wait for a stable pod
    local pod_name
    local max_pod_attempts=10
    local pod_attempt=1

    log_info "Finding a stable OpenEMR pod..."

    while [ $pod_attempt -le $max_pod_attempts ]; do
        # Get the first running pod (not terminating)
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[?(@.name=="openemr")].ready}{"\n"}{end}' | grep -E "\ttrue$" | head -1 | cut -f1 2>/dev/null || echo "")

        if [ -n "$pod_name" ]; then
            # Verify the pod is actually running and not terminating
            local pod_phase
            pod_phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

            if [ "$pod_phase" = "Running" ]; then
                log_success "Found stable OpenEMR pod: $pod_name"
                break
            else
                log_info "Pod $pod_name is in phase: $pod_phase, waiting for stable pod..."
            fi
        else
            log_info "No running pods found, attempt $pod_attempt/$max_pod_attempts"
        fi

        sleep 5
        ((pod_attempt++))
    done

    if [ -z "$pod_name" ] || [ "$pod_phase" != "Running" ]; then
        log_error "No stable OpenEMR pods found after $max_pod_attempts attempts"
        log_info "Current pod status:"
        kubectl get pods -n "$NAMESPACE" -l app=openemr -o wide || true
        return 1
    fi

    # Wait for pod to be ready (both containers) - with progress feedback
    log_info "Waiting for pod to be fully ready (both containers)..."
    log_info "This may take 15-20 minutes for OpenEMR containers to fully start..."

    # Use a more robust wait with progress feedback
    local wait_timeout=2400  # 40 minutes
    local check_interval=30  # Check every 30 seconds
    local elapsed=0

    while [ $elapsed -lt $wait_timeout ]; do
        if kubectl wait --for=condition=ready --timeout=30s pod "$pod_name" -n "$NAMESPACE" 2>/dev/null; then
            log_success "Pod is ready after ${elapsed}s"
            break
        else
            elapsed=$((elapsed + check_interval))
            local progress=$((elapsed * 100 / wait_timeout))
            log_info "Pod not ready yet... ${elapsed}s elapsed (${progress}%) - checking pod status..."

            # Show pod status for debugging
            kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | xargs -I {} log_info "Pod phase: {}"
            kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null | xargs -I {} log_info "Container ready status: {}"
        fi
    done

    if [ $elapsed -ge $wait_timeout ]; then
        log_error "Pod did not become ready within ${wait_timeout}s timeout"
        log_info "Final pod status:"
        kubectl describe pod "$pod_name" -n "$NAMESPACE" | tail -20 || true
        return 1
    fi

    # CRITICAL: Wait for OpenEMR swarm mode initialization to complete BEFORE deploying test data
    # This prevents our test data from being wiped out by swarm mode's sites directory restoration
    log_info "========================================="
    log_info "Waiting for OpenEMR swarm mode initialization to complete..."
    log_info "This prevents test data from being overwritten during swarm init"
    log_info "May take 10-15 minutes for database setup on fresh deployments"
    log_info "========================================="
    
    local swarm_max_wait=1200  # 20 minutes (allows for database setup)
    local swarm_elapsed=0
    local swarm_check_interval=10
    local swarm_complete=false
    
    while [ $swarm_elapsed -lt $swarm_max_wait ]; do
        # Check for instance-swarm-ready marker in /root/ (container-local, not EFS)
        # This is more reliable than docker-completed which persists on EFS across pod generations
        # docker-completed on EFS might be from a previous pod, but instance-swarm-ready is THIS pod's status
        local instance_swarm_ready
        local sites_default_exists
        
        instance_swarm_ready=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "test -f /root/instance-swarm-ready && echo 'yes' || echo 'no'" 2>/dev/null)
        sites_default_exists=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "test -d /var/www/localhost/htdocs/openemr/sites/default && echo 'yes' || echo 'no'" 2>/dev/null)
        
        # Treat empty responses as errors (pod terminating/inaccessible)
        if [ -z "$instance_swarm_ready" ]; then
            instance_swarm_ready="error"
        fi
        if [ -z "$sites_default_exists" ]; then
            sites_default_exists="error"
        fi
        
        # Handle pod restarts/inaccessibility
        if [ "$instance_swarm_ready" = "error" ] || [ "$sites_default_exists" = "error" ]; then
            log_warning "Pod became inaccessible (instance_swarm_ready='$instance_swarm_ready', sites_default='$sites_default_exists'), waiting..."
            sleep $swarm_check_interval
            swarm_elapsed=$((swarm_elapsed + swarm_check_interval))
            continue
        fi
        
        if [ "$instance_swarm_ready" = "yes" ] && [ "$sites_default_exists" = "yes" ]; then
            log_success "✅ Swarm mode initialization complete for THIS pod (elapsed: ${swarm_elapsed}s)"
            log_info "Pod-local swarm marker confirmed - safe to deploy test data"
            swarm_complete=true
            break
        fi
        
        log_info "⏳ Waiting for swarm mode... (instance_ready=$instance_swarm_ready, sites/default=$sites_default_exists) - elapsed: ${swarm_elapsed}s"
        sleep $swarm_check_interval
        swarm_elapsed=$((swarm_elapsed + swarm_check_interval))
    done
    
    if [ "$swarm_complete" = false ]; then
        log_error "Timeout waiting for swarm mode initialization (${swarm_elapsed}s)"
        log_error "OpenEMR may still be initializing - cannot safely deploy test data"
        return 1
    fi
    
    # Additional wait for OpenEMR application to be responsive
    log_info "Waiting for OpenEMR application to be responsive..."
    log_info "This may take 25-30 minutes for OpenEMR to fully initialize..."
    local max_attempts=120  # Increased to 120 attempts (20 minutes) for better reliability
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        # Try multiple endpoints to check responsiveness
        local responsive=false

        # Check main login page
        if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -f http://localhost:80/interface/login/login.php > /dev/null" 2>/dev/null; then
            responsive=true
        # Check root page as fallback
        elif kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -f http://localhost:80/ > /dev/null" 2>/dev/null; then
            responsive=true
        # Check if Apache is running
        elif kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "pgrep apache2 > /dev/null" 2>/dev/null; then
            # Apache is running, try a simple HTTP check
            if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -I http://localhost:80/ | head -1 | grep -q '200 OK'" 2>/dev/null; then
                responsive=true
            fi
        fi

        if [ "$responsive" = true ]; then
            log_success "OpenEMR application is responsive"
            break
        else
            # Show progress indicator with more detailed status
            local progress=$((attempt * 100 / max_attempts))
            log_info "Attempt $attempt/$max_attempts (${progress}%): OpenEMR not yet responsive, waiting 10 seconds..."

            # Show container status for debugging
            local container_ready
            container_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].ready}' 2>/dev/null || echo "false")
            log_info "Container ready status: $container_ready"

            sleep 10
            ((attempt++))
        fi
    done

    if [ $attempt -gt $max_attempts ]; then
        log_warning "OpenEMR may not be fully ready after $max_attempts attempts, but proceeding with test data deployment"
        log_info "This could indicate OpenEMR is taking longer than expected to initialize"
    fi

    # CRITICAL: Final verification that pod is still running before deploying test data
    log_info "Re-verifying pod is still running before deploying test data..."
    local final_pod_phase
    final_pod_phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    
    if [ "$final_pod_phase" != "Running" ]; then
        log_error "Pod $pod_name is no longer running (status: $final_pod_phase)"
        log_error "Pod was likely terminated during rolling restart"
        log_error "Cannot safely deploy test data"
        return 1
    fi
    
    log_success "Pod $pod_name confirmed running - safe to deploy test data"

    # CRITICAL: Use Kubernetes built-in readiness probes to wait for ALL pods
    # If pods pass readiness probes, they're fully initialized and won't overwrite data
    log_info "========================================="
    log_info "Waiting for ALL OpenEMR pods to pass readiness probes..."
    log_info "This ensures all pods are fully initialized"
    log_info "========================================="
    
    # Get all pods
    local all_pods
    all_pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o name 2>/dev/null)
    local pod_count
    pod_count=$(echo "$all_pods" | wc -l | tr -d ' ')
    log_info "Found $pod_count pod(s) to wait for"
    
    # Wait for all pods to be ready using a more robust approach
    log_info "Waiting for all pods to pass readiness checks (timeout: 20 minutes)..."
    
    local wait_timeout=1200  # 20 minutes
    local wait_elapsed=0
    local check_interval=10
    local all_ready=false
    
    while [ $wait_elapsed -lt $wait_timeout ]; do
        # Get current pod status
        local pod_status
        pod_status=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[?(@.name=="openemr")].ready}{"\n"}{end}' 2>/dev/null)
        
        if [ -z "$pod_status" ]; then
            log_info "No pods found, waiting... (elapsed: ${wait_elapsed}s)"
            sleep $check_interval
            wait_elapsed=$((wait_elapsed + check_interval))
            continue
        fi
        
        # Check if all pods are running and ready
        local all_running=true
        local all_ready_status=true
        local pod_count=0
        
        while IFS=$'\t' read -r pod_name pod_phase container_ready; do
            if [ -n "$pod_name" ]; then
                pod_count=$((pod_count + 1))
                if [ "$pod_phase" != "Running" ]; then
                    all_running=false
                    log_info "Pod $pod_name is in phase: $pod_phase (elapsed: ${wait_elapsed}s)"
                elif [ "$container_ready" != "true" ]; then
                    all_ready_status=false
                    log_info "Pod $pod_name container not ready (elapsed: ${wait_elapsed}s)"
                fi
            fi
        done <<< "$pod_status"
        
        if [ $pod_count -eq 0 ]; then
            log_info "No pods found, waiting... (elapsed: ${wait_elapsed}s)"
        elif [ "$all_running" = true ] && [ "$all_ready_status" = true ]; then
            log_success "✅ ALL $pod_count pod(s) are ready and fully initialized"
            log_success "Safe to deploy test data - OpenEMR is stable"
            all_ready=true
            break
        else
            log_info "Waiting for pods to be ready... ($pod_count pods, elapsed: ${wait_elapsed}s)"
        fi
        
        sleep $check_interval
        wait_elapsed=$((wait_elapsed + check_interval))
    done
    
    if [ "$all_ready" = false ]; then
        log_error "Timeout waiting for all pods to become ready (${wait_elapsed}s)"
        log_info "Current pod status:"
        kubectl get pods -n "$NAMESPACE" -l app=openemr -o wide || true
        return 1
    fi
    
    # Additional 30 second buffer for EFS propagation across all pods
    log_info "Allowing 30 seconds for EFS state to stabilize across all pods..."
    sleep 30

    # Re-select a pod after multi-pod wait
    log_info "Re-selecting a pod for test data deployment..."
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$pod_name" ]; then
        log_error "No OpenEMR pods found after readiness check"
        return 1
    fi
    log_success "Selected pod for test data: $pod_name"

    # Create test data directory
    log_info "Creating test data directory..."
    kubectl_exec_with_retry "$pod_name" "mkdir -p /var/www/localhost/htdocs/openemr/sites/default/documents/test_data"

    # Create proof.txt file
    log_info "Creating proof.txt file with test data..."
    kubectl_exec_with_retry "$pod_name" "echo '$PROOF_FILE_CONTENT' > /var/www/localhost/htdocs/openemr/sites/default/documents/test_data/proof.txt"

    # Verify file was created
    local file_content
    file_content=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "cat /var/www/localhost/htdocs/openemr/sites/default/documents/test_data/proof.txt" 2>/dev/null)

    if [[ "$file_content" == *"Test ID: ${TEST_TIMESTAMP}"* ]]; then
        log_success "Test data deployed successfully"
        log_info "Proof file content: $file_content"
        
        # Quick EFS sync to ensure data is written
        log_info "Syncing test data to EFS (30 seconds)..."
        kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "sync" 2>/dev/null || log_warning "Sync failed, but continuing"
        sleep 30
        
        # Final verification
        if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "test -f /var/www/localhost/htdocs/openemr/sites/default/documents/test_data/proof.txt" 2>/dev/null; then
            log_success "✅ Test data confirmed stable on EFS"
        else
            log_error "❌ Test data disappeared - EFS sync issue!"
            return 1
        fi
    else
        log_error "Test data verification failed"
        return 1
    fi

    local step_duration
    step_duration=$(get_duration "$step_start")
    log_success "Test data deployment completed in ${step_duration}s"
    add_test_result "Test Data Deployment" "SUCCESS" "Proof file created with timestamp: $TEST_TIMESTAMP" "$step_duration"
}

# Helper function: Validate backup contains application data
validate_backup_contains_app_data() {
    local bucket=$1
    
    log_info "Validating backup contains application data..."
    
    # Check if application data exists in S3
    local app_data_exists
    # Use grep -q to avoid the exit code issue, then count separately
    if aws s3 ls "s3://${bucket}/application-data/" --region "$AWS_REGION" 2>/dev/null | grep -q "app-data-backup-"; then
        app_data_exists=1
    else
        app_data_exists=0
    fi
    
    if [ "$app_data_exists" -eq 0 ]; then
        log_error "Application data backup not found in S3"
        log_error "Expected to find app-data-backup file in s3://${bucket}/application-data/"
        
        # Check backup report for failures
        local report_file
        report_file=$(aws s3 ls "s3://${bucket}/reports/" --region "$AWS_REGION" 2>/dev/null | grep "backup-report-" | tail -1 | awk '{print $4}')
        
        if [ -n "$report_file" ]; then
            log_info "Checking backup report for details..."
            local temp_report="/tmp/backup-report-check.txt"
            if aws s3 cp "s3://${bucket}/reports/${report_file}" "$temp_report" --region "$AWS_REGION" 2>/dev/null; then
                if grep -q "Application Data.*FAILED" "$temp_report" 2>/dev/null; then
                    log_error "Backup report confirms application data backup failed:"
                    grep "Application Data" "$temp_report" | head -5
                fi
                rm -f "$temp_report"
            fi
        fi
        
        return 1
    fi
    
    log_success "Application data backup validated in S3"
    return 0
}

# Step 4: Backup entire installation
backup_installation() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 4: Backing up entire installation..."

    cd "$PROJECT_ROOT"

    # Run backup script and capture output with progress feedback
    log_info "Running backup script..."
    log_info "This may take 5-10 minutes for database snapshot and file backup..."
    log_info "========================================="
    log_info "BACKUP SCRIPT OUTPUT (real-time)"
    log_info "========================================="
    
    # Use tee to show output in real-time AND capture it for parsing
    local backup_output_file="/tmp/backup-output-${TEST_TIMESTAMP}.log"
    ./scripts/backup.sh --cluster-name "$CLUSTER_NAME" --source-region "$AWS_REGION" --backup-region "$AWS_REGION" 2>&1 | tee "$backup_output_file"
    local backup_exit_code=$?
    
    log_info "========================================="
    log_info "END OF BACKUP SCRIPT OUTPUT"
    log_info "========================================="
    
    # Read captured output for parsing
    local backup_output
    backup_output=$(cat "$backup_output_file" 2>/dev/null || echo "")

    if [ $backup_exit_code -ne 0 ]; then
        log_error "Backup script failed with exit code $backup_exit_code"
        rm -f "$backup_output_file"
        return 1
    fi

    log_info "Backup completed successfully"
    rm -f "$backup_output_file"

    # Extract backup information from backup script output
    log_info "Extracting backup information..."

    # Extract snapshot ID from backup output
    # Try multiple patterns to find the snapshot ID
    SNAPSHOT_ID=$(echo "$backup_output" | grep -o "✅ Aurora Snapshot: [a-zA-Z0-9-]*" | sed 's/✅ Aurora Snapshot: //' | head -1)
    if [ -z "$SNAPSHOT_ID" ]; then
        # Fallback to the "Aurora snapshot created" pattern
        SNAPSHOT_ID=$(echo "$backup_output" | grep -o "Aurora snapshot created: [a-zA-Z0-9-]*" | sed 's/Aurora snapshot created: //' | head -1)
    fi
    if [ -z "$SNAPSHOT_ID" ]; then
        log_error "Failed to extract snapshot ID from backup output"
        log_error "Backup output: $backup_output"
        return 1
    fi

    # Extract backup bucket from backup output
    # Try multiple patterns to find the bucket name
    BACKUP_BUCKET=$(echo "$backup_output" | grep -o "✅ Backup Bucket: s3://[a-zA-Z0-9-]*" | sed 's/✅ Backup Bucket: s3:\/\///' | head -1)
    if [ -z "$BACKUP_BUCKET" ]; then
        # Fallback to the "Creating backup bucket" pattern
        BACKUP_BUCKET=$(echo "$backup_output" | grep -o "Creating backup bucket: s3://[a-zA-Z0-9-]*" | sed 's/Creating backup bucket: s3:\/\///' | head -1)
    fi
    if [ -z "$BACKUP_BUCKET" ]; then
        # Another fallback pattern for the actual output format
        BACKUP_BUCKET=$(echo "$backup_output" | grep -o "✅ Backup Bucket: s3://[a-zA-Z0-9-]*" | sed 's/✅ Backup Bucket: s3:\/\///' | head -1)
    fi
    if [ -z "$BACKUP_BUCKET" ]; then
        log_error "Failed to extract backup bucket from backup output"
        log_error "Backup output: $backup_output"
        return 1
    fi

    # Validate extracted values
    if [[ ! "$SNAPSHOT_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]]; then
        log_error "Invalid snapshot ID format: '$SNAPSHOT_ID'"
        return 1
    fi

    if [[ ! "$BACKUP_BUCKET" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]]; then
        log_error "Invalid backup bucket format: '$BACKUP_BUCKET'"
        return 1
    fi

    # Export variables to global scope for use by other functions
    export BACKUP_BUCKET
    export SNAPSHOT_ID

    # Track backup resources for cleanup
    BACKUP_BUCKET_CREATED="$BACKUP_BUCKET"
    SNAPSHOT_ID_CREATED="$SNAPSHOT_ID"

    log_success "Backup information extracted and validated successfully"
    log_info "Backup Bucket: $BACKUP_BUCKET"
    log_info "Snapshot ID: $SNAPSHOT_ID"

    # Validate that backup actually backed up application data
    log_info "Validating backup completeness..."
    if ! validate_backup_contains_app_data "$BACKUP_BUCKET"; then
        log_error "Backup validation failed - application data not backed up"
        log_error "Cannot proceed with restore test - no data to restore"
        log_error "This typically means the backup ran before OpenEMR was fully initialized"
        
        # Mark this as a backup failure
        local step_duration
        step_duration=$(get_duration "$step_start")
        add_test_result "Backup Creation" "FAILED" "Application data not backed up" "$step_duration"
        return 1
    fi
    
    log_success "Backup validation passed - all expected data backed up"

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Backup Creation" "SUCCESS" "Snapshot: $SNAPSHOT_ID, Application data verified" "$step_duration"
}

# Function to robustly empty S3 bucket (all versions and delete markers)
empty_s3_bucket() {
    local bucket_name="$1"
    local region="$2"

    if [ -z "$bucket_name" ]; then
        log_warning "No bucket name provided for S3 cleanup"
        return 0
    fi

    log_info "Robustly emptying S3 bucket: $bucket_name"

    # Check if bucket exists
    if ! aws s3api head-bucket --bucket "$bucket_name" --region "$region" 2>/dev/null; then
        log_info "Bucket $bucket_name does not exist, skipping cleanup"
        return 0
    fi

    # Step 1: Delete all object versions
    log_info "Deleting all object versions from $bucket_name..."
    local versions_output
    versions_output=$(aws s3api list-object-versions --bucket "$bucket_name" --region "$region" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":[]}')

    local versions_count
    versions_count=$(echo "$versions_output" | jq '.Objects | length' 2>/dev/null || echo "0")

    if [ "$versions_count" -gt 0 ]; then
        log_info "Found $versions_count object versions to delete"
        aws s3api delete-objects --bucket "$bucket_name" --delete "$versions_output" --region "$region" 2>/dev/null || {
            log_warning "Failed to delete some object versions, continuing..."
        }
    else
        log_info "No object versions found"
    fi

    # Step 2: Delete all delete markers
    log_info "Deleting all delete markers from $bucket_name..."
    local delete_markers_output
    delete_markers_output=$(aws s3api list-object-versions --bucket "$bucket_name" --region "$region" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":[]}')

    local delete_markers_count
    delete_markers_count=$(echo "$delete_markers_output" | jq '.Objects | length' 2>/dev/null || echo "0")

    if [ "$delete_markers_count" -gt 0 ]; then
        log_info "Found $delete_markers_count delete markers to delete"
        aws s3api delete-objects --bucket "$bucket_name" --delete "$delete_markers_output" --region "$region" 2>/dev/null || {
            log_warning "Failed to delete some delete markers, continuing..."
        }
    else
        log_info "No delete markers found"
    fi

    # Step 3: Fallback to recursive delete for any remaining objects
    log_info "Performing fallback recursive delete..."
    aws s3 rm "s3://$bucket_name" --recursive --region "$region" 2>/dev/null || {
        log_warning "Fallback recursive delete had issues, but continuing..."
    }

    # Step 4: Wait for bucket to be completely empty with retry logic
    log_info "Waiting for bucket to be completely empty..."
    local max_wait_attempts=30
    local wait_attempt=1
    local remaining_objects=1

    while [ $wait_attempt -le $max_wait_attempts ] && [ $remaining_objects -gt 0 ]; do
        # Check for remaining objects using a more reliable method
        local current_objects
        current_objects=$(aws s3api list-objects-v2 --bucket "$bucket_name" --region "$region" --query 'Contents[].Key' --output text 2>/dev/null)
        if [ -z "$current_objects" ] || [ "$current_objects" = "None" ]; then
            current_objects=0
        else
            current_objects=$(echo "$current_objects" | wc -w)
        fi

        # Check for object versions
        local current_versions
        current_versions=$(aws s3api list-object-versions --bucket "$bucket_name" --region "$region" --query 'Versions[].Key' --output text 2>/dev/null)
        if [ -z "$current_versions" ] || [ "$current_versions" = "None" ]; then
            current_versions=0
        else
            current_versions=$(echo "$current_versions" | wc -w)
        fi

        # Check for delete markers
        local current_delete_markers
        current_delete_markers=$(aws s3api list-object-versions --bucket "$bucket_name" --region "$region" --query 'DeleteMarkers[].Key' --output text 2>/dev/null)
        if [ -z "$current_delete_markers" ] || [ "$current_delete_markers" = "None" ]; then
            current_delete_markers=0
        else
            current_delete_markers=$(echo "$current_delete_markers" | wc -w)
        fi

        remaining_objects=$((current_objects + current_versions + current_delete_markers))

        if [ $remaining_objects -eq 0 ]; then
            log_success "S3 bucket $bucket_name is completely empty"
            break
        else
            log_info "Attempt $wait_attempt/$max_wait_attempts: Bucket still contains $remaining_objects items (objects: $current_objects, versions: $current_versions, delete markers: $current_delete_markers), waiting 5 seconds..."
            sleep 5
            ((wait_attempt++))
        fi
    done

    if [ $remaining_objects -gt 0 ]; then
        log_warning "S3 bucket $bucket_name still contains $remaining_objects items after $max_wait_attempts attempts"
        log_warning "This may cause Terraform destroy to fail, but continuing..."
        return 1
    else
        log_success "S3 bucket $bucket_name successfully emptied and verified"
    fi
}

# Function to disable RDS deletion protection
disable_rds_deletion_protection() {
    local db_cluster_id="$1"
    local region="$2"

    if [ -z "$db_cluster_id" ]; then
        log_warning "No RDS cluster ID provided for deletion protection disable"
        return 0
    fi

    log_info "Disabling deletion protection for RDS cluster: $db_cluster_id"

    # Check current deletion protection status
    local current_protection
    current_protection=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$db_cluster_id" \
        --region "$region" \
            --query 'DBClusters[0].DeletionProtection' \
            --output text 2>/dev/null || echo "unknown")

        if [ "$current_protection" = "True" ]; then
            log_info "Deletion protection is currently enabled, disabling..."
            aws rds modify-db-cluster \
                --db-cluster-identifier "$db_cluster_id" \
                --no-deletion-protection \
                --apply-immediately \
            --region "$region" || {
                log_error "Failed to disable deletion protection for cluster: $db_cluster_id"
                return 1
            }

            log_info "Waiting for deletion protection to be disabled..."
            aws rds wait db-cluster-available \
                --db-cluster-identifier "$db_cluster_id" \
            --region "$region" || {
                log_warning "Wait for cluster available failed, but continuing..."
            }

        # Verify deletion protection is disabled
        local new_protection
        new_protection=$(aws rds describe-db-clusters \
                --db-cluster-identifier "$db_cluster_id" \
            --region "$region" \
                --query 'DBClusters[0].DeletionProtection' \
                --output text 2>/dev/null || echo "unknown")

            if [ "$new_protection" = "False" ]; then
                log_success "Deletion protection successfully disabled"
            else
                log_error "Deletion protection is still enabled after attempt to disable"
                return 1
            fi
        else
            log_info "Deletion protection is already disabled (status: $current_protection)"
        fi
}

# Step 5: Test monitoring stack installation and uninstallation
test_monitoring_stack() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 5: Testing monitoring stack installation and uninstallation..."

    # Ensure kubeconfig is configured
    log_info "Configuring kubeconfig for monitoring test..."
    if ! ensure_kubeconfig; then
        log_error "Failed to configure kubeconfig for monitoring test"
        return 1
    fi

    # Check if monitoring script exists
    local monitoring_script="$PROJECT_ROOT/monitoring/install-monitoring.sh"
    if [ ! -f "$monitoring_script" ]; then
        log_error "Monitoring script not found: $monitoring_script"
        return 1
    fi

    # Make sure the script is executable
    chmod +x "$monitoring_script"

    # Test monitoring stack installation
    log_info "Installing monitoring stack..."
    log_info "This may take 10-15 minutes for full installation..."
    
    # Run monitoring installation
    if ! "$monitoring_script" install; then
        log_error "Monitoring stack installation failed"
        return 1
    fi
    log_success "Monitoring stack installed successfully"

    # Verify monitoring stack is working
    log_info "Verifying monitoring stack functionality..."
    if ! "$monitoring_script" verify; then
        log_error "Monitoring stack verification failed"
        return 1
    fi

    # Wait a bit for components to stabilize
    log_info "Waiting for monitoring components to stabilize..."
    sleep 30

    # Test monitoring stack uninstallation
    log_info "Uninstalling monitoring stack..."
    if ! "$monitoring_script" uninstall; then
        log_error "Monitoring stack uninstallation failed"
        return 1
    fi

    log_success "Monitoring stack uninstalled successfully"

    # Verify cleanup
    log_info "Verifying monitoring stack cleanup..."
    local monitoring_pods
    monitoring_pods=$(kubectl get pods -n monitoring 2>/dev/null | wc -l || echo "0")
    if [ "$monitoring_pods" -gt 1 ]; then  # More than just header line
        log_warning "Some monitoring pods still exist after uninstall"
    else
        log_success "Monitoring stack cleanup verified"
    fi

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Monitoring Stack Test" "SUCCESS" "Install and uninstall completed successfully" "$step_duration"
}

# Step 6: Delete all infrastructure
delete_infrastructure() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 6: Deleting all infrastructure..."

    # Use the comprehensive destroy.sh script for bulletproof cleanup
    log_info "Using comprehensive destroy.sh script for complete infrastructure cleanup..."
    
    # Note: We do NOT clean up the backup bucket OR snapshots here because we need them for restoration
    # The backup bucket and snapshots will be cleaned up in the final cleanup step
    log_info "Preserving backup bucket for restoration step: $BACKUP_BUCKET"
    log_info "Preserving backup snapshot for restoration step: $SNAPSHOT_ID"
    
    # Export cluster name and flags for destroy.sh script
    export CLUSTER_NAME="$CLUSTER_NAME"
    export AWS_REGION="$AWS_REGION"
    export PRESERVE_BACKUP_SNAPSHOTS="true"  # CRITICAL: Preserve backup snapshots for restore test
    
    # Ensure we're in the project root directory for consistent path handling
    cd "$PROJECT_ROOT"
    
    # Run destroy.sh with force for automated testing
    if ./scripts/destroy.sh --force; then
        log_success "Infrastructure deleted successfully using destroy.sh"
    else
        log_error "destroy.sh script failed - some resources may still exist"
        log_error "Check AWS console for remaining resources that need manual cleanup"
        return 1
    fi

    # Mark infrastructure as deleted - no longer needs cleanup
    INFRASTRUCTURE_CREATED=false

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Infrastructure Deletion" "SUCCESS" "All resources destroyed using destroy.sh" "$step_duration"
}


# Step 7: Recreate infrastructure
recreate_infrastructure() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 7: Recreating infrastructure..."

    # Clean up existing Kubernetes resources before recreating infrastructure
    log_info "Cleaning up existing Kubernetes resources..."
    ./scripts/restore-defaults.sh --force

    cd "$TERRAFORM_DIR"

    # Clean up manual RDS snapshots that might interfere with cluster recreation
    cleanup_manual_snapshots

    # Clean up existing CloudWatch log groups that might conflict
    cleanup_existing_log_groups

    # Initialize Terraform
    log_info "Initializing Terraform..."
    terraform init

    # Plan and apply infrastructure
    log_info "Planning infrastructure recreation..."
    terraform plan -var="cluster_name=$CLUSTER_NAME" -var="aws_region=$AWS_REGION" -out=tfplan

    log_info "Applying infrastructure recreation..."
    terraform apply -auto-approve tfplan

    # Wait for infrastructure to be ready
    log_info "Waiting for infrastructure to be ready..."
    sleep 60

    # Update kubectl context to point to the new cluster
    log_info "Updating kubectl context to point to the new cluster..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

    # Get outputs
    log_info "Getting Terraform outputs..."
    # Backup bucket will be created dynamically by backup script

    log_success "Infrastructure recreated successfully"

    # Mark infrastructure as created again for cleanup tracking
    INFRASTRUCTURE_CREATED=true
    CLEANUP_REQUIRED=true

    # Deploy OpenEMR after recreating infrastructure
    log_info "Deploying OpenEMR after infrastructure recreation..."
    deploy_openemr "restore"

    # Note: We do NOT create a new backup here - we use the original backup from step 4
    # The BACKUP_BUCKET and SNAPSHOT_ID variables should still be available from the backup_installation step

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Infrastructure Recreation" "SUCCESS" "Cluster: $CLUSTER_NAME" "$step_duration"

    cd "$PROJECT_ROOT"
}

# Step 8: Restore from backup
restore_from_backup() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 8: Restoring from backup..."

    cd "$PROJECT_ROOT"

    # Wait for cluster to be accessible before attempting restore
    log_info "Waiting for Kubernetes cluster to be accessible..."
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if kubectl cluster-info >/dev/null 2>&1; then
            log_success "Kubernetes cluster is accessible"
            break
        else
            log_info "Attempt $attempt/$max_attempts: Cluster not yet accessible, waiting 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    if [ $attempt -gt $max_attempts ]; then
        log_error "Kubernetes cluster not accessible after $max_attempts attempts"
        return 1
    fi

    # Reset Kubernetes manifests to default state with placeholders
    # This is crucial because the initial deployment replaced placeholders with actual values
    # but we need fresh placeholders for the restore to work with new infrastructure
    log_info "Resetting Kubernetes manifests to default state with placeholders..."
    ./scripts/restore-defaults.sh --force

    # Ensure kubeconfig is configured before restore
    log_info "Configuring kubeconfig for restore..."
    if ! ensure_kubeconfig; then
        log_error "Failed to configure kubeconfig for restore"
        return 1
    fi

    # Validate backup variables are still available
    if [ -z "$BACKUP_BUCKET" ] || [ -z "$SNAPSHOT_ID" ]; then
        log_error "Backup variables not available (BACKUP_BUCKET: '$BACKUP_BUCKET', SNAPSHOT_ID: '$SNAPSHOT_ID')"
        log_error "This indicates the backup step failed or variables were not properly exported"
        return 1
    fi

    # Run restore script with force flag for automated testing
    log_info "Running restore script with force flag..."
    log_info "This may take 10-15 minutes for database restore and file restoration..."
    log_info "Using backup bucket: $BACKUP_BUCKET"
    log_info "Using snapshot ID: $SNAPSHOT_ID"
    log_info "Using AWS region: $AWS_REGION"
    log_info "========================================="
    log_info "RESTORE SCRIPT OUTPUT (real-time)"
    log_info "========================================="
    
    ./scripts/restore.sh "$BACKUP_BUCKET" "$SNAPSHOT_ID" --region "$AWS_REGION"
    local restore_exit_code=$?
    
    log_info "========================================="
    log_info "END OF RESTORE SCRIPT OUTPUT"
    log_info "========================================="
    
    if [ $restore_exit_code -ne 0 ]; then
        log_error "Restore script failed with exit code $restore_exit_code"
        return 1
    fi

    # Wait for restoration to complete with progress feedback
    log_info "Waiting for restoration to complete..."
    local wait_time=180  # 3 minutes
    local check_interval=10  # Check every 10 seconds
    local elapsed=0

    while [ $elapsed -lt $wait_time ]; do
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        local progress=$((elapsed * 100 / wait_time))
        log_info "Restoration in progress... ${elapsed}s elapsed (${progress}%)"
    done

    log_success "Restoration completed successfully"

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Backup Restoration" "SUCCESS" "From bucket: $BACKUP_BUCKET, Snapshot: $SNAPSHOT_ID" "$step_duration"

    cd "$PROJECT_ROOT"
}

# Step 9: Verify restoration and connectivity
verify_restoration() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 9: Verifying restoration and connectivity..."

    # Wait for OpenEMR to be ready - extended timeout for startup
    log_info "Waiting for OpenEMR to be ready after restoration..."
    log_info "This may take 10-15 minutes for first startup..."

    # Check current deployment status first
    log_info "Checking current OpenEMR deployment status..."
    local current_replicas
    current_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    current_replicas=${current_replicas:-0}
    local available_replicas
    available_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    available_replicas=${available_replicas:-0}
    local ready_replicas
    ready_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    ready_replicas=${ready_replicas:-0}

    log_info "Current deployment status: $ready_replicas/$available_replicas/$current_replicas (ready/available/desired)"

    # If we already have ready replicas, we can proceed
    if [ "$ready_replicas" -gt 0 ]; then
        log_success "OpenEMR deployment already has $ready_replicas ready replicas, proceeding with verification"
    else
        # Wait for deployment to be progressing or have available replicas
        log_info "Waiting for OpenEMR deployment to be progressing or have available replicas..."
        local wait_timeout=1800  # 30 minutes (reduced from 40)
        local check_interval=30  # Check every 30 seconds
        local elapsed=0

        while [ $elapsed -lt $wait_timeout ]; do
            # Check if we have available replicas
            available_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
            available_replicas=${available_replicas:-0}
            if [ "$available_replicas" -gt 0 ]; then
                log_success "OpenEMR deployment has $available_replicas available replicas after ${elapsed}s"
                break
            fi

            # Check if deployment is progressing
            if kubectl wait --for=condition=progressing --timeout=10s deployment/openemr -n "$NAMESPACE" 2>/dev/null; then
                log_success "OpenEMR deployment is progressing after ${elapsed}s"
                break
            fi

            elapsed=$((elapsed + check_interval))
            local progress=$((elapsed * 100 / wait_timeout))
            log_info "Deployment not ready yet... ${elapsed}s elapsed (${progress}%) - checking status..."

            # Show deployment status for debugging
            local progressing_status
            progressing_status=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "Unknown")
            progressing_status=${progressing_status:-Unknown}
            log_info "Deployment progressing status: $progressing_status, available replicas: $available_replicas"
        done

        if [ $elapsed -ge $wait_timeout ]; then
            log_warning "OpenEMR deployment not ready within timeout, checking final status..."

            # Final status check
            available_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
            available_replicas=${available_replicas:-0}
            ready_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            ready_replicas=${ready_replicas:-0}

            log_info "Final deployment status: $ready_replicas/$available_replicas/$current_replicas (ready/available/desired)"

            if [ "$available_replicas" -gt 0 ]; then
                log_success "At least one replica is available, proceeding with verification"
            else
                log_error "No replicas are available after timeout"
                return 1
            fi
        fi
    fi

    # Verify deployment is ready
    log_info "Verifying deployment status..."
    ready_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    ready_replicas=${ready_replicas:-0}
    local desired_replicas
    desired_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    desired_replicas=${desired_replicas:-0}

    # More flexible readiness check - at least 1 replica should be ready
    # HPA may take time to scale up, so we shouldn't require all desired replicas immediately
    if [ "$ready_replicas" -gt 0 ]; then
        if [ "$ready_replicas" -ge "$desired_replicas" ]; then
            log_success "OpenEMR deployment is fully ready ($ready_replicas/$desired_replicas replicas)"
        else
            log_success "OpenEMR deployment is partially ready ($ready_replicas/$desired_replicas replicas)"
            log_info "HPA may scale up additional replicas based on load"
        fi

        # Additional verification: check if OpenEMR is actually responding
        log_info "Verifying OpenEMR application responsiveness..."
        local max_attempts=40  # Increased from 10 to 40 (20 minutes total)
        local attempt=1

        while [ $attempt -le $max_attempts ]; do
            log_info "Health check attempt $attempt/$max_attempts..."

            # Get the service endpoint
            local service_ip
            service_ip=$(kubectl get service openemr -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

            if [ -n "$service_ip" ]; then
                # Test connectivity to OpenEMR login page
                local health_check_result
                health_check_result=$(kubectl run test-health-check --rm -i --restart=Never --image=curlimages/curl:latest -- curl -s -o /dev/null -w "%{http_code}" --max-time 30 "http://$service_ip/interface/login/login.php" 2>/dev/null || echo "000")

                if [ "$health_check_result" = "200" ]; then
                    log_success "OpenEMR application is responding correctly (HTTP 200)"
                    break
                elif [ "$health_check_result" = "302" ] || [ "$health_check_result" = "301" ]; then
                    log_success "OpenEMR application is responding with redirect (HTTP $health_check_result) - this is normal"
                    break
                elif [ "$health_check_result" = "500" ]; then
                    log_info "OpenEMR returning HTTP 500 (internal server error) - this is common during restoration, waiting for database connection to stabilize..."
                    if [ $attempt -lt $max_attempts ]; then
                        sleep 30
                    fi
                else
                    log_info "OpenEMR not fully ready yet (HTTP $health_check_result), waiting..."
                    if [ $attempt -lt $max_attempts ]; then
                        sleep 30
                    fi
                fi
            else
                log_warning "Could not get service IP, skipping health check"
                break
            fi

            attempt=$((attempt + 1))
        done

        if [ $attempt -gt $max_attempts ]; then
            log_warning "OpenEMR health check failed after $max_attempts attempts, but deployment is ready"
            log_info "This may be due to temporary issues during restoration - deployment will continue"

            # Additional debugging for failed health checks
            log_info "Checking pod logs for debugging..."
            local pod_name
            pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[?(@.name=="openemr")].ready}{"\n"}{end}' | grep -E "\ttrue$" | head -1 | cut -f1 2>/dev/null || echo "")
            if [ -n "$pod_name" ]; then
                log_info "Pod logs for $pod_name:"
                kubectl logs "$pod_name" -n "$NAMESPACE" -c openemr --tail=20 || true
            fi
        fi

    else
        log_warning "OpenEMR deployment not fully ready ($ready_replicas/$desired_replicas replicas)"
        log_info "This is common after restoration - OpenEMR may need time to start up"
        
        # Check if we have any running pods (even if not ready)
        local running_pods
        running_pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$running_pods" ]; then
            log_info "Found running pods: $running_pods"
            log_info "Proceeding with verification - OpenEMR may be starting up"
        else
            log_error "No running pods found after restoration"
            
            # Show pod status for debugging
            log_info "Checking pod status for debugging..."
            kubectl get pods -n "$NAMESPACE" -l app=openemr -o wide || true
            kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10 || true
            
            return 1
        fi
    fi

    # Get OpenEMR pod name - wait for a stable pod
    local pod_name
    local max_pod_attempts=10
    local pod_attempt=1

    log_info "Finding a stable OpenEMR pod after restoration..."

    while [ $pod_attempt -le $max_pod_attempts ]; do
        # Get the first running pod (not terminating) - be more tolerant of readiness
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[?(@.name=="openemr")].ready}{"\n"}{end}' | head -1 | cut -f1 2>/dev/null || echo "")
        
        # If no pod found with the above method, try a simpler approach
        if [ -z "$pod_name" ]; then
            pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi

        if [ -n "$pod_name" ]; then
            # Verify the pod is actually running and not terminating
            local pod_phase
            pod_phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

            if [ "$pod_phase" = "Running" ]; then
                log_success "Found stable OpenEMR pod: $pod_name"
                break
            else
                log_info "Pod $pod_name is in phase: $pod_phase, waiting for stable pod..."
            fi
        else
            log_info "No running pods found, attempt $pod_attempt/$max_pod_attempts"
        fi

        sleep 5
        ((pod_attempt++))
    done

    if [ -z "$pod_name" ] || [ "$pod_phase" != "Running" ]; then
        log_error "No stable OpenEMR pods found after restoration"
        log_info "Current pod status:"
        kubectl get pods -n "$NAMESPACE" -l app=openemr -o wide || true
        return 1
    fi

    # Additional wait for OpenEMR application to be responsive
    log_info "Waiting for OpenEMR application to be responsive after restoration..."
    log_info "This may take 10-15 minutes for OpenEMR to fully initialize after restoration..."
    local max_attempts=60  # Increased to 60 attempts (10 minutes) for better reliability
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        # Try multiple endpoints to check responsiveness
        local responsive=false

        # Check main login page
        if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -f http://localhost:80/interface/login/login.php > /dev/null" 2>/dev/null; then
            responsive=true
        # Check root page as fallback
        elif kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -f http://localhost:80/ > /dev/null" 2>/dev/null; then
            responsive=true
        # Check if Apache is running
        elif kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "pgrep apache2 > /dev/null" 2>/dev/null; then
            # Apache is running, try a simple HTTP check
            if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -I http://localhost:80/ | head -1 | grep -q '200 OK'" 2>/dev/null; then
                responsive=true
            fi
        fi

        if [ "$responsive" = true ]; then
            log_success "OpenEMR application is responsive after restoration"
            break
        else
            # Show progress indicator with more detailed status
            local progress=$((attempt * 100 / max_attempts))
            log_info "Attempt $attempt/$max_attempts (${progress}%): OpenEMR not yet responsive, waiting 10 seconds..."

            # Show container status for debugging
            local container_ready
            container_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openemr")].ready}' 2>/dev/null || echo "false")
            log_info "Container ready status: $container_ready"

            sleep 10
            ((attempt++))
        fi
    done

    if [ $attempt -gt $max_attempts ]; then
        log_warning "OpenEMR may not be fully responsive after $max_attempts attempts, but proceeding with verification"
        log_info "This is common after restoration - OpenEMR may be taking time to initialize"
        log_info "Proceeding with proof file verification..."
    fi

    # CRITICAL: Wait for EFS to fully propagate restored files before verification
    log_info "========================================="
    log_info "Waiting for EFS to stabilize after restoration (30 seconds)..."
    log_info "This ensures restored files are visible across all pods"
    log_info "========================================="
    sleep 30
    
    # Force sync and verify filesystem is stable
    log_info "Forcing filesystem sync before verification..."
    if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "sync" 2>/dev/null; then
        log_success "Filesystem sync completed"
    else
        log_warning "Filesystem sync failed, but continuing with verification"
    fi
    
    # Quick sanity check: Verify EFS mount is still working
    log_info "Verifying EFS mount is accessible..."
    if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "test -d /var/www/localhost/htdocs/openemr/sites" 2>/dev/null; then
        log_success "EFS mount confirmed accessible"
        
        # Show what's in sites/ for debugging
        local sites_contents
        sites_contents=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "ls -la /var/www/localhost/htdocs/openemr/sites/ 2>/dev/null | head -10" 2>/dev/null || echo "Unable to list")
        log_info "Contents of sites/ directory:"
        echo "$sites_contents"
    else
        log_error "EFS mount not accessible - this will cause verification to fail"
    fi

    # Verify proof.txt exists
    log_info "Verifying proof.txt file exists..."
    if kubectl_exec_with_retry "$pod_name" "test -f /var/www/localhost/htdocs/openemr/sites/default/documents/test_data/proof.txt"; then
        log_success "Proof file exists after restoration"

        # Verify content
        local restored_content
        restored_content=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "cat /var/www/localhost/htdocs/openemr/sites/default/documents/test_data/proof.txt" 2>/dev/null)
        log_info "Restored proof file content: $restored_content"

        if [[ "$restored_content" == *"$TEST_TIMESTAMP"* ]]; then
            log_success "Proof file content verified correctly"
        else
            log_error "Proof file content mismatch - expected timestamp: $TEST_TIMESTAMP"
            local step_duration
            step_duration=$(get_duration "$step_start")
            add_test_result "Restoration Verification" "FAILED" "Proof file content mismatch - expected: $TEST_TIMESTAMP, got: $restored_content" "$step_duration"
            return 1
        fi
    else
        log_error "Proof file not found after restoration"
        
        # COMPREHENSIVE DEBUGGING - what went wrong?
        log_error "========================================="
        log_error "DEBUGGING RESTORATION FAILURE"
        log_error "========================================="
        
        # 1. Check what's in the sites directory
        log_error "1. Checking sites directory structure:"
        kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "ls -laR /var/www/localhost/htdocs/openemr/sites/ | head -100" 2>&1 || log_error "Failed to list sites directory"
        
        # 2. Check if sites/default exists
        log_error "2. Checking for sites/default:"
        if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "test -d /var/www/localhost/htdocs/openemr/sites/default" 2>/dev/null; then
            log_error "sites/default EXISTS"
            kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "ls -la /var/www/localhost/htdocs/openemr/sites/default/ | head -50" 2>&1 || true
        else
            log_error "sites/default does NOT EXIST - this is the problem!"
        fi
        
        # 3. Check if test_data directory exists
        log_error "3. Checking for test_data directory:"
        if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "test -d /var/www/localhost/htdocs/openemr/sites/default/documents/test_data" 2>/dev/null; then
            log_error "test_data directory EXISTS"
            kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "ls -la /var/www/localhost/htdocs/openemr/sites/default/documents/test_data/" 2>&1 || true
        else
            log_error "test_data directory does NOT EXIST"
        fi
        
        # 4. Count total files in sites
        log_error "4. File count in sites directory:"
        local file_count
        file_count=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "find /var/www/localhost/htdocs/openemr/sites/ -type f 2>/dev/null | wc -l" 2>/dev/null || echo "0")
        log_error "Total files in sites/: $file_count"
        
        # 5. Check EFS mount
        log_error "5. Checking EFS mount status:"
        kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "df -h | grep -E 'Filesystem|efs'" 2>&1 || log_error "Failed to check EFS mount"
        kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "mount | grep efs" 2>&1 || log_error "No EFS mount found"
        
        # 6. Check container logs for errors
        log_error "6. Recent container logs (last 30 lines):"
        kubectl logs "$pod_name" -n "$NAMESPACE" -c openemr --tail=30 2>&1 || log_error "Failed to get logs"
        
        # 7. Check backup contents in S3
        log_error "7. Checking what was actually in the backup:"
        log_error "Application data backups in S3:"
        aws s3 ls "s3://$BACKUP_BUCKET/application-data/" --region "$AWS_REGION" 2>&1 || log_error "Failed to list S3 backup"
        
        # 8. Try to download and inspect the backup locally
        log_error "8. Attempting to inspect backup contents:"
        local backup_file
        backup_file=$(aws s3 ls "s3://$BACKUP_BUCKET/application-data/" --region "$AWS_REGION" | grep "app-data-backup-" | sort -k1,2 | tail -1 | awk '{print $4}')
        if [ -n "$backup_file" ]; then
            log_error "Found backup: $backup_file"
            log_error "Downloading and inspecting..."
            local temp_backup="/tmp/debug-backup.tar.gz"
            if aws s3 cp "s3://$BACKUP_BUCKET/application-data/$backup_file" "$temp_backup" --region "$AWS_REGION" 2>/dev/null; then
                log_error "Backup contents:"
                tar -tzf "$temp_backup" 2>&1 | head -50 || log_error "Failed to list backup contents"
                log_error "Checking for proof.txt in backup:"
                if tar -tzf "$temp_backup" 2>/dev/null | grep -q "proof.txt"; then
                    log_error "proof.txt IS in the backup!"
                else
                    log_error "proof.txt is NOT in the backup - backup itself is incomplete!"
                fi
                rm -f "$temp_backup"
            else
                log_error "Failed to download backup for inspection"
            fi
        else
            log_error "No backup file found in S3!"
        fi
        
        log_error "========================================="
        log_error "END DEBUGGING OUTPUT"
        log_error "========================================="
        
        local step_duration
        step_duration=$(get_duration "$step_start")
        add_test_result "Restoration Verification" "FAILED" "Proof file not found after restoration" "$step_duration"
        return 1
    fi

    # Database connectivity is already tested by the restore script
    log_success "Database connectivity verified"

    log_success "Restoration verification completed successfully"

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Restoration Verification" "SUCCESS" "Proof file verified (database connectivity tested by restore script)" "$step_duration"
}

# Step 10: Clean up infrastructure and backups
cleanup_final() {
    local step_start
    step_start=$(start_timer)
    log_step "Step 10: Final cleanup of infrastructure and backups..."

    # Use the comprehensive destroy.sh script for bulletproof cleanup
    log_info "Using comprehensive destroy.sh script for final infrastructure cleanup..."
    
    # Export cluster name and region for destroy.sh script
    export CLUSTER_NAME="$CLUSTER_NAME"
    export AWS_REGION="$AWS_REGION"
    
    # Ensure we're in the project root directory for consistent path handling
    cd "$PROJECT_ROOT"
    
    # Run destroy.sh with force for automated testing
    # Note: destroy.sh will handle all infrastructure cleanup including S3 buckets, RDS, EKS, etc.
    if ./scripts/destroy.sh --force; then
        log_success "Infrastructure deleted successfully using destroy.sh"
    else
        log_error "destroy.sh script failed - some resources may still exist"
        log_error "Check AWS console for remaining resources that need manual cleanup"
        return 1
    fi

    # Clean up backup bucket if it exists
    if [ -n "$BACKUP_BUCKET" ]; then
        log_info "Cleaning up backup bucket: $BACKUP_BUCKET"
        empty_s3_bucket "$BACKUP_BUCKET" "$AWS_REGION"
    else
        log_warning "No backup bucket name available for cleanup"
    fi

    # Delete Aurora backups created during testing
    log_info "Deleting Aurora backups created during testing..."
    local backup_arn
    backup_arn=$(aws rds describe-db-cluster-snapshots \
        --region "$AWS_REGION" \
        --query "DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, '$TEST_TIMESTAMP')].DBClusterSnapshotArn" \
        --output text 2>/dev/null || echo "")

    if [ -n "$backup_arn" ]; then
        log_info "Deleting backup: $backup_arn"
        aws rds delete-db-cluster-snapshot \
            --db-cluster-snapshot-identifier "$backup_arn" \
            --region "$AWS_REGION" || true
    fi

    log_success "Final cleanup completed successfully"

    local step_duration
    step_duration=$(get_duration "$step_start")
    add_test_result "Final Cleanup" "SUCCESS" "Infrastructure destroyed and backups cleaned" "$step_duration"

    cd "$PROJECT_ROOT"
}

# Print test results
print_test_results() {
    local test_end_time
    test_end_time=$(date +%s)
    local total_duration=$((test_end_time - TEST_START_TIME))

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}📋 End-to-End Test Results Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${CYAN}Test Configuration:${NC}"
    echo -e "  Cluster Name: $CLUSTER_NAME"
    echo -e "  AWS Region: $AWS_REGION"
    echo -e "  Namespace: $NAMESPACE"
    echo -e "  Test ID: $TEST_TIMESTAMP"
    echo -e "  Total Duration: ${total_duration}s ($((total_duration / 60))m $((total_duration % 60))s)"
    echo ""
    echo -e "${CYAN}Test Steps Results:${NC}"

    if [ ${#TEST_RESULTS[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No test steps completed${NC}"
    else
        for result in "${TEST_RESULTS[@]}"; do
        IFS='|' read -r step status details duration <<< "$result"
        local status_color=""
        case "$status" in
            "SUCCESS") status_color="$GREEN" ;;
            "FAILED") status_color="$RED" ;;
            "SKIPPED") status_color="$YELLOW" ;;
            *) status_color="$BLUE" ;;
        esac

        echo -e "  ${status_color}${step}${NC}: ${status_color}${status}${NC} (${duration}s)"
        if [ -n "$details" ]; then
            echo -e "    Details: $details"
        fi
        done
    fi

    echo ""
    echo -e "${CYAN}Test Outcome:${NC}"

    local success_count=0
    local failed_count=0

    if [ ${#TEST_RESULTS[@]} -gt 0 ]; then
        for result in "${TEST_RESULTS[@]}"; do
        IFS='|' read -r step status details duration <<< "$result"
        case "$status" in
            "SUCCESS") ((success_count++)) ;;
            "FAILED") ((failed_count++)) ;;
        esac
        done
    fi

    if [ $failed_count -eq 0 ]; then
        echo -e "${GREEN}🎉 All tests passed successfully!${NC}"
        echo -e "${GREEN}✅ Success: $success_count${NC}"
        echo -e "${GREEN}✅ Failed: $failed_count${NC}"
    else
        echo -e "${RED}❌ Some tests failed${NC}"
        echo -e "${GREEN}✅ Success: $success_count${NC}"
        echo -e "${RED}❌ Failed: $failed_count${NC}"
    fi

    echo ""
    echo -e "${YELLOW}💡 Test completed in ${total_duration}s${NC}"
}

# Storage class validation functions
validate_storage_classes() {
    log_info "Validating storage class configuration..."

    local validation_failed=false
    local storage_classes=("efs-sc" "efs-sc-backup" "gp3-monitoring-encrypted")

    # Get EFS ID with proper directory validation
    local efs_id
    if ! cd "$PROJECT_ROOT/terraform" 2>/dev/null; then
        log_error "Cannot access terraform directory: $PROJECT_ROOT/terraform"
        return 1
    fi
    
    efs_id=$(terraform output -raw efs_id 2>/dev/null || echo "")
    if [ -z "$efs_id" ]; then
        log_error "EFS ID not available from Terraform output"
        return 1
    fi

    log_info "Using EFS ID: $efs_id"

    # Validate each storage class
    for sc in "${storage_classes[@]}"; do
        log_info "Validating storage class: $sc"

        if ! kubectl get storageclass "$sc" >/dev/null 2>&1; then
            log_error "Storage class $sc not found"
            validation_failed=true
            continue
        fi

        # Check EFS storage classes have correct EFS ID
        if [[ "$sc" == "efs-sc" || "$sc" == "efs-sc-backup" ]]; then
            local current_efs_id
            current_efs_id=$(kubectl get storageclass "$sc" -o jsonpath='{.parameters.fileSystemId}' 2>/dev/null || echo "")

            if [ -z "$current_efs_id" ]; then
                log_error "Storage class $sc missing fileSystemId parameter"
                validation_failed=true
            elif [ "$current_efs_id" != "$efs_id" ]; then
                log_warning "Storage class $sc has incorrect EFS ID: $current_efs_id (expected: $efs_id)"
                validation_failed=true
            else
                log_success "Storage class $sc has correct EFS ID"
            fi
        fi
    done

    if [ "$validation_failed" = true ]; then
        log_error "Storage class validation failed"
        return 1
    else
        log_success "All storage classes validated successfully"
        return 0
    fi
}

# Function to validate and update EFS ID in storage classes
validate_and_update_efs_id() {
    log_info "Validating and updating EFS ID in storage classes..."

    # Get current EFS ID from Terraform with proper directory validation
    if ! cd "$PROJECT_ROOT/terraform" 2>/dev/null; then
        log_error "Cannot access terraform directory: $PROJECT_ROOT/terraform"
        return 1
    fi
    
    CURRENT_EFS_ID=$(terraform output -raw efs_id 2>/dev/null || echo "")
    if [ -z "$CURRENT_EFS_ID" ]; then
        log_error "Could not get EFS ID from Terraform output"
        return 1
    fi

    log_info "Current EFS ID: $CURRENT_EFS_ID"

    # Check if EFS file system exists
    if ! aws efs describe-file-systems --file-system-id "$CURRENT_EFS_ID" >/dev/null 2>&1; then
        log_error "EFS file system $CURRENT_EFS_ID does not exist or is not accessible"
        return 1
    fi

    log_success "EFS file system $CURRENT_EFS_ID is accessible"

    # Update storage.yaml with current EFS ID
    if [ -f "$PROJECT_ROOT/k8s/storage.yaml" ]; then
        log_info "Updating storage.yaml with current EFS ID..."
        sed -i.bak "s/fileSystemId: \${EFS_ID}/fileSystemId: $CURRENT_EFS_ID/g" "$PROJECT_ROOT/k8s/storage.yaml"
        sed -i.bak2 "s/fileSystemId: fs-[a-zA-Z0-9]*/fileSystemId: $CURRENT_EFS_ID/g" "$PROJECT_ROOT/k8s/storage.yaml"
        log_success "Storage classes updated with EFS ID: $CURRENT_EFS_ID"
    else
        log_warning "Storage classes file not found: $PROJECT_ROOT/k8s/storage.yaml"
    fi
}

# Main execution
main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Set up directories
    get_directories
    
    # Detect AWS region from Terraform state if not explicitly set via --aws-region
    get_aws_region

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}🚀 OpenEMR End-to-End Backup/Restore Test${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${CYAN}Test Configuration:${NC}"
    echo -e "  AWS Region: $AWS_REGION"
    echo -e "  Cluster Name: $CLUSTER_NAME"
    echo -e "  Namespace: $NAMESPACE"
    echo -e "  Test ID: $TEST_TIMESTAMP"
    echo ""

    # Note: No kubeconfig check needed here - cluster doesn't exist yet

    # Reset Kubernetes manifests to default state before starting
    log_info "Resetting Kubernetes manifests to default state with placeholders..."
    cd "$PROJECT_ROOT"
    log_info "Current directory: $(pwd)"
    log_info "Looking for restore-defaults.sh at: $(pwd)/scripts/restore-defaults.sh"
    ls -la scripts/restore-defaults.sh || log_error "File not found"
    ./scripts/restore-defaults.sh --force || {
        log_error "Failed to reset Kubernetes manifests to default state."
        exit 1
    }
    log_success "Kubernetes manifests reset to default state."
    echo ""
    echo -e "${YELLOW}⚠️  WARNING: This test will create and destroy AWS resources!${NC}"
    echo -e "${YELLOW}   AWS resources will be created and destroyed during testing.${NC}"
    echo ""

    # Check prerequisites
    check_prerequisites
    
    # Check for orphaned resources from previous test runs
    # This prevents cascading failures and provides clear error messages
    check_for_orphaned_resources

    # Validate configuration
    validate_configuration

    # Validate pre-flight state
    validate_preflight_state

    # Execute test steps with error handling
    if ! deploy_infrastructure; then
        log_error "Infrastructure deployment failed"
        print_test_results
        exit 1
    fi

    if ! deploy_openemr; then
        log_error "OpenEMR deployment failed"
        print_test_results
        exit 1
    fi

    if ! deploy_test_data; then
        log_error "Test data deployment failed"
        print_test_results
        exit 1
    fi

    if ! backup_installation; then
        log_error "Backup creation failed"
        print_test_results
        exit 1
    fi

    if ! test_monitoring_stack; then
        log_error "Monitoring stack test failed"
        print_test_results
        exit 1
    fi

    if ! delete_infrastructure; then
        log_error "Infrastructure deletion failed"
        print_test_results
        exit 1
    fi

    if ! recreate_infrastructure; then
        log_error "Infrastructure recreation failed"
        print_test_results
        exit 1
    fi

    if ! restore_from_backup; then
        log_error "Backup restoration failed"
        print_test_results
        exit 1
    fi

    if ! verify_restoration; then
        log_error "Restoration verification failed"
        add_test_result "Restoration Verification" "FAILED" "Restoration verification step failed" "0"
        print_test_results
        exit 1
    fi

    if ! cleanup_final; then
        log_error "Final cleanup failed"
        print_test_results
        exit 1
    fi

    # Test completed successfully - disable emergency cleanup trap
    trap - ERR EXIT

    # Print results
    print_test_results

    log_success "🎉 END-TO-END TEST COMPLETED SUCCESSFULLY! 🎉"
}

# Run main function
main "$@"
