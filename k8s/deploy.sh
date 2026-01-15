#!/bin/bash

# =============================================================================
# OpenEMR EKS Deployment Script
# =============================================================================
# This script deploys OpenEMR to an EKS cluster with robust error handling.
# Handles various cluster states including fresh, failed, or existing deployments.
# Designed to be reliable and provide clear feedback during the deployment process.
#
# DEPLOYMENT STRATEGY:
# This script implements a "bulletproof" deployment strategy that can handle
# any cluster state and ensure OpenEMR is properly deployed. It performs the
# following key operations in sequence:
#
# 1. PREREQUISITE VALIDATION: Ensures all required infrastructure components
#    (Redis, Aurora, EFS CSI driver) are available before proceeding
# 2. CLUSTER STATE ANALYSIS: Detects if OpenEMR is already running, needs
#    cleanup, or is a fresh deployment
# 3. CLEANUP OPERATIONS: Removes failed pods, stuck resources, and old replicasets
# 4. INFRASTRUCTURE SETUP: Creates namespaces, secrets, storage classes
# 5. APPLICATION DEPLOYMENT: Deploys OpenEMR with proper health checks
# 6. VALIDATION: Verifies deployment success and application responsiveness
#
# ERROR HANDLING:
# - Uses 'set -euo pipefail' for strict error handling
# - Implements fail-fast validation for critical prerequisites
# - Provides detailed logging with color-coded output levels
# - Includes cleanup mechanisms for partial failures
#
# DEPENDENCIES:
# - kubectl: Must be configured with cluster access
# - terraform: Must be in PROJECT_ROOT/terraform with applied state
# - AWS CLI: Must be configured with appropriate permissions
# - EKS cluster: Must be running with EFS CSI driver installed
#
# Features:
# - 🧹 Automatic cleanup of failed states and stuck resources
# - 🔍 Cluster state detection and optimization
# - ⚡ Comprehensive validation with health checks
# - 🛡️ Prerequisite validation before deployment
# - 🚀 Support for various cluster states
# =============================================================================

# Strict error handling: exit on any command failure, undefined variables, or pipe failures
# This ensures the script fails fast and doesn't continue with undefined state
set -euo pipefail

# =============================================================================
# OUTPUT FORMATTING CONFIGURATION
# =============================================================================
# Color codes for consistent, readable output across different terminal types.
# Using ANSI escape sequences that work across most modern terminals.
# The NC (No Color) constant is used to reset formatting after colored text.

readonly RED='\033[0;31m'      # Error messages and critical failures
readonly GREEN='\033[0;32m'    # Success messages and completed operations
readonly YELLOW='\033[1;33m'   # Warning messages and important notices
readonly BLUE='\033[0;34m'     # Information messages and status updates
readonly CYAN='\033[0;36m'     # Step headers and section dividers
readonly NC='\033[0m'          # Reset to default color (No Color)

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================
# All configuration values are centralized here for easy maintenance and updates.
# These constants define timeouts, resource names, and operational parameters
# that control the deployment behavior and resource management.

# Script metadata - automatically determined paths for reliable file operations
# These paths are used throughout the script to locate terraform outputs and
# Kubernetes manifests relative to the script location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
readonly SCRIPT_DIR      # Directory containing this deploy.sh script
readonly PROJECT_ROOT    # Root directory of the OpenEMR project
readonly TERRAFORM_DIR   # Terraform directory for state access

# Deployment timeouts - carefully tuned based on OpenEMR's startup characteristics
# These timeouts account for OpenEMR's complex initialization process which includes
# database schema creation, configuration setup, and service startup.
readonly POD_READY_TIMEOUT=1800          # 30 minutes - OpenEMR can take 7-11 minutes normally (can spike to 19 min)
readonly HEALTH_CHECK_TIMEOUT=600        # 10 minutes - For PVC binding and service readiness
readonly EFS_CSI_TIMEOUT=300             # 5 minutes - EFS CSI driver operations
readonly CLEANUP_WAIT_TIME=5             # 5 seconds - Wait after cleanup operations
readonly PVC_CHECK_INTERVAL=5            # 5 seconds - Interval between PVC status checks
readonly ESSENTIAL_PVC_COUNT=3           # 3 PVCs required for OpenEMR deployment

# Kubernetes resource names - consistent naming across all manifests
# These names must match the corresponding Kubernetes manifests in the k8s/ directory.
readonly DEPLOYMENT_NAME="openemr"           # Name of the OpenEMR deployment
readonly SERVICE_NAME="openemr-service"      # Name of the OpenEMR service
readonly NAMESPACE_DEFAULT="openemr"         # Default namespace for OpenEMR resources
readonly CLUSTER_NAME_DEFAULT="openemr-eks"  # Default EKS cluster name

# Storage classes required for OpenEMR deployment
# These storage classes must be available in the cluster for PVCs to bind properly.
# - efs-sc: Primary EFS storage for OpenEMR application data
# - efs-sc-backup: Secondary EFS storage for backup operations
# - gp3-monitoring-encrypted: GP3 EBS storage for monitoring components
readonly STORAGE_CLASSES=("efs-sc" "efs-sc-backup" "gp3-monitoring-encrypted")

# =============================================================================
# RUNTIME CONFIGURATION
# =============================================================================
# These variables are set at runtime based on environment variables or auto-detection.
# They provide flexibility for different deployment scenarios while maintaining
# sensible defaults for standard deployments.

# AWS region configuration with auto-detection
# First tries to use the AWS_REGION environment variable, then falls back to
# the configured AWS CLI region, and finally defaults to us-west-2.
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-west-2")}

# Cluster name detection with intelligent fallback
# This logic attempts to auto-detect the cluster name from Terraform outputs,
# which ensures the script works with the actual deployed infrastructure.
# If Terraform output is not available, it falls back to the default name.
if [ -z "${CLUSTER_NAME:-}" ]; then
    # Try to get cluster name from Terraform output
    # Uses multiple filters to ensure we get a valid cluster name:
    # - Removes terraform warnings
    # - Validates format with regex
    # - Takes the first valid result
    TERRAFORM_CLUSTER_NAME=$(cd "$PROJECT_ROOT/terraform" 2>/dev/null && terraform output -raw cluster_name 2>/dev/null | grep -v "Warning:" | grep -E "^[a-zA-Z0-9-]+$" | head -1 || true)
    if [ -n "$TERRAFORM_CLUSTER_NAME" ]; then
        CLUSTER_NAME="$TERRAFORM_CLUSTER_NAME"
    else
        CLUSTER_NAME="$CLUSTER_NAME_DEFAULT"
    fi
fi

# Namespace and SSL configuration
NAMESPACE=${NAMESPACE:-"$NAMESPACE_DEFAULT"}  # Kubernetes namespace for OpenEMR
SSL_CERT_ARN=${SSL_CERT_ARN:-""}              # Optional: AWS Certificate Manager ARN for SSL
DOMAIN_NAME=${DOMAIN_NAME:-""}                # Optional: Domain name for SSL certificate

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
# Centralized logging functions that provide consistent, color-coded output
# throughout the script. Each function has a specific purpose and visual style
# to make the deployment process easy to follow and debug.

# Standard information messages - used for general status updates
log_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
}

# Success messages - used when operations complete successfully
log_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

# Warning messages - used for non-critical issues that should be noted
log_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
}

# Error messages - used for failures and critical issues (redirected to stderr)
log_error() {
    echo -e "${RED}❌ $*${NC}" >&2
}

# Step indicators - used to mark the beginning of major operations
log_step() {
    echo -e "${CYAN}🔄 $*${NC}"
}

# Header messages - used for major section dividers and important announcements
log_header() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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

# Enhanced status display function - provides detailed deployment progress information
# This function shows real-time status of the OpenEMR deployment including pod phases,
# readiness status, and HTTP responsiveness for better user understanding.
show_deployment_status() {
    local ready_replicas desired_replicas available_replicas pod_count running_pods
    ready_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    available_replicas=$(kubectl get deployment openemr -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    
    # Sanitize all variables to ensure they're clean integers
    ready_replicas=$(printf '%s' "$ready_replicas" | tr -d '[:space:]')
    desired_replicas=$(printf '%s' "$desired_replicas" | tr -d '[:space:]')
    available_replicas=$(printf '%s' "$available_replicas" | tr -d '[:space:]')
    pod_count=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --no-headers 2>/dev/null | grep -c . 2>/dev/null || echo "0")
    running_pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c . 2>/dev/null || echo "0")
    
    # Ensure all variables are clean integers
    ready_replicas=$(printf '%s' "$ready_replicas" | tr -d '[:space:]')
    desired_replicas=$(printf '%s' "$desired_replicas" | tr -d '[:space:]')
    available_replicas=$(printf '%s' "$available_replicas" | tr -d '[:space:]')
    
    # Validate all variables are valid integers (fallback to 0 if invalid)
    if [ -z "$ready_replicas" ] || ! [[ "$ready_replicas" =~ ^[0-9]+$ ]]; then
        ready_replicas=0
    fi
    if [ -z "$desired_replicas" ] || ! [[ "$desired_replicas" =~ ^[0-9]+$ ]]; then
        desired_replicas=0
    fi
    if [ -z "$available_replicas" ] || ! [[ "$available_replicas" =~ ^[0-9]+$ ]]; then
        available_replicas=0
    fi
    if ! [[ "$pod_count" =~ ^[0-9]+$ ]]; then
        pod_count=0
    fi
    if ! [[ "$running_pods" =~ ^[0-9]+$ ]]; then
        running_pods=0
    fi

    echo -e "${CYAN}📈 Status: Ready=$ready_replicas/$desired_replicas | Available=$available_replicas | Pods=$running_pods/$pod_count${NC}"

    # Show detailed pod startup phases for better user understanding
    if [ "$pod_count" -gt 0 ]; then
        if [ "$ready_replicas" -eq 0 ] && [ "$running_pods" -gt 0 ]; then
            echo -e "${YELLOW}🔄 Phase: OpenEMR init → Database setup (10+ min) → Apache start → Ready${NC}"
        elif [ "$ready_replicas" -gt 0 ] && [ "$ready_replicas" -lt "$desired_replicas" ]; then
            echo -e "${YELLOW}🔄 Phase: Scaling up ($ready_replicas ready, waiting for $desired_replicas)${NC}"
        elif [ "$ready_replicas" -eq "$desired_replicas" ] && [ "$ready_replicas" -gt 0 ]; then
            echo -e "${GREEN}✅ Phase: All pods ready and serving traffic${NC}"
        fi
    fi

    if [ "$ready_replicas" -gt 0 ]; then
        local pod_name
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$pod_name" ]; then
            if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -f http://localhost:80/ > /dev/null" 2>/dev/null; then
                echo -e "${GREEN}   🎉 OpenEMR is responding to HTTP requests${NC}"
                return 0
            else
                echo -e "${YELLOW}   ⏳ OpenEMR starting up (containers ready but HTTP not responding yet)${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}   ⏳ Waiting for containers to start...${NC}"
    fi
    return 1
}

# Enhanced startup logs display function - shows recent OpenEMR container logs
# This function provides users with real-time visibility into the OpenEMR startup
# process, helping them understand what's happening during the long initialization.
show_startup_logs() {
    # Get the most recent pod (usually the one starting up)
    local pod_name
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$pod_name" ]; then
        echo -e "${CYAN}📋 Recent OpenEMR startup logs from pod: $pod_name${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # Get the last 10 lines of OpenEMR container logs
        local logs
        logs=$(kubectl logs "$pod_name" -n "$NAMESPACE" -c openemr --tail=10 2>/dev/null || echo "No logs available yet")
        
        if [ "$logs" != "No logs available yet" ]; then
            # Format logs with nice indentation and color coding
            echo "$logs" | while IFS= read -r line; do
                # Color code different types of log messages
                if echo "$line" | grep -q -E "(ERROR|FATAL|CRITICAL)"; then
                    echo -e "${RED}   $line${NC}"
                elif echo "$line" | grep -q -E "(WARN|WARNING)"; then
                    echo -e "${YELLOW}   $line${NC}"
                elif echo "$line" | grep -q -E "(INFO|Starting|Ready|Complete)"; then
                    echo -e "${GREEN}   $line${NC}"
                else
                    echo -e "${BLUE}   $line${NC}"
                fi
            done
        else
            echo -e "${YELLOW}   Container is still initializing - logs will appear shortly...${NC}"
        fi
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    else
        echo -e "${YELLOW}📋 No OpenEMR pods found yet - waiting for pod creation...${NC}"
        echo ""
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
# These utility functions provide common operations used throughout the script.
# They encapsulate complex logic, provide error handling, and ensure consistent
# behavior across different parts of the deployment process.

# Safe kubectl wrapper with comprehensive error handling
# This function ensures all kubectl commands use the correct namespace and
# provides detailed error reporting when commands fail. It's used throughout
# the script to maintain consistency and proper error handling.
kubectl_safe() {
    local namespace_arg=""
    # Only add namespace argument if NAMESPACE is set and not empty
    if [[ -n "${NAMESPACE:-}" ]]; then
        namespace_arg="-n $NAMESPACE"
    fi
    
    # Execute kubectl command and handle failures gracefully
    if ! kubectl "$namespace_arg" "$@"; then
        log_error "kubectl command failed: kubectl $namespace_arg $*"
        return 1
    fi
}

# Safe kubectl with JSON path extraction and fallback values
# This function safely extracts values from Kubernetes resources using JSONPath
# queries and provides fallback values when extraction fails. This prevents
# script failures due to missing or malformed resource data.
kubectl_get_json() {
    local resource="$1"    # The Kubernetes resource to query (e.g., "deployment/openemr")
    local jsonpath="$2"    # The JSONPath expression to extract data
    local default="${3:-}" # Fallback value if extraction fails
    
    local result
    # Attempt to extract the value using JSONPath
    if result=$(kubectl_safe get "$resource" -o jsonpath="$jsonpath" 2>/dev/null); then
        echo "$result"
    else
        # Return the default value if extraction fails
        echo "$default"
    fi
}

# Generate secure random password using OpenSSL
# Creates cryptographically secure random passwords suitable for database
# and application credentials. The password is base64 encoded but filtered
# to remove characters that might cause issues in various contexts.
generate_password() {
    local length="${1:-32}"  # Password length (default: 32 characters)
    # Generate base64 random data, remove problematic characters, and truncate to desired length
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

# Check and ensure database exists for OpenEMR deployment
# This function verifies database connectivity and creates an empty 'openemr' database
# if it doesn't exist, ensuring OpenEMR can complete its auto-configuration successfully.
check_and_ensure_database() {
    local temp_namespace
    temp_namespace="db-check-temp-$(date +%s)"
    local max_attempts=5
    local attempt=1
    
    log_info "Verifying database connection and ensuring 'openemr' database exists..."
    
    # Create temporary namespace for database check
    if ! kubectl create namespace "$temp_namespace" --dry-run=client -o yaml | kubectl apply -f -; then
        log_error "Failed to create namespace for database check"
        return 1
    fi
    
    # Create database credentials secret
    if ! kubectl create secret generic temp-db-credentials \
        --namespace="$temp_namespace" \
        --from-literal=mysql-host="$AURORA_ENDPOINT" \
        --from-literal=mysql-user="openemr" \
        --from-literal=mysql-password="$AURORA_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        log_error "Failed to create database credentials secret"
        kubectl delete namespace "$temp_namespace" 2>/dev/null || true
        return 1
    fi
    
    # Create database check pod
    if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: db-check-pod
  namespace: $temp_namespace
spec:
  restartPolicy: Never
  containers:
  - name: db-check
    image: openemr/openemr:$OPENEMR_VERSION
    env:
    - name: MYSQL_HOST
      valueFrom:
        secretKeyRef:
          name: temp-db-credentials
          key: mysql-host
    - name: MYSQL_USER
      valueFrom:
        secretKeyRef:
          name: temp-db-credentials
          key: mysql-user
    - name: MYSQL_PASSWORD
      valueFrom:
        secretKeyRef:
          name: temp-db-credentials
          key: mysql-password
    command: ["/bin/sh"]
    args:
    - -c
    - |
      set -e
      echo "Using OpenEMR container ($OPENEMR_VERSION) for database check..."
      echo "Testing MySQL connection to: \${MYSQL_HOST}"
      
      # Install MySQL client
      apk add --no-cache mysql-client
      
      # Test connection and check/create database
      echo "Testing database connection..."
      mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SELECT 1;" 2>/dev/null || {
        echo "❌ Failed to connect to MySQL database"
        exit 1
      }
      
      echo "✅ Successfully connected to MySQL database"
      
      # Check if openemr database exists
      echo "Checking if 'openemr' database exists..."
      DB_EXISTS=\$(mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SHOW DATABASES LIKE 'openemr';" 2>/dev/null | grep -c "openemr" || echo "0")
      
      if [ "\$DB_EXISTS" = "0" ]; then
        echo "⚠️  'openemr' database does not exist, creating empty database..."
        mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "CREATE DATABASE openemr CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" 2>/dev/null || {
          echo "❌ Failed to create openemr database"
          exit 1
        }
        echo "✅ Empty 'openemr' database created successfully"
      else
        echo "✅ 'openemr' database already exists"
      fi
      
      echo "✅ Database check completed successfully"
EOF
    then
        log_error "Failed to create database check pod"
        kubectl delete namespace "$temp_namespace" 2>/dev/null || true
        return 1
    fi
    
    # Wait for pod to be ready
    kubectl wait --for=condition=Ready pod/db-check-pod -n "$temp_namespace" --timeout=60s 2>/dev/null || true
    
    # Wait for completion
    while [ $attempt -le $max_attempts ]; do
        if kubectl logs db-check-pod -n "$temp_namespace" 2>/dev/null | grep -q "Database check completed successfully"; then
            log_success "Database check completed successfully"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_error "Database check failed after $max_attempts attempts"
            kubectl logs db-check-pod -n "$temp_namespace" 2>/dev/null || true
            kubectl delete namespace "$temp_namespace" 2>/dev/null || true
            return 1
        fi
        
        log_info "Waiting for database check to complete... (attempt $attempt/$max_attempts)"
        sleep 10
        attempt=$((attempt + 1))
    done
    
    # Cleanup
    kubectl delete namespace "$temp_namespace" 2>/dev/null || true
    log_success "Database is ready for OpenEMR deployment"
}

# Check if OpenEMR is already installed and running successfully
# This function performs a comprehensive check to determine if OpenEMR is
# already deployed and functional. It checks multiple conditions to ensure
# the application is truly ready for use.
check_openemr_installation() {
    # First check: Verify the namespace exists
    # If the namespace doesn't exist, OpenEMR is definitely not installed
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        return 1
    fi
    
    # Second check: Verify the deployment exists and has ready replicas
    # This checks that the Kubernetes deployment resource exists and has
    # at least one pod in the ready state
    local ready_replicas
    ready_replicas=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    # Ensure we have a clean integer
    ready_replicas=$(printf '%s' "$ready_replicas" | tr -d '[:space:]')
    if [ -z "$ready_replicas" ] || ! [[ "$ready_replicas" =~ ^[0-9]+$ ]]; then
        ready_replicas=0
    fi
    
    if [ "$ready_replicas" -ge 1 ]; then
        # Third check: Verify at least one pod is actually running
        # This ensures we have a pod in the Running phase, not just Ready
        local pod_name
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$pod_name" ]; then
            # Fourth check: Verify OpenEMR application is actually responding
            # This performs a real HTTP request to the OpenEMR login page to ensure
            # the application is not just running but also functional
            if kubectl exec "$pod_name" -n "$NAMESPACE" -- curl -s -f http://localhost/interface/login/login.php >/dev/null 2>&1; then
                return 0  # OpenEMR is fully functional
            fi
        fi
    fi
    
    return 1  # OpenEMR is not properly installed or functional
}

# Analyze current cluster state and determine deployment strategy
# This is a critical function that determines how the deployment should proceed.
# It examines the current state of the cluster and returns different codes
# to indicate the appropriate deployment strategy.
analyze_cluster_state() {
    log_step "Analyzing current cluster state..."
    
    # Check 1: Namespace existence
    # If the namespace doesn't exist, this is definitely a fresh deployment
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_info "Namespace '$NAMESPACE' does not exist - fresh deployment"
        return 0  # Fresh deployment needed
    fi
    
    # Check 2: Deployment existence
    # If the deployment doesn't exist, we need a fresh deployment
    if ! kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        log_info "OpenEMR deployment does not exist - fresh deployment"
        return 0  # Fresh deployment needed
    fi
    
    # Check 3: Deployment status analysis
    # Get detailed status information about the current deployment
    local ready_replicas desired_replicas available_replicas
    ready_replicas=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired_replicas=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    available_replicas=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    
    # Sanitize all variables to ensure they're clean integers
    ready_replicas=$(printf '%s' "$ready_replicas" | tr -d '[:space:]')
    desired_replicas=$(printf '%s' "$desired_replicas" | tr -d '[:space:]')
    available_replicas=$(printf '%s' "$available_replicas" | tr -d '[:space:]')
    
    # Validate all variables are valid integers (fallback to 0 if invalid)
    if [ -z "$ready_replicas" ] || ! [[ "$ready_replicas" =~ ^[0-9]+$ ]]; then
        ready_replicas=0
    fi
    if [ -z "$desired_replicas" ] || ! [[ "$desired_replicas" =~ ^[0-9]+$ ]]; then
        desired_replicas=0
    fi
    if [ -z "$available_replicas" ] || ! [[ "$available_replicas" =~ ^[0-9]+$ ]]; then
        available_replicas=0
    fi
    
    log_info "Current deployment state: $ready_replicas/$desired_replicas ready, $available_replicas available"
    
    # Check 4: Determine if OpenEMR is fully functional
    # If we have the expected number of ready replicas, test if they're actually working
    if [ "$ready_replicas" -ge "$desired_replicas" ] && [ "$ready_replicas" -gt 0 ]; then
        local pod_name
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$pod_name" ]; then
            # Test if the application is actually responding to requests
            if kubectl exec "$pod_name" -n "$NAMESPACE" -- curl -s -f http://localhost/interface/login/login.php >/dev/null 2>&1; then
                log_success "OpenEMR is already running and responsive"
                return 2  # Already running successfully - skip deployment
            fi
        fi
    fi
    
    # Check 5: Look for failed or stuck pods that need cleanup
    # Count pods in the Failed phase - these are completely dead and need removal
    local failed_pods
    # Count failed pods with robust error handling
    failed_pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Failed --no-headers 2>/dev/null | grep -c . || echo "0")
    # Clean the output: remove all whitespace and ensure it's a clean integer
    failed_pods=$(printf '%s' "$failed_pods" | tr -d '[:space:]')
    # Ensure we have a valid integer (fallback to 0 if empty or invalid)
    if [ -z "$failed_pods" ] || ! [[ "$failed_pods" =~ ^[0-9]+$ ]]; then
        failed_pods=0
    fi
    
    if [ "$failed_pods" -gt 0 ]; then
        log_warning "Found $failed_pods failed pods - cleanup needed"
        return 1  # Needs cleanup before proceeding
    fi
    
    # Check 6: Look for pods in problematic states that prevent normal operation
    # These states indicate pods that are stuck and can't recover on their own:
    # - CrashLoopBackOff: Pod keeps crashing and restarting
    # - ImagePullBackOff: Can't pull the container image
    # - ErrImagePull: Error occurred while pulling the image
    local problematic_pods
    # Count problematic pods with robust error handling
    problematic_pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --no-headers 2>/dev/null | grep -c -E "(CrashLoopBackOff|ImagePullBackOff|ErrImagePull)" || echo "0")
    # Clean the output: remove all whitespace, newlines, and ensure it's a clean integer
    problematic_pods=$(printf '%s' "$problematic_pods" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo "0")
    
    if [ "$problematic_pods" -gt 0 ]; then
        log_warning "Found $problematic_pods pods in problematic states - cleanup needed"
        return 1  # Needs cleanup before proceeding
    fi
    
    # If we reach here, the deployment exists but isn't fully ready
    # This could be a normal deployment in progress or a partially failed state
    log_info "Deployment exists but not fully ready - proceeding with update"
    return 0  # Proceed with deployment (will handle updates and fixes)
}

# Return codes for analyze_cluster_state():
# 0 = Fresh deployment or update needed
# 1 = Cleanup required before deployment
# 2 = Already running successfully, skip deployment

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================
# These functions handle cleanup of failed or stuck Kubernetes resources.
# They are essential for recovering from partial failures and ensuring
# clean deployments.

# Clean up failed deployment states and stuck resources
# This function removes pods and resources that are in error states and
# preventing normal deployment. It's called when the cluster state analysis
# detects failed or problematic resources.
cleanup_failed_deployment() {
    log_step "Cleaning up failed deployment states..."
    
    # Remove pods in Failed phase
    # These are pods that have completely failed and are dead. They need to be
    # forcefully deleted to allow the deployment controller to create new ones.
    log_info "Removing pods in Error/CrashLoopBackOff states..."
    kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Failed --no-headers 2>/dev/null | \
        awk '{print $1}' | \
        xargs -r kubectl delete pod -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Remove pods in problematic states
    # These pods are stuck in states where they can't recover on their own.
    # Force deletion allows the deployment controller to create replacement pods.
    kubectl get pods -n "$NAMESPACE" -l app=openemr --no-headers 2>/dev/null | \
        grep -E "(CrashLoopBackOff|ImagePullBackOff|ErrImagePull)" | \
        awk '{print $1}' | \
        xargs -r kubectl delete pod -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Clean up old replica sets
    # During rolling updates, old replica sets with 0 replicas can accumulate.
    # These should be cleaned up to keep the cluster tidy and avoid confusion.
    log_info "Removing old replica sets..."
    kubectl get replicasets -n "$NAMESPACE" -l app=openemr --no-headers 2>/dev/null | \
        awk '$2==0 {print $1}' | \
        xargs -r kubectl delete replicaset -n "$NAMESPACE" 2>/dev/null || true
    
    # Wait for cleanup to complete
    # Give Kubernetes time to process the deletions before proceeding.
    # This prevents race conditions and ensures clean state.
    sleep "$CLEANUP_WAIT_TIME"
    log_success "Cleanup completed"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validate all prerequisites
validate_prerequisites() {
    log_step "Validating prerequisites..."
    
    local errors=0
    
    # Validate Redis availability (critical for OpenEMR functionality)
    if [ "$REDIS_ENDPOINT" = "redis-not-available" ]; then
        log_error "Redis endpoint not available - CRITICAL FAILURE"
        log_error "ElastiCache serverless cache is required for OpenEMR deployment"
        ((errors++))
    else
        log_success "Redis endpoint validated: $REDIS_ENDPOINT"
    fi
    
    # Validate Aurora availability (critical for data persistence)
    if [ -z "$AURORA_ENDPOINT" ] || [ "$AURORA_ENDPOINT" = "aurora-not-available" ]; then
        log_error "Aurora endpoint not available - CRITICAL FAILURE"
        log_error "Database is required for OpenEMR deployment"
        ((errors++))
    else
        log_success "Aurora endpoint validated: $AURORA_ENDPOINT"
    fi
    
    # Validate EFS CSI driver (critical for persistent storage)
    log_info "Validating EFS CSI driver..."
    if ! kubectl get storageclass efs-sc >/dev/null 2>&1; then
        log_error "EFS storage class not found - CRITICAL FAILURE"
        log_error "EFS CSI driver must be installed for persistent storage"
        ((errors++))
    else
        log_success "EFS storage class validated"
    fi
    
    # Validate cluster connectivity (critical for deployment)
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster - CRITICAL FAILURE"
        log_error "Please ensure kubeconfig is properly configured"
        ((errors++))
    else
        log_success "Kubernetes cluster connectivity validated"
    fi
    
    # Fail fast if any critical prerequisites are missing
    if [ $errors -gt 0 ]; then
        log_error "Prerequisites validation failed with $errors critical errors"
        log_error "Deployment cannot proceed - fix prerequisites and retry"
        exit 1
    fi
    
     log_success "All prerequisites validated"
}

# Validate deployment success
validate_deployment_success() {
    log_step "Validating deployment success..."
    
    # Wait for at least one pod to be ready
    local max_wait=$POD_READY_TIMEOUT  # Use configured timeout
    local wait_time=0
    local ready_pods=0
    
    while [ $wait_time -lt $max_wait ]; do
        ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c . || echo "0")
        
        if [ "$ready_pods" -ge 1 ]; then
            log_success "Found $ready_pods running OpenEMR pods"
            break
        fi
        
        log_info "Waiting for OpenEMR pods to be ready... (${wait_time}s elapsed)"
        sleep 30
        wait_time=$((wait_time + 30))
    done
    
    if [ "$ready_pods" -eq 0 ]; then
        log_error "No OpenEMR pods are running after 30 minutes"
        log_info "Debugging pod status..."
        kubectl get pods -n "$NAMESPACE" -l app=openemr
        kubectl describe pods -n "$NAMESPACE" -l app=openemr
        exit 1
    fi
    
    # Test OpenEMR responsiveness
    log_info "Testing OpenEMR responsiveness..."
    local test_pod
    test_pod=$(kubectl get pods -n "$NAMESPACE" -l app=openemr --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$test_pod" ]; then
        local max_health_checks=$((HEALTH_CHECK_TIMEOUT / 10))  # Convert seconds to 10-second intervals
        local health_check=0
        
        while [ $health_check -lt $max_health_checks ]; do
            if kubectl exec "$test_pod" -n "$NAMESPACE" -- curl -s -f http://localhost/interface/login/login.php >/dev/null 2>&1; then
                log_success "OpenEMR is responding to HTTP requests"
                return 0
            fi
            
            log_info "Waiting for OpenEMR to be responsive... (check $((health_check + 1))/$max_health_checks)"
            sleep 10
            health_check=$((health_check + 1))
        done
        
        log_error "OpenEMR is not responding to HTTP requests after 10 minutes"
        log_info "Debugging pod logs..."
        kubectl logs "$test_pod" -n "$NAMESPACE" --tail=50
        exit 1
    else
        log_error "No running pods found for health check"
        exit 1
    fi
}

# Ensure kubeconfig is properly configured
ensure_kubeconfig() {
    log_step "Configuring kubectl..."

    # Check if cluster exists
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_error "EKS cluster '$CLUSTER_NAME' not found in region '$AWS_REGION'"
        exit 1
    fi

    # Update kubeconfig
    log_info "Updating kubeconfig for cluster: $CLUSTER_NAME"
    if aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"; then
        log_success "Kubeconfig updated successfully"
    else
        log_error "Failed to update kubeconfig"
        exit 1
    fi

    # Verify kubectl connectivity
    log_info "Verifying kubectl connectivity..."
    if kubectl cluster-info >/dev/null 2>&1; then
        log_success "kubectl connectivity verified"
    else
        log_error "kubectl cannot connect to cluster"
        exit 1
    fi
}

# Validate deployment health
validate_deployment_health() {
    echo ""
    log_header "Final Health Validation"

    local max_attempts=30  # 5 minutes of final validation
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "Health check $attempt/$max_attempts"

        # Get deployment status
        local ready_replicas desired_replicas available_replicas
        ready_replicas=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired_replicas=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        available_replicas=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        
        # Sanitize all variables to ensure they're clean integers
        ready_replicas=$(printf '%s' "$ready_replicas" | tr -d '[:space:]')
        desired_replicas=$(printf '%s' "$desired_replicas" | tr -d '[:space:]')
        available_replicas=$(printf '%s' "$available_replicas" | tr -d '[:space:]')
        
        # Validate all variables are valid integers (fallback to 0 if invalid)
        if [ -z "$ready_replicas" ] || ! [[ "$ready_replicas" =~ ^[0-9]+$ ]]; then
            ready_replicas=0
        fi
        if [ -z "$desired_replicas" ] || ! [[ "$desired_replicas" =~ ^[0-9]+$ ]]; then
            desired_replicas=0
        fi
        if [ -z "$available_replicas" ] || ! [[ "$available_replicas" =~ ^[0-9]+$ ]]; then
            available_replicas=0
        fi

        log_info "Deployment: $ready_replicas/$desired_replicas ready, $available_replicas available"

        if [ "$ready_replicas" -ge "$desired_replicas" ] && [ "$ready_replicas" -gt 0 ]; then
            # Test OpenEMR functionality
            local pod_name
            pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

            if [ -n "$pod_name" ]; then
                log_info "Testing OpenEMR functionality in pod: ${pod_name}"

                # Test basic HTTP connectivity
                if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -f http://localhost:80/ > /dev/null" 2>/dev/null; then
                    log_success "HTTP server responding"

                    # Test login page
                    if kubectl exec -n "$NAMESPACE" "$pod_name" -c openemr -- sh -c "curl -s -f http://localhost:80/interface/login/login.php > /dev/null" 2>/dev/null; then
                        log_success "OpenEMR login page accessible"
                        echo ""
                        log_header "DEPLOYMENT SUCCESSFUL!"
                        return 0
                    else
                        log_warning "HTTP works but login page not ready yet"
                    fi
                else
                    log_warning "HTTP server not responding yet"
                fi
            else
                log_warning "No pods found"
            fi
        else
            log_warning "Waiting for deployment ($ready_replicas/$desired_replicas ready)"
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_info "Waiting 10 seconds before next check..."
            sleep 10
        fi
        ((attempt++))
    done

    echo ""
    log_error "Health validation timed out after $max_attempts attempts"
    log_warning "The deployment may still be starting up. Check status with:"
    log_warning "  kubectl get pods -n $NAMESPACE"
    log_warning "  kubectl logs -n $NAMESPACE deployment/openemr"
    return 1
}

# Validate storage classes
validate_storage_classes() {
    log_step "Validating storage class configuration..."

    local validation_failed=false
    local storage_classes=("${STORAGE_CLASSES[@]}")

    # Get EFS ID
    local efs_id
    efs_id=$(cd "$PROJECT_ROOT/terraform" && terraform output -raw efs_id 2>/dev/null || echo "")
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

        # Check if EFS ID is correctly set in the storage class
        if [[ "$sc" == efs-* ]]; then
            local current_efs_id
            current_efs_id=$(kubectl get storageclass "$sc" -o jsonpath='{.parameters.fileSystemId}' 2>/dev/null || echo "")
            if [ "$current_efs_id" != "$efs_id" ]; then
                log_error "Storage class $sc has incorrect EFS ID: $current_efs_id (expected: $efs_id)"
                validation_failed=true
            else
                log_success "Storage class $sc is correctly configured"
            fi
        else
            log_success "Storage class $sc exists"
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

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy OpenEMR to EKS cluster with automatic infrastructure provisioning"
    echo ""
    echo "Options:"
    echo "  --cluster-name NAME     EKS cluster name (default: auto-detect from Terraform, fallback: openemr-eks)"
    echo "  --aws-region REGION     AWS region (default: us-west-2)"
    echo "  --namespace NAMESPACE   Kubernetes namespace (default: openemr)"
    echo "  --ssl-cert-arn ARN      AWS Certificate Manager ARN for SSL"
    echo "  --domain-name DOMAIN    Domain name for SSL configuration"
    echo "  --help                  Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_NAME            EKS cluster name"
    echo "  AWS_REGION              AWS region"
    echo "  NAMESPACE               Kubernetes namespace"
    echo "  SSL_CERT_ARN            AWS Certificate Manager ARN"
    echo "  DOMAIN_NAME             Domain name for SSL"
    echo ""
    echo "Example:"
    echo "  $0 --cluster-name my-cluster --aws-region us-east-1"
    echo "  CLUSTER_NAME=my-cluster AWS_REGION=us-east-1 $0"
    echo ""
    echo "Prerequisites:"
    echo "  - EKS cluster must be deployed and accessible"
    echo "  - Terraform outputs must be available"
    echo "  - kubectl, aws CLI, and helm must be installed"
    echo "  - AWS credentials must be configured"
    exit 0
}

# Parse command line arguments
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
        --ssl-cert-arn)
            SSL_CERT_ARN="$2"
            shift 2
            ;;
        --domain-name)
            DOMAIN_NAME="$2"
            shift 2
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

# Detect AWS region from Terraform state if not explicitly set via --aws-region
get_aws_region

# =============================================================================
# MAIN EXECUTION
# =============================================================================
# This is the main execution flow of the deployment script. It follows a
# carefully orchestrated sequence of operations designed to handle any cluster
# state and ensure a successful OpenEMR deployment.
#
# EXECUTION FLOW:
# 1. Configuration and Environment Setup
# 2. Infrastructure Prerequisites Validation
# 3. Terraform Output Retrieval
# 4. Cluster State Analysis
# 5. Cleanup Operations (if needed)
# 6. Kubernetes Resource Creation
# 7. Application Deployment
# 8. Health Validation and Verification
#
# Each step includes comprehensive error handling and detailed logging to
# ensure reliability and maintainability.

log_header "OpenEMR EKS Deployment Starting"

log_info "Configuration:"
log_info "  Script location: $SCRIPT_DIR"
log_info "  Project root: $PROJECT_ROOT"
log_info "  Working directory: $(pwd)"
log_info "  AWS Region: $AWS_REGION"
log_info "  Cluster Name: $CLUSTER_NAME"
log_info "  Namespace: $NAMESPACE"

# Check prerequisites
log_step "Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed." >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { log_error "AWS CLI is required but not installed." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { log_error "Helm is required but not installed." >&2; exit 1; }
log_success "All required tools found"

# Ensure kubeconfig is properly configured
ensure_kubeconfig

# Check AWS credentials
log_step "Verifying AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS credentials not configured or invalid." >&2
    log_warning "Run: aws configure" >&2
    exit 1
fi
log_success "AWS credentials verified"

# Check if cluster exists and is accessible
log_step "Checking cluster accessibility..."
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    log_error "Cluster $CLUSTER_NAME not found or not accessible." >&2
    log_warning "Ensure the cluster is deployed and you have proper permissions." >&2
    exit 1
fi
log_success "Cluster accessibility verified"

# Validate required variables for WAF functionality
log_step "Validating WAF configuration..."
if [ "${enable_waf:-false}" = "true" ] && [ -z "$WAF_ACL_ARN" ]; then
    log_warning "WAF enabled but no WAF ACL ARN found in Terraform outputs"
    log_warning "This may indicate WAF resources haven't been created yet"
fi

# Update kubeconfig
log_step "Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

# Verify cluster connection
log_step "Verifying cluster connection..."
kubectl cluster-info 2>/dev/null | head -1

# Get Terraform outputs
log_step "Getting infrastructure details..."
cd "$PROJECT_ROOT/terraform"

EFS_ID=$(terraform output -raw efs_id)
AURORA_ENDPOINT=$(terraform output -raw aurora_endpoint)
AURORA_PASSWORD=$(terraform output -raw aurora_password)
REDIS_ENDPOINT=$(terraform output -raw redis_endpoint 2>/dev/null || echo "redis-not-available")
REDIS_PORT=$(terraform output -raw redis_port 2>/dev/null || echo "6379")
REDIS_PASSWORD=$(terraform output -raw redis_password 2>/dev/null || echo "fallback-password")
ALB_LOGS_BUCKET=$(terraform output -raw alb_logs_bucket_name)

# Validate critical infrastructure components
log_step "Validating infrastructure components..."

# Check if Redis is available - Redis is critical for OpenEMR
if [ "$REDIS_ENDPOINT" = "redis-not-available" ]; then
    log_error "Error: Redis endpoint not available. Redis is required for OpenEMR deployment."
    log_error "   Please ensure ElastiCache serverless cache is properly created and accessible."
    log_error "   Check Terraform outputs and ensure all infrastructure is deployed successfully."
    log_warning "   Troubleshooting steps:"
    log_warning "   1. Run 'cd terraform && terraform output redis_endpoint' to check output"
    log_warning "   2. Check if ElastiCache serverless cache exists in AWS console"
    log_warning "   3. Verify Terraform state is consistent with actual AWS resources"
    exit 1
else
    log_success "Redis endpoint available: ${REDIS_ENDPOINT}"
fi

# Validate other critical components
if [ -z "$EFS_ID" ]; then
    log_error "Error: EFS ID not available"
    exit 1
fi

if [ -z "$AURORA_ENDPOINT" ]; then
    log_error "Error: Aurora endpoint not available"
    exit 1
fi

log_success "All critical infrastructure components validated"
WAF_ACL_ARN=$(terraform output -raw waf_web_acl_arn 2>/dev/null || echo "")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get OpenEMR IAM role ARN for IRSA
OPENEMR_ROLE_ARN=$(terraform output -raw openemr_role_arn 2>/dev/null || echo "")
if [ -z "$OPENEMR_ROLE_ARN" ]; then
    log_warning "Could not retrieve OpenEMR role ARN from Terraform"
    log_warning "IRSA annotation may not work properly"
fi

# Get autoscaling configuration
OPENEMR_MIN_REPLICAS=$(terraform output -json openemr_autoscaling_config | jq -r '.min_replicas')
OPENEMR_MAX_REPLICAS=$(terraform output -json openemr_autoscaling_config | jq -r '.max_replicas')
OPENEMR_CPU_THRESHOLD=$(terraform output -json openemr_autoscaling_config | jq -r '.cpu_utilization_threshold')
OPENEMR_MEMORY_THRESHOLD=$(terraform output -json openemr_autoscaling_config | jq -r '.memory_utilization_threshold')
OPENEMR_SCALE_DOWN_STABILIZATION=$(terraform output -json openemr_autoscaling_config | jq -r '.scale_down_stabilization_seconds')
OPENEMR_SCALE_UP_STABILIZATION=$(terraform output -json openemr_autoscaling_config | jq -r '.scale_up_stabilization_seconds')

# Get OpenEMR application configuration
OPENEMR_VERSION=$(terraform output -json openemr_app_config | jq -r '.version')
OPENEMR_API_ENABLED=$(terraform output -json openemr_app_config | jq -r '.api_enabled')
PATIENT_PORTAL_ENABLED=$(terraform output -json openemr_app_config | jq -r '.patient_portal_enabled')

cd "$PROJECT_ROOT/k8s"

# Configure SSL certificate handling
log_step "Configuring SSL certificates..."
if [ -n "$SSL_CERT_ARN" ]; then
  log_success "Using AWS Certificate Manager certificate: $SSL_CERT_ARN"
  SSL_MODE="acm"
else
  log_warning "No SSL certificate provided - using OpenEMR self-signed certificates"
  log_warning "Note: Browsers will show security warnings for self-signed certificates"
  SSL_MODE="self-signed"
fi

# Replace placeholders in manifests
log_step "Preparing manifests..."
sed -i.bak "s/\${EFS_ID}/$EFS_ID/g" storage.yaml
sed -i.bak "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" deployment.yaml
sed -i.bak "s/\${OPENEMR_VERSION}/$OPENEMR_VERSION/g" deployment.yaml
sed -i.bak "s/\${OPENEMR_VERSION}/$OPENEMR_VERSION/g" ssl-renewal.yaml
sed -i.bak "s/\${DOMAIN_NAME}/$DOMAIN_NAME/g" deployment.yaml
sed -i.bak "s/\${AWS_REGION}/$AWS_REGION/g" deployment.yaml
sed -i.bak "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" deployment.yaml
sed -i.bak "s|\${OPENEMR_ROLE_ARN}|$OPENEMR_ROLE_ARN|g" deployment.yaml

# Substitute OpenEMR role ARN for IRSA annotation
if [ -n "$OPENEMR_ROLE_ARN" ]; then
    sed -i.bak "s|\${OPENEMR_ROLE_ARN}|$OPENEMR_ROLE_ARN|g" security.yaml
else
    log_error "OpenEMR role ARN not available. Cannot configure IRSA."
    exit 1
fi

# Configure OpenEMR feature environment variables based on Terraform settings
log_step "Configuring OpenEMR feature environment variables..."

# Prepare environment variables to add
OPENEMR_ENV_VARS=""

# Add API configuration if enabled
if [ "$OPENEMR_API_ENABLED" = "true" ]; then
    log_success "Adding OpenEMR API environment variables"
    OPENEMR_ENV_VARS="$OPENEMR_ENV_VARS
        - name: OPENEMR_SETTING_rest_api
          value: \"1\"
        - name: OPENEMR_SETTING_rest_fhir_api
          value: \"1\""
fi

# Add Patient Portal configuration if enabled
if [ "$PATIENT_PORTAL_ENABLED" = "true" ]; then
    log_success "Adding Patient Portal environment variables"
    OPENEMR_ENV_VARS="$OPENEMR_ENV_VARS
        - name: OPENEMR_SETTING_portal_onsite_two_enable
          value: \"1\"
        - name: OPENEMR_SETTING_portal_onsite_two_address
          value: \"https://$DOMAIN_NAME/portal\"
        - name: OPENEMR_SETTING_ccda_alt_service_enable
          value: \"3\"
        - name: OPENEMR_SETTING_rest_portal_api
          value: \"1\""
fi

# Insert the environment variables into the deployment manifest
if [ -n "$OPENEMR_ENV_VARS" ]; then
    # Find the line with the comment about conditional environment variables and insert after it
    sed -i.bak "/# OPENEMR_SETTING_rest_portal_api will be added if portal is enabled/a\\
$OPENEMR_ENV_VARS" deployment.yaml
fi
sed -i.bak "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" logging.yaml
sed -i.bak "s/\${AWS_REGION}/$AWS_REGION/g" logging.yaml
sed -i.bak "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" logging.yaml
sed -i.bak "s|\${OPENEMR_ROLE_ARN}|$OPENEMR_ROLE_ARN|g" logging.yaml
sed -i.bak "s/\${S3_BUCKET_NAME}/$ALB_LOGS_BUCKET/g" ingress.yaml

# Configure WAF ACL ARN if available
if [ -n "$WAF_ACL_ARN" ]; then
    log_info "Configuring WAF ACL ARN: $WAF_ACL_ARN"
    sed -i.bak "s|\${WAF_ACL_ARN}|$WAF_ACL_ARN|g" ingress.yaml
    log_success "WAF protection enabled with ACL: $WAF_ACL_ARN"
else
    log_warning "WAF ACL ARN not available - checking if WAF is enabled..."
    # Check if WAF is enabled in Terraform
    if terraform output -raw waf_enabled 2>/dev/null | grep -q "true"; then
        log_error "Error: WAF is enabled but ACL ARN not found"
        log_warning "This may indicate a Terraform deployment issue"
        log_warning "Continuing without WAF protection..."
    else
        log_info "WAF is disabled - continuing without WAF protection"
    fi
    # Remove WAF annotation
    sed -i.bak '/alb.ingress.kubernetes.io\/wafv2-acl-arn:/d' ingress.yaml
fi

# Configure autoscaling parameters
log_step "Configuring autoscaling parameters..."
sed -i.bak "s/\${OPENEMR_MIN_REPLICAS}/$OPENEMR_MIN_REPLICAS/g" hpa.yaml
sed -i.bak "s/\${OPENEMR_MAX_REPLICAS}/$OPENEMR_MAX_REPLICAS/g" hpa.yaml
sed -i.bak "s/\${OPENEMR_CPU_THRESHOLD}/$OPENEMR_CPU_THRESHOLD/g" hpa.yaml
sed -i.bak "s/\${OPENEMR_MEMORY_THRESHOLD}/$OPENEMR_MEMORY_THRESHOLD/g" hpa.yaml
sed -i.bak "s/\${OPENEMR_SCALE_DOWN_STABILIZATION}/$OPENEMR_SCALE_DOWN_STABILIZATION/g" hpa.yaml
sed -i.bak "s/\${OPENEMR_SCALE_UP_STABILIZATION}/$OPENEMR_SCALE_UP_STABILIZATION/g" hpa.yaml

log_success "Autoscaling configured: ${OPENEMR_MIN_REPLICAS}-${OPENEMR_MAX_REPLICAS} replicas, CPU: ${OPENEMR_CPU_THRESHOLD}%, Memory: ${OPENEMR_MEMORY_THRESHOLD}%"

# Configure SSL in service manifest
if [ "$SSL_MODE" = "acm" ]; then
  # ACM mode: SSL re-encryption (ACM cert at NLB, self-signed cert to pod)
  log_info "Configuring ACM SSL with re-encryption to OpenEMR pods..."

  # Set backend protocol to SSL for re-encryption
  sed -i.bak "s|\${BACKEND_PROTOCOL}|ssl|g" service.yaml

  # Replace SSL certificate ARN placeholder
  sed -i.bak "s|\${SSL_CERT_ARN}|$SSL_CERT_ARN|g" service.yaml

  # Enable SSL annotations by removing comment markers
  sed -i.bak 's|#    service.beta.kubernetes.io/aws-load-balancer-ssl-ports:|    service.beta.kubernetes.io/aws-load-balancer-ssl-ports:|g' service.yaml
  sed -i.bak 's|#    service.beta.kubernetes.io/aws-load-balancer-ssl-cert:|    service.beta.kubernetes.io/aws-load-balancer-ssl-cert:|g' service.yaml
  sed -i.bak 's|#    service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy:|    service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy:|g' service.yaml
else
  # Self-signed mode: SSL passthrough (no SSL termination at NLB)
  log_info "Configuring self-signed SSL passthrough..."

  # Set backend protocol to TCP for passthrough
  sed -i.bak "s|\${BACKEND_PROTOCOL}|tcp|g" service.yaml

  # Remove SSL certificate annotations (no SSL termination at NLB)
  sed -i.bak '/service.beta.kubernetes.io\/aws-load-balancer-ssl-/d' service.yaml
fi

# Use passwords from Terraform (retrieved above)
log_step "Using infrastructure passwords from Terraform..."

# Check if OpenEMR is already installed and configured
if check_openemr_installation; then
    log_success "Using existing OpenEMR installation"
    log_info "Admin credentials will not be changed - existing credentials remain valid"

    # Get existing admin password from secret
    if kubectl get secret openemr-app-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
        ADMIN_PASSWORD=$(kubectl get secret openemr-app-credentials -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "")
        if [ -n "$ADMIN_PASSWORD" ]; then
            log_success "Retrieved existing admin password from secret"
        else
            log_warning "Could not retrieve existing admin password - generating new one"
            ADMIN_PASSWORD=$(generate_password)
        fi
    else
        log_warning "No existing app credentials secret found - generating new password"
        ADMIN_PASSWORD=$(generate_password)
    fi
else
    log_info "Proceeding with new OpenEMR installation"
    ADMIN_PASSWORD=$(generate_password)
fi

# Analyze current cluster state
analyze_cluster_state
cluster_state_result=$?

if [ $cluster_state_result -eq 2 ]; then
    log_success "OpenEMR is already running successfully - skipping deployment"
    # Still need to ensure service and other components are applied
    log_info "Ensuring service and other components are up to date..."
    kubectl apply -f service.yaml
    kubectl apply -f ingress.yaml 2>/dev/null || true
    kubectl apply -f network-policies.yaml 2>/dev/null || true
    
    # Clean up temporary file
    rm -f deployment-temp.yaml 2>/dev/null || true
    
    # Skip the deployment and rollout logic
    log_success "All components verified - OpenEMR is ready"
    log_success "OpenEMR deployment completed successfully!"
    exit 0
fi

# Clean up failed deployment states
cleanup_failed_deployment

# Create namespace
log_step "Creating namespaces..."
kubectl apply -f namespace.yaml
log_success "Namespace '$NAMESPACE' ensured."

# Create secrets with actual values
log_step "Creating secrets..."
kubectl create secret generic openemr-db-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=mysql-host="$AURORA_ENDPOINT" \
  --from-literal=mysql-user="openemr" \
  --from-literal=mysql-password="$AURORA_PASSWORD" \
  --from-literal=mysql-database="openemr" \
  --dry-run=client -o yaml | kubectl apply -f -
log_info "Database credentials secret created/updated."

kubectl create secret generic openemr-redis-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=redis-host="$REDIS_ENDPOINT" \
  --from-literal=redis-port="$REDIS_PORT" \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
log_info "Redis credentials secret created/updated."

kubectl create secret generic openemr-app-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=admin-user="admin" \
  --from-literal=admin-password="$ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
log_info "Application credentials secret created/updated."
log_success "All secrets configured."

# Run database check
if ! check_and_ensure_database; then
    log_error "Database check failed - deployment cannot proceed"
    exit 1
fi

# Display application and feature configuration
log_info "OpenEMR Application Configuration:"
log_success "OpenEMR Version: $OPENEMR_VERSION"
log_info "To change version: Set openemr_version in terraform.tfvars"

log_info "OpenEMR Feature Configuration:"
if [ "$OPENEMR_API_ENABLED" = "true" ]; then
    log_success "REST API and FHIR endpoints: ENABLED"
else
    log_warning "REST API and FHIR endpoints: DISABLED"
    log_info "To enable: Set enable_openemr_api = true in terraform.tfvars"
fi

if [ "$PATIENT_PORTAL_ENABLED" = "true" ]; then
    log_success "Patient Portal: ENABLED"
else
    log_warning "Patient Portal: DISABLED"
    log_info "To enable: Set enable_patient_portal = true in terraform.tfvars"
fi

# Apply storage configuration
log_step "Setting up storage..."
kubectl apply -f storage.yaml
log_success "Storage configuration applied."

# Validate storage classes after creation
log_step "Validating storage classes..."
if ! validate_storage_classes; then
    log_warning "Storage class validation failed - attempting to recreate..."

    # Get current EFS ID
    current_efs_id=$(cd "$PROJECT_ROOT/terraform" && terraform output -raw efs_id 2>/dev/null || echo "")

    if [ -n "$current_efs_id" ]; then
        log_info "Recreating storage classes with EFS ID: $current_efs_id"

        # Delete existing storage classes
        kubectl delete storageclass efs-sc efs-sc-backup 2>/dev/null || true

        # Recreate from template (create temporary file to avoid modifying original)
        temp_storage_file=$(mktemp)
        sed "s/fileSystemId: \${EFS_ID}/fileSystemId: $current_efs_id/g" storage.yaml > "$temp_storage_file"
        
        if kubectl apply -f "$temp_storage_file"; then
            log_success "Storage classes applied from temporary file"
        else
            log_error "Failed to apply storage classes from temporary file"
            rm -f "$temp_storage_file"
            exit 1
        fi
        
        # Clean up temporary file
        rm -f "$temp_storage_file"

        # Validate again
        if validate_storage_classes; then
            log_success "Storage classes recreated successfully"
        else
            log_error "Storage class recreation failed"
            exit 1
        fi
    else
        log_error "Could not get EFS ID for storage class recreation"
        exit 1
    fi
fi

# Ensure EFS CSI controller picks up IAM role annotation from Terraform
log_step "Ensuring EFS CSI controller is properly configured..."
kubectl rollout restart daemonset efs-csi-node -n kube-system
kubectl rollout restart deployment efs-csi-controller -n kube-system

# Wait for EFS CSI controller to be ready
log_info "Waiting for EFS CSI controller to be ready..."
kubectl rollout status daemonset efs-csi-node -n kube-system --timeout="${EFS_CSI_TIMEOUT}s"
kubectl rollout status deployment efs-csi-controller -n kube-system --timeout="${EFS_CSI_TIMEOUT}s"
log_success "EFS CSI controller is ready."

# Note: PVC binding check moved to after deployment due to WaitForFirstConsumer mode

# Apply security configuration
log_step "Applying security configuration..."
kubectl apply -f security.yaml
log_success "Security configuration applied."

# Apply logging configuration FIRST (before deployment)
log_step "Setting up logging..."
# Substitute environment variables in logging.yaml
sed -i.bak "s/\${AWS_REGION}/$AWS_REGION/g" logging.yaml
sed -i.bak "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" logging.yaml
kubectl apply -f logging.yaml
log_success "Logging configuration applied."

# Apply network policies
log_step "Applying network policies..."
kubectl apply -f network-policies.yaml 2>/dev/null || log_info "Network policies not found or already applied"
log_success "Network policies applied."

# Apply service configuration
log_step "Applying service configuration..."
kubectl apply -f service.yaml
log_success "Service configuration applied."

# Apply deployment configuration
log_step "Applying deployment configuration..."
kubectl apply -f deployment.yaml
log_success "Deployment configuration applied."

# For WaitForFirstConsumer storage classes, PVCs bind when pods are scheduled
# So we need to wait for pods to be scheduled first, then check PVC binding
log_step "Waiting for pods to be scheduled (required for WaitForFirstConsumer PVC binding)..."
sleep 10  # Give pods time to be scheduled

# Now check PVC binding after pods are scheduled
log_step "Checking PVC binding status..."
pvc_wait_time=0
pvc_wait_max=$HEALTH_CHECK_TIMEOUT  # Use configured timeout
essential_pvcs_bound=0

while [ $pvc_wait_time -lt $pvc_wait_max ]; do
    # Count bound PVCs with robust error handling
    essential_pvcs_bound=$(kubectl get pvc -n "$NAMESPACE" -l app=openemr --no-headers 2>/dev/null | grep -c "Bound" 2>/dev/null || echo "0")
    # Ensure we have a valid integer (fallback to 0 if empty or invalid)
    if ! [[ "$essential_pvcs_bound" =~ ^[0-9]+$ ]]; then
        essential_pvcs_bound=0
    fi
    
    if [ "$essential_pvcs_bound" -ge "$ESSENTIAL_PVC_COUNT" ]; then
        log_success "Essential PVCs are bound ($essential_pvcs_bound/$ESSENTIAL_PVC_COUNT)"
        break
    fi
    
    log_info "Waiting for PVCs to be bound... ($essential_pvcs_bound/$ESSENTIAL_PVC_COUNT bound, ${pvc_wait_time}s elapsed)"
    sleep $PVC_CHECK_INTERVAL
    pvc_wait_time=$((pvc_wait_time + PVC_CHECK_INTERVAL))
done

if [ "$essential_pvcs_bound" -lt "$ESSENTIAL_PVC_COUNT" ]; then
    log_warning "Not all essential PVCs are bound after $pvc_wait_max seconds"
    log_info "This may be normal for backup PVC which remains Pending until first backup"
fi

# Wait for deployment rollout to complete with enhanced monitoring
log_step "Waiting for deployment rollout to complete..."
log_info "This may take 7-11 minutes for first startup (measured from E2E tests, can spike to 19 min)..."
log_info "OpenEMR containers typically take 7-11 minutes to start responding to HTTP requests"

# Enhanced monitoring with periodic status updates
log_info "📊 Monitoring deployment progress..."
log_info "⏳ Leader pod: ~9-11 minutes (database setup) | Follower pods: ~7-9 minutes"
log_info "💡 Startup phases: OpenEMR init → Database setup → Apache start → Ready"
echo ""

# Monitor with periodic status updates and startup logs
{
    attempt=0
    max_attempts=60  # 30 minutes at 30-second intervals (accommodates 10min leader + buffer)

    while [ $attempt -lt $max_attempts ]; do
        sleep 30
        echo ""
        show_deployment_status && break
        ((attempt++))

        # Show progress indicator
        progress=$((attempt * 100 / max_attempts))
        echo -e "${BLUE}   Progress: ${progress}% (${attempt}/${max_attempts} checks)${NC}"
        
        # Show startup logs for user visibility
        show_startup_logs
    done
} &
MONITOR_PID=$!

# Wait for deployment rollout to complete (suppress output to keep monitoring clean)
if kubectl rollout status deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=${POD_READY_TIMEOUT}s >/dev/null 2>&1; then
    # Kill the monitoring process and show final status
    kill $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true
    echo ""
    log_success "Deployment rollout completed successfully!"
    show_deployment_status
else
    # Kill the monitoring process
    kill $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true
    log_error "OpenEMR deployment failed to become ready within timeout"
    log_warning "Checking deployment status..."
    kubectl get deployment openemr -n "$NAMESPACE" -o wide
    log_warning "Checking replicasets..."
    kubectl get replicasets -n "$NAMESPACE" -l app=openemr
    log_warning "Checking pod status..."
    kubectl get pods -n "$NAMESPACE" -l app=openemr -o wide
    log_warning "Checking pod events..."
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
    log_warning "Checking OpenEMR container logs..."
    kubectl logs -n "$NAMESPACE" deployment/openemr -c openemr --tail=30
    log_warning "Checking Fluent-bit container logs..."
    kubectl logs -n "$NAMESPACE" deployment/openemr -c fluent-bit-sidecar --tail=20
    log_warning "Checking pod descriptions for issues..."
    for pod in $(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[*].metadata.name}'); do
        log_info "Pod: $pod"
        kubectl describe pod "$pod" -n "$NAMESPACE" | grep -A 10 -B 5 -E "(Events:|Conditions:|Warning:|Error:)"
    done
    exit 1
fi

# Only restart deployment if it's not already running properly
if [ $cluster_state_result -ne 2 ]; then
    log_info "Ensuring deployment uses latest configuration..."
    # Use rollout restart only if needed, not every time
    kubectl rollout restart deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE"
else
    log_success "Deployment already using latest configuration"
fi

# Validate deployment success with bulletproof approach
validate_deployment_success

# Deployment validation completed successfully - OpenEMR is ready
log_success "OpenEMR deployment completed successfully!"

# Apply Horizontal Pod Autoscaler for intelligent scaling
log_step "Setting up intelligent autoscaling..."
kubectl apply -f hpa.yaml
log_success "HPA configured: Replicas will autoscale based on CPU/memory usage"
log_success "EKS Auto Mode will provision nodes as needed"

# Always apply ingress for ALB and WAF functionality
log_step "Setting up ingress with ALB and WAF..."

# Set fallback domain if none provided (for LoadBalancer access)
if [ -z "$DOMAIN_NAME" ]; then
  log_warning "No domain specified - using LoadBalancer IP for access"
  DOMAIN_NAME="openemr.local"  # Fallback domain for TLS
fi

# Substitute all required variables in ingress
sed -i.bak "s/\${DOMAIN_NAME}/$DOMAIN_NAME/g" ingress.yaml

# Handle SSL certificate configuration
if [ -n "$SSL_CERT_ARN" ]; then
  log_info "Using ACM certificate: $SSL_CERT_ARN"
  sed -i.bak "s|\${SSL_CERT_ARN}|$SSL_CERT_ARN|g" ingress.yaml
else
  log_warning "No SSL certificate - removing SSL annotations"
  # Remove SSL-related annotations when no certificate
  sed -i.bak '/alb.ingress.kubernetes.io\/certificate-arn:/d' ingress.yaml
  sed -i.bak '/alb.ingress.kubernetes.io\/ssl-policy:/d' ingress.yaml
  sed -i.bak '/tls:/,/secretName:/d' ingress.yaml
  sed -i.bak '/hosts:/d' ingress.yaml
  sed -i.bak '/- host:/d' ingress.yaml
fi

# Apply the ingress configuration
kubectl apply -f ingress.yaml
log_success "Ingress applied with ALB and WAF support"

# Logging configuration already applied earlier
log_success "Logging configuration applied"

# EKS Auto Mode handles logging configuration automatically
log_success "EKS Auto Mode manages compute and logging automatically"

# Note: Monitoring configuration is handled by the optional monitoring stack
log_info "Core deployment complete. For monitoring: cd ../monitoring && ./install-monitoring.sh"

# Deploy SSL certificate renewal automation
log_step "Setting up SSL certificate renewal automation..."
kubectl apply -f ssl-renewal.yaml
log_success "SSL certificates will be automatically renewed every 2 days"

# Display deployment status
log_success "Deployment completed successfully!"
log_info "Checking deployment status..."
kubectl get all -n "$NAMESPACE"

# Report WAF status
log_info "WAF Security Status:"
if [ -n "$WAF_ACL_ARN" ]; then
    log_success "WAF Protection: ENABLED"
    log_info "ACL ARN: $WAF_ACL_ARN"
    log_info "Features: Rate limiting, SQL injection protection, bot blocking"
else
    log_warning "WAF Protection: DISABLED"
    log_info "To enable: Set enable_waf = true in terraform.tfvars"
fi

# Get LoadBalancer URL
LB_URL=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [ -n "$LB_URL" ]; then
  log_info "LoadBalancer URL (HTTPS): https://$LB_URL"

  if [ "$SSL_MODE" = "self-signed" ]; then
    log_warning "SSL Mode: Self-signed certificates (browser warnings expected)"
    log_info "To use trusted certificates, set SSL_CERT_ARN environment variable"
  else
    log_info "SSL Mode: AWS Certificate Manager"
    log_info "Certificate ARN: $SSL_CERT_ARN"
  fi
fi

# Save credentials to file
log_step "Saving credentials to openemr-credentials.txt..."
if [ -f "openemr-credentials.txt" ]; then
  # Create backup of existing credentials file
  BACKUP_FILE="openemr-credentials-$(date +%Y%m%d-%H%M%S).txt"
  cp openemr-credentials.txt "$BACKUP_FILE"
  log_warning "Existing credentials file backed up to: $BACKUP_FILE"
fi

cat > openemr-credentials.txt << EOF
OpenEMR Deployment Credentials
==============================
Admin Username: admin
Admin Password: $ADMIN_PASSWORD
Database Password: $AURORA_PASSWORD
Redis Password: $REDIS_PASSWORD
LoadBalancer URL (HTTPS): https://$LB_URL
SSL Mode: $SSL_MODE
EOF

# Add certificate ARN if using ACM
if [ "$SSL_MODE" = "acm" ]; then
  echo "Certificate ARN: $SSL_CERT_ARN" >> openemr-credentials.txt
fi

# Add generation timestamp
echo "" >> openemr-credentials.txt
echo "Generated on: $(date)" >> openemr-credentials.txt

log_success "Credentials saved to openemr-credentials.txt"
log_success "Please store these credentials securely!"

# Cleanup backup files
rm ./*.yaml.bak

echo ""
log_header "🎉 DEPLOYMENT SUCCESSFUL!"
echo ""
log_success "OpenEMR deployment completed successfully!"
echo ""

# Display comprehensive completion information
log_info "📊 Storage Information:"
log_info "• Essential PVCs (sites, ssl, letsencrypt) should be Bound"
log_info "• Backup PVC remains Pending until first backup runs - this is normal"
log_info "• Run backup script to provision backup storage: cd ../scripts && ./backup.sh"
echo ""

log_info "🔍 Troubleshooting: If pods remain in Pending status"
log_info "Run the EFS CSI validation script: cd ../scripts && ./validate-efs-csi.sh"
echo ""

log_info "📊 Optional: Install Full Monitoring Stack"
log_info "To install Prometheus, Grafana, and advanced monitoring:"
log_info "   cd ../monitoring && ./install-monitoring.sh"
log_info "This includes dashboards, alerting, and log aggregation."
echo ""

# Show final deployment status
log_info "📈 Final Deployment Status:"
kubectl get all -n "$NAMESPACE"
echo ""

log_success "🚀 OpenEMR is ready for use!"
