#!/bin/bash

# =============================================================================
# OpenEMR Deployment Validation Script
# =============================================================================
#
# Purpose:
#   Performs comprehensive validation of the deployment environment for
#   OpenEMR on Amazon EKS, checking prerequisites, AWS credentials,
#   infrastructure state, and security configuration with detailed feedback.
#
# Key Features:
#   - Validates required tools and dependencies (kubectl, aws, helm, jq)
#   - Comprehensive AWS credentials validation and source detection
#   - Infrastructure state checking (Terraform, EKS cluster, AWS resources)
#   - Kubernetes resource validation and namespace checking
#   - Security configuration analysis and recommendations
#   - Deployment readiness assessment with actionable next steps
#   - Support for both first-time and existing deployments
#
# Prerequisites:
#   - AWS CLI installed
#   - kubectl installed (for cluster validation)
#   - jq installed (for JSON parsing)
#
# Usage:
#   ./validate-deployment.sh
#
# Environment Variables:
#   CLUSTER_NAME    EKS cluster name to validate (default: openemr-eks)
#   AWS_REGION      AWS region (default: us-west-2)
#   NAMESPACE       Kubernetes namespace (default: openemr)
#
# Validation Categories:
#   1. Prerequisites      Required tools and dependencies
#   2. AWS Credentials    Authentication and authorization
#   3. Terraform State    Infrastructure configuration and state
#   4. Cluster Access     EKS cluster connectivity and configuration
#   5. AWS Resources      VPC, RDS, ElastiCache, EFS validation
#   6. Kubernetes         Namespace and deployment status
#   7. Security Config    Endpoint access and encryption
#
# Examples:
#   ./validate-deployment.sh
#   CLUSTER_NAME=my-eks ./validate-deployment.sh
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
CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}   # EKS cluster name to validate
AWS_REGION=${AWS_REGION:-"us-west-2"}         # AWS region where resources are located
NAMESPACE=${NAMESPACE:-"openemr"}             # Kubernetes namespace for OpenEMR

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

echo -e "${BLUE}🔍 OpenEMR Deployment Validation${NC}"
echo -e "${BLUE}================================${NC}"

# Function to check command availability
# This function validates that required command-line tools are installed and accessible
# It uses the 'command -v' builtin to check for command existence without executing it
check_command() {
    local cmd="$1"  # Command name to check for availability
    
    # Use command -v to check if the command exists in PATH
    # Redirect stderr to /dev/null to suppress error messages
    if command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ $cmd is installed${NC}"
        return 0  # Success - command is available
    else
        echo -e "${RED}❌ $cmd is not installed${NC}"
        return 1  # Failure - command is not available
    fi
}

# Function to check AWS credentials
# This function validates AWS authentication by calling the STS GetCallerIdentity API
# It provides detailed information about the authenticated identity and credential sources
check_aws_credentials() {
    echo -e "${BLUE}Checking AWS credential sources...${NC}"

    # Test AWS credentials by calling STS GetCallerIdentity API
    # This is the most reliable way to validate AWS authentication
    if aws sts get-caller-identity >/dev/null 2>&1; then
        # Extract account ID and user/role ARN from the successful response
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
        echo -e "${GREEN}✅ AWS credentials valid${NC}"
        echo -e "${GREEN}   Account ID: $ACCOUNT_ID${NC}"
        echo -e "${GREEN}   User/Role: $USER_ARN${NC}"

        # Analyze and display credential source information
        detect_credential_source
        return 0  # Success - credentials are valid
    else
        # Credentials are invalid or not configured
        echo -e "${RED}❌ AWS credentials invalid or not configured${NC}"
        echo -e "${YELLOW}💡 Configure credentials using one of these methods:${NC}"
        echo -e "${YELLOW}   • aws configure${NC}"
        echo -e "${YELLOW}   • AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables${NC}"
        echo -e "${YELLOW}   • IAM instance profile (if running on EC2)${NC}"
        echo -e "${YELLOW}   • AWS SSO: aws sso login${NC}"
        return 1  # Failure - credentials are invalid
    fi
}

# Function to detect AWS credential source
# This function analyzes the environment to determine how AWS credentials are configured
# It checks multiple credential sources in order of precedence and provides detailed information
detect_credential_source() {
    local cred_sources=()  # Array to track detected credential sources

    # Check environment variables (highest precedence)
    # AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY take precedence over all other sources
    if [ ! -z "$AWS_ACCESS_KEY_ID" ] && [ ! -z "$AWS_SECRET_ACCESS_KEY" ]; then
        cred_sources+=("Environment variables (AWS_ACCESS_KEY_ID)")
        echo -e "${BLUE}   📍 Source: Environment variables${NC}"
    fi

    # Check AWS credentials file (~/.aws/credentials)
    # This file contains access keys and is used by aws configure
    AWS_CREDS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
    if [ -f "$AWS_CREDS_FILE" ]; then
        cred_sources+=("Credentials file ($AWS_CREDS_FILE)")
        echo -e "${BLUE}   📍 Source: Credentials file found at $AWS_CREDS_FILE${NC}"

        # Extract and display available profiles from credentials file
        # Profiles are defined in [profile-name] sections
        if command -v grep >/dev/null 2>&1; then
            PROFILES=$(grep -E '^\[.*\]' "$AWS_CREDS_FILE" | sed 's/\[//g' | sed 's/\]//g' | tr '\n' ', ' | sed 's/, $//')
            if [ ! -z "$PROFILES" ]; then
                echo -e "${BLUE}   📋 Available profiles: $PROFILES${NC}"
            fi
        fi

        # Display current active profile (default if AWS_PROFILE not set)
        CURRENT_PROFILE="${AWS_PROFILE:-default}"
        echo -e "${BLUE}   🎯 Current profile: $CURRENT_PROFILE${NC}"
    fi

    # Check AWS config file (~/.aws/config)
    # This file contains configuration settings like region and SSO settings
    AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
    if [ -f "$AWS_CONFIG_FILE" ]; then
        echo -e "${BLUE}   📍 Config file found at $AWS_CONFIG_FILE${NC}"

        # Check for AWS SSO configuration
        # SSO uses temporary credentials obtained through browser-based authentication
        if grep -q "sso_" "$AWS_CONFIG_FILE" 2>/dev/null; then
            cred_sources+=("AWS SSO configuration")
            echo -e "${BLUE}   🔐 SSO configuration detected${NC}"
        fi

        # Check for IAM role assumption configuration
        # Role assumption allows assuming different IAM roles for different profiles
        if grep -q "role_arn" "$AWS_CONFIG_FILE" 2>/dev/null; then
            cred_sources+=("IAM role assumption")
            echo -e "${BLUE}   👤 Role assumption configured${NC}"
        fi
    fi

    # Check for EC2 instance profile (if running on EC2)
    # Instance profiles provide credentials automatically to EC2 instances
    # The metadata service is only available from within EC2 instances
    if curl -s --max-time 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ >/dev/null 2>&1; then
        cred_sources+=("EC2 instance profile")
        echo -e "${BLUE}   🖥️  EC2 instance profile detected${NC}"
    fi

    # Check for ECS task role (if running in ECS)
    # ECS task roles provide credentials to containers running in ECS tasks
    if [ ! -z "$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" ]; then
        cred_sources+=("ECS task role")
        echo -e "${BLUE}   📦 ECS task role detected${NC}"
    fi

    # Validate and display current AWS region configuration
    # Region is important for determining which AWS endpoints to use
    CURRENT_REGION=$(aws configure get region 2>/dev/null || echo "not set")
    echo -e "${BLUE}   🌍 Current region: $CURRENT_REGION${NC}"

    # Provide region configuration recommendations
    if [ "$CURRENT_REGION" = "not set" ]; then
        echo -e "${YELLOW}   ⚠️  AWS region not configured${NC}"
        echo -e "${YELLOW}   💡 Set region: aws configure set region $AWS_REGION${NC}"
    elif [ "$CURRENT_REGION" != "$AWS_REGION" ]; then
        echo -e "${YELLOW}   ⚠️  Current region ($CURRENT_REGION) differs from deployment region ($AWS_REGION)${NC}"
        echo -e "${YELLOW}   💡 Consider setting region: aws configure set region $AWS_REGION${NC}"
    fi

    # Provide summary of detected credential sources
    if [ ${#cred_sources[@]} -eq 0 ]; then
        echo -e "${YELLOW}   ❓ Credential source unclear${NC}"
    else
        echo -e "${GREEN}   ✅ Credential sources detected: ${#cred_sources[@]}${NC}"
    fi
}

# Function to check cluster accessibility
# This function validates that the EKS cluster exists and is accessible via kubectl
# It handles both existing clusters and first-time deployment scenarios
check_cluster_access() {
    # Check if the EKS cluster exists and is accessible via AWS API
    if aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
        echo -e "${GREEN}✅ EKS cluster '$CLUSTER_NAME' is accessible${NC}"

        # Test kubectl connectivity to the cluster
        # This validates that the kubeconfig is properly configured
        if kubectl get nodes >/dev/null 2>&1; then
            echo -e "${GREEN}✅ kubectl can connect to cluster (EKS Auto Mode)${NC}"
            echo -e "${GREEN}💡 Auto Mode manages compute automatically - no nodes to count${NC}"
            return 0  # Success - cluster is accessible and kubectl works
        else
            # kubectl cannot connect - likely due to IP restrictions or kubeconfig issues
            echo -e "${YELLOW}⚠️  kubectl cannot connect to cluster${NC}"
            echo -e "${YELLOW}💡 Your IP may have changed. Run: $SCRIPT_DIR/cluster-security-manager.sh check-ip${NC}"
            return 1  # Failure - cluster exists but kubectl cannot connect
        fi
    else
        # Cluster does not exist - this is normal for first-time deployments
        echo -e "${BLUE}ℹ️  EKS cluster '$CLUSTER_NAME' not found${NC}"
        echo -e "${BLUE}💡 This is expected for first-time deployments${NC}"
        return 2  # Special return code for first-time deployment
    fi
}

# Function to check Terraform state
# This function validates the Terraform state file and infrastructure deployment status
# It provides detailed information about the current infrastructure state
check_terraform_state() {
    # Detect script location and set project root for path resolution
    # This ensures the script works regardless of the current working directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ "$SCRIPT_DIR" == */scripts ]]; then
        PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    else
        PROJECT_ROOT="$SCRIPT_DIR"
    fi

    # Check if Terraform state file exists
    if [ -f "$PROJECT_ROOT/terraform/terraform.tfstate" ]; then
        echo -e "${GREEN}✅ Terraform state file exists${NC}"

        # Validate Terraform state and check infrastructure deployment
        cd "$PROJECT_ROOT/terraform"
        if terraform show >/dev/null 2>&1; then
            # Count deployed resources to determine infrastructure status
            # Use jq to parse JSON output and count resources in the root module
            RESOURCES=$(terraform show -json | jq -r '.values.root_module.resources | length' 2>/dev/null || echo "0")
            if [ "$RESOURCES" -gt 0 ]; then
                echo -e "${GREEN}✅ Terraform infrastructure deployed ($RESOURCES resources)${NC}"
                cd "$SCRIPT_DIR"
                return 0  # Success - infrastructure is deployed
            else
                # State exists but no resources deployed - clean slate scenario
                echo -e "${BLUE}ℹ️  Terraform state exists but no resources deployed${NC}"
                echo -e "${BLUE}💡 This indicates a clean slate for deployment${NC}"
                cd "$SCRIPT_DIR"
                return 2  # Special return code for clean slate
            fi
        else
            # Terraform state file exists but cannot be read - potential corruption
            echo -e "${YELLOW}⚠️  Terraform state exists but may be corrupted${NC}"
            cd "$SCRIPT_DIR"
            return 1  # Failure - state file is corrupted
        fi
    else
        # No Terraform state file - first-time deployment scenario
        echo -e "${BLUE}ℹ️  Terraform state file not found${NC}"
        echo -e "${BLUE}💡 This is expected for first-time deployments${NC}"
        echo -e "${BLUE}📋 Next step: cd $PROJECT_ROOT/terraform && terraform init && terraform apply${NC}"
        return 2  # Special return code for first-time deployment
    fi
}

# Function to check required resources
# This function validates that all required AWS resources exist and are accessible
# It checks VPC, RDS Aurora cluster, ElastiCache Valkey cluster, and EFS file system
check_required_resources() {
    echo -e "${BLUE}Checking AWS resources...${NC}"

    local resources_found=0  # Counter for found resources
    local total_resources=4  # Total number of required resources to check

    # Check VPC (Virtual Private Cloud)
    # VPC provides network isolation and routing for the EKS cluster
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
    if [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "" ]; then
        echo -e "${GREEN}✅ VPC exists: $VPC_ID${NC}"
        ((resources_found++))
    else
        echo -e "${BLUE}ℹ️  VPC not found${NC}"
        echo -e "${BLUE}💡 This is expected for first-time deployments${NC}"
    fi

    # Check RDS Aurora cluster
    # Aurora provides the MySQL database backend for OpenEMR
    RDS_CLUSTER=$(aws rds describe-db-clusters --query "DBClusters[?contains(DBClusterIdentifier, '${CLUSTER_NAME}')].DBClusterIdentifier" --output text 2>/dev/null)
    if [ "$RDS_CLUSTER" != "" ]; then
        echo -e "${GREEN}✅ RDS Aurora cluster exists: $RDS_CLUSTER${NC}"
        ((resources_found++))
    else
        echo -e "${BLUE}ℹ️  RDS Aurora cluster not found${NC}"
        echo -e "${BLUE}💡 This is expected for first-time deployments${NC}"
    fi

    # Check ElastiCache Valkey cluster (Redis-compatible)
    # Valkey provides caching and session storage for OpenEMR
    REDIS_CLUSTER=$(aws elasticache describe-serverless-caches --query "ServerlessCaches[?contains(ServerlessCacheName, '${CLUSTER_NAME}')].ServerlessCacheName" --output text 2>/dev/null)
    if [ "$REDIS_CLUSTER" != "" ]; then
        echo -e "${GREEN}✅ ElastiCache Valkey cluster exists: $REDIS_CLUSTER${NC}"
        ((resources_found++))
    else
        echo -e "${BLUE}ℹ️  ElastiCache Valkey cluster not found${NC}"
        echo -e "${BLUE}💡 This is expected for first-time deployments${NC}"
    fi

    # Check EFS (Elastic File System)
    # EFS provides persistent storage for OpenEMR application data
    EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?contains(Name, '${CLUSTER_NAME}')].FileSystemId" --output text 2>/dev/null)
    if [ "$EFS_ID" != "" ]; then
        echo -e "${GREEN}✅ EFS file system exists: $EFS_ID${NC}"
        ((resources_found++))
    else
        echo -e "${BLUE}ℹ️  EFS file system not found${NC}"
        echo -e "${BLUE}💡 This is expected for first-time deployments${NC}"
    fi

    # Return appropriate status code based on resource availability
    if [ $resources_found -eq 0 ]; then
        return 2  # Special return code for first-time deployment
    elif [ $resources_found -eq $total_resources ]; then
        return 0  # All resources found - ready for deployment
    else
        return 1  # Some resources found, some missing - potential issue
    fi
}

# Function to check Kubernetes resources
# This function validates the Kubernetes namespace and OpenEMR deployment status
# It provides information about the current state of Kubernetes resources
check_k8s_resources() {
    echo -e "${BLUE}Checking Kubernetes resources...${NC}"

    local resources_found=0  # Counter for found resources
    local total_resources=2  # Total number of resources to check

    # Check if the OpenEMR namespace exists
    # Namespaces provide logical separation and resource isolation
    if kubectl get namespace $NAMESPACE >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Namespace '$NAMESPACE' exists${NC}"
        ((resources_found++))
    else
        echo -e "${YELLOW}⚠️  Namespace '$NAMESPACE' not found${NC}"
        echo -e "${YELLOW}💡 Will be created during deployment${NC}"
    fi

    # Check if OpenEMR deployment already exists
    # This helps determine if this is an update or fresh deployment
    if kubectl get deployment openemr -n $NAMESPACE >/dev/null 2>&1; then
        # Get the number of ready replicas to show current deployment status
        REPLICAS=$(kubectl get deployment openemr -n $NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        echo -e "${YELLOW}⚠️  OpenEMR deployment already exists ($REPLICAS ready replicas)${NC}"
        echo -e "${YELLOW}💡 Deployment will update existing resources${NC}"
        ((resources_found++))
    else
        echo -e "${GREEN}✅ OpenEMR not yet deployed (clean deployment)${NC}"
    fi

    # Display EKS Auto Mode information
    # EKS Auto Mode automatically manages compute resources without manual intervention
    echo -e "${GREEN}✅ EKS Auto Mode handles compute automatically${NC}"
    echo -e "${GREEN}💡 No Karpenter needed - Auto Mode manages all compute${NC}"

    # Return appropriate status code based on resource availability
    if [ $resources_found -eq 0 ]; then
        return 2  # Special return code for first-time deployment
    elif [ $resources_found -eq $total_resources ]; then
        return 0  # All resources found - ready for deployment
    else
        return 1  # Some resources found, some missing - potential issue
    fi
}

# Function to check security configuration
# This function validates the security configuration of the EKS cluster
# It checks endpoint access, encryption, and provides security recommendations
check_security_config() {
    echo -e "${BLUE}Checking security configuration...${NC}"

    # Check if cluster exists first - if not, show planned security features
    if ! aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
        echo -e "${BLUE}ℹ️  EKS cluster not found - security configuration will be applied during deployment${NC}"
        echo -e "${BLUE}📋 Planned deployment features:${NC}"
        echo -e "${BLUE}   • OpenEMR 7.0.5 with HTTPS-only access (port 443)${NC}"
        echo -e "${BLUE}   • EKS Auto Mode for managed EC2 compute${NC}"
        echo -e "${BLUE}   • Aurora Serverless V2 MySQL database${NC}"
        echo -e "${BLUE}   • Valkey Serverless cache (Redis-compatible)${NC}"
        echo -e "${BLUE}   • IP-restricted cluster endpoint access${NC}"
        echo -e "${BLUE}   • Private subnet deployment${NC}"
        echo -e "${BLUE}   • 6 dedicated KMS keys (EKS, EFS, RDS, ElastiCache, S3, CloudWatch)${NC}"
        echo -e "${BLUE}   • Network policies and Pod Security Standards${NC}"
        return 0
    fi

    # Check cluster endpoint access configuration
    # Public access allows kubectl from the internet (with IP restrictions)
    # Private access allows kubectl only from within the VPC
    PUBLIC_ACCESS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text 2>/dev/null)
    PRIVATE_ACCESS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text 2>/dev/null)

    # Validate public access configuration
    if [ "$PUBLIC_ACCESS" = "True" ]; then
        # Get the list of allowed CIDR blocks for public access
        ALLOWED_CIDRS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text 2>/dev/null)
        echo -e "${YELLOW}⚠️  Public access enabled for: $ALLOWED_CIDRS${NC}"
        echo -e "${YELLOW}💡 Consider disabling after deployment: $SCRIPT_DIR/cluster-security-manager.sh disable${NC}"
    else
        echo -e "${GREEN}✅ Public access disabled (secure)${NC}"
    fi

    # Validate private access configuration
    if [ "$PRIVATE_ACCESS" = "True" ]; then
        echo -e "${GREEN}✅ Private access enabled${NC}"
    else
        echo -e "${RED}❌ Private access disabled (not recommended)${NC}"
    fi

    # Check EKS secrets encryption configuration
    # Encryption at rest protects sensitive data stored in etcd
    ENCRYPTION_CONFIG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.encryptionConfig' --output text 2>/dev/null)
    if [ "$ENCRYPTION_CONFIG" != "None" ] && [ "$ENCRYPTION_CONFIG" != "" ]; then
        echo -e "${GREEN}✅ EKS secrets encryption enabled${NC}"
    else
        echo -e "${RED}❌ EKS secrets encryption not configured${NC}"
    fi

    return 0
}

# Function to provide deployment recommendations
# This function provides comprehensive recommendations for security, cost optimization,
# and monitoring based on the current deployment state and best practices
provide_recommendations() {
    echo -e "${BLUE}📋 Deployment Recommendations${NC}"
    echo -e "${BLUE}=============================${NC}"

    # Check for IP changes if cluster exists
    # This helps users understand if they need to update cluster access
    if aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
        # Get current public IP address
        CURRENT_IP=$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo "unknown")
        # Get the first allowed IP from the cluster configuration
        ALLOWED_IP=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.publicAccessCidrs[0]' --output text 2>/dev/null | cut -d'/' -f1)

        # Compare current IP with allowed IP to detect changes
        if [ "$CURRENT_IP" != "$ALLOWED_IP" ] && [ "$CURRENT_IP" != "unknown" ] && [ "$ALLOWED_IP" != "None" ] && [ "$ALLOWED_IP" != "" ]; then
            echo -e "${YELLOW}💡 Your IP has changed since cluster creation${NC}"
            echo -e "${YELLOW}   Current IP: $CURRENT_IP${NC}"
            echo -e "${YELLOW}   Allowed IP: $ALLOWED_IP${NC}"
            echo -e "${YELLOW}   Run: $SCRIPT_DIR/cluster-security-manager.sh enable${NC}"
            echo ""
        fi
    fi

    # Security best practices recommendations
    # These recommendations help maintain a secure deployment
    echo -e "${GREEN}🔒 Security Best Practices:${NC}"
    echo -e "   • HTTPS-only access (port 443) - HTTP traffic is refused"
    echo -e "   • Disable public access after deployment"
    echo -e "   • Use strong passwords for all services"
    echo -e "   • Enable AWS WAF for production"
    echo -e "   • Regularly update container images"
    echo -e "   • Monitor audit logs for compliance"
    echo ""

    # Cost optimization recommendations
    # These recommendations help control AWS costs
    echo -e "${GREEN}💰 Cost Optimization:${NC}"
    echo -e "   • Aurora Serverless V2 scales automatically"
    echo -e "   • EKS Auto Mode: EC2 costs + management fee for full automation"
    echo -e "   • Valkey Serverless provides cost-effective caching"
    echo -e "   • Monitor usage with CloudWatch dashboards"
    echo -e "   • Set up cost alerts and budgets"
    echo ""

    # Monitoring setup recommendations
    # These recommendations help with observability and troubleshooting
    echo -e "${GREEN}📊 Monitoring Setup:${NC}"
    echo -e "   • CloudWatch logging with Fluent Bit (included in OpenEMR deployment)"
    echo -e "   • Basic deployment: CloudWatch logs only"
    echo -e "   • Optional: Enhanced monitoring stack: cd $PROJECT_ROOT/monitoring && ./install-monitoring.sh"
    echo -e "   • Enhanced stack includes:"
    echo -e "     - Prometheus v81.4.2 (metrics & alerting)"
    echo -e "     - Grafana (dashboards with auto-discovery)"
    echo -e "     - Loki v6.51.0 (log aggregation)"
    echo -e "     - Tempo v1.61.3 (distributed tracing with S3 storage, microservice mode)"
    echo -e "     - Mimir v6.0.5 (long-term metrics storage)"
    echo -e "     - OTeBPF v0.3.0 (eBPF auto-instrumentation)"
    echo -e "     - AlertManager (Slack integration support)"
    echo -e "     - OpenEMR-specific monitoring (ServiceMonitor, PrometheusRule)"
    echo -e "   • Configure alerting for critical issues"
    echo -e "   • Regular backup testing"
    echo ""
}

# Main validation flow
# This function orchestrates the complete validation process and provides
# comprehensive feedback about deployment readiness
main() {
    local errors=0                    # Counter for validation errors
    local first_time_deployment=false # Flag to track first-time deployment scenario

    # Step 1: Validate required command-line tools
    echo -e "${BLUE}1. Checking prerequisites...${NC}"
    check_command "kubectl" || ((errors++))  # Kubernetes command-line tool
    check_command "aws" || ((errors++))      # AWS CLI tool
    check_command "helm" || ((errors++))     # Helm package manager
    check_command "jq" || echo -e "${YELLOW}⚠️  jq not installed (optional but recommended)${NC}"  # JSON processor (optional)
    echo ""

    # Step 2: Validate AWS credentials and authentication
    echo -e "${BLUE}2. Checking AWS credentials...${NC}"
    check_aws_credentials || ((errors++))
    echo ""

    # Step 3: Validate Terraform state and infrastructure
    echo -e "${BLUE}3. Checking Terraform state...${NC}"
    check_terraform_state
    local terraform_check_result=$?
    if [ "$terraform_check_result" -eq 2 ]; then
        first_time_deployment=true
        echo -e "${BLUE}💡 This is normal for first-time deployments${NC}"
    elif [ "$terraform_check_result" -eq 1 ]; then
        ((errors++))
    fi
    echo ""

    # Step 4: Validate EKS cluster access and connectivity
    echo -e "${BLUE}4. Checking cluster access...${NC}"
    check_cluster_access
    local cluster_access_check_result=$?
    if [ "$cluster_access_check_result" -eq 2 ]; then
        first_time_deployment=true
        echo -e "${BLUE}💡 This is normal for first-time deployments${NC}"
    elif [ "$cluster_access_check_result" -eq 1 ]; then
        ((errors++))
    fi
    echo ""

    # Step 5: Validate required AWS resources
    echo -e "${BLUE}5. Checking AWS resources...${NC}"
    check_required_resources
    local aws_resources_check_result=$?
    if [ "$aws_resources_check_result" -eq 2 ]; then
        first_time_deployment=true
        echo -e "${BLUE}💡 This is normal for first-time deployments${NC}"
    elif [ "$aws_resources_check_result" -eq 1 ]; then
        ((errors++))
    fi
    echo ""

    # Step 6: Validate Kubernetes resources and namespace
    echo -e "${BLUE}6. Checking Kubernetes resources...${NC}"
    check_k8s_resources
    local k8s_resources_check_result=$?
    if [ "$k8s_resources_check_result" -eq 2 ]; then
        first_time_deployment=true
        echo -e "${BLUE}💡 This is normal for first-time deployments${NC}"
    elif [ "$k8s_resources_check_result" -eq 1 ]; then
        ((errors++))
    fi
    echo ""

    # Step 7: Validate security configuration
    echo -e "${BLUE}7. Checking security configuration...${NC}"
    check_security_config
    echo ""

    # Provide summary and next steps based on validation results
    if [ "$first_time_deployment" = true ] && [ $errors -eq 0 ]; then
        # First-time deployment scenario - all validations passed
        echo -e "${GREEN}🎉 First-time deployment validation completed!${NC}"
        echo -e "${GREEN}✅ Prerequisites and AWS credentials are ready${NC}"
        echo -e "${BLUE}📋 You're all set for your first deployment!${NC}"
        echo ""
        echo -e "${BLUE}Next steps for first-time deployment:${NC}"
        echo -e "${BLUE}   1. cd $PROJECT_ROOT/terraform${NC}"
        echo -e "${BLUE}   2. terraform init${NC}"
        echo -e "${BLUE}   3. terraform plan${NC}"
        echo -e "${BLUE}   4. terraform apply${NC}"
        echo -e "${BLUE}   5. cd $PROJECT_ROOT/k8s${NC}"
        echo -e "${BLUE}   6. ./deploy.sh${NC}"
        echo ""
        echo -e "${YELLOW}⏱️  Expected deployment time: 40-45 minutes total (measured from E2E tests)${NC}"
        echo -e "${YELLOW}   • Infrastructure (Terraform): 30-32 minutes${NC}"
        echo -e "${YELLOW}   • Application (Kubernetes): 7-11 minutes (can spike to 19 min)${NC}"
        echo ""
    elif [ $errors -eq 0 ]; then
        # Existing deployment scenario - all validations passed
        echo -e "${GREEN}🎉 Validation completed successfully!${NC}"
        echo -e "${GREEN}✅ Ready to deploy OpenEMR${NC}"
        echo ""
        echo -e "${BLUE}Next steps:${NC}"
        echo -e "   1. cd $PROJECT_ROOT/k8s"
        echo -e "   2. ./deploy.sh"
        echo ""
    else
        # Validation failed - show error summary
        echo -e "${RED}❌ Validation failed with $errors error(s)${NC}"
        echo -e "${RED}Please fix the issues above before deploying${NC}"
        echo ""
    fi

    # Provide comprehensive recommendations for security, cost, and monitoring
    provide_recommendations

    # Return error count as exit code
    return $errors
}

# Run main function
main "$@"
