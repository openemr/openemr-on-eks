#!/bin/bash

# OpenEMR Backup Script
# Simple, reliable, comprehensive backup for OpenEMR data protection

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}
AWS_REGION=${AWS_REGION:-"us-west-2"}
BACKUP_REGION=${BACKUP_REGION:-"$AWS_REGION"}
NAMESPACE=${NAMESPACE:-"openemr"}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_ID="openemr-backup-${TIMESTAMP}"

# Polling configuration (in seconds)
CLUSTER_AVAILABILITY_TIMEOUT=${CLUSTER_AVAILABILITY_TIMEOUT:-1800}  # 30 minutes default
SNAPSHOT_AVAILABILITY_TIMEOUT=${SNAPSHOT_AVAILABILITY_TIMEOUT:-1800}  # 30 minutes default
POLLING_INTERVAL=${POLLING_INTERVAL:-30}  # 30 seconds default

# Help function
show_help() {
    echo "OpenEMR Backup Script"
    echo "====================="
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --cluster-name NAME     EKS cluster name (default: openemr-eks)"
    echo "  --source-region REGION  Source AWS region (default: us-west-2)"
    echo "  --backup-region REGION  Backup AWS region (default: same as source)"
    echo "  --namespace NAMESPACE   Kubernetes namespace (default: openemr)"
    echo "  --help                  Show this help message"
    echo ""
    echo "Environment Variables for Timeouts:"
    echo "  CLUSTER_AVAILABILITY_TIMEOUT  Timeout for RDS cluster availability (default: 1800s = 30m)"
    echo "  SNAPSHOT_AVAILABILITY_TIMEOUT Timeout for RDS snapshot availability (default: 1800s = 30m)"
    echo "  POLLING_INTERVAL              Polling interval in seconds (default: 30s)"
    echo ""
    echo "What Gets Backed Up:"
    echo "  ✅ RDS Aurora cluster snapshots"
    echo "  ✅ Kubernetes configurations and secrets"
    echo "  ✅ Application data from EFS volumes"
    echo "  ✅ Backup metadata and restore instructions"
    echo ""
    echo "Example:"
    echo "  $0 --backup-region us-east-1"
    echo ""
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --source-region)
            AWS_REGION="$2"
            shift 2
            ;;
        --backup-region)
            BACKUP_REGION="$2"
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
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

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
    exit 1
}

# Polling functions
wait_for_cluster_availability() {
    local cluster_id=$1
    local region=$2
    local timeout=$3
    local start_time
    start_time=$(date +%s)
    local elapsed=0

    log_info "Waiting for RDS cluster '$cluster_id' to be available in $region..."

    while [ $elapsed -lt "$timeout" ]; do
        local status
        status=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$cluster_id" \
            --region "$region" \
            --query 'DBClusters[0].Status' \
            --output text 2>/dev/null || echo "unknown")

        if [ "$status" = "available" ]; then
            log_success "RDS cluster '$cluster_id' is now available"
            return 0
        fi

        elapsed=$(($(date +%s) - start_time))
        local remaining=$((timeout - elapsed))

        if [ $elapsed -ge "$timeout" ]; then
            log_warning "Timeout waiting for cluster availability after ${timeout}s"
            return 1
        fi

        log_info "Cluster status: $status (${remaining}s remaining)"
        sleep "$POLLING_INTERVAL"
    done

    return 1
}

wait_for_snapshot_availability() {
    local snapshot_id=$1
    local region=$2
    local timeout=$3
    local start_time
    start_time=$(date +%s)
    local elapsed=0

    log_info "Waiting for RDS snapshot '$snapshot_id' to be available in $region..."

    while [ $elapsed -lt "$timeout" ]; do
        local status
        status=$(aws rds describe-db-cluster-snapshots \
            --db-cluster-snapshot-identifier "$snapshot_id" \
            --region "$region" \
            --query 'DBClusterSnapshots[0].Status' \
            --output text 2>/dev/null || echo "unknown")

        if [ "$status" = "available" ]; then
            log_success "RDS snapshot '$snapshot_id' is now available"
            return 0
        fi

        elapsed=$(($(date +%s) - start_time))
        local remaining=$((timeout - elapsed))

        if [ $elapsed -ge "$timeout" ]; then
            log_warning "Timeout waiting for snapshot availability after ${timeout}s"
            return 1
        fi

        log_info "Snapshot status: $status (${remaining}s remaining)"
        sleep "$POLLING_INTERVAL"
    done

    return 1
}

# Initialize backup
echo -e "${GREEN}🚀 OpenEMR Backup Starting${NC}"
echo -e "${BLUE}=========================${NC}"
echo -e "${BLUE}Backup ID: ${BACKUP_ID}${NC}"
echo -e "${BLUE}Source Region: ${AWS_REGION}${NC}"
echo -e "${BLUE}Backup Region: ${BACKUP_REGION}${NC}"
echo -e "${BLUE}Cluster: ${CLUSTER_NAME}${NC}"
echo ""

# Check dependencies
check_dependencies() {
    local missing_deps=()

    # Check AWS CLI
    if ! command -v aws >/dev/null 2>&1; then
        missing_deps+=("aws")
    fi

    # Check kubectl
    if ! command -v kubectl >/dev/null 2>&1; then
        missing_deps+=("kubectl")
    fi

    # Check tar
    if ! command -v tar >/dev/null 2>&1; then
        missing_deps+=("tar")
    fi

    # Check gzip
    if ! command -v gzip >/dev/null 2>&1; then
        missing_deps+=("gzip")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install: ${missing_deps[*]}"
        exit 1
    fi
}

# Check prerequisites
log_info "Checking prerequisites..."

# Check dependencies
check_dependencies

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS credentials not configured"
    exit 1
fi

# Check regions
for region in "$AWS_REGION" "$BACKUP_REGION"; do
    if ! aws ec2 describe-regions --region-names "$region" >/dev/null 2>&1; then
        log_error "Cannot access region: $region"
        exit 1
    fi
done

log_success "Prerequisites verified"

# Create backup bucket
BACKUP_BUCKET="openemr-backups-$(aws sts get-caller-identity --query Account --output text)-${CLUSTER_NAME}-$(date +%Y%m%d)"

log_info "Creating backup bucket: s3://${BACKUP_BUCKET}"

if ! aws s3 ls "s3://${BACKUP_BUCKET}" --region "$BACKUP_REGION" >/dev/null 2>&1; then
    aws s3 mb "s3://${BACKUP_BUCKET}" --region "$BACKUP_REGION"

    # Enable versioning and encryption
    aws s3api put-bucket-versioning \
        --bucket "$BACKUP_BUCKET" \
        --region "$BACKUP_REGION" \
        --versioning-configuration Status=Enabled

    aws s3api put-bucket-encryption \
        --bucket "$BACKUP_BUCKET" \
        --region "$BACKUP_REGION" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'

    log_success "Backup bucket created and configured"
else
    log_info "Backup bucket already exists"
fi

# Initialize backup results
BACKUP_RESULTS=""
BACKUP_SUCCESS=true

# Function to add result
add_result() {
    local component=$1
    local status=$2
    local details=$3

    BACKUP_RESULTS="${BACKUP_RESULTS}${component}: ${status}"
    if [ -n "$details" ]; then
        BACKUP_RESULTS="${BACKUP_RESULTS} (${details})"
    fi
    BACKUP_RESULTS="${BACKUP_RESULTS}\n"

    if [ "$status" = "FAILED" ]; then
        BACKUP_SUCCESS=false
    fi
}

# Backup RDS Aurora cluster
log_info "🗄️  Backing up RDS Aurora cluster..."

# Get cluster ID from Terraform or discover
AURORA_CLUSTER_ID=""
if [ -f "terraform/terraform.tfstate" ]; then
    AURORA_CLUSTER_ID=$(cd terraform && terraform output -raw aurora_cluster_id 2>/dev/null | grep -E '^[a-zA-Z0-9-]+$' | head -1 || echo "")
fi

if [ -z "$AURORA_CLUSTER_ID" ]; then
    # Try to discover cluster
    AURORA_CLUSTER_ID=$(aws rds describe-db-clusters \
        --region "$AWS_REGION" \
        --query "DBClusters[?contains(DBClusterIdentifier, '${CLUSTER_NAME}')].DBClusterIdentifier" \
        --output text 2>/dev/null | head -1)
fi

if [ -n "$AURORA_CLUSTER_ID" ] && [ "$AURORA_CLUSTER_ID" != "None" ]; then
    log_info "Found Aurora cluster: ${AURORA_CLUSTER_ID}"

    # Wait for cluster to be available before creating snapshot
    if wait_for_cluster_availability "$AURORA_CLUSTER_ID" "$AWS_REGION" "$CLUSTER_AVAILABILITY_TIMEOUT"; then
        # Create snapshot
        SNAPSHOT_ID="${AURORA_CLUSTER_ID}-backup-${TIMESTAMP}"
        log_info "Creating snapshot: ${SNAPSHOT_ID}"

        if aws rds create-db-cluster-snapshot \
            --region "$AWS_REGION" \
            --db-cluster-identifier "$AURORA_CLUSTER_ID" \
            --db-cluster-snapshot-identifier "$SNAPSHOT_ID" >/dev/null 2>&1; then

            log_success "Aurora snapshot created: ${SNAPSHOT_ID}"

            # If backup region is different from source region, copy the snapshot
            if [ "$BACKUP_REGION" != "$AWS_REGION" ]; then
                log_info "Cross-region backup detected - copying snapshot to ${BACKUP_REGION}"

                # Generate backup region snapshot name
                BACKUP_SNAPSHOT_ID="${SNAPSHOT_ID}-${BACKUP_REGION}"

                # Check if snapshot is encrypted and get KMS key for backup region
                KMS_KEY_PARAM=""
                if aws rds describe-db-cluster-snapshots \
                    --region "$AWS_REGION" \
                    --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
                    --query 'DBClusterSnapshots[0].StorageEncrypted' \
                    --output text 2>/dev/null | grep -q "True"; then

                    log_info "RDS cluster is encrypted - using default KMS key in backup region"
                    # Use the default AWS RDS KMS key in the backup region
                    DEFAULT_KMS_KEY=$(aws kms list-aliases \
                        --region "$BACKUP_REGION" \
                        --query "Aliases[?AliasName==\`alias/aws/rds\`].TargetKeyId" \
                        --output text 2>/dev/null || echo "")

                    if [ -n "$DEFAULT_KMS_KEY" ]; then
                        KMS_KEY_PARAM="--kms-key-id $DEFAULT_KMS_KEY"
                        log_info "Using KMS key: $DEFAULT_KMS_KEY"
                    else
                        log_warning "No default KMS key found in backup region - copy may fail"
                    fi
                fi

                # Wait for snapshot to be available before copying
                log_info "Waiting for source snapshot to be available before copying..."
                if wait_for_snapshot_availability "$SNAPSHOT_ID" "$AWS_REGION" "$SNAPSHOT_AVAILABILITY_TIMEOUT"; then
                    # Copy snapshot to backup region
                    if aws rds copy-db-cluster-snapshot \
                        --source-db-cluster-snapshot-identifier "arn:aws:rds:${AWS_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):cluster-snapshot:${SNAPSHOT_ID}" \
                        --target-db-cluster-snapshot-identifier "${BACKUP_SNAPSHOT_ID}" \
                        --source-region "${AWS_REGION}" \
                        --region "${BACKUP_REGION}" \
                        "$KMS_KEY_PARAM"; then

                        log_success "Snapshot copy initiated: ${BACKUP_SNAPSHOT_ID}"

                        # Wait for copy to complete using polling function
                        log_info "Waiting for snapshot copy to complete..."
                        if wait_for_snapshot_availability "$BACKUP_SNAPSHOT_ID" "$BACKUP_REGION" "$SNAPSHOT_AVAILABILITY_TIMEOUT"; then
                            log_success "Snapshot copy completed successfully"
                            SNAPSHOT_ID="$BACKUP_SNAPSHOT_ID"  # Use the copied snapshot ID
                            add_result "Aurora RDS" "SUCCESS" "$SNAPSHOT_ID (cross-region copy completed)"
                        else
                            log_warning "Snapshot copy did not complete within timeout"
                            add_result "Aurora RDS" "WARNING" "$SNAPSHOT_ID (copy timeout)"
                        fi
                    else
                        log_warning "Failed to initiate snapshot copy to backup region"
                        log_info "Snapshot exists in source region but copy to backup region failed"
                        log_info "Manual copy command:"
                        echo ""
                        echo "aws rds copy-db-cluster-snapshot \\"
                        echo "    --source-db-cluster-snapshot-identifier arn:aws:rds:${AWS_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):cluster-snapshot:${SNAPSHOT_ID} \\"
                        echo "    --target-db-cluster-snapshot-identifier ${SNAPSHOT_ID}-${BACKUP_REGION} \\"
                        echo "    --source-region ${AWS_REGION} \\"
                        echo "    --region ${BACKUP_REGION}"
                        if [ -n "$KMS_KEY_PARAM" ]; then
                            echo "    --kms-key-id $DEFAULT_KMS_KEY"
                        fi
                        echo ""
                        add_result "Aurora RDS" "WARNING" "$SNAPSHOT_ID (copy failed)"
                    fi
                else
                    log_warning "Source snapshot did not become available within timeout"
                    add_result "Aurora RDS" "WARNING" "$SNAPSHOT_ID (source snapshot timeout)"
                fi
            else
                add_result "Aurora RDS" "SUCCESS" "$SNAPSHOT_ID"
            fi
        else
            log_warning "Failed to create Aurora snapshot"
            add_result "Aurora RDS" "FAILED" "Snapshot creation failed"
        fi
    else
        log_warning "Aurora cluster not available (status: ${CLUSTER_STATUS})"
        add_result "Aurora RDS" "SKIPPED" "Cluster not available"
    fi
else
    log_warning "No Aurora cluster found"
    add_result "Aurora RDS" "SKIPPED" "No cluster found"
fi

# Backup Kubernetes configurations
log_info "⚙️  Backing up Kubernetes configurations..."

if kubectl cluster-info >/dev/null 2>&1; then
    log_info "Kubernetes cluster accessible"

    # Create backup directory
    K8S_BACKUP_DIR="k8s-backup-${TIMESTAMP}"
    mkdir -p "$K8S_BACKUP_DIR"

    # Export all resources
    kubectl get all -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/all-resources.yaml" 2>/dev/null || true
    kubectl get secrets -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/secrets.yaml" 2>/dev/null || true
    kubectl get configmaps -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/configmaps.yaml" 2>/dev/null || true
    kubectl get pvc -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/pvc.yaml" 2>/dev/null || true
    kubectl get ingress -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/ingress.yaml" 2>/dev/null || true
    kubectl get hpa -n "$NAMESPACE" -o yaml > "$K8S_BACKUP_DIR/hpa.yaml" 2>/dev/null || true
    kubectl get storageclass -o yaml > "$K8S_BACKUP_DIR/storage.yaml" 2>/dev/null || true

    # Create archive
    tar -czf "${K8S_BACKUP_DIR}.tar.gz" "$K8S_BACKUP_DIR"

    # Upload to S3
    if aws s3 cp "${K8S_BACKUP_DIR}.tar.gz" "s3://${BACKUP_BUCKET}/kubernetes/" --region "$BACKUP_REGION"; then
        log_success "Kubernetes configurations backed up"
        add_result "Kubernetes Config" "SUCCESS" "${K8S_BACKUP_DIR}.tar.gz"
    else
        log_warning "Failed to upload Kubernetes backup"
        add_result "Kubernetes Config" "FAILED" "Upload failed"
    fi

    # Cleanup
    rm -rf "$K8S_BACKUP_DIR" "${K8S_BACKUP_DIR}.tar.gz"
else
    log_warning "Kubernetes cluster not accessible"
    add_result "Kubernetes Config" "SKIPPED" "Cluster not accessible"
fi

# Backup application data
log_info "📦 Backing up application data..."

if kubectl cluster-info >/dev/null 2>&1; then
    # Find OpenEMR pods
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=openemr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$POD_NAME" ]; then
        log_info "Found OpenEMR pod: ${POD_NAME}"

        # Create application data backup
        APP_BACKUP_FILE="app-data-backup-${TIMESTAMP}.tar.gz"

        # First, check if the sites directory exists
        if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c "test -d /var/www/localhost/htdocs/openemr/sites" 2>/dev/null; then
            log_info "Sites directory exists, creating backup..."

            # Check if tar is available
            if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c "which tar" 2>/dev/null; then
                log_info "Tar utility available, creating archive..."

                if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c "tar -czf /tmp/${APP_BACKUP_FILE} -C /var/www/localhost/htdocs/openemr sites/" 2>/dev/null; then
            # Copy from pod
            kubectl cp "${NAMESPACE}/${POD_NAME}:/tmp/${APP_BACKUP_FILE}" "./${APP_BACKUP_FILE}" 2>/dev/null

            # Upload to S3
            if aws s3 cp "${APP_BACKUP_FILE}" "s3://${BACKUP_BUCKET}/application-data/" --region "$BACKUP_REGION"; then
                log_success "Application data backed up"
                add_result "Application Data" "SUCCESS" "$APP_BACKUP_FILE"
            else
                log_warning "Failed to upload application data"
                add_result "Application Data" "FAILED" "Upload failed"
            fi

            # Cleanup
            rm -f "${APP_BACKUP_FILE}"
            kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c "rm -f /tmp/${APP_BACKUP_FILE}" 2>/dev/null || true
        else
            log_warning "Failed to create tar archive"
            add_result "Application Data" "FAILED" "Tar archive creation failed"
        fi
            else
                log_warning "Tar utility not available in container"
                add_result "Application Data" "FAILED" "Tar utility not found"
            fi
        else
            log_warning "Sites directory not found in container"
            add_result "Application Data" "FAILED" "Sites directory not found"
        fi
    else
        log_warning "No OpenEMR pods found"
        add_result "Application Data" "SKIPPED" "No pods found"
    fi
else
    log_warning "Kubernetes cluster not accessible"
    add_result "Application Data" "SKIPPED" "Cluster not accessible"
fi

# Create backup metadata
log_info "📋 Creating backup metadata..."

# Get database configuration details for automatic restore
DB_CONFIG="{}"
if [ -n "$AURORA_CLUSTER_ID" ]; then
    log_info "Capturing database configuration for automatic restore..."

    # Get cluster details
    CLUSTER_DETAILS=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$AURORA_CLUSTER_ID" \
        --region "$AWS_REGION" \
        --query 'DBClusters[0].{EngineMode:EngineMode,ServerlessV2ScalingConfiguration:ServerlessV2ScalingConfiguration,DBSubnetGroup:DBSubnetGroup,VpcSecurityGroups:VpcSecurityGroups}' \
        --output json 2>/dev/null || echo "{}")

    # Get instance details
    INSTANCE_DETAILS=$(aws rds describe-db-instances \
        --region "$AWS_REGION" \
        --filters "Name=db-cluster-id,Values=$AURORA_CLUSTER_ID" \
        --query 'DBInstances[0].{DBInstanceClass:DBInstanceClass,Engine:Engine}' \
        --output json 2>/dev/null || echo "{}")

    # Get VPC and subnet information
    SUBNET_GROUP_NAME=$(echo "$CLUSTER_DETAILS" | jq -r '.DBSubnetGroup' 2>/dev/null || echo "")

    VPC_ID=""
    VPC_CIDR=""
    if [ -n "$SUBNET_GROUP_NAME" ]; then
        VPC_ID=$(aws rds describe-db-subnet-groups \
            --db-subnet-group-name "$SUBNET_GROUP_NAME" \
            --region "$AWS_REGION" \
            --query 'DBSubnetGroups[0].VpcId' \
            --output text 2>/dev/null || echo "")

        if [ -n "$VPC_ID" ]; then
            VPC_CIDR=$(aws ec2 describe-vpcs \
                --vpc-ids "$VPC_ID" \
                --region "$AWS_REGION" \
                --query 'Vpcs[0].CidrBlock' \
                --output text 2>/dev/null || echo "")
        fi
    fi

    # Get security group rules
    SECURITY_GROUP_ID=$(echo "$CLUSTER_DETAILS" | jq -r '.VpcSecurityGroups[0].VpcSecurityGroupId' 2>/dev/null || echo "")
    SECURITY_GROUP_RULES="[]"
    if [ -n "$SECURITY_GROUP_ID" ]; then
        SECURITY_GROUP_RULES=$(aws ec2 describe-security-groups \
            --group-ids "$SECURITY_GROUP_ID" \
            --region "$AWS_REGION" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json 2>/dev/null || echo "[]")
    fi

    # Combine all database configuration
    DB_CONFIG=$(jq -n \
        --arg vpc_id "$VPC_ID" \
        --arg vpc_cidr "$VPC_CIDR" \
        --arg subnet_group_name "$SUBNET_GROUP_NAME" \
        --arg security_group_id "$SECURITY_GROUP_ID" \
        --argjson cluster_config "$CLUSTER_DETAILS" \
        --argjson instance_config "$INSTANCE_DETAILS" \
        --argjson security_group_rules "$SECURITY_GROUP_RULES" \
        '{
            cluster_config: $cluster_config,
            instance_config: $instance_config,
            vpc_id: $vpc_id,
            vpc_cidr: $vpc_cidr,
            subnet_group_name: $subnet_group_name,
            security_group_id: $security_group_id,
            security_group_rules: $security_group_rules
        }' 2>/dev/null || echo "{}")
fi

METADATA_FILE="backup-metadata-${TIMESTAMP}.json"
cat > "$METADATA_FILE" << EOF
{
    "backup_id": "${BACKUP_ID}",
    "timestamp": "${TIMESTAMP}",
    "source_region": "${AWS_REGION}",
    "backup_region": "${BACKUP_REGION}",
    "cluster_name": "${CLUSTER_NAME}",
    "namespace": "${NAMESPACE}",
    "backup_bucket": "${BACKUP_BUCKET}",
    "aurora_cluster_id": "${AURORA_CLUSTER_ID:-"none"}",
    "aurora_snapshot_id": "${SNAPSHOT_ID:-"none"}",
    "backup_success": ${BACKUP_SUCCESS},
    "components": {
        "aurora_rds": $([ -n "$SNAPSHOT_ID" ] && echo "true" || echo "false"),
        "kubernetes_config": true,
        "application_data": true
    },
    "database_config": $DB_CONFIG,
    "restore_command": "./restore.sh ${BACKUP_BUCKET} ${SNAPSHOT_ID:-none} ${BACKUP_REGION}",
    "created_by": "$(aws sts get-caller-identity --query Arn --output text)",
    "aws_account": "$(aws sts get-caller-identity --query Account --output text)"
}
EOF

# Upload metadata
aws s3 cp "$METADATA_FILE" "s3://${BACKUP_BUCKET}/metadata/" --region "$BACKUP_REGION"

# Create human-readable report
REPORT_FILE="backup-report-${TIMESTAMP}.txt"
cat > "$REPORT_FILE" << EOF
OpenEMR Backup Report
=====================
Date: $(date)
Backup ID: ${BACKUP_ID}
Source Region: ${AWS_REGION}
Backup Region: ${BACKUP_REGION}
Cluster: ${CLUSTER_NAME}
Namespace: ${NAMESPACE}
Backup Bucket: s3://${BACKUP_BUCKET}

Backup Results:
$(echo -e "$BACKUP_RESULTS")

Overall Status: $([ "$BACKUP_SUCCESS" = true ] && echo "SUCCESS ✅" || echo "PARTIAL FAILURE ⚠️")

Restore Instructions:
1. Run: ./restore.sh ${BACKUP_BUCKET} ${SNAPSHOT_ID:-none} ${BACKUP_REGION}
2. The restore script will automatically:
   - Use the stored database configuration (VPC, subnet groups, security groups)
   - Apply Serverless v2 scaling configuration
   - Configure security group rules for database access
   - Create the appropriate Aurora instance
   - Reset the master password to match existing credentials
3. Verify data integrity after restore

Next Steps:
- Test restore procedures regularly
- Monitor backup bucket costs
- Update retention policies as needed
- Document any custom configurations

Support:
- Check logs in S3 bucket for detailed information
- Verify snapshots in RDS console
- Test Kubernetes restore in non-production environment
EOF

# Upload report
aws s3 cp "$REPORT_FILE" "s3://${BACKUP_BUCKET}/reports/" --region "$BACKUP_REGION"

# Cleanup local files
rm -f "$METADATA_FILE" "$REPORT_FILE"

# Final summary
echo ""
if [ "$BACKUP_SUCCESS" = true ]; then
    echo -e "${GREEN}🎉 Backup Completed Successfully!${NC}"
else
    echo -e "${YELLOW}⚠️  Backup Completed with Warnings${NC}"
fi

echo -e "${BLUE}=================================${NC}"
echo -e "${GREEN}✅ Backup ID: ${BACKUP_ID}${NC}"
echo -e "${GREEN}✅ Backup Bucket: s3://${BACKUP_BUCKET}${NC}"
echo -e "${GREEN}✅ Backup Region: ${BACKUP_REGION}${NC}"
if [ -n "$SNAPSHOT_ID" ]; then
    echo -e "${GREEN}✅ Aurora Snapshot: ${SNAPSHOT_ID}${NC}"
fi
echo ""
echo -e "${BLUE}📋 Backup Results:${NC}"
echo -e "$BACKUP_RESULTS"
echo -e "${BLUE}🔄 Restore Command:${NC}"
echo -e "${BLUE}   ./restore.sh ${BACKUP_BUCKET} ${SNAPSHOT_ID:-none} ${BACKUP_REGION}${NC}"
echo ""

log_success "Backup process completed"
