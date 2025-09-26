#!/bin/bash

# OpenEMR Clean Deployment Script
# ===============================
# This script performs a comprehensive cleanup of an OpenEMR deployment on Amazon EKS.
# It removes Kubernetes resources, cleans the database, and handles orphaned storage
# to ensure a clean slate for redeployment or troubleshooting.
#
# Key Features:
# - Removes OpenEMR Kubernetes namespace and all resources
# - Cleans database by dropping all tables and recreating structure
# - Handles orphaned PersistentVolumeClaims and PersistentVolumes
# - Restarts EFS CSI controller to refresh storage connections
# - Cleans up local backup files and temporary data
# - Provides safety confirmations (unless --force is used)
#
# WARNING: This script will permanently delete all OpenEMR data and configurations.
# Use with caution and ensure you have backups before running.

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

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true        # Enable force mode - skip all confirmation prompts
            shift             # Consume the option
            ;;
        -h|--help)
            # Display comprehensive help information including usage examples
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -f, --force    Skip confirmation prompts and force cleanup"
            echo "  -h, --help     Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0              # Interactive cleanup with prompts"
            echo "  $0 --force      # Force cleanup without prompts"
            echo "  $0 -f           # Force cleanup without prompts (short form)"
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
NAMESPACE=${NAMESPACE:-"openemr"}             # Kubernetes namespace to clean

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
echo -e "${RED}⚠️  DATABASE WARNING: This will DELETE ALL OpenEMR data from the database!${NC}"
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

# Step 1: Remove Kubernetes namespace and all contained resources
# Deleting a namespace automatically removes all resources within it (pods, services, secrets, etc.)
echo -e "${YELLOW}1. Removing OpenEMR namespace and all resources...${NC}"
if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
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

# Step 3: Clean up OpenEMR database to prevent reconfiguration conflicts
# This step removes all OpenEMR tables and data to ensure a clean database state
# for fresh deployment without configuration conflicts from previous installations
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
    # Retrieve database connection details and OpenEMR version from Terraform state
    # This ensures we connect to the correct database instance and use the right OpenEMR version
    cd "$PROJECT_ROOT/terraform"
    if [ -f "terraform.tfstate" ]; then
        echo -e "${BLUE}   Getting database details and OpenEMR version from Terraform...${NC}"
        AURORA_ENDPOINT=$(terraform output -raw aurora_endpoint 2>/dev/null || echo "")
        AURORA_PASSWORD=$(terraform output -raw aurora_password 2>/dev/null || echo "")
        
        # Try to get OpenEMR version from terraform.tfvars, fallback to 7.0.3
        OPENEMR_VERSION="7.0.3"  # Default fallback version
        if [ -f "terraform.tfvars" ]; then
            TFVARS_VERSION=$(grep -E '^openemr_version\s*=' terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "")
            if [ -n "$TFVARS_VERSION" ]; then
                OPENEMR_VERSION="$TFVARS_VERSION"
            fi
        fi
        echo -e "${BLUE}   Using OpenEMR version: $OPENEMR_VERSION${NC}"

        if [ -n "$AURORA_ENDPOINT" ] && [ -n "$AURORA_PASSWORD" ]; then
            echo -e "${BLUE}   Database endpoint: $AURORA_ENDPOINT${NC}"

            # Use OpenEMR container for database cleanup
            echo -e "${YELLOW}   Launching temporary OpenEMR database cleanup pod...${NC}"

            # Create a temporary namespace for the cleanup pod
            TEMP_NAMESPACE="db-cleanup-temp"
            kubectl create namespace $TEMP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

            # Create a temporary secret with database credentials
            kubectl create secret generic temp-db-credentials \
                --namespace=$TEMP_NAMESPACE \
                --from-literal=mysql-host="$AURORA_ENDPOINT" \
                --from-literal=mysql-user="openemr" \
                --from-literal=mysql-password="$AURORA_PASSWORD" \
                --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

            # Create a temporary database cleanup pod using OpenEMR container
            cat <<EOF | kubectl apply -f -
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
      echo "Waiting for MySQL connection..."
      until mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SELECT 1;" >/dev/null 2>&1; do
        sleep 2
      done
      echo "Connected to MySQL, cleaning database..."
      mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "DROP DATABASE IF EXISTS openemr; CREATE DATABASE openemr CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
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

            # Wait for the pod to complete
            echo -e "${BLUE}   Waiting for database cleanup to complete...${NC}"

            # Wait for the pod to complete (not just be Ready)
            kubectl wait --for=condition=Ready pod/db-cleanup-pod -n $TEMP_NAMESPACE --timeout=60s 2>/dev/null || true

            # Give the pod time to complete its work and check multiple times
            max_attempts=12  # 60 seconds total (12 * 5 seconds)
            attempt=0
            cleanup_completed=false

            while [ $attempt -lt $max_attempts ]; do
                if kubectl logs db-cleanup-pod -n $TEMP_NAMESPACE 2>/dev/null | grep -q "Database cleanup completed"; then
                    cleanup_completed=true
                    break
                fi

                # Check if pod has failed
                pod_phase=$(kubectl get pod db-cleanup-pod -n $TEMP_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                if [ "$pod_phase" = "Failed" ]; then
                    echo -e "${RED}   Pod failed, exiting wait loop${NC}"
                    break
                fi

                echo -e "${BLUE}   Waiting for cleanup to complete... (attempt $((attempt + 1))/$max_attempts)${NC}"
                sleep 5
                attempt=$((attempt + 1))
            done

            # Check if the pod completed successfully by looking at the logs
            if [ "$cleanup_completed" = true ]; then
                echo -e "${GREEN}✅ OpenEMR database cleaned successfully via OpenEMR container${NC}"
                # Show the logs
                echo -e "${BLUE}   Cleanup logs:${NC}"
                kubectl logs db-cleanup-pod -n $TEMP_NAMESPACE
            else
                echo -e "${YELLOW}⚠️  Database cleanup pod may not have completed successfully${NC}"
                echo -e "${BLUE}   Pod status:${NC}"
                kubectl get pod db-cleanup-pod -n $TEMP_NAMESPACE
                echo -e "${BLUE}   Pod logs:${NC}"
                kubectl logs db-cleanup-pod -n $TEMP_NAMESPACE || echo "No logs available"
                echo -e "${BLUE}   Database cleanup will be handled during deployment${NC}"
            fi

            # Clean up temporary resources
            echo -e "${BLUE}   Cleaning up temporary resources...${NC}"
            kubectl delete namespace $TEMP_NAMESPACE --timeout=30s 2>/dev/null || true
        else
            echo -e "${YELLOW}⚠️  Could not get database details from Terraform${NC}"
            echo -e "${BLUE}   Database cleanup will be handled during deployment${NC}"
        fi
    else
        echo -e "${BLUE}ℹ️  Terraform state not found - skipping database cleanup${NC}"
    fi

    cd "$SCRIPT_DIR"
fi

# Clean up any orphaned PVCs (in case they weren't deleted with namespace)
echo -e "${YELLOW}4. Checking for orphaned PVCs...${NC}"
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

# Step 5: Clean up orphaned PersistentVolumes
# PVs that are no longer bound to PVCs should be removed to free up storage resources
echo -e "${YELLOW}5. Checking for orphaned PVs...${NC}"
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

# Step 6: Restart EFS CSI controller to clear cached state
# This ensures the CSI driver has a fresh state and can properly handle new PVCs
echo -e "${YELLOW}6. Restarting EFS CSI controller to clear cached state...${NC}"
kubectl rollout restart deployment efs-csi-controller -n kube-system
kubectl rollout status deployment efs-csi-controller -n kube-system --timeout=120s
echo -e "${GREEN}✅ EFS CSI controller restarted${NC}"
echo ""

# Step 7: Clean up local backup files from previous deployments
# Remove any .bak files and credential files that may have been generated
echo -e "${YELLOW}7. Cleaning up backup files...${NC}"
cd ../k8s
rm -f ./*.yaml.bak              # Remove backup files created during deployment
rm -f openemr-credentials*.txt  # Remove any credential files
echo -e "${GREEN}✅ Backup files cleaned${NC}"
echo ""

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
