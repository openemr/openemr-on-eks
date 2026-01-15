#!/bin/bash

# =============================================================================
# EFS CSI Driver Validation Script
# =============================================================================
#
# Purpose:
#   Validates the EFS CSI (Container Storage Interface) driver configuration
#   for OpenEMR on Amazon EKS, checking controller pods, IAM permissions,
#   EFS file system accessibility, and PVC status with troubleshooting guidance.
#
# Key Features:
#   - Validates EFS CSI controller pod status and health
#   - Checks IAM configuration (IRSA or Pod Identity) for EFS access
#   - Verifies EFS file system accessibility and state
#   - Analyzes PVC (PersistentVolumeClaim) binding status
#   - Monitors OpenEMR pod status and readiness
#   - Provides comprehensive troubleshooting recommendations
#   - Generates validation summary with pass/fail counts
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - AWS CLI configured with appropriate permissions
#   - EFS CSI driver installed in the cluster
#
# Usage:
#   ./validate-efs-csi.sh
#
# Environment Variables:
#   CLUSTER_NAME    EKS cluster name for Pod Identity checks (default: openemr-eks)
#   AWS_REGION      AWS region (default: us-west-2)
#
# Validation Categories:
#   1. EFS CSI Controller    Pod status and health
#   2. IAM Configuration     Service account permissions (IRSA/Pod Identity)
#   3. EFS File System       Accessibility and lifecycle state
#   4. PVC Status            Binding status for essential and backup volumes
#   5. Pod Status            OpenEMR pod readiness and health
#   6. Error Analysis        Recent errors in controller logs
#
# Examples:
#   ./validate-efs-csi.sh
#   CLUSTER_NAME=my-eks ./validate-efs-csi.sh
#
# =============================================================================

set -e

# Script directories for Terraform state access
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical issues
GREEN='\033[0;32m'    # Success messages and positive feedback
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
NC='\033[0m'          # Reset color to default

# Configuration variables - can be overridden by environment variables
CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}  # EKS cluster name for Pod Identity checks
AWS_REGION=${AWS_REGION:-"us-west-2"}        # AWS region where EFS and cluster are located

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

# Detect AWS region from Terraform state if not explicitly set
get_aws_region

echo -e "${GREEN}🔍 EFS CSI Driver Validation Tool${NC}"
echo -e "${GREEN}===================================${NC}"
echo ""

# Step 1: Validate EFS CSI controller pod status
# The EFS CSI controller is responsible for managing EFS volumes and PVCs
# It must be running for EFS storage to work properly
echo -e "${YELLOW}1. Checking EFS CSI controller pods...${NC}"
if kubectl get pods -n kube-system | grep efs-csi-controller | grep Running > /dev/null; then
    echo -e "${GREEN}✅ EFS CSI controller pods are running${NC}"
    # Display detailed pod information for verification
    kubectl get pods -n kube-system | grep efs-csi-controller
else
    echo -e "${RED}❌ EFS CSI controller pods are not running${NC}"
    # Show current pod status for troubleshooting
    kubectl get pods -n kube-system | grep efs-csi-controller || echo "No EFS CSI controller pods found"
    exit 1  # Exit on critical failure - EFS CSI controller is essential
fi
echo ""

# Step 2: Validate IAM configuration for EFS CSI service account
# The EFS CSI controller needs IAM permissions to access EFS file systems
# This can be configured via IRSA (IAM Roles for Service Accounts) or EKS Pod Identity
echo -e "${YELLOW}2. Checking EFS CSI service account IAM configuration...${NC}"
if kubectl get serviceaccount efs-csi-controller-sa -n kube-system > /dev/null 2>&1; then
    # Check for IRSA annotation (traditional method)
    # IRSA uses annotations on the service account to specify the IAM role
    IRSA_ANNOTATION=$(kubectl get serviceaccount efs-csi-controller-sa -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")

    # Check for Pod Identity (newer method)
    # EKS Pod Identity is the newer way to provide IAM permissions to pods
    POD_IDENTITY_CHECK=false
    if command -v aws >/dev/null 2>&1; then
        # Query EKS Pod Identity associations for the EFS CSI service account
        POD_IDENTITY_ASSOC=$(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $AWS_REGION --query "associations[?serviceAccount=='efs-csi-controller-sa'].associationId" --output text 2>/dev/null || echo "")
        if [ -n "$POD_IDENTITY_ASSOC" ] && [ "$POD_IDENTITY_ASSOC" != "None" ]; then
            POD_IDENTITY_CHECK=true
            # Get the role ARN associated with the Pod Identity
            POD_IDENTITY_ROLE=$(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $AWS_REGION --query "associations[?serviceAccount=='efs-csi-controller-sa'].roleArn" --output text 2>/dev/null || echo "")
        fi
    fi

    # Validate IAM configuration - either IRSA or Pod Identity must be present
    if [ -n "$IRSA_ANNOTATION" ]; then
        echo -e "${GREEN}✅ EFS CSI service account has IRSA IAM role annotation${NC}"
        echo -e "${BLUE}   Role ARN: $IRSA_ANNOTATION${NC}"
    elif [ "$POD_IDENTITY_CHECK" = true ]; then
        echo -e "${GREEN}✅ EFS CSI service account has EKS Pod Identity configuration${NC}"
        echo -e "${BLUE}   Association ID: $POD_IDENTITY_ASSOC${NC}"
        if [ -n "$POD_IDENTITY_ROLE" ] && [ "$POD_IDENTITY_ROLE" != "None" ]; then
            echo -e "${BLUE}   Role ARN: $POD_IDENTITY_ROLE${NC}"
        fi
    else
        echo -e "${RED}❌ EFS CSI service account missing IAM configuration${NC}"
        echo -e "${YELLOW}   Neither IRSA annotation nor Pod Identity found${NC}"
        echo -e "${YELLOW}   This should be configured automatically by Terraform${NC}"
        exit 1  # Exit on critical failure - IAM permissions are essential
    fi
else
    echo -e "${RED}❌ EFS CSI service account not found${NC}"
    exit 1  # Exit on critical failure - service account is essential
fi
echo ""

# Step 3: Validate EFS file system configuration and accessibility
# This step verifies that the EFS file system exists and is accessible
# It retrieves the EFS ID from Terraform outputs and validates AWS access
echo -e "${YELLOW}3. Checking EFS file system configuration...${NC}"
if [ -d "$TERRAFORM_DIR" ]; then
    cd "$TERRAFORM_DIR"
    # Retrieve EFS ID from Terraform outputs
    EFS_ID=$(terraform output -raw efs_id 2>/dev/null || echo "unknown")
    cd - >/dev/null
    if [ "$EFS_ID" != "unknown" ] && [ -n "$EFS_ID" ]; then
        echo -e "${GREEN}✅ EFS ID from Terraform: $EFS_ID${NC}"

        # Validate EFS accessibility via AWS CLI
        if command -v aws >/dev/null 2>&1; then
            if aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" > /dev/null 2>&1; then
                echo -e "${GREEN}✅ EFS file system is accessible via AWS CLI${NC}"
                # Get EFS lifecycle state for additional validation
                EFS_STATE=$(aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" --query 'FileSystems[0].LifeCycleState' --output text 2>/dev/null || echo "unknown")
                echo -e "${BLUE}   EFS State: $EFS_STATE${NC}"
            else
                echo -e "${YELLOW}⚠️  EFS file system not accessible via AWS CLI (check credentials)${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️  AWS CLI not available for EFS validation${NC}"
        fi
    else
        echo -e "${RED}❌ Could not get EFS ID from Terraform${NC}"
        echo -e "${YELLOW}   Make sure Terraform has been deployed${NC}"
        exit 1  # Exit on critical failure - EFS ID is essential
    fi
else
    echo -e "${RED}❌ Terraform directory not found at $TERRAFORM_DIR${NC}"
    echo -e "${YELLOW}   Make sure you're running this from the project root${NC}"
    exit 1  # Exit on critical failure - Terraform directory is essential
fi
echo ""

# Step 4: Analyze EFS CSI controller logs for errors
# This step checks for recent errors in the EFS CSI controller logs
# It helps identify credential issues, connectivity problems, or other failures
echo -e "${YELLOW}4. Checking EFS CSI controller logs for errors...${NC}"
# Extract recent errors from the last 50 log lines in the past 5 minutes
RECENT_ERRORS=$(kubectl logs -n kube-system deployment/efs-csi-controller --tail=50 --since=5m 2>/dev/null | grep -i "error\|failed" | head -5 || echo "")
if [ -n "$RECENT_ERRORS" ]; then
    echo -e "${YELLOW}⚠️  Recent errors found in EFS CSI controller logs:${NC}"
    echo "$RECENT_ERRORS"
    echo ""
    echo -e "${BLUE}💡 If you see credential errors, try restarting the EFS CSI controller:${NC}"
    echo -e "${BLUE}   kubectl rollout restart deployment efs-csi-controller -n kube-system${NC}"
else
    echo -e "${GREEN}✅ No recent errors in EFS CSI controller logs${NC}"
fi
echo ""

# Step 5: Validate PVC (PersistentVolumeClaim) status in OpenEMR namespace
# This step checks the binding status of PVCs, which is critical for OpenEMR functionality
# Essential PVCs must be bound for OpenEMR pods to start successfully
echo -e "${YELLOW}5. Checking PVC status in openemr namespace...${NC}"
if kubectl get namespace openemr > /dev/null 2>&1; then
    if kubectl get pvc -n openemr > /dev/null 2>&1; then
        echo -e "${BLUE}PVC Status:${NC}"
        kubectl get pvc -n openemr
        echo ""

        # Count essential PVCs that are bound (required for OpenEMR to start)
        # Essential PVCs: sites (application data), ssl (certificates), letsencrypt (SSL certificates)
        ESSENTIAL_BOUND=$(kubectl get pvc -n openemr --no-headers | grep -E "(openemr-sites-pvc|openemr-ssl-pvc|openemr-letsencrypt-pvc)" | grep -c "Bound" || echo "0")
        # Check backup PVC status (binds only when backup runs)
        BACKUP_STATUS=$(kubectl get pvc openemr-backup-pvc -n openemr --no-headers 2>/dev/null | awk '{print $2}' || echo "Not Found")
        TOTAL_PVCS=$(kubectl get pvc -n openemr --no-headers | wc -l | tr -d ' ')

        # Display status of essential PVCs with color-coded feedback
        echo -e "${BLUE}Essential PVCs (required for OpenEMR):${NC}"
        kubectl get pvc -n openemr --no-headers | grep -E "(openemr-sites-pvc|openemr-ssl-pvc|openemr-letsencrypt-pvc)" | while read line; do
            PVC_NAME=$(echo "$line" | awk '{print $1}')
            PVC_STATUS=$(echo "$line" | awk '{print $2}')
            if [ "$PVC_STATUS" = "Bound" ]; then
                echo -e "${GREEN}   ✅ $PVC_NAME: $PVC_STATUS${NC}"
            else
                echo -e "${RED}   ❌ $PVC_NAME: $PVC_STATUS${NC}"
            fi
        done

        # Display backup PVC status (uses WaitForFirstConsumer - normal to be Pending)
        echo -e "${BLUE}Backup PVC (binds when backup runs):${NC}"
        if [ "$BACKUP_STATUS" = "Pending" ]; then
            echo -e "${BLUE}   ℹ️  openemr-backup-pvc: $BACKUP_STATUS (normal - uses WaitForFirstConsumer)${NC}"
        elif [ "$BACKUP_STATUS" = "Bound" ]; then
            echo -e "${GREEN}   ✅ openemr-backup-pvc: $BACKUP_STATUS${NC}"
        else
            echo -e "${YELLOW}   ⚠️  openemr-backup-pvc: $BACKUP_STATUS${NC}"
        fi
        echo ""

        # Provide summary of essential PVC binding status
        if [ "$ESSENTIAL_BOUND" -ge 3 ]; then
            echo -e "${GREEN}✅ All essential PVCs are bound (3/3)${NC}"
            echo -e "${BLUE}💡 OpenEMR pods should be able to start successfully${NC}"
        else
            echo -e "${YELLOW}⚠️  Only $ESSENTIAL_BOUND/3 essential PVCs are bound${NC}"
            echo -e "${YELLOW}💡 OpenEMR pods may remain in Pending status${NC}"

            # Show events for pending essential PVCs to help with troubleshooting
            echo -e "${BLUE}Checking events for pending essential PVCs...${NC}"
            kubectl describe pvc -n openemr | grep -A 10 "Events:" | head -20 || echo "No events found"
        fi
    else
        echo -e "${YELLOW}ℹ️  No PVCs found in openemr namespace${NC}"
    fi
else
    echo -e "${YELLOW}ℹ️  OpenEMR namespace not found${NC}"
fi
echo ""

# Step 6: Validate OpenEMR pod status and readiness
# This step checks the status of OpenEMR pods to determine if they can start successfully
# Pod status is directly related to PVC binding status and EFS CSI functionality
echo -e "${YELLOW}6. Checking OpenEMR pod status...${NC}"
if kubectl get namespace openemr > /dev/null 2>&1; then
    if kubectl get pods -n openemr > /dev/null 2>&1; then
        echo -e "${BLUE}Pod Status:${NC}"
        kubectl get pods -n openemr
        echo ""

        # Get the status of the first OpenEMR pod for analysis
        POD_STATUS=$(kubectl get pods -n openemr --no-headers | awk '{print $3}' | head -1 || echo "None")
        case "$POD_STATUS" in
            "Running")
                echo -e "${GREEN}✅ OpenEMR pod is running${NC}"
                # Check if the pod is ready (all containers started successfully)
                READY=$(kubectl get pods -n openemr --no-headers | awk '{print $2}' | head -1)
                if [ "$READY" = "1/1" ]; then
                    echo -e "${GREEN}✅ OpenEMR pod is ready${NC}"
                else
                    echo -e "${YELLOW}ℹ️  OpenEMR pod is starting up (this can take 5-10 minutes)${NC}"
                fi
                ;;
            "Pending")
                echo -e "${YELLOW}⚠️  OpenEMR pod is pending - likely waiting for PVCs${NC}"
                ;;
            "ContainerCreating")
                echo -e "${YELLOW}ℹ️  OpenEMR pod is being created${NC}"
                ;;
            "None")
                echo -e "${YELLOW}ℹ️  No OpenEMR pods found${NC}"
                ;;
            *)
                echo -e "${YELLOW}ℹ️  OpenEMR pod status: $POD_STATUS${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}ℹ️  No pods found in openemr namespace${NC}"
    fi
else
    echo -e "${YELLOW}ℹ️  OpenEMR namespace not found${NC}"
fi
echo ""

# Summary and recommendations section
# This section provides a comprehensive summary of all validation checks
# and offers troubleshooting guidance based on the results
echo -e "${GREEN}🎯 Validation Summary${NC}"
echo -e "${GREEN}===================${NC}"

# Count successful validation checks
# This provides a quantitative measure of EFS CSI driver health
CHECKS_PASSED=0

# Check 1: EFS CSI controller pods are running
if kubectl get pods -n kube-system | grep efs-csi-controller | grep Running > /dev/null; then
    ((CHECKS_PASSED++))
fi

# Check 2: IAM configuration is present (either IRSA or Pod Identity)
IRSA_ANNOTATION=$(kubectl get serviceaccount efs-csi-controller-sa -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
POD_IDENTITY_ASSOC=$(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $AWS_REGION --query "associations[?serviceAccount=='efs-csi-controller-sa'].associationId" --output text 2>/dev/null || echo "")

if [ -n "$IRSA_ANNOTATION" ] || ([ -n "$POD_IDENTITY_ASSOC" ] && [ "$POD_IDENTITY_ASSOC" != "None" ]); then
    ((CHECKS_PASSED++))
fi

# Check 3: EFS file system ID is available from Terraform
if [ "$EFS_ID" != "unknown" ] && [ -n "$EFS_ID" ]; then
    ((CHECKS_PASSED++))
fi

# Check 4: No recent errors in EFS CSI controller logs
if [ -z "$RECENT_ERRORS" ]; then
    ((CHECKS_PASSED++))
fi

# Display validation results
echo -e "${BLUE}Checks passed: $CHECKS_PASSED/4${NC}"

# Provide final assessment and recommendations
if [ $CHECKS_PASSED -eq 4 ]; then
    echo -e "${GREEN}✅ EFS CSI driver appears to be configured correctly${NC}"
    echo -e "${GREEN}✅ Storage should be working properly${NC}"
else
    echo -e "${YELLOW}⚠️  Some issues detected with EFS CSI configuration${NC}"
    echo ""
    echo -e "${BLUE}💡 Troubleshooting Steps:${NC}"
    echo -e "${BLUE}1. Restart EFS CSI controller:${NC}"
    echo -e "${BLUE}   kubectl rollout restart deployment efs-csi-controller -n kube-system${NC}"
    echo -e "${BLUE}2. Check Terraform outputs:${NC}"
    echo -e "${BLUE}   cd ../terraform && terraform output${NC}"
    echo -e "${BLUE}3. Verify AWS credentials:${NC}"
    echo -e "${BLUE}   aws sts get-caller-identity${NC}"
    echo -e "${BLUE}4. Re-run deployment:${NC}"
    echo -e "${BLUE}   cd ../k8s && ./deploy.sh${NC}"
fi

echo ""
echo -e "${GREEN}Validation completed!${NC}"
