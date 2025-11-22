# OpenEMR on EKS Auto Mode Deployment Guide

This comprehensive guide provides step-by-step instructions for deploying a production-ready OpenEMR system on Amazon EKS with Auto Mode.

> **📌 Prerequisites**: This guide assumes you're deploying to AWS region `us-west-2` with EKS version `1.34`. Adjust accordingly for your region.

## 📋 Table of Contents

### **Phase 1: Prerequisites & Planning**

- [System Requirements](#system-requirements)
- [Repository Configuration](#repository-configuration)
- [Compliance Checklist](#compliance-checklist)
- [Cost Estimation](#cost-estimation)

### **Phase 2: Infrastructure Deployment**

- [AWS Account Setup](#aws-account-setup)
- [Terraform Configuration](#terraform-configuration)
- [Infrastructure Deployment](#infrastructure-deployment)

### **Phase 3: Application Deployment**

- [Kubernetes Setup](#kubernetes-setup)
- [Resilient Deployment Architecture](#resilient-deployment-architecture)
- [OpenEMR Deployment](#openemr-deployment)
- [SSL Configuration](#ssl-configuration)

### **Phase 4: Post-Deployment**

- [Security Hardening](#security-hardening)
- [Monitoring Setup](#monitoring-setup)
- [Backup Configuration](#backup-configuration)
- [Operational Scripts Reference](#operational-scripts-reference)

### **Phase 5: Validation & Testing**

- [Script Usage Best Practices](#script-usage-best-practices)
- [Performance Testing](#performance-testing)
- [Disaster Recovery Testing](#disaster-recovery-testing)

---

## Phase 1: Prerequisites & Planning

### System Requirements

#### Local Development Machine

```bash
# Required tools and minimum versions
aws-cli >= 2.15.0
terraform >= 1.5.0
kubectl >= 1.29.0
helm >= 3.12.0
jq >= 1.6
openssl >= 1.1.1

# Install on macOS
brew install awscli terraform kubectl helm jq

# Verify installations
aws --version
terraform --version
kubectl version --client
helm version
```

#### AWS Account Requirements

- **Business Associate Agreement (BAA)** executed with AWS
- **Service Quotas**:

  ```bash
  # Check current quotas
  aws service-quotas get-service-quota \
    --service-code eks \
    --quota-code L-1194D53C \
    --region us-west-2

  # Minimum required quotas:
  # - EKS Clusters: 1
  # - EC2 On-Demand vCPUs: 50 (for Auto Mode)
  # - VPC: 1
  # - NAT Gateways: 2
  # - Elastic IPs: 2
  ```

### Repository Configuration

#### **Configure Branch Rulesets (Recommended)**

To maintain code quality and enable proper code review, configure your GitHub repository using the modern **branch rulesets** feature, which provides more granular control and better organization than traditional branch protection rules.

1. **Navigate to Repository Settings:**
   - Go to your GitHub repository
   - Click on **Settings** tab
   - Under **Code and automation**, click on **Rules**
   - Select **Rulesets**

2. **Create a New Branch Ruleset:**
   - Click **New ruleset**
   - Choose **New branch ruleset**

3. **Configure the Ruleset:**
   - **Name**: `Main Branch Protection`
   - **Enforcement status**: `Active`
   - **Target branches**: `main`
   - **Branch protections**:
     - ✅ **Block force pushes**
     - ✅ **Require linear history** (keeps git history clean)

4. **Save the Ruleset:**
   - Click **Create** to activate the ruleset

#### **Why GitHub Actions Bypass is Essential**

GitHub Actions must be able to bypass branch rulesets to function properly:

- **Automated Releases**: The `manual-releases.yml` workflow needs to push version updates directly to main
- **CI/CD Operations**: Automated merges and deployments require direct push access
- **Emergency Fixes**: Automated hotfixes and security patches need immediate access
- **Status Updates**: Workflows that update commit statuses and create releases

Without proper bypass permissions, your automated workflows will fail when trying to push to the main branch.

#### **Bypass Role Options Explained**

**Available Bypass Options:**
- **Organization admin Role**: Full organization access (use sparingly)
- **Repository admin Role**: Full repository access (recommended for GitHub Actions)
- **Maintain Role**: Can manage issues, pull requests, and some settings (good for trusted contributors)
- **Write Role**: Can push to repository (use with caution)
- **Deploy keys**: For automated deployments (specific use cases)

**Recommended Configuration:**
- **Repository admin Role**: Essential for GitHub Actions to function properly
- **Maintain Role**: Optional, for trusted contributors who need emergency access

#### **Recommended Settings Explanation**

**✅ Essential Settings:**
- **Block force pushes**: Prevents accidental history rewriting and maintains audit trail

**✅ Recommended Settings:**
- **Require linear history**: Keeps git history clean and easier to follow

**❌ Not Recommended:**
- **Restrict creations/updates/deletions**: Would block normal development workflow
- **Require deployments to succeed**: Not applicable (we're not using GitHub deployments)
- **Require code scanning results**: Redundant with our pre-commit hooks

#### **Why Use Branch Rulesets?**

- **Modern Approach**: More flexible and comprehensive than traditional branch protection rules
- **Granular Control**: Define detailed rules for different branches with specific conditions
- **Layered Enforcement**: Multiple rulesets can apply simultaneously with automatic conflict resolution
- **Bypass Permissions**: Grant specific users, teams, or GitHub Apps the ability to bypass certain rules
- **Better Organization**: Centralized management of all branch protection policies
- **Code Quality**: Ensures all changes are reviewed before merging
- **Collaboration**: Enables team members to review and discuss changes
- **Testing**: Requires all tests to pass before merging
- **Documentation**: Encourages proper commit messages and documentation
- **Security**: Prevents accidental pushes and maintains audit trail
- **Compliance**: Meets enterprise security and governance requirements

#### **Workflow After Configuration**

Once branch protection is enabled:

1. **Create Feature Branches:**
   ```bash
   git checkout -b feature/your-feature-name
   # Make your changes
   git add .
   git commit -m "feat: add your feature"
   git push origin feature/your-feature-name
   ```

2. **Create Pull Request:**
   - Go to GitHub repository
   - Click **Compare & pull request**
   - Fill in PR description and assign reviewers
   - Wait for required checks to pass
   - Get required approvals

3. **Merge After Approval:**
   - Once approved and checks pass, merge the PR
   - Delete the feature branch after merging

### Compliance Checklist

Before a production deployment, ensure these requirements are met:

- [ ] **AWS BAA Executed**

  ```bash
  # Verify BAA status
  aws organizations describe-organization
  ```

- [ ] **Encryption Requirements**
  - [ ] KMS keys configured with rotation
  - [ ] EBS encryption by default enabled
  - [ ] S3 bucket encryption enabled
  - [ ] Network encryption (TLS 1.2+)

- [ ] **Audit Requirements**
  - [ ] CloudTrail enabled
  - [ ] VPC Flow Logs configured
  - [ ] 365-day retention for audit logs

- [ ] **Access Controls**
  - [ ] MFA enabled for AWS root account
  - [ ] IAM roles with least privilege
  - [ ] Network segmentation planned

### Cost Estimation

#### Calculate Your Expected Costs

```python
#!/usr/bin/env python3
# save as estimate-costs.py

from typing import Dict, Any


def estimate_monthly_cost(users: int, environment: str = "production") -> Dict[str, Any]:
    """
    Estimate monthly AWS costs for an OpenEMR deployment.

    Args:
        users: Number of concurrent users.
        environment: 'production' or 'development'.
    """
    # Base costs (USD/month)
    eks_control_plane = 73
    nat_gateway = 47
    kms_keys = 7  # 7 keys: EKS, EFS, RDS, ElastiCache, S3, CloudWatch, Backup
    waf = 10
    # AWS Backup costs vary by deployment size and usage patterns (estimated for different sizes below)
    # See here for detailed backup pricing information: https://aws.amazon.com/backup/pricing/

    # Variable costs based on user tiers
    if users <= 50:  # Small clinic
        ec2_compute = 60
        aurora = 87
        valkey = 22
        efs = 30
        aws_backup = 18  # Small deployment: ~200 GB backup 
    elif users <= 200:  # Medium practice
        ec2_compute = 135
        aurora = 173
        valkey = 55
        efs = 150
        aws_backup = 40  # Medium deployment: ~500 GB backup
    else:  # Large hospital
        ec2_compute = 1104
        aurora = 518
        valkey = 138
        efs = 600
        aws_backup = 75  # Large deployment: ~900 GB backup

    auto_mode_fee = ec2_compute * 0.12  # 12% of EC2

    total = (
        eks_control_plane
        + ec2_compute
        + auto_mode_fee
        + aurora
        + valkey
        + efs
        + nat_gateway
        + kms_keys
        + waf
        + aws_backup
    )

    env = environment.lower().strip()
    if env == "development":
        # Only the total reflects scheduled shutdown savings
        total *= 0.3  # 70% savings with scheduled shutdown
        print('NOTE: When "development" is specified only the total is discounted.')
        print(
            "Total price assumes it is only active 30% of the month for development."
        )
        print(
            "All other line items reflect an estimated 24/7 monthly usage."
        )

    return {
        "total": total,
        "breakdown": {
            "EKS Control Plane": eks_control_plane,
            "EC2 Compute": ec2_compute,
            "Auto Mode Fee": auto_mode_fee,
            "Aurora Serverless": aurora,
            "Valkey Cache": valkey,
            "EFS Storage": efs,
            "NAT Gateway": nat_gateway,
            "KMS Keys": kms_keys,
            "WAFv2 Static Costs (doesn't include variable request-based pricing)": waf,
            "AWS Backup Storage (first month; reduces after cold storage transition)": aws_backup,
        },
    }


if __name__ == "__main__":
    # Example usage
    result = estimate_monthly_cost(users=75, environment="production")
    print(f"Estimated Monthly Cost (Production): ${result['total']:.2f}")
    for service, cost in result["breakdown"].items():
        print(f"  {service}: ${cost:.2f}")

    result = estimate_monthly_cost(users=75, environment="development")
    print(f"Estimated Monthly Cost (Development): ${result['total']:.2f}")
    for service, cost in result["breakdown"].items():
        print(f"  {service}: ${cost:.2f}")
```

## Phase 2: Infrastructure Deployment

### AWS Account Setup

#### 1. Configure AWS CLI

```bash
# Configure credentials
aws configure
# AWS Access Key ID [None]: YOUR_ACCESS_KEY
# AWS Secret Access Key [None]: YOUR_SECRET_KEY
# Default region name [None]: us-west-2
# Default output format [None]: json

# Verify access
aws sts get-caller-identity

# Set up AWS profiles for different environments
aws configure --profile production
aws configure --profile development
```

#### 2. Create Deployment S3 Bucket

```bash
# Create bucket for Terraform state
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="openemr-terraform-state-${ACCOUNT_ID}"

aws s3api create-bucket \
  --bucket $BUCKET_NAME \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket $BUCKET_NAME \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'
```

### Terraform Configuration

#### 1. Clone Repository and Configure

```bash
# Clone the repository
git clone <repository_url>
cd openemr-on-eks

# Navigate to terraform directory
cd terraform

# Copy example configuration
cp terraform.tfvars.example terraform.tfvars
```

#### 2. Configure terraform.tfvars

```hcl
# terraform.tfvars - Production Configuration

# Basic Configuration
aws_region   = "us-west-2"
environment  = "production"
cluster_name = "openemr-eks"

# Kubernetes Configuration (MUST be 1.29+ for Auto Mode)
kubernetes_version = "1.34"

# OpenEMR Application Configuration
openemr_version = "7.0.4"  # Latest stable OpenEMR version

# Network Configuration
vpc_cidr        = "10.0.0.0/16"
private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# Database Configuration (Aurora Serverless V2)
# IMPORTANT: 0.5 ACUs minimum = ~$43/month always-on cost
aurora_min_capacity = 0.5  # Cannot scale to zero
aurora_max_capacity = 16   # Adjust based on user count

# Cache Configuration (Valkey Serverless)
redis_max_data_storage    = 20   # GB
redis_max_ecpu_per_second = 5000 # ECPUs

# Security Configuration
enable_public_access = true  # Set to false after deployment
enable_waf          = true   # Recommended for production

# Compliance Settings
backup_retention_days     = 30   # RDS backups
alb_logs_retention_days   = 90   # ALB access logs
app_logs_retention_days   = 30   # Application logs
audit_logs_retention_days = 365  # Audit logs

# Optional: Custom domain
# domain_name = "openemr.yourhospital.org"
```

#### 3. Initialize Terraform Backend

```bash
# Create backend configuration
cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket = "${BUCKET_NAME}"
    key    = "openemr/terraform.tfstate"
    region = "us-west-2"
    encrypt = true
  }
}
EOF

# Initialize Terraform
terraform init

# Validate configuration
terraform validate
```

### Infrastructure Deployment

#### 1. Review Deployment Plan

```bash
# Generate detailed plan
terraform plan -out=tfplan

# Review resources to be created
terraform show -json tfplan | jq '.resource_changes[] | {address: .address, action: .change.actions[]}'

# Estimate costs (requires Infracost)
# brew install infracost
# infracost breakdown --path .
```

#### 2. Deploy Infrastructure

```bash
# Deploy with approval
terraform apply tfplan

# Monitor deployment (typically 40-45 minutes total)
# Infrastructure (Terraform): ~30-32 minutes (measured from E2E tests)
#   - EKS cluster: 15-20 minutes
#   - Aurora RDS cluster: 10-12 minutes  
#   - VPC/NAT gateways: 3-5 minutes
#   - Other resources (S3, EFS, ElastiCache, KMS, WAF): 5-8 minutes
# Application deployment: ~7-11 minutes (measured, can spike to 19 min on bad runs)

# Save outputs for later use
terraform output -json > ../terraform-outputs.json
```

#### 3. Verify Infrastructure

```bash
# Verify EKS cluster with Auto Mode
aws eks describe-cluster --name openemr-eks \
  --query 'cluster.{Status:status,Version:version,ComputeConfig:computeConfig}'

# Expected output:
# {
#    "Status": "ACTIVE",
#    "Version": "1.34",
#    "ComputeConfig": {
#        "enabled": true,
#        "nodePools": [
#            "general-purpose",
#            "system"
#        ],
#        "nodeRoleArn": "arn:aws:iam::<AWS_ACCOUNT_NUMBER>:role/openemr-eks-eks-auto-20250817154026184600000010"
#    }
# }


# Verify Aurora
aws rds describe-db-clusters \
  --db-cluster-identifier openemr-eks-aurora \
  --query 'DBClusters[0].Status'

# Verify Valkey
aws elasticache describe-serverless-caches \
  --serverless-cache-name openemr-eks-valkey-serverless \
  --query 'ServerlessCaches[0].Status'
```

## Phase 3: Application Deployment

### Kubernetes Setup

#### 1. Configure kubectl

```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-west-2 --name openemr-eks

# Verify connection
kubectl cluster-info

# Check Auto Mode nodes (may be empty initially)
kubectl get nodes

# Check system pods
kubectl get pods -n kube-system
```

#### 2. Verify Auto Mode Configuration

```bash
# Check for nodeclaims (Auto Mode specific)
kubectl get nodeclaim

# Check node pools
kubectl get nodepool

# Verify Pod Security Standards
kubectl get namespace default -o yaml | grep -A 5 "pod-security"
```

### Resilient Deployment Architecture

The deployment system includes **resilient deployment architecture** that handles OpenEMR initialization automatically:

#### **Deployment Benefits**

- **Automatic Initialization**: OpenEMR containers handle their own setup automatically
- **State Persistence**: Application state is preserved across container restarts
- **Health Monitoring**: Comprehensive health checks and readiness probes
- **Kubernetes Native**: Standard Kubernetes deployment patterns for reliability
- **Resource Management**: Efficient resource allocation and autoscaling

#### **Deployment Flow**

```bash
1. Infrastructure Setup
   ├── EKS cluster, RDS, Redis, EFS
   └── Security policies and network configuration

2. Application Deployment
   ├── Deploy OpenEMR application (deployment.yaml)
   ├── Create services and ingress
   └── Configure monitoring and logging
```

**Automatic Setup**: OpenEMR containers automatically initialize and configure themselves during startup.

#### **Version Management**

OpenEMR version is always specified as `${OPENEMR_VERSION}` in manifests and substituted during deployment:

```yaml
# In deployment.yaml
image: openemr/openemr:${OPENEMR_VERSION}
```

**Benefits:**

- **Centralized Control**: Version managed in Terraform variables
- **Consistency**: Same version across all components
- **Easy Updates**: Change version in one place
- **Audit Trail**: Version changes tracked in infrastructure code

### OpenEMR Deployment

#### 1. OpenEMR Version Management

The deployment supports configurable OpenEMR versions through Terraform variables:

```hcl
# In terraform.tfvars
openemr_version = "7.0.4"    # Latest stable version (recommended)
# openemr_version = "7.0.3"  # Previous stable version (deprecated)
# openemr_version = "latest" # Latest development version (not recommended for production)
```

**Available Versions:**

- `7.0.4` - Latest stable release (recommended for production)
- `7.0.2` - Previous stable release
- `7.0.1` - Older stable release
- `latest` - Latest development build (use with caution)

**Note:** OpenEMR follows a versioning pattern where the latest version may be a development release. The stable production version is typically the second-to-latest version.

**Check Available Versions:**

```bash
# Use the version checker script
cd scripts
./check-openemr-versions.sh --latest     # Show stable version (recommended)
./check-openemr-versions.sh --count 10   # Show latest 10 versions
./check-openemr-versions.sh --search 7.0 # Show all 7.0.x versions
```

The version checker automatically identifies the stable version following OpenEMR's pattern where the stable release is typically the second-to-latest version.

**Version Upgrade Process:**

```bash
# 1. Check available versions
cd scripts
./check-openemr-versions.sh --latest

# 2. Update terraform.tfvars
openemr_version = "7.0.4"

# 3. Apply infrastructure changes
cd ../terraform
terraform plan
terraform apply

# 4. Redeploy application
cd ../k8s
./deploy.sh

# 5. Monitor rolling update
kubectl rollout status deployment/openemr -n openemr
```

#### 2. Deploy Application

```bash
# Navigate to k8s directory
cd ../k8s

# Run deployment script
./deploy.sh

# Monitor deployment
watch -n 5 kubectl get pods -n openemr
```

### SSL Configuration

#### Option 1: AWS Certificate Manager (Production)

```bash
cd ../scripts

# Request certificate with automatic DNS validation
./ssl-cert-manager.sh request openemr.yourhospital.org

# Monitor validation
./ssl-cert-manager.sh validate <certificate-arn>

# Deploy certificate
./ssl-cert-manager.sh deploy <certificate-arn>
```

#### Option 2: Self-Signed (Development)

```bash
# Deploy with self-signed certificates (automatic)
cd ../k8s
./deploy.sh

# NOTE: command below shown here for documentation purposes; this will always be set up automatically as part of the "deploy.sh" script.
# Set up automatic renewal
cd ../scripts
./ssl-renewal-manager.sh deploy
```

## Phase 4: Post-Deployment

### Security Hardening

#### Disable Public Cluster Access

```bash
cd ../scripts

# Check current status
./cluster-security-manager.sh status

# Disable public access (do this after deployment is complete)
./cluster-security-manager.sh disable

# NOTE: In production this should never be enabled. Instead refer to sections in the main README.md on more secure ways to conduct Kubernetes management operations without the need to enable the public endpoint.

# For future management, temporarily enable (DEVELOPMENT ONLY)
./cluster-security-manager.sh enable

# Do your work...

# Then disable IMMEDIATELY afterwards (again DEVELOPMENT ONLY)
./cluster-security-manager.sh disable
```

### Monitoring Setup

#### Basic Monitoring (Included)

```bash
# Verify Fluent Bit is running
kubectl get pods -n openemr -l app=fluent-bit

# Check CloudWatch logs
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/openemr-eks"
```

#### Advanced Monitoring (Optional)

```bash
cd ../monitoring

# Install Prometheus, Grafana, Loki, Jaeger
./install-monitoring.sh

# With Slack alerts
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
export SLACK_CHANNEL="#openemr-alerts"
./install-monitoring.sh

# Access Grafana
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80
# Open http://localhost:3000
```

### Backup Configuration

#### 1. Configure Automated Backups

```bash
# RDS automated backups
aws rds modify-db-cluster \
  --db-cluster-identifier openemr-eks-aurora \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "sun:04:00-sun:05:00"

# Create comprehensive cross-region backup (recommended)
cd ../scripts
./backup.sh --backup-region us-east-1

# Or same-region backup
./backup.sh
```

### Operational Scripts Reference

The `scripts/` directory contains essential operational tools for managing your OpenEMR deployment. Here's a comprehensive reference:

#### **Application Management**

##### **`check-openemr-versions.sh`** - Version Discovery and Management

```bash
cd scripts

# Check latest stable version (recommended for production)
./check-openemr-versions.sh --latest

# Show latest 10 versions with stability indicators
./check-openemr-versions.sh --count 10

# Search for specific version pattern
./check-openemr-versions.sh --search 7.0

# Show all available options
./check-openemr-versions.sh --help
```

**Key Features:**

- Automatically identifies stable vs development versions
- Follows OpenEMR's versioning pattern (stable = second-to-latest)
- Shows current deployment version
- Provides upgrade guidance

**When to Use:**

- Before planning version upgrades
- Checking for security updates
- Evaluating new features in newer versions

##### **`openemr-feature-manager.sh`** - Feature Configuration Management

```bash
cd scripts

# Check current feature status
./openemr-feature-manager.sh status all

# Enable OpenEMR API endpoints (FHIR, REST API)
./openemr-feature-manager.sh enable api

# Enable Patient Portal
./openemr-feature-manager.sh enable portal

# Disable features for security hardening
./openemr-feature-manager.sh disable api
./openemr-feature-manager.sh disable portal

# Enable all features
./openemr-feature-manager.sh enable all

# Disable all optional features (maximum security)
./openemr-feature-manager.sh disable all
```

**When to Use:**

- Post-deployment feature configuration
- Security hardening and compliance
- Troubleshooting feature-specific issues
- Adapting to changing organizational needs

#### **Validation and Troubleshooting**

##### **`validate-deployment.sh`** - Comprehensive Health Checks

```bash
cd scripts

# Run full deployment validation
./validate-deployment.sh

# Expected output:
🔍 OpenEMR Deployment Validation
================================
1. Checking prerequisites...
✅ kubectl is installed
✅ aws is installed
✅ helm is installed
✅ jq is installed

2. Checking AWS credentials...
Checking AWS credential sources...
✅ AWS credentials valid
   Account ID: <AWS_ACCOUNT_ID>
   User/Role: arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/<ASSUMED_ROLE_NAME>/<AWS_USER>
   📍 Source: Environment variables
   📍 Source: Credentials file found at /path/to/.aws/credentials
   📋 Available profiles: default,
   🎯 Current profile: default
   📍 Config file found at /path/to/.aws/config
   🌍 Current region: us-west-2
   ✅ Credential sources detected: 2

3. Checking Terraform state...
✅ Terraform state file exists
✅ Terraform infrastructure deployed (77 resources)

4. Checking cluster access...
✅ EKS cluster 'openemr-eks' is accessible
✅ kubectl can connect to cluster (EKS Auto Mode)
💡 Auto Mode manages compute automatically - no nodes to count

5. Checking AWS resources...
Checking AWS resources...
✅ VPC exists: <VPC_ID>
✅ RDS Aurora cluster exists: openemr-eks-aurora
✅ ElastiCache Valkey cluster exists: openemr-eks-valkey-serverless
✅ EFS file system exists: <EFS_FILE_SYSTEM_ID>

6. Checking Kubernetes resources...
Checking Kubernetes resources...
✅ Namespace 'openemr' exists
⚠️  OpenEMR deployment already exists (2 ready replicas)
💡 Deployment will update existing resources
✅ EKS Auto Mode handles compute automatically
💡 No Karpenter needed - Auto Mode manages all compute

7. Checking security configuration...
Checking security configuration...
⚠️  Public access enabled for: <YOUR_IP_ADDRESS>/32
💡 Consider disabling after deployment: /path/to/openemr-on-eks/scripts/cluster-security-manager.sh disable
✅ Private access enabled
✅ EKS secrets encryption enabled

🎉 Validation completed successfully!
✅ Ready to deploy OpenEMR

Next steps:
   1. cd /path/to/openemr-on-eks/k8s
   2. ./deploy.sh

📋 Deployment Recommendations
=============================
🔒 Security Best Practices:
   • HTTPS-only access (port 443) - HTTP traffic is refused
   • Disable public access after deployment
   • Use strong passwords for all services
   • Enable AWS WAF for production
   • Regularly update container images
   • Monitor audit logs for compliance

💰 Cost Optimization:
   • Aurora Serverless V2 scales automatically
   • EKS Auto Mode: EC2 costs + management fee for full automation
   • Valkey Serverless provides cost-effective caching
   • Monitor usage with CloudWatch dashboards
   • Set up cost alerts and budgets

📊 Monitoring Setup:
   • CloudWatch logging with Fluent Bit (included in OpenEMR deployment)
   • Basic deployment: CloudWatch logs only
   • Optional: Enhanced monitoring stack: cd /path/to/openemr-on-eks/monitoring && ./install-monitoring.sh
   • Enhanced stack includes:
     - Prometheus v79.1.0 (metrics & alerting)
     - Grafana (dashboards with auto-discovery)
     - Loki v6.45.2 (log aggregation with S3 storage)
     - Jaeger v3.4.1 (distributed tracing)
     - AlertManager (Slack integration support)
     - OpenEMR-specific monitoring (ServiceMonitor, PrometheusRule)
   • **Loki S3 Storage**: Loki uses AWS S3 for production-grade log storage. As [recommended by Grafana](https://grafana.com/docs/loki/latest/setup/install/helm/configure-storage/), we configure object storage via cloud provider for production deployments. This provides better durability, scalability, and cost-effectiveness compared to filesystem storage.
   • Configure alerting for critical issues
   • Regular backup testing

🔍 **Enhanced OpenEMR 7.0.4 Logging Configuration:**
   • **Comprehensive Log Capture**: All OpenEMR application logs, audit trails, and system events
   • **CloudWatch Log Groups**:
     - `/aws/eks/${CLUSTER_NAME}/openemr/application` - Application logs and events
     - `/aws/eks/${CLUSTER_NAME}/openemr/access` - Apache access logs
     - `/aws/eks/${CLUSTER_NAME}/openemr/error` - Apache error logs
     - `/aws/eks/${CLUSTER_NAME}/openemr/audit` - Basic audit logs
     - `/aws/eks/${CLUSTER_NAME}/openemr/audit_detailed` - Detailed audit logs with patient ID and event categorization
     - `/aws/eks/${CLUSTER_NAME}/openemr/system` - System-level logs and component status
     - `/aws/eks/${CLUSTER_NAME}/openemr/php_error` - PHP application errors with file/line information
     - `/aws/eks/${CLUSTER_NAME}/fluent-bit/metrics` - Fluent Bit operational metrics
   • **Log Retention**: Application logs (30 days), Audit logs (365 days)
   • **Security**: All logs encrypted with KMS and tagged for compliance
   • **Real-time Processing**: Fluent Bit with 5-second refresh intervals
   • **Structured Parsing**: Custom parsers for OpenEMR-specific log formats
```

**Key Features:**

- AWS credentials and permissions validation
- EKS cluster connectivity and status
- Terraform state and resource verification
- Kubernetes resource health checks
- Application-specific validations
- SSL certificate status
- Network connectivity tests

**When to Use:**

- Before any deployment or upgrade
- Troubleshooting deployment issues
- Routine health monitoring
- After infrastructure changes

##### **`validate-efs-csi.sh`** - Storage System Validation

```bash
cd scripts

# Validate EFS CSI driver and storage
./validate-efs-csi.sh

# Automatically checks:
# - EFS CSI controller status
# - IAM permissions and roles
# - Storage class configuration
# - PVC provisioning capability
# - Mount target accessibility
```

**Key Features:**

- EFS CSI driver health monitoring
- IAM role and permission validation
- Storage class and PVC troubleshooting
- Mount target connectivity tests
- Automatic remediation suggestions

**When to Use:**

- When pods are stuck in Pending state
- Storage-related error troubleshooting
- After infrastructure changes
- EFS performance issues

#### **Deployment Management**

##### **`clean-deployment.sh`** - Erases OpenEMR Deployment

```bash
cd scripts

# Clean OpenEMR deployment (WARNING: Deletes all data but preserves infrastructure)
./clean-deployment.sh

# Force cleanup without prompts (great for automated testing)
./clean-deployment.sh --force

# Show usage information
./clean-deployment.sh --help

# This safely removes:
# - OpenEMR namespace and all resources
# - PVCs and PVs (data is preserved in EFS)
# - Application secrets and configs
# - Restarts EFS CSI controller
# - Cleans temporary files
```

**Key Features:**

- Infrastructure preservation (EKS, RDS, EFS remain intact)
- Automatic cleanup of Kubernetes resources
- EFS CSI controller restart for fresh state
- Preparation for clean redeployment

**When to Use:**

- Before fresh deployments
- When deployment is corrupted
- Testing and development scenarios
- Troubleshooting complex issues
- Automated testing and CI/CD pipelines (use `--force` flag)

**Force Mode Benefits:**

- **Automated Testing**: Skip prompts for automated deployment testing
- **CI/CD Integration**: Use in continuous integration pipelines
- **Batch Operations**: Clean multiple deployments without manual intervention
- **Development Workflow**: Quick cleanup during iterative development

##### **`restore-defaults.sh`** - File State Management

```bash
cd scripts

# Restore all deployment files to default template state
./restore-defaults.sh

# With backup creation
./restore-defaults.sh --backup

# Skip confirmation prompts
./restore-defaults.sh --force

# The script restores:
# - deployment.yaml to template state with placeholders
# - service.yaml to template state with placeholders
# - All other YAML files to template state
# - Removes all .bak files created by deployments
# - Removes generated credentials files
# - Preserves terraform.tfvars and infrastructure
```

**Key Features:**

- Clean git tracking preparation
- Template state restoration
- Generated file cleanup
- Configuration preservation
- Optional backup creation

**When to Use:**

- Before committing changes to git
- After deployments for clean state
- When preparing for configuration changes
- Before sharing code with team members
- When switching between different configurations
- After testing or troubleshooting deployments

**Important Notes:**

- Requires git repository (uses `git checkout` to restore files)
- Always preserves `terraform.tfvars` with your configuration
- Creates optional backups with `--backup` flag
- Safe to run multiple times - idempotent operation
- Does not affect running deployments or infrastructure

**⚠️ DEVELOPER WARNING:**

- **Will ERASE structural changes** to YAML files (restores to git HEAD)
- **Only use for cleaning deployment artifacts**, not during active development
- **If modifying file structure/content**, your changes will be LOST
- **Always use `--backup` flag** when unsure about file modifications

#### **Security Management**

##### **`cluster-security-manager.sh`** - EKS Access Control

```bash
cd scripts

# Check current cluster access status
./cluster-security-manager.sh status

# Check if your IP has changed
./cluster-security-manager.sh check-ip

# Enable public access (DEVELOPMENT ONLY)
./cluster-security-manager.sh enable

# Disable public access (PRODUCTION RECOMMENDED)
./cluster-security-manager.sh disable

# Schedule automatic disable (security feature)
./cluster-security-manager.sh auto-disable 60  # Disable after 60 minutes
```

**Key Features:**

- IP-based access control management
- Automatic security hardening
- Scheduled access disable for safety
- Current access status monitoring
- IP change detection and alerts

**When to Use:**

- Initial cluster setup and hardening
- Temporary administrative access
- IP address changes
- Security incident response
- Routine security audits

#### **SSL Certificate Management**

##### **`ssl-cert-manager.sh`** - AWS Certificate Manager Integration

```bash
cd scripts

# Request new SSL certificate with DNS validation
./ssl-cert-manager.sh request openemr.yourdomain.com

# Check certificate validation status
./ssl-cert-manager.sh validate arn:aws:acm:region:account:certificate/cert-id

# Deploy certificate to load balancer
./ssl-cert-manager.sh deploy arn:aws:acm:region:account:certificate/cert-id

# Check current SSL configuration status
./ssl-cert-manager.sh status

# Clean up unused certificates
./ssl-cert-manager.sh cleanup
```

**Key Features:**

- Automated DNS validation setup
- Certificate lifecycle management
- Load balancer integration
- Multi-domain certificate support
- Automatic renewal monitoring

**When to Use:**

- Setting up production SSL certificates
- Domain changes or additions
- Certificate renewal processes
- SSL troubleshooting

##### **`ssl-renewal-manager.sh`** - Self-Signed Certificate Automation

```bash
cd scripts

# Deploy self-signed certificate renewal automation
./ssl-renewal-manager.sh deploy

# Check renewal job status
./ssl-renewal-manager.sh status

# Trigger immediate certificate renewal
./ssl-renewal-manager.sh run-now

# View renewal logs
./ssl-renewal-manager.sh logs

# Remove renewal automation
./ssl-renewal-manager.sh cleanup
```

**Key Features:**

- Kubernetes CronJob-based automation
- Automatic certificate rotation
- Renewal logging and monitoring
- Development environment optimization
- Zero-downtime certificate updates

**When to Use:**

- Development and testing environments
- When ACM certificates aren't available

#### **Backup and Disaster Recovery**

##### **`backup.sh`** - Enhanced Cross-Region Backup Creation

```bash
cd scripts

# Create cross-region backup (recommended)
./backup.sh --backup-region us-east-1

# Create same-region backup
./backup.sh

# Custom configuration
./backup.sh --cluster-name my-cluster --namespace my-namespace --backup-region us-east-1

# The enhanced backup includes:
# - Aurora database snapshots with cross-region support
# - Kubernetes configurations (all resources, secrets, configs)
# - Application data and custom configurations
# - Rich metadata with restore instructions
# - Human-readable backup reports
# - Graceful handling of missing components
```

**New Enhanced Features:**

- ✅ **Simple command-line interface** with clear options
- ✅ **Cross-region S3 bucket creation** automatically
- ✅ **Graceful error handling** when components are missing
- ✅ **Rich metadata** with JSON + human-readable reports
- ✅ **Comprehensive logging** with detailed progress
- ✅ **Flexible configuration** for different environments

**When to Use:**

- Daily automated backups (recommended)
- Before major system changes
- Disaster recovery preparation
- Cross-region data protection

##### **`restore.sh`** - Enhanced Disaster Recovery Restoration

```bash
cd scripts

# Restore from cross-region backup (with confirmation prompts)
./restore.sh <backup-bucket> <snapshot-id> <backup-region>

# Example with actual backup names:
./restore.sh openemr-backups-123456789012-openemr-eks-20250815 openemr-eks-aurora-backup-20250815-120000 us-east-1

# The intelligent restore process automatically detects database state:
# 
# **When database doesn't exist or is misconfigured:**
# 1. Restore database - creates database from snapshot (early)
# 2. Clean deployment - removes existing resources and cleans database
# 3. Deploy OpenEMR - fresh install (creates proper config files)
# 4. Restore database - creates database from snapshot (always)
# 5. Restore data - extracts backup files + updates configuration
#
# **When database exists and is properly configured:**
# 1. Clean deployment - removes existing resources and database
# 2. Deploy OpenEMR - fresh install (creates proper config files)
# 3. Restore database - creates database from snapshot
# 4. Restore data - extracts backup files + updates configuration
#
# - OpenEMR automatically starts working once database and config are ready
```

**Intelligent Process Benefits:**

- ✅ **Smart database detection** - automatically detects if database exists and is properly configured
- ✅ **Dynamic process order** - adjusts restore order based on actual database state
- ✅ **Instance validation** - verifies correct cluster and instance names from Terraform
- ✅ **Early restore capability** - creates database first when needed to avoid connection issues
- ✅ **Fresh install approach** - OpenEMR creates proper config files during deployment
- ✅ **Minimal reconfiguration** - only updates database endpoint after restore
- ✅ **Automatic recovery** - pods start working once database and config are ready
- ✅ **Cross-region support** - handles snapshot copying automatically
- ✅ **Comprehensive validation** - checks all prerequisites before starting
- ✅ **Clear error messages** - provides actionable feedback and suggestions
- ✅ **Resilient process** - handles edge cases and provides recovery options

**When to Use:**

- Disaster recovery scenarios
- Data corruption recovery
- Testing backup integrity

### Script Usage Best Practices

#### **Security Considerations**

- Always run `cluster-security-manager.sh disable` in production
- Use `openemr-feature-manager.sh` to disable unused features
- Regularly validate deployments with `validate-deployment.sh`
- Test backup/restore procedures monthly

#### **Operational Workflow**

1. **Pre-deployment**: Run `validate-deployment.sh`
2. **Version management**: Use `check-openemr-versions.sh` for updates
3. **Feature configuration**: Use `openemr-feature-manager.sh` post-deployment
4. **Security hardening**: Use `cluster-security-manager.sh` to disable public access
5. **Backup**: Schedule regular cross-region backups with `backup.sh --backup-region us-east-1`
6. **Monitoring**: Validate with operational scripts regularly

#### **Troubleshooting Workflow**

1. **General issues**: Start with `validate-deployment.sh`
2. **Storage issues**: Use `validate-efs-csi.sh`
3. **SSL issues**: Check with `ssl-cert-manager.sh status`
4. **Feature issues**: Verify with `openemr-feature-manager.sh status`
5. **Access issues**: Check with `cluster-security-manager.sh status`

#### **Common Deployment Issues**

##### **"Illegal character(s) in database name" Error**

**Symptoms:**

- OpenEMR pod fails to start with "Illegal character(s) in database name"
- "Error in auto-config. Configuration failed" message
- Pod stuck in initialization phase

**Root Cause:**
The `MYSQL_DATABASE` environment variable is missing from the deployed Kubernetes deployment, causing OpenEMR to receive an empty or invalid database name.

**Solution:**

1. **Verify the deployment configuration:**

   ```bash
   kubectl get deployment -n openemr openemr -o yaml | grep -A 5 -B 5 MYSQL_DATABASE
   ```

2. **Check if the secret contains the database name:**

   ```bash
   kubectl get secret -n openemr openemr-db-credentials -o yaml | grep mysql-database
   ```

3. **If missing, update the deployment:**

   ```bash
   kubectl apply -f k8s/deployment.yaml -n openemr
   ```

4. **If the secret is missing the key, add it:**

   ```bash
   kubectl patch secret -n openemr openemr-db-credentials --type='json' -p='[{"op": "add", "path": "/data/mysql-database", "value": "b3BlbmVtcg=="}]'
   ```

5. **Wait for the deployment to roll out:**

   ```bash
   kubectl rollout status deployment/openemr -n openemr
   ```

**Prevention:**

- Always use the latest `k8s/deployment.yaml` which includes the `MYSQL_DATABASE` environment variable
- Ensure the `deploy.sh` script includes `--from-literal=mysql-database="openemr"` when creating the secret

##### **HPA Metrics Server Issues**

**Symptoms:**

- HPA warnings: "failed to get cpu utilization: unable to get metrics for resource cpu"
- "unable to fetch metrics from resource metrics API: the server could not find the requested resource (get pods.metrics.k8s.io)"
- HPA not scaling pods based on CPU/memory usage

**Root Cause:**

The Kubernetes Metrics Server is not installed in the EKS cluster, which is required for HPA to collect resource metrics.

**Solution:**

The EKS cluster configuration now includes the Metrics Server addon by default. After deploying with the updated configuration:

1. **Verify Metrics Server is running:**

   ```bash
   kubectl get pods -n kube-system | grep metrics-server
   ```

2. **Test metrics collection:**

   ```bash
   kubectl top nodes
   kubectl top pods -n openemr
   ```

3. **Check HPA status:**

   ```bash
   kubectl describe hpa -n openemr openemr-hpa
   ```

**Prevention:**

- The Metrics Server addon is now included in the EKS cluster configuration
- This ensures HPA can collect the necessary metrics for autoscaling decisions
- The addon is automatically managed by EKS and kept up to date

##### **"Waiting for docker-leader" Issue**

**Symptoms:**

- OpenEMR pod shows "Waiting for the docker-leader to finish configuration before proceeding"
- Pod never completes initialization
- Multiple pods stuck in this state

**Root Cause:**
Stale configuration marker files from previous deployments are preventing new deployments from starting properly.

**Solution:**

1. **Use the enhanced clean deployment script:**

   ```bash
   cd scripts
   ./clean-deployment.sh --force
   ```

2. **The script now automatically:**
   - Deletes orphaned persistent volumes (PVs)
   - Cleans up stale OpenEMR configuration files
   - Restarts the EFS CSI controller
   - Removes backup files from previous deployments

**Prevention:**

- Always use `clean-deployment.sh` before fresh deployments
- The enhanced script now properly cleans PVCs and stale configuration files

### Performance Testing

```bash
# Conduct load testing using the recommendations found in documentation below
# https://grafana.com/load-testing/

# Monitor HPA scaling
kubectl get hpa -n openemr --watch

# Check Auto Mode provisioning
kubectl get nodeclaim --watch
```

### Disaster Recovery Testing

#### **🔒 MANDATORY: End-to-End Backup/Restore Testing**

Before any production deployment or configuration changes, the **complete end-to-end backup/restore test must pass successfully**. This ensures disaster recovery capabilities remain intact.

```bash
# Run the comprehensive end-to-end test
./scripts/test-end-to-end-backup-restore.sh --cluster-name openemr-eks-test

# Expected outcome: All 10 test steps must pass
# ✅ Infrastructure deployment
# ✅ OpenEMR installation
# ✅ Test data creation
# ✅ Backup creation
# ✅ Monitoring stack test
# ✅ Infrastructure destruction
# ✅ Infrastructure recreation
# ✅ Backup restoration
# ✅ Verification
# ✅ Final cleanup
```

**Why This Is Critical:**

- **Disaster Recovery**: Ensures backup/restore functionality works correctly
- **Infrastructure Validation**: Validates Terraform and Kubernetes configurations
- **Regression Prevention**: Prevents changes that could break recovery procedures
- **Compliance**: Demonstrates disaster recovery capabilities for audits
- **Quality Assurance**: Ensures all changes are thoroughly tested

**Test Requirements:**

- **All test steps must pass**: No exceptions or partial failures allowed
- **Complete infrastructure cycle**: Test must validate full create/destroy/restore cycle
- **Data integrity verification**: Proof files must be correctly restored
- **Connectivity validation**: Database and application connectivity must work after restore
- **Resource cleanup**: All test resources must be properly cleaned up

**Failure Handling:**

- **If any test step fails**: Deployment process must be halted
- **Changes must be reverted**: Fix issues before proceeding with deployment
- **Re-test required**: After fixes, complete test must pass again
- **No exceptions**: This testing is mandatory for all deployments

#### **Basic Recovery Testing**

```bash
# Simulate failure
kubectl delete pod -n openemr -l app=openemr

# Monitor recovery
watch kubectl get pods -n openemr

# Test database failover
aws rds failover-db-cluster \
  --db-cluster-identifier openemr-eks-aurora

# Verify application recovers
```

## 🔧 Recent Improvements (August 28, 2025)

### Enhanced Health Checks

- **Improved probe configuration**: Better timing and failure thresholds for production workloads
- **User-Agent headers**: Added health check identification for better monitoring
- **Optimized intervals**: Reduced unnecessary health check overhead

### Resource Optimization

- **Better resource allocation**: Increased CPU and memory limits for improved performance
- **Fluent Bit optimization**: Enhanced resource allocation for better log processing
- **Security context improvements**: Added proper group permissions for compliance

### Performance Enhancements

- **Readiness probe tuning**: Faster detection of ready state
- **Liveness probe improvements**: More resilient to temporary issues

## 🎉 Deployment Complete

### Access Information

```bash
# Get application URL and admin credentials
cat k8s/openemr-credentials.txt
```

### Next Steps

1. **Configure OpenEMR**
   - Log in with admin credentials
   - Set up users and roles
   - Configure clinical settings
   - Import patient data

2. **Security Hardening**
   - Enable MFA for OpenEMR users
   - Configure session timeouts
   - Review and adjust network policies
   - Schedule security scans

3. **Operational Setup**
   - Set up monitoring alerts
   - Configure backup verification
   - Document runbooks
   - Train staff

### Maintenance Schedule

**Daily:**

- Check monitoring dashboards
- Review error logs
- Verify backups completed

**Weekly:**

- Review scaling metrics
- Check for security updates
- Test backup restoration

**Monthly:**

- Review costs
- Update documentation
- Security audit
- Performance optimization

## Rollback Procedures

If deployment fails:

```bash
# Rollback Kubernetes deployment
kubectl rollout undo deployment/openemr -n openemr

# Rollback infrastructure
cd terraform
terraform plan -destroy
terraform destroy  # Careful: This removes all infrastructure

# Restore from backup
cd ../scripts
./restore.sh <backup-bucket> <snapshot-id> <backup-region>
```

## Support Resources

- **OpenEMR Documentation**: <https://www.open-emr.org/wiki/>
- **AWS EKS Documentation**: <https://docs.aws.amazon.com/eks/>

Remember: Healthcare data requires special care. Always follow your organization's policies and procedures for handling sensitive healthcare information.
