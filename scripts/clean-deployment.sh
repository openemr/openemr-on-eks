#!/bin/bash

# =============================================================================
# OpenEMR Clean Deployment Script
# =============================================================================
#
# Purpose:
#   Performs comprehensive cleanup of an OpenEMR deployment on Amazon EKS,
#   removing Kubernetes resources, cleaning the database, and handling
#   orphaned storage to ensure a clean slate for redeployment or troubleshooting.
#
# Key Features:
#   - Removes OpenEMR Kubernetes namespace and all resources
#   - Cleans database by dropping all tables and recreating structure
#   - Handles orphaned PersistentVolumeClaims and PersistentVolumes
#   - Restarts EFS CSI controller to refresh storage connections
#   - Cleans up local backup files and temporary data
#   - Provides safety confirmations (unless --force is used)
#
# Prerequisites:
#   - kubectl configured for the target EKS cluster
#   - AWS CLI configured with appropriate permissions
#   - Access to the RDS database
#
# Usage:
#   ./clean-deployment.sh [OPTIONS]
#
# Options:
#   -f, --force         Skip confirmation prompts
#   --skip-db-cleanup   Skip database cleanup (useful for restore operations)"
#   -h, --help          Show this help message
#
# Notes:
#   ⚠️  WARNING: This script will permanently delete all OpenEMR data and
#   configurations. Use with caution and ensure you have backups before running.
#
# Examples:
#   ./clean-deployment.sh
#   ./clean-deployment.sh --force
#
# Environment Variables:
#   NAMESPACE                Kubernetes namespace to clean (default: "openemr")
#   DB_CLEANUP_MAX_ATTEMPTS Maximum attempts to wait for database cleanup pod completion (default: 12)
#
# =============================================================================

set -e

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical warnings
GREEN='\033[0;32m'    # Success messages and positive feedback
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
NC='\033[0m'          # Reset color to default

# Parse command line arguments
# This section processes command-line options to control script behavior
# The --force flag bypasses safety confirmations for automated/scripted usage
FORCE=false  # Flag to skip confirmation prompts (set by --force or -f)
SKIP_DB_CLEANUP=false  # Flag to skip database cleanup (set by --skip-db-cleanup)

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true        # Enable force mode - skip all confirmation prompts
            shift             # Consume the option
            ;;
        --skip-db-cleanup)
            SKIP_DB_CLEANUP=true  # Skip database cleanup
            shift                 # Consume the option
            ;;
        -h|--help)
            # Display comprehensive help information including usage examples
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -f, --force         Skip confirmation prompts and force cleanup"
            echo "  --skip-db-cleanup   Skip database cleanup (useful for restore operations)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                    # Interactive cleanup with prompts"
            echo "  $0 --force            # Force cleanup without prompts"
            echo "  $0 -f                 # Force cleanup without prompts (short form)"
            echo "  $0 --skip-db-cleanup  # Skip database cleanup (for restore operations)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1            # Exit with error for unknown options
            ;;
    esac
done

# Configuration variables - can be overridden by environment variables
NAMESPACE=${NAMESPACE:-"openemr"}                       # Kubernetes namespace to clean
DB_CLEANUP_MAX_ATTEMPTS=${DB_CLEANUP_MAX_ATTEMPTS:-24}  # Maximum attempts to wait for database cleanup pod completion

# Timeout recommendations based on scenario
# - Normal database cleanup: 12 attempts (60 seconds) - default
# - Slow/unreliable database: 20 attempts (100 seconds) - increase DB_CLEANUP_MAX_ATTEMPTS
# - Fast local database: 6 attempts (30 seconds) - decrease DB_CLEANUP_MAX_ATTEMPTS
# - Database already destroyed: 3 attempts (15 seconds) - minimal wait

# Path resolution for script portability
# These variables ensure the script works regardless of the current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Directory containing this script
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"                      # Parent directory (project root)

# Display script header and warnings
echo -e "${GREEN}🧹 OpenEMR Clean Deployment Script${NC}"
echo -e "${GREEN}===================================${NC}"
echo ""
echo -e "${YELLOW}This script will clean up the current OpenEMR deployment${NC}"
echo -e "${YELLOW}Infrastructure (EKS, RDS, etc.) will remain intact${NC}"
echo -e "${RED}⚠️  DATA WARNING: This will DELETE ALL OpenEMR data from both EFS and RDS!${NC}"
echo -e "${RED}⚠️  This action cannot be undone!${NC}"
echo ""

# Safety confirmation mechanism
# This section ensures users understand the destructive nature of the cleanup
# Force mode bypasses this for automated/scripted usage scenarios
if [ "$FORCE" = false ]; then
    # Interactive confirmation prompt - requires explicit 'y' or 'Y' to proceed
    read -p "Are you sure you want to clean the current deployment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Cleanup cancelled${NC}"
        exit 0
    fi
else
    # Force mode: skip confirmation for automated usage
    echo -e "${YELLOW}Force mode enabled - skipping confirmation prompts${NC}"
fi

echo -e "${YELLOW}Starting cleanup...${NC}"
echo ""

# Get OpenEMR version from Terraform for use in cleanup pods
echo -e "${BLUE}Getting OpenEMR version from Terraform...${NC}"
cd "$PROJECT_ROOT/terraform"
OPENEMR_VERSION="7.0.4"  # Default fallback version
if [ -f "terraform.tfvars" ]; then
    TFVARS_VERSION=$(grep -E '^openemr_version\s*=' terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "")
    if [ -n "$TFVARS_VERSION" ]; then
        OPENEMR_VERSION="$TFVARS_VERSION"
    fi
fi
echo -e "${BLUE}Using OpenEMR version: $OPENEMR_VERSION${NC}"
cd "$SCRIPT_DIR"
echo ""

# Step 1: Force delete all pods and handle stuck PVCs
# EFS PVCs can hang during deletion, so we need to handle this properly
echo -e "${YELLOW}1. Force deleting pods and handling stuck PVCs...${NC}"

if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    # First, force delete all pods in the namespace
    echo -e "${BLUE}   Force deleting all pods in namespace '$NAMESPACE'...${NC}"
    kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' | while read -r pod; do
        if [ -n "$pod" ]; then
            echo -e "${BLUE}   Force deleting pod: $pod${NC}"
            kubectl delete pod "$pod" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        fi
    done

    # Wait a moment for pods to be deleted
    sleep 5

    # Check for PVCs that might be stuck in Terminating state
    echo -e "${BLUE}   Checking for stuck PVCs...${NC}"
    STUCK_PVCS=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep "Terminating" | awk '{print $1}' || echo "")
    if [ -n "$STUCK_PVCS" ]; then
        echo -e "${YELLOW}   Found stuck PVCs, removing finalizers...${NC}"
        echo "$STUCK_PVCS" | while read -r pvc; do
            if [ -n "$pvc" ]; then
                echo -e "${BLUE}   Removing finalizers from PVC: $pvc${NC}"
                kubectl patch pvc "$pvc" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
            fi
        done
        sleep 3
    fi

    # Now delete the namespace
    echo -e "${BLUE}   Deleting namespace '$NAMESPACE'...${NC}"
    kubectl delete namespace "$NAMESPACE" --timeout=300s
    echo -e "${GREEN}✅ OpenEMR namespace deleted${NC}"
else
    echo -e "${BLUE}ℹ️  OpenEMR namespace not found${NC}"
fi
echo ""

# Step 2: Wait for namespace deletion to complete
# Kubernetes namespace deletion is asynchronous - we must wait for finalizers to complete
echo -e "${YELLOW}2. Waiting for namespace deletion to complete...${NC}"
while kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; do
    echo -e "${BLUE}   Waiting for namespace deletion...${NC}"
    sleep 5
done
echo -e "${GREEN}✅ Namespace fully deleted${NC}"
echo ""

# Step 3: Complete EFS filesystem wipe
# This step performs a comprehensive cleanup of the entire EFS filesystem
# by deleting all PVCs, Storage Classes, and directly mounting EFS to wipe everything
echo -e "${YELLOW}3. Performing complete EFS filesystem wipe...${NC}"

# Get EFS file system ID from Terraform
cd "$PROJECT_ROOT/terraform"
if [ -f "terraform.tfstate" ]; then
    EFS_FILE_SYSTEM_ID=$(terraform output -raw efs_id 2>/dev/null || echo "")
    AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-west-2")
    if [ -n "$EFS_FILE_SYSTEM_ID" ]; then
        echo -e "${BLUE}   EFS File System ID: $EFS_FILE_SYSTEM_ID${NC}"
        echo -e "${BLUE}   AWS Region: $AWS_REGION${NC}"
        
        # Step 3a: Delete all OpenEMR-related PVCs and Storage Classes
        echo -e "${BLUE}   Step 3a: Deleting all OpenEMR PVCs and Storage Classes...${NC}"
        
        # Delete all PVCs with 'openemr' in the name across all namespaces
        echo -e "${BLUE}   Deleting all OpenEMR PVCs...${NC}"
        kubectl get pvc --all-namespaces -o json | jq -r '.items[] | select(.metadata.name | contains("openemr")) | "\(.metadata.namespace) \(.metadata.name)"' | while read -r namespace pvc; do
            echo -e "${BLUE}   Deleting PVC: $pvc in namespace: $namespace${NC}"
            kubectl delete pvc "$pvc" -n "$namespace" --timeout=30s 2>/dev/null || echo "   Failed to delete $pvc"
        done
        
        # Delete all Storage Classes with 'efs' in the name
        echo -e "${BLUE}   Deleting all EFS Storage Classes...${NC}"
        kubectl get storageclass -o json | jq -r '.items[] | select(.metadata.name | contains("efs")) | .metadata.name' | while read -r sc; do
            echo -e "${BLUE}   Deleting Storage Class: $sc${NC}"
            kubectl delete storageclass "$sc" --timeout=30s 2>/dev/null || echo "   Failed to delete $sc"
        done
        
        # Step 3b: Direct EFS wipe (bypassing CSI driver)
        echo -e "${BLUE}   Step 3b: Performing direct EFS wipe...${NC}"
        
        # Create a temporary namespace for direct EFS access
        TEMP_NAMESPACE="openemr-efs-wipe-$(date +%s)"
        echo -e "${BLUE}   Creating temporary namespace: $TEMP_NAMESPACE${NC}"

        if ! kubectl create namespace "$TEMP_NAMESPACE" 2>/dev/null; then
            echo -e "${RED}   ❌ Failed to create namespace $TEMP_NAMESPACE${NC}"
            echo -e "${RED}   Skipping EFS wipe due to namespace creation failure${NC}"
            exit 1
        fi
        echo -e "${GREEN}   ✅ Created namespace: $TEMP_NAMESPACE${NC}"

        # No Storage Class or PVC needed for direct EFS mount approach

        # Step 3b: Recreate efs-sc Storage Class and wipe OpenEMR directory
        echo -e "${BLUE}   Step 3b: Recreating efs-sc Storage Class and wiping OpenEMR directory...${NC}"
        
        # First, recreate the normal efs-sc Storage Class
        echo -e "${BLUE}   Recreating efs-sc Storage Class...${NC}"
        cat > "/tmp/efs-sc-recreate.yaml" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
    storageclass.kubernetes.io/description: "EFS storage class for OpenEMR application data"
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $EFS_FILE_SYSTEM_ID
  directoryPerms: "0755"
  basePath: "/openemr"
  uid: "0"
  gid: "0"
mountOptions: []
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

        if ! kubectl apply -f "/tmp/efs-sc-recreate.yaml" --validate=false; then
            echo -e "${RED}   ❌ Failed to recreate efs-sc Storage Class${NC}"
            exit 1
        fi
        rm -f "/tmp/efs-sc-recreate.yaml"
        echo -e "${GREEN}   ✅ Recreated efs-sc Storage Class${NC}"
        
        # Restart EFS CSI driver to pick up the new storage class configuration
        echo -e "${BLUE}   Restarting EFS CSI driver to apply new storage class...${NC}"
        kubectl rollout restart daemonset/efs-csi-node -n kube-system >/dev/null 2>&1
        kubectl rollout restart deployment/efs-csi-controller -n kube-system >/dev/null 2>&1
        
        echo -e "${BLUE}   Waiting for EFS CSI driver to be ready...${NC}"
        kubectl rollout status daemonset/efs-csi-node -n kube-system --timeout=120s >/dev/null 2>&1 || echo "   ⚠️  DaemonSet rollout check timed out, but driver may still be operational"
        kubectl rollout status deployment/efs-csi-controller -n kube-system --timeout=120s >/dev/null 2>&1 || echo "   ⚠️  Deployment rollout check timed out, but driver may still be operational"
        echo -e "${GREEN}   ✅ EFS CSI driver restart initiated${NC}"
        
        # Additional wait to ensure CSI driver is fully ready
        sleep 10
        
        # Create PVC for EFS access (will remain Pending until pod is scheduled with WaitForFirstConsumer)
        cat > "/tmp/temp-efs-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-wipe-pvc
  namespace: $TEMP_NAMESPACE
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 10Gi
EOF

        if ! kubectl apply -f "/tmp/temp-efs-pvc.yaml" --validate=false; then
            echo -e "${RED}   ❌ Failed to create EFS PVC${NC}"
            kubectl delete namespace "$TEMP_NAMESPACE" 2>/dev/null || true
            exit 1
        fi
        rm -f "/tmp/temp-efs-pvc.yaml"
        echo -e "${GREEN}   ✅ EFS PVC created (will bind when pod is scheduled)${NC}"

        # Create wipe job using OpenEMR container with EFS mount
        # With WaitForFirstConsumer, the PVC will bind when this job's pod is scheduled
        echo -e "${BLUE}   Creating EFS wipe job...${NC}"
        cat > "/tmp/temp-efs-wipe-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: efs-wipe-job
  namespace: $TEMP_NAMESPACE
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      name: efs-wipe-job
    spec:
      restartPolicy: Never
      tolerations:
      - operator: Exists
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0
      containers:
      - name: wiper
        image: openemr/openemr:$OPENEMR_VERSION
        securityContext:
          runAsUser: 0
          runAsGroup: 0
          privileged: true
        command:
        - /bin/sh
        - -c
        - |
          set -euo pipefail
          MOUNT=/mnt/efs

          echo "Starting EFS OpenEMR directory wipe..."
          echo "EFS File System ID: $EFS_FILE_SYSTEM_ID"
          echo "OpenEMR version: $OPENEMR_VERSION"
          echo "Targeting OpenEMR directory: /openemr"

          # Wait for mount to be ready by checking if the directory is accessible
          echo "Waiting for EFS volume to be accessible..."
          for i in 1 2 3 4 5 6 7 8 9 10; do
            if [ -d "\$MOUNT" ]; then
              echo "✅ EFS volume is accessible at \$MOUNT"
              break
            fi
            echo "Waiting for volume... attempt \$i/10"
            sleep 3
          done

          # Verify directory is accessible
          if [ ! -d "\$MOUNT" ]; then
            echo "❌ EFS volume directory not accessible after waiting"
            echo "Directory listing of /mnt:"
            ls -la /mnt/ 2>/dev/null || echo "Cannot list /mnt/"
            echo "Mount info:"
            mount | head -20
            exit 1
          fi

          echo "==== preview (top-level) ===="
          ls -la "\$MOUNT" | sed -n '1,200p'

          echo "==== wiping OpenEMR directory... ===="
          # Robust removal (handles hidden files/dirs, deep trees)
          # Use find to avoid removing the mountpoint itself
          find "\$MOUNT" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true

          echo "==== verifying empty ===="
          if [ -z "\$(ls -A "\$MOUNT" 2>/dev/null)" ]; then
            echo "✅ OpenEMR directory wiped successfully"
          else
            echo "⚠️ Some items remain:"; ls -la "\$MOUNT"; exit 2
          fi

          # Keep pod around briefly so you can kubectl logs it if needed
          sleep 5
        volumeMounts:
        - name: efs-storage
          mountPath: /mnt/efs
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: efs-storage
        persistentVolumeClaim:
          claimName: efs-wipe-pvc
EOF

        if ! kubectl apply -f "/tmp/temp-efs-wipe-job.yaml" --validate=false; then
            echo -e "${RED}   ❌ Failed to create EFS wipe job${NC}"
            kubectl delete namespace "$TEMP_NAMESPACE" 2>/dev/null || true
            exit 1
        fi
        rm -f "/tmp/temp-efs-wipe-job.yaml"

        # Wait for wipe job to complete with retry logic
        max_retries=3
        attempt=1
        job_succeeded=false
        
        while [ $attempt -le $max_retries ]; do
            if [ $attempt -gt 1 ]; then
                echo -e "${YELLOW}   Retry attempt $attempt/$max_retries${NC}"
                # Delete the failed job before retrying
                kubectl delete job efs-wipe-job -n "$TEMP_NAMESPACE" 2>/dev/null || true
                sleep 5
            fi
            
            echo -e "${BLUE}   Waiting for complete EFS wipe to finish (attempt $attempt)...${NC}"
            kubectl wait --for=condition=Complete job/efs-wipe-job -n "$TEMP_NAMESPACE" --timeout=300s 2>/dev/null || true

            # More robust job completion check with automatic log printing on failure
            echo -e "${BLUE}   Checking EFS wipe job status...${NC}"
            for i in {1..150}; do
                job_status=$(kubectl get job efs-wipe-job -n "$TEMP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "Unknown")
                job_failed=$(kubectl get job efs-wipe-job -n "$TEMP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "Unknown")
                
                if [ "$job_status" = "True" ]; then
                    echo -e "${GREEN}✅ EFS wipe job completed successfully${NC}"
                    # Show the logs
                    echo -e "${BLUE}   EFS wipe logs:${NC}"
                    kubectl logs job/efs-wipe-job -n "$TEMP_NAMESPACE" 2>/dev/null || echo "No logs available"
                    job_succeeded=true
                    break
                fi
                
                if [ "$job_failed" = "True" ]; then
                    echo -e "${YELLOW}   ⚠️  EFS wipe job failed on attempt $attempt${NC}"
                    
                    # Get pod name for diagnostics
                    POD_NAME=$(kubectl get pods -n "$TEMP_NAMESPACE" -l job-name=efs-wipe-job -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                    
                    if [ -n "$POD_NAME" ]; then
                        echo -e "${YELLOW}   POD LOGS FOR: $POD_NAME${NC}"
                        kubectl logs "$POD_NAME" -n "$TEMP_NAMESPACE" 2>/dev/null || echo "   Could not retrieve logs"
                    fi
                    
                    # If this is not the last attempt, delete job and retry
                    if [ $attempt -lt $max_retries ]; then
                        echo -e "${YELLOW}   Cleaning up failed job and retrying...${NC}"
                        kubectl delete job efs-wipe-job -n "$TEMP_NAMESPACE" 2>/dev/null || true
                        sleep 5
                        # Recreate the job
                        if [ -f "/tmp/temp-efs-wipe-job.yaml" ]; then
                            kubectl apply -f "/tmp/temp-efs-wipe-job.yaml" --validate=false 2>/dev/null || true
                        fi
                        break
                    else
                        # Last attempt failed - print full diagnostics
                        echo -e "${RED}   ❌ EFS wipe job FAILED after $max_retries attempts - printing diagnostic information${NC}"
                        echo ""
                        
                        if [ -n "$POD_NAME" ]; then
                            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                            echo -e "${RED}   POD LOGS FOR: $POD_NAME${NC}"
                            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                            kubectl logs "$POD_NAME" -n "$TEMP_NAMESPACE" 2>/dev/null || echo "   Could not retrieve logs"
                            echo ""
                            
                            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                            echo -e "${RED}   POD STATUS FOR: $POD_NAME${NC}"
                            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                            kubectl describe pod "$POD_NAME" -n "$TEMP_NAMESPACE" 2>/dev/null | tail -80
                            echo ""
                            
                            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                            echo -e "${RED}   JOB STATUS${NC}"
                            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                            kubectl describe job efs-wipe-job -n "$TEMP_NAMESPACE" 2>/dev/null || echo "   Could not retrieve job status"
                            echo ""
                        else
                            echo -e "${RED}   Could not find pod for job efs-wipe-job${NC}"
                        fi
                        
                        kubectl delete namespace "$TEMP_NAMESPACE" 2>/dev/null || true
                        exit 1
                    fi
                fi
                
                # Show progress every 10 seconds
                if [ $((i % 5)) -eq 0 ]; then
                    echo -e "${BLUE}   Still waiting... (${i}/150)${NC}"
                fi
                
                sleep 2
            done
            
            # If job succeeded, break out of retry loop
            if [ "$job_succeeded" = true ]; then
                break
            fi
            
            attempt=$((attempt + 1))
        done
        
        # Check if we timed out
        if [ "$job_status" != "True" ] && [ "$job_failed" != "True" ]; then
            echo -e "${RED}   ❌ EFS wipe job timed out after 300 seconds${NC}"
            echo ""
            
            # Get pod name
            POD_NAME=$(kubectl get pods -n "$TEMP_NAMESPACE" -l job-name=efs-wipe-job -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            
            if [ -n "$POD_NAME" ]; then
                echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${RED}   POD LOGS FOR: $POD_NAME (timeout)${NC}"
                echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                kubectl logs "$POD_NAME" -n "$TEMP_NAMESPACE" 2>/dev/null || echo "   Could not retrieve logs"
                echo ""
                
                echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${RED}   POD STATUS FOR: $POD_NAME (timeout)${NC}"
                echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                kubectl describe pod "$POD_NAME" -n "$TEMP_NAMESPACE" 2>/dev/null | tail -80
                echo ""
            fi
            
            kubectl delete namespace "$TEMP_NAMESPACE" 2>/dev/null || true
            exit 1
        fi

        # Clean up temporary resources
        echo -e "${BLUE}   Cleaning up temporary resources...${NC}"
        kubectl delete namespace "$TEMP_NAMESPACE" --timeout=30s 2>/dev/null || true
        
        echo -e "${GREEN}✅ Complete EFS filesystem wipe completed${NC}"
    else
        echo -e "${YELLOW}⚠️  Could not retrieve EFS File System ID from Terraform${NC}"
        echo -e "${YELLOW}   EFS wipe will be skipped${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Terraform state not found - skipping EFS wipe${NC}"
fi
echo ""

# Step 4: Clean up OpenEMR database to prevent reconfiguration conflicts
# This step removes all OpenEMR tables and data to ensure a clean database state
# for fresh deployment without configuration conflicts from previous installations

if [ "$SKIP_DB_CLEANUP" = true ]; then
    echo -e "${BLUE}ℹ️  Skipping database cleanup (--skip-db-cleanup flag enabled)${NC}"
    echo -e "${BLUE}   Database will be replaced during restore process${NC}"
    echo ""
    DB_CLEANUP=false
else
echo -e "${YELLOW}3. Cleaning up OpenEMR database...${NC}"
echo -e "${RED}⚠️  WARNING: This will DELETE ALL OpenEMR data from the database!${NC}"
echo -e "${RED}⚠️  This action cannot be undone!${NC}"
echo ""

# Additional safety confirmation for database cleanup
# Database cleanup is more destructive than namespace deletion, so we require explicit confirmation
if [ "$FORCE" = false ]; then
    read -p "Are you sure you want to DELETE ALL OpenEMR data from the database? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Database cleanup skipped - deployment may fail due to existing data${NC}"
        echo -e "${BLUE}   You can manually clean the database later if needed${NC}"
        echo ""
        DB_CLEANUP=false
    else
        echo -e "${YELLOW}Proceeding with database cleanup...${NC}"
        echo ""
        DB_CLEANUP=true
    fi
else
    echo -e "${YELLOW}Force mode enabled - proceeding with database cleanup${NC}"
    echo ""
    DB_CLEANUP=true
fi

# Execute database cleanup only if user confirmed (or force mode is enabled)
if [ "$DB_CLEANUP" = true ]; then
        # Retrieve database connection details from Terraform state
        echo -e "${BLUE}   Getting database details from Terraform...${NC}"
    cd "$PROJECT_ROOT/terraform"
        
        # Validate terraform state
        if ! terraform output -raw aurora_endpoint >/dev/null 2>&1; then
            echo -e "${RED}   ❌ Terraform state appears to be invalid or corrupted${NC}"
            echo -e "${YELLOW}   ℹ️  Try running: cd terraform && terraform refresh${NC}"
            echo -e "${YELLOW}   ℹ️  Database cleanup will be skipped${NC}"
            DB_CLEANUP=false
        else
            AURORA_ENDPOINT=$(terraform output -raw aurora_endpoint 2>/dev/null || echo "")
            AURORA_USERNAME="openemr"  # Hardcoded username from terraform/rds.tf
            AURORA_PASSWORD=$(terraform output -raw aurora_password 2>/dev/null || echo "")
        fi

        if [ -n "$AURORA_ENDPOINT" ] && [ -n "$AURORA_USERNAME" ] && [ -n "$AURORA_PASSWORD" ]; then
            echo -e "${BLUE}   Database endpoint: $AURORA_ENDPOINT${NC}"
            echo -e "${BLUE}   Database username: $AURORA_USERNAME${NC}"
            echo -e "${BLUE}   Database password: [REDACTED]${NC}"

            # Use OpenEMR container for database cleanup
            echo -e "${YELLOW}   Launching temporary OpenEMR database cleanup pod...${NC}"

            # Create a temporary namespace for the cleanup pod
            TEMP_NAMESPACE="db-cleanup-temp"
            if ! kubectl create namespace "$TEMP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -; then
                echo -e "${RED}   ❌ Failed to create namespace for database cleanup${NC}"
                exit 1
            fi

            # Create a temporary secret with database credentials
            if ! kubectl create secret generic temp-db-credentials \
                --namespace="$TEMP_NAMESPACE" \
                --from-literal=mysql-host="$AURORA_ENDPOINT" \
                --from-literal=mysql-user="openemr" \
                --from-literal=mysql-password="$AURORA_PASSWORD" \
                --dry-run=client -o yaml | kubectl apply -f -; then
                echo -e "${RED}   ❌ Failed to create database credentials secret${NC}"
                kubectl delete namespace "$TEMP_NAMESPACE" 2>/dev/null || true
                exit 1
            fi

            # Create a temporary database cleanup pod using OpenEMR container
            if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: db-cleanup-pod
  namespace: $TEMP_NAMESPACE
spec:
  containers:
  - name: db-cleanup
    image: openemr/openemr:$OPENEMR_VERSION
    command: ['sh', '-c']
    args:
    - |
      echo "Using OpenEMR container ($OPENEMR_VERSION) for database cleanup..."
      echo "Testing MySQL connection to: \${MYSQL_HOST}"
      
      # Install MySQL client
      echo "Installing MySQL client..."
      apk add --no-cache mysql-client
      
      # Test connection with timeout
      echo "Waiting for MySQL connection..."
      connection_timeout=30
      connection_attempts=0
      
      while [ \$connection_attempts -lt \$connection_timeout ]; do
        if mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SELECT 1;" >/dev/null 2>&1; then
          echo "✅ Successfully connected to MySQL database"
          break
        fi
        
        echo "Connection attempt \$((connection_attempts + 1))/\$connection_timeout failed, retrying in 2 seconds..."
        sleep 2
        connection_attempts=\$((connection_attempts + 1))
      done
      
      if [ \$connection_attempts -ge \$connection_timeout ]; then
        echo "❌ ERROR: Failed to connect to MySQL database after \$connection_timeout attempts"
        echo "Database may not exist or be accessible. This is normal if the database was already destroyed."
        echo "Database cleanup will be handled during deployment."
        exit 0  # Exit successfully since this is expected in some cases
      fi
      
      echo "Connected to MySQL, proceeding with complete database cleanup..."
      
      # Drop the entire openemr database - much simpler and more reliable
      echo "  - Dropping entire openemr database..."
      mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "DROP DATABASE IF EXISTS openemr;" 2>/dev/null || {
        echo "❌ Failed to drop openemr database"
        exit 1
      }
      
      echo "✅ OpenEMR database dropped successfully"
      
      # Create empty openemr database for auto-configuration
      echo "  - Creating empty openemr database for auto-configuration..."
      mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "CREATE DATABASE openemr CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" 2>/dev/null || {
        echo "❌ Failed to create openemr database"
        exit 1
      }
      
      echo "✅ Empty OpenEMR database created successfully"
      echo "✅ Database cleanup completed - OpenEMR will configure the empty database during deployment"
      
      echo "Database cleanup completed successfully with OpenEMR container"
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
  restartPolicy: Never
EOF
            then
                echo -e "${RED}   ❌ Failed to create database cleanup pod${NC}"
                kubectl delete namespace "$TEMP_NAMESPACE" 2>/dev/null || true
                exit 1
            fi

            # Wait for the pod to complete with retry logic
            db_max_retries=3
            db_attempt=1
            db_cleanup_succeeded=false
            
            while [ $db_attempt -le $db_max_retries ]; do
                if [ $db_attempt -gt 1 ]; then
                    echo -e "${YELLOW}   Retry attempt $db_attempt/$db_max_retries for database cleanup${NC}"
                    # Delete the failed pod before retrying
                    kubectl delete pod db-cleanup-pod -n "$TEMP_NAMESPACE" 2>/dev/null || true
                    sleep 5
                    # Recreate the pod
                    cat <<DBEOFPOD | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: db-cleanup-pod
  namespace: $TEMP_NAMESPACE
spec:
  containers:
  - name: db-cleanup
    image: openemr/openemr:$OPENEMR_VERSION
    command: ['sh', '-c']
    args:
    - |
      echo "Starting database cleanup attempt $db_attempt..."
      
      # Install mysql client
      apk add --no-cache mysql-client
      
      # Test database connection
      echo "Testing database connection..."
      if ! mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SELECT 1" 2>/dev/null; then
        echo "❌ Database connection failed"
        exit 1
      fi
      echo "✅ Database connection successful"
      
      # Drop and recreate the openemr database
      echo "  - Dropping existing openemr database..."
      mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "DROP DATABASE IF EXISTS openemr;" 2>/dev/null || {
        echo "❌ Failed to drop openemr database"
        exit 1
      }
      
      # Create empty openemr database for auto-configuration
      echo "  - Creating empty openemr database for auto-configuration..."
      mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "CREATE DATABASE openemr CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" 2>/dev/null || {
        echo "❌ Failed to create openemr database"
        exit 1
      }
      
      echo "✅ Empty OpenEMR database created successfully"
      echo "✅ Database cleanup completed - OpenEMR will configure the empty database during deployment"
      
      echo "Database cleanup completed successfully with OpenEMR container"
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
  restartPolicy: Never
DBEOFPOD
                fi
                
                echo -e "${BLUE}   Waiting for database cleanup to complete (attempt $db_attempt)...${NC}"
                
                # Wait for the pod to complete (not just be Ready)
                kubectl wait --for=condition=Ready pod/db-cleanup-pod -n "$TEMP_NAMESPACE" --timeout=30s 2>/dev/null || true
                echo -e "${BLUE}   Pod is ready, waiting for completion...${NC}"

                # Give the pod time to complete its work
                max_attempts=$DB_CLEANUP_MAX_ATTEMPTS
                attempt=0

                while [ $attempt -lt "$max_attempts" ]; do
                    echo -e "${BLUE}   Checking completion... (attempt $((attempt + 1))/$max_attempts)${NC}"
                    
                    # Check if pod has completed successfully
                    pod_phase=$(kubectl get pod db-cleanup-pod -n "$TEMP_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                    if [ "$pod_phase" = "Succeeded" ]; then
                        if kubectl logs db-cleanup-pod -n "$TEMP_NAMESPACE" 2>/dev/null | grep -q "Database cleanup completed successfully"; then
                            echo -e "${GREEN}   ✅ Completion message detected!${NC}"
                            db_cleanup_succeeded=true
                            break
                        fi
                    elif [ "$pod_phase" = "Failed" ]; then
                        echo -e "${YELLOW}   ⚠️  Pod failed on attempt $db_attempt${NC}"
                        if [ -n "$(kubectl get pod db-cleanup-pod -n "$TEMP_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || echo "")" ]; then
                            kubectl logs db-cleanup-pod -n "$TEMP_NAMESPACE" 2>/dev/null || echo "No logs available"
                        fi
                    break
                fi

                echo -e "${BLUE}   Waiting for cleanup to complete... (attempt $((attempt + 1))/$max_attempts)${NC}"
                sleep 5
                attempt=$((attempt + 1))
            done

                # If successful, break out of retry loop
                if [ "$db_cleanup_succeeded" = true ]; then
                echo -e "${GREEN}✅ OpenEMR database cleaned successfully via OpenEMR container${NC}"
                # Show the logs
                echo -e "${BLUE}   Cleanup logs:${NC}"
                    kubectl logs db-cleanup-pod -n "$TEMP_NAMESPACE"
                    break
                elif [ "$db_attempt" -lt "$db_max_retries" ]; then
                    echo -e "${YELLOW}   Will retry...${NC}"
                    db_attempt=$((db_attempt + 1))
                else
                    # Last attempt failed - print full diagnostics
                    pod_phase=$(kubectl get pod db-cleanup-pod -n "$TEMP_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                    pod_reason=$(kubectl get pod db-cleanup-pod -n "$TEMP_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
                    
                    echo -e "${RED}❌ Database cleanup FAILED after $db_max_retries attempts${NC}"
                    echo -e "${BLUE}   Pod status: $pod_phase${NC}"
                    if [ -n "$pod_reason" ]; then
                        echo -e "${BLUE}   Pod reason: $pod_reason${NC}"
                    fi
                    
                    echo -e "${BLUE}   Pod details:${NC}"
                    kubectl get pod db-cleanup-pod -n "$TEMP_NAMESPACE"
                    
                echo -e "${BLUE}   Pod logs:${NC}"
                    kubectl logs db-cleanup-pod -n "$TEMP_NAMESPACE" || echo "No logs available"
                    
                    # Check if this is a connection failure (database doesn't exist)
                    if kubectl logs db-cleanup-pod -n "$TEMP_NAMESPACE" 2>/dev/null | grep -q "Database may not exist or be accessible"; then
                        echo -e "${BLUE}ℹ️  Database appears to be unavailable - this is normal if it was already destroyed${NC}"
                        echo -e "${GREEN}✅ Cleanup completed successfully (database was already cleaned up)${NC}"
                    else
                echo -e "${BLUE}   Database cleanup will be handled during deployment${NC}"
            fi
                fi
            done

            # Clean up temporary resources
            echo -e "${BLUE}   Cleaning up temporary resources...${NC}"
            kubectl delete namespace "$TEMP_NAMESPACE" --timeout=30s 2>/dev/null || true
        else
            echo -e "${RED}   ❌ Could not retrieve database credentials from Terraform${NC}"
            echo -e "${RED}   ❌ Missing: endpoint=$([ -n "$AURORA_ENDPOINT" ] && echo "✅" || echo "❌"), username=$([ -n "$AURORA_USERNAME" ] && echo "✅" || echo "❌"), password=$([ -n "$AURORA_PASSWORD" ] && echo "✅" || echo "❌")${NC}"
            echo -e "${YELLOW}   ℹ️  This is expected if the database was already destroyed${NC}"
            echo -e "${YELLOW}   ℹ️  Database cleanup will be skipped${NC}"
        fi
    else
        echo -e "${BLUE}ℹ️  Terraform state not found - skipping database cleanup${NC}"
    fi

    cd "$SCRIPT_DIR"
fi

# Step 5: Clean up any orphaned PVCs (in case they weren't deleted with namespace)
echo -e "${YELLOW}5. Checking for orphaned PVCs...${NC}"
ORPHANED_PVCS=$(kubectl get pvc --all-namespaces | grep openemr || echo "")
if [ -n "$ORPHANED_PVCS" ]; then
    echo -e "${YELLOW}Found orphaned PVCs, cleaning up...${NC}"
    kubectl get pvc --all-namespaces | grep openemr | awk '{print $1 " " $2}' | while read -r namespace pvc; do
        echo -e "${BLUE}   Deleting PVC: $pvc in namespace: $namespace${NC}"
        kubectl delete pvc "$pvc" -n "$namespace" --timeout=60s || echo "Failed to delete $pvc"
    done
    echo -e "${GREEN}✅ Orphaned PVCs cleaned up${NC}"
else
    echo -e "${GREEN}✅ No orphaned PVCs found${NC}"
fi
echo ""

# Step 6: Clean up orphaned PersistentVolumes
# PVs that are no longer bound to PVCs should be removed to free up storage resources
echo -e "${YELLOW}6. Checking for orphaned PVs...${NC}"
ORPHANED_PVS=$(kubectl get pv | grep openemr || echo "")
if [ -n "$ORPHANED_PVS" ]; then
    echo -e "${YELLOW}Found orphaned PVs, cleaning up...${NC}"
    kubectl get pv | grep openemr | awk '{print $1}' | while read -r pv; do
        kubectl delete pv "$pv" --timeout=60s || echo "Failed to delete $pv"
    done
else
    echo -e "${GREEN}✅ No orphaned PVs found${NC}"
fi
echo ""

# Step 7: Restart EFS CSI controller to clear cached state
# This ensures the CSI driver has a fresh state and can properly handle new PVCs
echo -e "${YELLOW}7. Restarting EFS CSI controller to clear cached state...${NC}"
kubectl rollout restart deployment efs-csi-controller -n kube-system
kubectl rollout status deployment efs-csi-controller -n kube-system --timeout=120s
echo -e "${GREEN}✅ EFS CSI controller restarted${NC}"
echo ""

# Step 8: Clean up local backup files from previous deployments
# Remove any .bak files and credential files that may have been generated
echo -e "${YELLOW}8. Cleaning up backup files...${NC}"
cd "$PROJECT_ROOT/k8s"
rm -f ./*.yaml.bak              # Remove backup files created during deployment
rm -f openemr-credentials*.txt  # Remove any credential files
echo -e "${GREEN}✅ Backup files cleaned${NC}"
echo ""

# Prepare for fresh deployment by restoring defaults
echo -e "${YELLOW}📋 Preparing for fresh deployment...${NC}"
echo -e "${BLUE}   Running restore-defaults.sh --force...${NC}"
if ! "$PROJECT_ROOT/scripts/restore-defaults.sh" --force; then
    echo -e "${RED}❌ restore-defaults.sh failed${NC}" >&2
    echo -e "${RED}   Cleanup completed but deployment preparation failed${NC}"
    exit 1
fi
echo -e "${GREEN}   ✅ restore-defaults.sh completed${NC}"

echo -e "${GREEN}🎉 Cleanup completed successfully!${NC}"
echo ""
echo -e "${BLUE}📋 Next Steps:${NC}"
echo -e "${BLUE}1. Run a fresh deployment:${NC}"
echo -e "${BLUE}   cd ../k8s && ./deploy.sh${NC}"
echo -e "${BLUE}2. Monitor the deployment:${NC}"
echo -e "${BLUE}   kubectl get pods -n openemr -w${NC}"
echo -e "${BLUE}3. Validate EFS CSI if needed:${NC}"
echo -e "${BLUE}   cd ../scripts && ./validate-efs-csi.sh${NC}"
echo ""
echo -e "${GREEN}Infrastructure (EKS cluster, RDS, etc.) remains intact${NC}"
