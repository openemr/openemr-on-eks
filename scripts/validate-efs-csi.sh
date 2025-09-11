#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}
AWS_REGION=${AWS_REGION:-"us-west-2"}

echo -e "${GREEN}🔍 EFS CSI Driver Validation Tool${NC}"
echo -e "${GREEN}===================================${NC}"
echo ""

# Check if EFS CSI controller pods are running
echo -e "${YELLOW}1. Checking EFS CSI controller pods...${NC}"
if kubectl get pods -n kube-system | grep efs-csi-controller | grep Running > /dev/null; then
    echo -e "${GREEN}✅ EFS CSI controller pods are running${NC}"
    kubectl get pods -n kube-system | grep efs-csi-controller
else
    echo -e "${RED}❌ EFS CSI controller pods are not running${NC}"
    kubectl get pods -n kube-system | grep efs-csi-controller || echo "No EFS CSI controller pods found"
    exit 1
fi
echo ""

# Check service account IAM configuration (IRSA or Pod Identity)
echo -e "${YELLOW}2. Checking EFS CSI service account IAM configuration...${NC}"
if kubectl get serviceaccount efs-csi-controller-sa -n kube-system > /dev/null 2>&1; then
    # Check for IRSA annotation (traditional method)
    IRSA_ANNOTATION=$(kubectl get serviceaccount efs-csi-controller-sa -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")

    # Check for Pod Identity (newer method)
    POD_IDENTITY_CHECK=false
    if command -v aws >/dev/null 2>&1; then
        # Check if there's a pod identity association for this service account
        POD_IDENTITY_ASSOC=$(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $AWS_REGION --query "associations[?serviceAccount=='efs-csi-controller-sa'].associationId" --output text 2>/dev/null || echo "")
        if [ -n "$POD_IDENTITY_ASSOC" ] && [ "$POD_IDENTITY_ASSOC" != "None" ]; then
            POD_IDENTITY_CHECK=true
            POD_IDENTITY_ROLE=$(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $AWS_REGION --query "associations[?serviceAccount=='efs-csi-controller-sa'].roleArn" --output text 2>/dev/null || echo "")
        fi
    fi

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
        exit 1
    fi
else
    echo -e "${RED}❌ EFS CSI service account not found${NC}"
    exit 1
fi
echo ""

# Check EFS file system from Terraform
echo -e "${YELLOW}3. Checking EFS file system configuration...${NC}"
if [ -d "../terraform" ]; then
    cd ../terraform
    EFS_ID=$(terraform output -raw efs_id 2>/dev/null || echo "unknown")
    if [ "$EFS_ID" != "unknown" ] && [ -n "$EFS_ID" ]; then
        echo -e "${GREEN}✅ EFS ID from Terraform: $EFS_ID${NC}"

        # Check if EFS is accessible via AWS CLI
        if command -v aws >/dev/null 2>&1; then
            if aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" > /dev/null 2>&1; then
                echo -e "${GREEN}✅ EFS file system is accessible via AWS CLI${NC}"
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
        echo -e "${YELLOW}   Make sure you're running this from the scripts directory${NC}"
        exit 1
    fi
    cd ../scripts
else
    echo -e "${RED}❌ Terraform directory not found${NC}"
    echo -e "${YELLOW}   Make sure you're running this from the scripts directory${NC}"
    exit 1
fi
echo ""

# Check EFS CSI controller logs for errors
echo -e "${YELLOW}4. Checking EFS CSI controller logs for errors...${NC}"
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

# Check PVC status if openemr namespace exists
echo -e "${YELLOW}5. Checking PVC status in openemr namespace...${NC}"
if kubectl get namespace openemr > /dev/null 2>&1; then
    if kubectl get pvc -n openemr > /dev/null 2>&1; then
        echo -e "${BLUE}PVC Status:${NC}"
        kubectl get pvc -n openemr
        echo ""

        # Check essential PVCs (required for OpenEMR to start)
        ESSENTIAL_BOUND=$(kubectl get pvc -n openemr --no-headers | grep -E "(openemr-sites-pvc|openemr-ssl-pvc|openemr-letsencrypt-pvc)" | grep -c "Bound" || echo "0")
        BACKUP_STATUS=$(kubectl get pvc openemr-backup-pvc -n openemr --no-headers 2>/dev/null | awk '{print $2}' || echo "Not Found")
        TOTAL_PVCS=$(kubectl get pvc -n openemr --no-headers | wc -l | tr -d ' ')

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

        echo -e "${BLUE}Backup PVC (binds when backup runs):${NC}"
        if [ "$BACKUP_STATUS" = "Pending" ]; then
            echo -e "${BLUE}   ℹ️  openemr-backup-pvc: $BACKUP_STATUS (normal - uses WaitForFirstConsumer)${NC}"
        elif [ "$BACKUP_STATUS" = "Bound" ]; then
            echo -e "${GREEN}   ✅ openemr-backup-pvc: $BACKUP_STATUS${NC}"
        else
            echo -e "${YELLOW}   ⚠️  openemr-backup-pvc: $BACKUP_STATUS${NC}"
        fi
        echo ""

        if [ "$ESSENTIAL_BOUND" -ge 3 ]; then
            echo -e "${GREEN}✅ All essential PVCs are bound (3/3)${NC}"
            echo -e "${BLUE}💡 OpenEMR pods should be able to start successfully${NC}"
        else
            echo -e "${YELLOW}⚠️  Only $ESSENTIAL_BOUND/3 essential PVCs are bound${NC}"
            echo -e "${YELLOW}💡 OpenEMR pods may remain in Pending status${NC}"

            # Show events for pending essential PVCs
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

# Check pod status if openemr namespace exists
echo -e "${YELLOW}6. Checking OpenEMR pod status...${NC}"
if kubectl get namespace openemr > /dev/null 2>&1; then
    if kubectl get pods -n openemr > /dev/null 2>&1; then
        echo -e "${BLUE}Pod Status:${NC}"
        kubectl get pods -n openemr
        echo ""

        POD_STATUS=$(kubectl get pods -n openemr --no-headers | awk '{print $3}' | head -1 || echo "None")
        case "$POD_STATUS" in
            "Running")
                echo -e "${GREEN}✅ OpenEMR pod is running${NC}"
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

# Summary and recommendations
echo -e "${GREEN}🎯 Validation Summary${NC}"
echo -e "${GREEN}===================${NC}"

# Count successful checks
CHECKS_PASSED=0
if kubectl get pods -n kube-system | grep efs-csi-controller | grep Running > /dev/null; then
    ((CHECKS_PASSED++))
fi

# Check for either IRSA or Pod Identity
IRSA_ANNOTATION=$(kubectl get serviceaccount efs-csi-controller-sa -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
POD_IDENTITY_ASSOC=$(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $AWS_REGION --query "associations[?serviceAccount=='efs-csi-controller-sa'].associationId" --output text 2>/dev/null || echo "")

if [ -n "$IRSA_ANNOTATION" ] || ([ -n "$POD_IDENTITY_ASSOC" ] && [ "$POD_IDENTITY_ASSOC" != "None" ]); then
    ((CHECKS_PASSED++))
fi

if [ "$EFS_ID" != "unknown" ] && [ -n "$EFS_ID" ]; then
    ((CHECKS_PASSED++))
fi

if [ -z "$RECENT_ERRORS" ]; then
    ((CHECKS_PASSED++))
fi

echo -e "${BLUE}Checks passed: $CHECKS_PASSED/4${NC}"

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
