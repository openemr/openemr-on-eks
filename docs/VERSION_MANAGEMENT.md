# OpenEMR EKS Version Awareness System

This document describes the comprehensive version awareness and notification system for the OpenEMR on EKS project. The system provides **read-only awareness** of available updates without automatically applying any changes.

## 📋 Table of Contents

### **🎯 Getting Started**
- [Overview](#-overview)
- [System Components](#-system-components)
  - [Centralized Configuration (`versions.yaml`)](#1-centralized-configuration-versionsyaml)
  - [Version Manager Script (`scripts/version-manager.sh`)](#2-version-manager-script-scriptsversion-managersh)
  - [GitHub Actions Workflow (`.github/workflows/monthly-version-check.yml`)](#3-github-actions-workflow-githubworkflowsmonthly-version-checkyml)
- [Quick Start](#-quick-start)
  - [Initial Setup](#1-initial-setup)
  - [Check for Updates](#2-check-for-updates)

### **📋 Component Management**
- [OpenEMR Application](#openemr-application)
- [Kubernetes Version](#kubernetes-version)
- [Monitoring Stack](#monitoring-stack)
- [Infrastructure Components](#infrastructure-components)
- [Terraform Modules](#terraform-modules)
- [GitHub Workflows](#github-workflows)
- [EKS Add-ons](#eks-add-ons)

### **🔧 Configuration**
- [AWS IAM Permissions](#aws-iam-permissions)

### **🔄 Workflow Examples**
- [Monthly Update Process](#monthly-update-process)
- [Manual On-Demand Checks](#manual-on-demand-checks)
- [Emergency Update Process](#emergency-update-process)

### **✨ Enhanced Features**
- [Dual Run Modes](#dual-run-modes)
- [Comprehensive Codebase Search](#comprehensive-codebase-search)
- [Component Selection](#component-selection)
- [Flexible Reporting](#flexible-reporting)

### **🛡️ Safety & Monitoring**
- [Safety Features](#%EF%B8%8F-safety-features)
  - [Awareness and Notifications](#awareness-and-notifications)
  - [Monitoring](#monitoring)
- [Monitoring and Reporting](#-monitoring-and-reporting)
  - [Update Reports](#update-reports)
  - [GitHub Integration](#github-integration)
  - [Logging](#logging)

### **🚨 Troubleshooting & Support**
- [Troubleshooting](#-troubleshooting)
  - [Common Issues](#common-issues)
  - [Debug Mode](#debug-mode)
- [Integration Points](#-integration-points)
  - [CI/CD Pipeline](#cicd-pipeline)
  - [External Services](#external-services)
- [Best Practices](#-best-practices)
  - [Update Strategy](#update-strategy)
  - [Risk Management](#risk-management)
  - [Maintenance](#maintenance)
- [Support](#-support)
  - [Getting Help](#getting-help)
  - [Emergency Contacts](#emergency-contacts)

## 🎯 Overview

The version awareness system provides:
- **Automated version checking** for all project components
- **GitHub issue notifications** when updates are available
- **Comprehensive monitoring** of all dependencies
- **GitHub Actions integration** for continuous awareness
- **Centralized configuration** for all version dependencies
- **Manual control** - no automatic updates applied
- **AWS CLI integration** for accurate version checking when credentials are available
- **Graceful fallback** when AWS credentials are not available
- **Comprehensive codebase search** to locate version strings in files
- **Dual run modes** for both automated monthly and manual on-demand checks

## 📁 System Components

### 1. Centralized Configuration (`versions.yaml`)

The `versions.yaml` file serves as the single source of truth for all version information:

```yaml
# Core Application Versions
applications:
  openemr:
    current: "7.0.3"
    registry: "openemr/openemr"
```

### 2. Version Manager Script (`scripts/version-manager.sh`)

The main script for checking and updating versions:

```bash
# Check for available updates
./scripts/version-manager.sh check

# Show current status
./scripts/version-manager.sh status
```

**Capabilities:**
- Queries Docker Hub, Helm repositories, and AWS APIs
- Respects update policies (stable vs latest)
- Generates detailed update reports
- Provides version awareness for CI/CD workflows

### 3. GitHub Actions Workflow (`.github/workflows/monthly-version-check.yml`)

Automated CI/CD integration with dual run support:

**Triggers:**
- **Monthly scheduled checks** (1st of every month at 9:00 AM UTC)
- **Manual workflow dispatch** with component selection (defaults to "all")

**Features:**
- **Dual run modes**: Monthly automated and manual timestamped runs
- **Component selection**: Choose specific component types for manual runs if desired or use the default of "all"
- **Flexible reporting**: Option to run checks without creating issues
- **Timestamped issues**: Manual runs create unique timestamped issues
- **Duplicate prevention**: Monthly runs check for existing issues
- **Comprehensive search**: Includes codebase search for version locations
- **Artifact storage**: Version check logs and reports
- **Notification system**: Success/failure notifications
- **AWS CLI integration**: Uses AWS credentials when available for accurate version checking
- **Graceful fallback**: Works without AWS credentials with clear reporting

## 🚀 Quick Start

### 1. Initial Setup

```bash
# Install dependencies
sudo apt-get update
sudo apt-get install -y curl jq yq kubectl terraform

# Make version manager script executable
chmod +x scripts/version-manager.sh

# Check current status
./scripts/version-manager.sh status
```

### 2. Check for Updates

```bash
# Check all components
./scripts/version-manager.sh check

# Check specific component types
./scripts/version-manager.sh check --components applications
./scripts/version-manager.sh check --components infrastructure
./scripts/version-manager.sh check --components terraform_modules
./scripts/version-manager.sh check --components github_workflows
./scripts/version-manager.sh check --components monitoring
./scripts/version-manager.sh check --components eks_addons
```


## 📋 Component Management

### OpenEMR Application

**Version Source:** Docker Hub (`openemr/openemr`)
**Update Policy:** Stable (recommended for production)
**Files Updated:**
- `terraform/terraform.tfvars`
- `k8s/deployment.yaml`
- `versions.yaml`

```bash
# Check OpenEMR versions
./scripts/check-openemr-versions.sh --latest

# Check for OpenEMR updates
./scripts/version-manager.sh check --components applications
```

### Kubernetes Version

**Version Source:** AWS EKS supported versions
**Files Updated:**
- `terraform/terraform.tfvars`
- `versions.yaml`

### Monitoring Stack

**Components:**
- Prometheus Operator (Helm chart)
- Loki (Helm chart)
- Jaeger (Helm chart)

**Files Updated:**
- `monitoring/prometheus-values.yaml`
- `versions.yaml`

### Infrastructure Components

**Components:**
- Fluent Bit (Docker image)
- Aurora MySQL (AWS RDS)
- Terraform AWS Provider

### Terraform Modules

**Components:**
- EKS Module ([terraform-aws-modules/eks/aws](https://github.com/terraform-aws-modules/terraform-aws-eks))
- EKS Pod Identity Module ([terraform-aws-modules/eks-pod-identity/aws](https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity))
- VPC Module ([terraform-aws-modules/vpc/aws](https://github.com/terraform-aws-modules/terraform-aws-vpc))
- AWS Provider ([hashicorp/aws](https://github.com/hashicorp/terraform-provider-aws))
- Kubernetes Provider ([hashicorp/kubernetes](https://github.com/hashicorp/terraform-provider-kubernetes))

### GitHub Workflows

**Components:**
- GitHub Actions dependencies and versions
- Pre-commit hooks
- CI/CD pipeline components

### EKS Add-ons

**Components:**
- EFS CSI Driver
- Metrics Server

## 🔧 Configuration

### AWS IAM Permissions

The version checking workflow uses AWS CLI commands to fetch the latest versions of AWS services when credentials are available. The workflow gracefully handles missing credentials by falling back to documentation scraping.

#### Required AWS Services

The workflow interacts with the following AWS services:

1. **EKS (Elastic Kubernetes Service)** - For Kubernetes and add-on version information
2. **RDS (Relational Database Service)** - For Aurora MySQL version information  
3. **STS (Security Token Service)** - For credential validation

#### Minimum IAM Policy

Here's the minimum IAM policy that provides read-only access to the required services:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VersionCheckEKSReadOnly",
            "Effect": "Allow",
            "Action": [
                "eks:DescribeAddonVersions"
            ],
            "Resource": "*"
        },
        {
            "Sid": "VersionCheckRDSReadOnly",
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBEngineVersions"
            ],
            "Resource": "*"
        },
        {
            "Sid": "VersionCheckSTSReadOnly",
            "Effect": "Allow",
            "Action": [
                "sts:GetCallerIdentity"
            ],
            "Resource": "*"
        }
    ]
}
```

#### IAM User Setup

1. **Create IAM User:**
   ```bash
   aws iam create-user --user-name openemr-version-check
   ```

2. **Attach Policy:**
   ```bash
   # Save the policy above as version-check-policy.json
   aws iam put-user-policy \
       --user-name openemr-version-check \
       --policy-name VersionCheckReadOnly \
       --policy-document file://version-check-policy.json
   ```

3. **Create Access Keys:**
   ```bash
   aws iam create-access-key --user-name openemr-version-check
   ```

4. **Configure GitHub Secrets:**
   Add the following secrets to your GitHub repository:
   - `AWS_ACCESS_KEY_ID`: The access key ID from step 3
   - `AWS_SECRET_ACCESS_KEY`: The secret access key from step 3
   - `AWS_REGION`: The AWS region (e.g., `us-east-1`)

#### Security Considerations

- **Read-only access only**: No write, create, update, or delete permissions
- **Fallback behavior**: Workflow continues to function without AWS credentials

#### Testing Permissions

You can test the permissions with these commands:

```bash
# Test EKS permissions
aws eks describe-addon-versions --addon-name aws-ebs-csi-driver --query 'addons[0].addonVersions[].compatibilities[].clusterVersion' --output text

# Test RDS permissions
aws rds describe-db-engine-versions --engine aurora-mysql --query 'DBEngineVersions[?contains(EngineVersion, `8.0.mysql_aurora.3`)].EngineVersion' --output text

# Test STS permissions
aws sts get-caller-identity
```

## 🔄 Workflow Examples

### Monthly Update Process

1. **Automated Check** (1st of every month at 9:00 AM UTC)
   ```bash
   # GitHub Actions runs automatically
   # Creates monthly issue: "Version Check Report for Month of [Month Year]"
   ```

2. **Review Updates**
   ```bash
   # Check the generated GitHub issue
   # Review comprehensive update report with codebase search results
   # Each report includes locations (files and line numbers in said files) where old version strings are found
   ```

3. **Test in Development**
   ```bash
   # Check what updates are available
   ./scripts/version-manager.sh check

   # Apply updates manually in development environment
   ```

4. **Deploy to Production**
   ```bash
   # After testing, apply updates manually to production
   ```

### Manual On-Demand Checks

1. **Trigger Manual Check**
   ```bash
   # Via GitHub Actions UI:
   # 1. Go to Actions → Version Check & Awareness
   # 2. Click "Run workflow"
   # 3. Select component type (all, applications, infrastructure, etc.)
   # 4. Choose whether to create issue (default: true)
   # 5. Click "Run workflow"
   ```

2. **Component-Specific Checks**
   ```bash
   # Check only applications
   ./scripts/version-manager.sh check --components applications

   # Check only EKS add-ons
   ./scripts/version-manager.sh check --components eks_addons

   # Check only monitoring stack
   ./scripts/version-manager.sh check --components monitoring
   ```

3. **Review Timestamped Issues**
   ```bash
   # Manual runs create timestamped issues:
   # "Manual Version Check Report - 2025-01-15 14:30:25 UTC"
   # Each manual run creates a new unique issue
   ```

### Emergency Update Process

1. **Identify Issue**
   ```bash
   # Check for security updates
   ./scripts/version-manager.sh check
   ```

2. **Quick Update**
   ```bash
   # Apply critical updates immediately (manual process)
   # Review GitHub issue for specific update instructions
   ```

3. **Verify and Monitor**
   ```bash
   # Check deployment version status
   ./scripts/version-manager.sh status
   ```

## ✨ Enhanced Features

### Dual Run Modes

The version checker supports two distinct run modes:

#### **Monthly Automated Runs**
- **Schedule**: 1st of every month at 9:00 AM UTC
- **Issue Title**: "Version Check Report for Month of [Month Year]"
- **Labels**: `version-check`, `automated`, `monthly`, `maintenance`, `dependencies`, `awareness`
- **Behavior**: Checks for existing monthly issues to prevent duplicates
- **Purpose**: Regular awareness and maintenance planning

#### **Manual On-Demand Runs**
- **Trigger**: Manual workflow dispatch via GitHub Actions UI
- **Issue Title**: "Manual Version Check Report - [YYYY-MM-DD HH:MM:SS UTC]"
- **Labels**: `version-check`, `manual`, `maintenance`, `dependencies`, `awareness`
- **Behavior**: Always creates new timestamped issues (no duplicate checking)
- **Purpose**: Ad-hoc checking, targeted analysis, emergency assessments

### Comprehensive Codebase Search

When updates are found, the system automatically searches the entire codebase for the current version string:

#### **Search Scope**
- **Comprehensive coverage**: Searches all files in the project
- **Smart exclusions**: Excludes build artifacts, temporary files, and logs
- **Categorized results**: Groups findings by file type (Configuration, Documentation, Script, Terraform, Other)

#### **Search Results Format**
```markdown
### 📍 Version Locations for [Component]

**Current Version:** `1.2.3`
**Latest Version:** `1.3.0`

**Files containing current version:**

#### 🔧 Configuration Files
versions.yaml:    current: "1.2.3"
deployment.yaml:  image: openemr:1.2.3

#### 📚 Documentation Files
README.md:        OpenEMR version 1.2.3
CHANGELOG.md:     - Updated to version 1.2.3

#### 🐚 Script Files
deploy.sh:        VERSION="1.2.3"
update.sh:        check_version "1.2.3"
```

### Component Selection

Manual runs support targeted component checking:

#### **Available Component Types**
- `all` - Check all components (default)
- `applications` - OpenEMR, Fluent Bit
- `infrastructure` - Kubernetes, Terraform, AWS Provider
- `terraform_modules` - EKS, VPC, RDS modules
- `github_workflows` - GitHub Actions dependencies
- `monitoring` - Prometheus, Loki, Jaeger
- `eks_addons` - EFS CSI Driver, Metrics Server

#### **Use Cases**
- **Targeted updates**: Check only specific component types
- **Focused analysis**: Investigate particular areas of concern
- **Quick checks**: Fast verification of specific components

### Flexible Reporting

The system provides multiple reporting options:

#### **Issue Creation Options**
- **Create issue**: Generate a GitHub issue with full report (default)
- **No issue**: Run checks without creating issues (useful for testing)

#### **Report Content**
- **Comprehensive updates**: All available updates with details
- **Codebase search results**: Exact locations of version strings

#### **Report Formats**
- **GitHub Issues**: Rich markdown with formatting and links
- **Console Output**: Terminal-friendly text format
- **Log Files**: Detailed logs for debugging and analysis
- **Artifacts**: Downloadable reports from GitHub Actions

## 🛡️ Safety Features

### Awareness and Notifications

- **GitHub Issues:** Automatic issue creation for updates
- **Detailed Reports:** Comprehensive update information
- **Component Filtering:** Can choose to check only specific component types
- **Priority Management:** Configurable priority thresholds

### Monitoring

- **Comprehensive Coverage:** All dependencies tracked
- **Regular Checks:** Monthly automated checking
- **Access Control:** GitHub Actions with properly scoped permissions

## 📊 Monitoring and Reporting

### Update Reports

Generated reports include:
- Available updates for each component
- Risk assessment and recommendations
- File locations where versions are found
- Priority-based update recommendations

### GitHub Integration

- **Issues:** Automatic issue creation for updates
- **Artifacts:** Logs and reports stored as artifacts
- **Dual Run Modes:** Monthly automated and manual timestamped runs

### Logging

- **Detailed Logs:** All operations logged with timestamps
- **Error Tracking:** Comprehensive error reporting

## 🚨 Troubleshooting

### Common Issues

**1. Version Check Fails**
```bash
# Check dependencies
./scripts/version-manager.sh check --log-level DEBUG

# Verify network connectivity
curl -I https://registry.hub.docker.com
```

### Debug Mode

Enable detailed logging:
```bash
export LOG_LEVEL=DEBUG
./scripts/version-manager.sh check

# or 

./scripts/version-manager.sh check --log-level DEBUG
```

## 🔗 Integration Points

### CI/CD Pipeline

The version management system integrates with:
- **GitHub Actions:** Automated checking and reporting
- **Terraform:** Infrastructure version management
- **Kubernetes:** Application deployment updates
- **Docker Hub:** Container image version tracking
- **AWS APIs:** EKS and RDS version checking

### External Services

- **Docker Hub API:** Image version checking
- **Helm Repositories:** Chart version checking
- **AWS APIs:** Service version checking
- **GitHub API:** Issue creation and management

## 📈 Best Practices

### Update Strategy

1. **Staged Rollouts:** Test in dev before production
2. **Regular Updates:** monthly checks, monthly updates
3. **Security First:** Prioritize security updates
4. **Documentation:** Keep release notes updated

### Risk Management

1. **Backup Everything:** Always create backups
2. **Test Thoroughly:** Comprehensive testing before production
3. **Monitor Closely:** Watch for issues after updates
4. **Have Rollback Plan:** Know how to revert changes

### Maintenance

1. **Regular Cleanup:** Remove old backups and logs
2. **Update Dependencies:** Keep tools and scripts current
3. **Review Policies:** Adjust update policies as needed
4. **Monitor Performance:** Track update success rates

## 🆘 Support

### Getting Help

- **Documentation:** Check this guide and others in this repository
- **Logs:** Review log files for detailed information
- **GitHub Issues:** Report problems via GitHub issues
- **Community:** OpenEMR community forums

### Emergency Contacts

- **Critical Issues:** Create GitHub issues with `urgent` label
- **Rollback Help:** Have rollback procedures planned and ready to execute when performing updates

---

*This version management system is designed to keep your OpenEMR EKS deployment secure, up-to-date, and reliable. Regular maintenance and following best practices will ensure optimal performance and security.*
