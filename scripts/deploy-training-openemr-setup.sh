#!/bin/bash

# =============================================================================
# OpenEMR Training Setup Deployment Script
# =============================================================================
#
# Purpose:
#   Deploys OpenEMR on EKS with Warp for training purposes. This script:
#   1. Stands up OpenEMR on EKS terraform infrastructure
#   2. Deploys OpenEMR on EKS
#   3. Installs Warp
#   4. Imports synthetic patient data from a specified S3 bucket
#   5. Prints out login address and credentials
#
# Usage:
#   ./scripts/deploy-training-openemr-setup.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME     EKS cluster name (default: auto-detect)
#   --aws-region REGION     AWS region (default: us-west-2)
#   --s3-bucket BUCKET      S3 bucket containing OMOP data (required unless --use-default-dataset)
#   --s3-prefix PREFIX      S3 prefix/path within bucket (default: empty)
#   --max-records COUNT     Number of records to import (default: 1000)
#   --use-default-dataset   Use the public SynPUF OMOP dataset (s3://synpuf-omop/cmsdesynpuf1k/)
#   --skip-terraform        Skip Terraform deployment (use existing infrastructure)
#   --skip-openemr          Skip OpenEMR deployment (use existing deployment)
#   --help                  Show this help message
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - Terraform >= 1.14.0
#   - kubectl >= 1.35.0
#   - jq, tar, gzip
#
# =============================================================================

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
readonly SCRIPT_DIR
readonly PROJECT_ROOT
readonly TERRAFORM_DIR

# Configuration defaults
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-west-2")}
CLUSTER_NAME=""
S3_BUCKET=""
S3_PREFIX=""
MAX_RECORDS="${MAX_RECORDS:-1000}"
SKIP_TERRAFORM=false
SKIP_OPENEMR=false
NAMESPACE="openemr"
USE_DEFAULT_DATASET=false

# Default public dataset (SynPUF OMOP)
DEFAULT_S3_BUCKET="synpuf-omop"
DEFAULT_S3_PREFIX="cmsdesynpuf1k"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
}

log_error() {
    echo -e "${RED}❌ $*${NC}" >&2
}

log_step() {
    echo -e "${CYAN}🔄 $*${NC}"
}

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

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing_tools=()
    
    for tool in terraform kubectl aws jq tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Verify AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi
    
    log_success "All prerequisites met"
}

get_cluster_name() {
    if [ -z "$CLUSTER_NAME" ]; then
        log_info "Auto-detecting cluster name from Terraform..."
        cd "$PROJECT_ROOT/terraform" || exit 1
        TERRAFORM_CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null | grep -v "Warning:" | grep -E "^[a-zA-Z0-9-]+$" | head -1 || true)
        cd - >/dev/null || exit 1
        
        if [ -n "$TERRAFORM_CLUSTER_NAME" ]; then
            CLUSTER_NAME="$TERRAFORM_CLUSTER_NAME"
        else
            CLUSTER_NAME="openemr-eks"
        fi
    fi
    log_info "Using cluster name: $CLUSTER_NAME"
}

validate_s3_bucket() {
    # If using default dataset, set bucket and prefix
    if [ "$USE_DEFAULT_DATASET" = true ]; then
        S3_BUCKET="$DEFAULT_S3_BUCKET"
        S3_PREFIX="$DEFAULT_S3_PREFIX"
        log_info "Using default public dataset: s3://$S3_BUCKET/$S3_PREFIX/"
        
        # Validate public bucket access (no credentials needed)
        log_step "Validating public S3 bucket access..."
        if ! aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" --no-sign-request >/dev/null 2>&1; then
            log_error "Cannot access public S3 bucket: s3://$S3_BUCKET/$S3_PREFIX/"
            log_error "This is unusual - the SynPUF dataset should be publicly accessible."
            exit 1
        fi
        log_success "Public S3 bucket validated: s3://$S3_BUCKET/$S3_PREFIX/"
        return 0
    fi
    
    if [ -z "$S3_BUCKET" ]; then
        log_error "S3 bucket is required. Use --s3-bucket to specify the bucket name."
        echo ""
        echo "Example:"
        echo "  $0 --s3-bucket my-training-data-bucket --max-records 500"
        echo ""
        echo "Or use the default public SynPUF dataset:"
        echo "  $0 --use-default-dataset --max-records 500"
        exit 1
    fi
    
    # Validate S3 bucket exists and is accessible
    log_step "Validating S3 bucket access..."
    if ! aws s3 ls "s3://$S3_BUCKET" >/dev/null 2>&1; then
        log_error "Cannot access S3 bucket: $S3_BUCKET"
        log_error "Please verify:"
        log_error "  1. Bucket name is correct"
        log_error "  2. AWS credentials have S3 read permissions"
        log_error "  3. Bucket exists in region: $AWS_REGION"
        exit 1
    fi
    
    log_success "S3 bucket validated: $S3_BUCKET"
}

build_data_source() {
    # Build the full S3 path
    if [ -n "$S3_PREFIX" ]; then
        # Remove leading/trailing slashes from prefix
        S3_PREFIX=$(echo "$S3_PREFIX" | sed 's|^/||;s|/$||')
        DATA_SOURCE="s3://$S3_BUCKET/$S3_PREFIX/"
    else
        DATA_SOURCE="s3://$S3_BUCKET/"
    fi
    
    log_info "Data source: $DATA_SOURCE"
}

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

deploy_terraform() {
    if [ "$SKIP_TERRAFORM" = true ]; then
        log_warning "Skipping Terraform deployment (using existing infrastructure)"
        return 0
    fi
    
    log_header "Step 1: Deploying Terraform Infrastructure"
    
    cd "$PROJECT_ROOT/terraform" || exit 1
    
    log_step "Initializing Terraform..."
    terraform init -upgrade -no-color
    
    log_step "Planning Terraform deployment..."
    terraform plan -out=tfplan -no-color
    
    log_step "Applying Terraform configuration..."
    log_info "This may take 30-45 minutes..."
    terraform apply tfplan -no-color
    
    log_success "Terraform infrastructure deployed successfully"
    cd - >/dev/null || exit 1
}

deploy_openemr() {
    if [ "$SKIP_OPENEMR" = true ]; then
        log_warning "Skipping OpenEMR deployment (using existing deployment)"
        return 0
    fi
    
    log_header "Step 2: Deploying OpenEMR on EKS"
    
    cd "$PROJECT_ROOT/k8s" || exit 1
    
    log_step "Running OpenEMR deployment script..."
    log_info "This may take 7-11 minutes for OpenEMR to initialize..."
    ./deploy.sh --cluster-name "$CLUSTER_NAME" --aws-region "$AWS_REGION" --namespace "$NAMESPACE"
    
    log_success "OpenEMR deployed successfully"
    cd - >/dev/null || exit 1
}

install_warp() {
    log_header "Step 3: Installing Warp"
    
    # Ensure kubectl is configured
    log_step "Configuring kubectl..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
    
    # Package Warp code
    log_step "Packaging Warp code..."
    cd "$PROJECT_ROOT/warp" || exit 1
    
    TEMP_TAR=$(mktemp)
    tar czf "$TEMP_TAR" warp/ setup.py requirements.txt README.md
    
    # Create ConfigMap
    log_step "Creating Warp ConfigMap..."
    kubectl create configmap warp-code \
        --from-file=warp-code.tar.gz="$TEMP_TAR" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    
    rm -f "$TEMP_TAR"
    
    log_success "Warp installed successfully"
    cd - >/dev/null || exit 1
}

import_data() {
    log_header "Step 4: Importing $MAX_RECORDS Records with Warp"
    
    # Create temporary job YAML
    TEMP_JOB=$(mktemp)
    cat > "$TEMP_JOB" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: warp-training-import
  namespace: $NAMESPACE
  labels:
    app: warp
    purpose: training
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: warp
        purpose: training
    spec:
      serviceAccountName: openemr-sa
      restartPolicy: Never
      containers:
      - name: warp
        image: python:3.14-slim
        workingDir: /app
        env:
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: openemr-db-credentials
              key: mysql-host
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: openemr-db-credentials
              key: mysql-user
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: openemr-db-credentials
              key: mysql-password
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: openemr-db-credentials
              key: mysql-database
        - name: DATA_SOURCE
          value: "$DATA_SOURCE"
        - name: AWS_REGION
          value: "$AWS_REGION"
        - name: BATCH_SIZE
          value: "100"
        - name: WORKERS
          value: "1"
        - name: MAX_RECORDS
          value: "$MAX_RECORDS"
        command: ["/bin/bash"]
        args:
        - -c
        - |
          set -e
          echo "=========================================="
          echo "Warp Training Data Import"
          echo "=========================================="
          echo "Start time: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          START_TIME=\$(date +%s)
          
          echo "Installing system dependencies..."
          apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
          
          echo "Extracting warp code from ConfigMap..."
          cd /app
          tar xzf /warp-code/warp-code.tar.gz
          
          echo "Installing Python dependencies from requirements.txt..."
          pip install --no-cache-dir -r requirements.txt
          
          echo "Installing warp..."
          cd /app
          pip install --no-cache-dir -e .
          
          echo "Running warp import..."
          warp ccda_data_upload \\
            --db-host "\$DB_HOST" \\
            --db-user "\$DB_USER" \\
            --db-password "\$DB_PASSWORD" \\
            --db-name "\$DB_NAME" \\
            --data-source "\$DATA_SOURCE" \\
            --batch-size "\$BATCH_SIZE" \\
            --workers "\$WORKERS" \\
            --max-records "\$MAX_RECORDS" \\
            --aws-region "\$AWS_REGION"
          
          END_TIME=\$(date +%s)
          DURATION=\$((END_TIME - START_TIME))
          echo "=========================================="
          echo "Import Complete"
          echo "End time: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          echo "Total duration: \${DURATION} seconds (\$(awk "BEGIN {printf \"%.2f\", \$DURATION / 60}") minutes)"
          echo "=========================================="
        resources:
          requests:
            memory: "2Gi"
            cpu: "1"
          limits:
            memory: "4Gi"
            cpu: "2"
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: warp-code
          mountPath: /warp-code
          readOnly: true
      volumes:
      - name: tmp
        emptyDir: {}
      - name: warp-code
        configMap:
          name: warp-code
EOF
    
    log_step "Creating Warp import job..."
    kubectl apply -f "$TEMP_JOB" >/dev/null
    rm -f "$TEMP_JOB"
    
    log_step "Waiting for job to complete..."
    log_info "This may take several minutes depending on dataset size..."
    
    # Wait for job to complete
    if kubectl wait --for=condition=complete --timeout=1800s job/warp-training-import -n "$NAMESPACE" >/dev/null 2>&1; then
        log_success "Data import completed successfully"
        
        # Show job logs
        log_step "Import job logs:"
        kubectl logs -n "$NAMESPACE" job/warp-training-import --tail=50
    else
        log_error "Job failed or timed out"
        log_info "Job status:"
        kubectl get job -n "$NAMESPACE" warp-training-import
        log_info "Job logs:"
        kubectl logs -n "$NAMESPACE" job/warp-training-import --tail=100 || true
        exit 1
    fi
}

print_credentials() {
    log_header "Step 5: Training Setup Complete"
    
    # Get LoadBalancer URL
    LB_URL=$(kubectl get svc openemr-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    # Get credentials from secret or credentials file
    ADMIN_USER="admin"
    ADMIN_PASSWORD=""
    
    # Try to get from credentials file first
    if [ -f "$PROJECT_ROOT/k8s/openemr-credentials.txt" ]; then
        ADMIN_PASSWORD=$(grep "Admin Password:" "$PROJECT_ROOT/k8s/openemr-credentials.txt" | awk '{print $3}' || echo "")
    fi
    
    # Fallback to secret if file doesn't exist
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(kubectl get secret openemr-app-credentials -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🎉 OpenEMR Training Setup Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}OpenEMR Access Information:${NC}"
    echo ""
    
    if [ -n "$LB_URL" ]; then
        echo -e "  ${BLUE}Login URL:${NC}     https://$LB_URL"
    else
        echo -e "  ${YELLOW}Login URL:${NC}     LoadBalancer URL not yet available"
        echo -e "  ${YELLOW}              Run: kubectl get svc openemr-service -n $NAMESPACE${NC}"
    fi
    
    echo ""
    echo -e "  ${BLUE}Username:${NC}       $ADMIN_USER"
    
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo -e "  ${BLUE}Password:${NC}       $ADMIN_PASSWORD"
    else
        echo -e "  ${YELLOW}Password:${NC}       Unable to retrieve password"
        echo -e "  ${YELLOW}              Check: kubectl get secret openemr-app-credentials -n $NAMESPACE${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}Training Setup Summary:${NC}"
    echo ""
    echo -e "  ${BLUE}Records Imported:${NC} $MAX_RECORDS"
    echo -e "  ${BLUE}Data Source:${NC}     $DATA_SOURCE"
    echo -e "  ${BLUE}S3 Bucket:${NC}       $S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        echo -e "  ${BLUE}S3 Prefix:${NC}      $S3_PREFIX"
    fi
    echo -e "  ${BLUE}Cluster Name:${NC}    $CLUSTER_NAME"
    echo -e "  ${BLUE}AWS Region:${NC}      $AWS_REGION"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo ""
    echo "  1. Access OpenEMR at the URL above"
    echo "  2. Login with the credentials provided"
    echo "  3. Navigate to Finder → Patient Finder to verify imported patients"
    echo "  4. Explore OpenEMR features with the synthetic patient data"
    echo "  5. Use this setup for training and familiarization"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_help() {
    cat <<EOF
OpenEMR Training Setup Deployment Script

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    Deploys OpenEMR on EKS with Warp for training purposes. This script:
    1. Stands up OpenEMR on EKS terraform infrastructure
    2. Deploys OpenEMR on EKS
    3. Installs Warp
    4. Imports synthetic patient data from a specified S3 bucket
    5. Prints out login address and credentials

OPTIONS:
    --cluster-name NAME     EKS cluster name (default: auto-detect from Terraform)
    --aws-region REGION     AWS region (default: us-west-2)
    --s3-bucket BUCKET      S3 bucket containing OMOP data (required unless --use-default-dataset)
    --s3-prefix PREFIX      S3 prefix/path within bucket (default: empty)
    --max-records COUNT     Number of records to import (default: 1000)
    --use-default-dataset   Use the public SynPUF OMOP dataset (s3://synpuf-omop/cmsdesynpuf1k/)
    --skip-terraform        Skip Terraform deployment (use existing infrastructure)
    --skip-openemr          Skip OpenEMR deployment (use existing deployment)
    --help                  Show this help message

ENVIRONMENT VARIABLES:
    AWS_REGION              AWS region
    CLUSTER_NAME            EKS cluster name
    MAX_RECORDS             Number of records to import

EXAMPLES:
    # Deploy with default public SynPUF dataset (recommended for testing)
    $0 --use-default-dataset --max-records 100

    # Deploy with 1000 records from S3 bucket
    $0 --s3-bucket my-training-data-bucket

    # Deploy with 500 records from a specific S3 prefix
    $0 --s3-bucket my-training-data-bucket --s3-prefix omop-data/ --max-records 500

    # Use existing infrastructure with default dataset
    $0 --use-default-dataset --skip-terraform --skip-openemr --max-records 50

PREREQUISITES:
    - AWS CLI configured with appropriate permissions
    - Terraform >= 1.14.0
    - kubectl >= 1.35.0
    - jq >= 1.6
    - tar, gzip

EOF
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
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
            --s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            --s3-prefix)
                S3_PREFIX="$2"
                shift 2
                ;;
            --max-records)
                MAX_RECORDS="$2"
                shift 2
                ;;
            --skip-terraform)
                SKIP_TERRAFORM=true
                shift
                ;;
            --skip-openemr)
                SKIP_OPENEMR=true
                shift
                ;;
            --use-default-dataset)
                USE_DEFAULT_DATASET=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Detect AWS region from Terraform state if not explicitly set via --aws-region
    get_aws_region
    
    log_header "OpenEMR Training Setup Deployment"
    
    log_info "Configuration:"
    log_info "  Project root: $PROJECT_ROOT"
    log_info "  AWS Region: $AWS_REGION"
    log_info "  Max Records: $MAX_RECORDS"
    log_info "  Use Default Dataset: $USE_DEFAULT_DATASET"
    log_info "  Skip Terraform: $SKIP_TERRAFORM"
    log_info "  Skip OpenEMR: $SKIP_OPENEMR"
    
    # Check prerequisites
    check_prerequisites
    
    # Validate S3 bucket (required)
    validate_s3_bucket
    
    # Build data source path
    build_data_source
    
    # Get cluster name
    get_cluster_name
    
    # Deploy infrastructure
    deploy_terraform
    
    # Deploy OpenEMR
    deploy_openemr
    
    # Install Warp
    install_warp
    
    # Import data
    import_data
    
    # Print credentials
    print_credentials
    
    log_success "Training setup deployment completed successfully!"
}

# Run main function
main "$@"

