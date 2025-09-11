#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
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
            exit 1
            ;;
    esac
done

CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}
AWS_REGION=${AWS_REGION:-"us-west-2"}
NAMESPACE=${NAMESPACE:-"openemr"}

# Get the script's directory and project root for path-independent operation
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}🧹 OpenEMR Clean Deployment Script${NC}"
echo -e "${GREEN}===================================${NC}"
echo ""
echo -e "${YELLOW}This script will clean up the current OpenEMR deployment${NC}"
echo -e "${YELLOW}Infrastructure (EKS, RDS, etc.) will remain intact${NC}"
echo -e "${RED}⚠️  DATABASE WARNING: This will DELETE ALL OpenEMR data from the database!${NC}"
echo -e "${RED}⚠️  This action cannot be undone!${NC}"
echo ""

# Confirm with user (unless force mode is enabled)
if [ "$FORCE" = false ]; then
    read -p "Are you sure you want to clean the current deployment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Cleanup cancelled${NC}"
        exit 0
    fi
else
    echo -e "${YELLOW}Force mode enabled - skipping confirmation prompts${NC}"
fi

echo -e "${YELLOW}Starting cleanup...${NC}"
echo ""

# Delete OpenEMR namespace (this removes all resources in the namespace)
echo -e "${YELLOW}1. Removing OpenEMR namespace and all resources...${NC}"
if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    kubectl delete namespace "$NAMESPACE" --timeout=300s
    echo -e "${GREEN}✅ OpenEMR namespace deleted${NC}"
else
    echo -e "${BLUE}ℹ️  OpenEMR namespace not found${NC}"
fi
echo ""

# Wait for namespace to be fully deleted
echo -e "${YELLOW}2. Waiting for namespace deletion to complete...${NC}"
while kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; do
    echo -e "${BLUE}   Waiting for namespace deletion...${NC}"
    sleep 5
done
echo -e "${GREEN}✅ Namespace fully deleted${NC}"
echo ""

# Clean up OpenEMR database to prevent reconfiguration conflicts
echo -e "${YELLOW}3. Cleaning up OpenEMR database...${NC}"
echo -e "${RED}⚠️  WARNING: This will DELETE ALL OpenEMR data from the database!${NC}"
echo -e "${RED}⚠️  This action cannot be undone!${NC}"
echo ""

# Confirm database cleanup (unless force mode is enabled)
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

# Only proceed with database cleanup if DB_CLEANUP is true
if [ "$DB_CLEANUP" = true ]; then
    # Get database details from Terraform
    cd "$PROJECT_ROOT/terraform"
    if [ -f "terraform.tfstate" ]; then
        echo -e "${BLUE}   Getting database details from Terraform...${NC}"
        AURORA_ENDPOINT=$(terraform output -raw aurora_endpoint 2>/dev/null || echo "")
        AURORA_PASSWORD=$(terraform output -raw aurora_password 2>/dev/null || echo "")

        if [ -n "$AURORA_ENDPOINT" ] && [ -n "$AURORA_PASSWORD" ]; then
            echo -e "${BLUE}   Database endpoint: $AURORA_ENDPOINT${NC}"

            # Use a temporary MySQL pod to clean the database
            echo -e "${YELLOW}   Launching temporary MySQL pod to clean database...${NC}"

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

            # Create a temporary MySQL pod for database cleanup
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: db-cleanup-pod
  namespace: $TEMP_NAMESPACE
spec:
  containers:
  - name: mysql-client
    image: mysql:8.0
    command: ['sh', '-c']
    args:
    - |
      echo "Waiting for MySQL connection..."
      until mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SELECT 1;" >/dev/null 2>&1; do
        sleep 2
      done
      echo "Connected to MySQL, cleaning database..."
      mysql -h \${MYSQL_HOST} -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "DROP DATABASE IF EXISTS openemr; CREATE DATABASE openemr CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
      echo "Database cleanup completed"
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
                echo -e "${GREEN}✅ OpenEMR database cleaned successfully via temporary MySQL pod${NC}"
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
        kubectl delete pvc "$pvc" -n "$namespace" --timeout=60s || echo "Failed to delete $pvc"
    done
else
    echo -e "${GREEN}✅ No orphaned PVCs found${NC}"
fi

# Also check for any PVCs in the openemr namespace specifically
echo -e "${YELLOW}   Checking for any remaining PVCs in openemr namespace...${NC}"
if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    # Namespace still exists, check for PVCs
    REMAINING_PVCS=$(kubectl get pvc -n "$NAMESPACE" 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")
    if [ -n "$REMAINING_PVCS" ]; then
        echo -e "${YELLOW}   Found remaining PVCs in $NAMESPACE namespace, force deleting...${NC}"
        echo "$REMAINING_PVCS" | while read -r pvc; do
            if [ -n "$pvc" ]; then
                echo -e "${BLUE}   Force deleting PVC: $pvc${NC}"
                kubectl delete pvc "$pvc" -n "$NAMESPACE" --force --grace-period=0 --timeout=30s 2>/dev/null || true
            fi
        done
    fi
else
    echo -e "${BLUE}   Namespace $NAMESPACE no longer exists${NC}"
fi
echo ""

# Clean up any orphaned PVs
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

# Restart EFS CSI controller to clear any cached state
echo -e "${YELLOW}6. Restarting EFS CSI controller to clear cached state...${NC}"
kubectl rollout restart deployment efs-csi-controller -n kube-system
kubectl rollout status deployment efs-csi-controller -n kube-system --timeout=120s
echo -e "${GREEN}✅ EFS CSI controller restarted${NC}"
echo ""

# Clean up any stale OpenEMR configuration files from EFS volumes
echo -e "${YELLOW}7. Cleaning up stale OpenEMR configuration files from EFS volumes...${NC}"
# Create a temporary pod to clean up stale configuration files
TEMP_NAMESPACE="efs-cleanup-temp"
kubectl create namespace $TEMP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

# Create a temporary pod to clean up stale configuration files
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: efs-cleanup-pod
  namespace: $TEMP_NAMESPACE
spec:
  containers:
  - name: cleanup
    image: busybox:1.35
    command: ['sh', '-c']
    args:
    - |
      echo "Cleaning up stale OpenEMR configuration files..."
      # Mount the EFS volumes and clean up stale configuration files
      if [ -d "/mnt/sites" ]; then
        echo "Cleaning /mnt/sites directory..."
        rm -rf /mnt/sites/*
        echo "✅ Sites directory cleaned"
      fi
      if [ -d "/mnt/ssl" ]; then
        echo "Cleaning /mnt/ssl directory..."
        rm -rf /mnt/ssl/*
        echo "✅ SSL directory cleaned"
      fi
      if [ -d "/mnt/letsencrypt" ]; then
        echo "Cleaning /mnt/letsencrypt directory..."
        rm -rf /mnt/letsencrypt/*
        echo "✅ Let's Encrypt directory cleaned"
      fi
      echo "EFS cleanup completed"
    volumeMounts:
    - name: sites-volume
      mountPath: /mnt/sites
    - name: ssl-volume
      mountPath: /mnt/ssl
    - name: letsencrypt-volume
      mountPath: /mnt/letsencrypt
  volumes:
  - name: sites-volume
    persistentVolumeClaim:
      claimName: openemr-sites-pvc
  - name: ssl-volume
    persistentVolumeClaim:
      claimName: openemr-ssl-pvc
  - name: letsencrypt-volume
    persistentVolumeClaim:
      claimName: openemr-letsencrypt-pvc
  restartPolicy: Never
EOF

# Wait for the cleanup pod to complete
echo -e "${BLUE}   Waiting for EFS cleanup to complete...${NC}"
kubectl wait --for=condition=Ready pod/efs-cleanup-pod -n $TEMP_NAMESPACE --timeout=60s 2>/dev/null || true

# Check if the pod completed successfully
sleep 5
if kubectl logs efs-cleanup-pod -n $TEMP_NAMESPACE 2>/dev/null | grep -q "EFS cleanup completed"; then
    echo -e "${GREEN}✅ EFS volumes cleaned successfully${NC}"
    echo -e "${BLUE}   Cleanup logs:${NC}"
    kubectl logs efs-cleanup-pod -n $TEMP_NAMESPACE
else
    echo -e "${YELLOW}⚠️  EFS cleanup may not have completed successfully${NC}"
    echo -e "${BLUE}   Pod status:${NC}"
    kubectl get pod efs-cleanup-pod -n $TEMP_NAMESPACE 2>/dev/null || echo "Pod not found"
    echo -e "${BLUE}   Pod logs:${NC}"
    kubectl logs efs-cleanup-pod -n $TEMP_NAMESPACE 2>/dev/null || echo "No logs available"
fi

# Clean up temporary resources
echo -e "${BLUE}   Cleaning up temporary EFS cleanup resources...${NC}"
kubectl delete namespace $TEMP_NAMESPACE --timeout=30s 2>/dev/null || true
echo ""

# Clean up any backup files from previous deployments
echo -e "${YELLOW}8. Cleaning up backup files...${NC}"
cd ../k8s
rm -f ./*.yaml.bak
rm -f openemr-credentials*.txt
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
