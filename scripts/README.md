# Scripts Directory

This directory contains all the operational scripts for the OpenEMR on EKS deployment. These scripts handle infrastructure management, application deployment, monitoring, security, and maintenance tasks.

## 📋 Table of Contents

### **📁 Directory Overview**
- [Directory Structure](#directory-structure)
  - [Core Deployment Scripts](#core-deployment-scripts)
  - [Infrastructure Management](#infrastructure-management)
  - [Security & Compliance](#security--compliance)
  - [Feature Management](#feature-management)
  - [Version Management](#version-management)
  - [Testing & Validation](#testing--validation)

### **📄 Script Categories**
- [Deployment & Infrastructure](#1-deployment--infrastructure)
  - [clean-deployment.sh](#clean-deploymentsh)
  - [restore-defaults.sh](#restore-defaultssh)
  - [destroy.sh](#destroysh)
  - [validate-deployment.sh](#validate-deploymentsh)
  - [validate-efs-csi.sh](#validate-efs-csish)
- [Backup & Restore](#2-backup--restore)
  - [backup.sh](#backupsh)
  - [restore.sh](#restoresh)
- [Security & Compliance](#3-security--compliance)
  - [cluster-security-manager.sh](#cluster-security-managersh)
  - [ssl-cert-manager.sh](#ssl-cert-managersh)
  - [ssl-renewal-manager.sh](#ssl-renewal-managersh)
- [Feature Management](#4-feature-management)
  - [openemr-feature-manager.sh](#openemr-feature-managersh)
  - [check-openemr-versions.sh](#check-openemr-versionssh)
- [Version Management](#5-version-management)
  - [version-manager.sh](#version-managersh)
- [Testing & Validation](#6-testing--validation)
  - [run-test-suite.sh](#run-test-suitesh)
  - [test-end-to-end-backup-restore.sh](#test-end-to-end-backup-restoresh)
  - [test-config.yaml](#test-configyaml)

### **🔧 Maintenance & Operations**
- [Maintenance Guidelines](#maintenance-guidelines)
  - [Adding New Scripts](#adding-new-scripts)
  - [Updating Existing Scripts](#updating-existing-scripts)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)
- [Support](#support)

## Directory Structure

### Core Deployment Scripts

- **`clean-deployment.sh`** - Cleanup script for removing all (application layer) deployment resources
- **`restore-defaults.sh`** - Resets Kubernetes manifests to default state with placeholders

### Infrastructure Management

- **`backup.sh`** - Comprehensive backup system for our deployment
- **`restore.sh`** - Restore system designed to work with the backup script
- **`destroy.sh`** - Complete infrastructure destruction (bulletproof cleanup)
- **`validate-deployment.sh`** - Pre-deployment validation and health checks (also can be used to validate a running deployment
- **`validate-efs-csi.sh`** - EFS CSI driver validation and troubleshooting

### Security & Compliance

- **`cluster-security-manager.sh`** - EKS cluster security management (IP whitelisting, access control)
- **`ssl-cert-manager.sh`** - SSL certificate management and renewal
- **`ssl-renewal-manager.sh`** - Automated SSL certificate renewal system for self-signed certificates used by OpenEMR for encryption between the load balancer and the OpenEMR pods.

### Feature Management

- **`openemr-feature-manager.sh`** - OpenEMR feature flag management and configuration
- **`check-openemr-versions.sh`** - OpenEMR version checking and awareness

### Version Management

- **`version-manager.sh`** - Comprehensive version awareness checking for all project dependencies

### Testing & Validation

- **`run-test-suite.sh`** - Comprehensive test suite runner
- **`test-end-to-end-backup-restore.sh`** - End-to-end backup/restore testing (this script MUST run successfully to test new additions)
- **`test-config.yaml`** - Test configuration for CI/CD pipeline

## Script Categories

### 1. Deployment & Infrastructure

#### `clean-deployment.sh`

- **Purpose**: Complete cleanup of all deployment resources
- **Dependencies**: kubectl, aws, helm
- **Key Features**:
  - Removes all Kubernetes resources
  - Deletes all data stored in RDS MySQL database
  - Deletes all data stored on the EFS
- **Maintenance Notes**:
  - Ensure all resources are properly identified for cleanup
  - Update resource names if infrastructure changes

#### `restore-defaults.sh`

- **Purpose**: Resets Kubernetes manifests to default state with placeholders
- **Dependencies**: kubectl, yq, git
- **Key Features**:
  - Restores all Kubernetes manifest files to their default template state
  - Replaces actual values with placeholder text
  - Preserves file structure while removing sensitive data
  - Safe to run without affecting running deployments
- **Maintenance Notes**:
  - Update placeholder values if template structure changes
  - Ensure all manifest files are included in restoration process
  - Test restoration process after infrastructure changes

#### `destroy.sh`

- **Purpose**: Complete and bulletproof destruction of all OpenEMR infrastructure
- **Dependencies**: terraform, aws, kubectl
- **Key Features**:
  - **Comprehensive cleanup** - Removes ALL infrastructure resources including Terraform state
  - **RDS deletion protection handling** - Automatically disables deletion protection before destruction
  - **Snapshot cleanup** - Deletes all snapshots to prevent automatic restoration
  - **Orphaned resource cleanup** - Removes security groups, load balancers, WAF resources
  - **AWS API retry logic** - Handles rate limiting and transient failures
  - **Interactive confirmation** - Safety prompts with automation options
  - **Complete verification** - Confirms cleanup success before declaring completion
- **Safety Features**:
  - Interactive confirmation prompts (unless `--force` used)
  - AWS credentials validation before execution
  - Prerequisites checking (terraform, aws, kubectl)
  - Retry logic for AWS API calls
  - Comprehensive verification of cleanup completion
- **Usage Examples**:
  ```bash
  ./destroy.sh                              # Interactive destruction with prompts
  ./destroy.sh --force                      # Automated destruction (CI/CD) - no prompts
  ```
- **⚠️ Important Notes**:
  - **Irreversible**: This action completely destroys all infrastructure and cannot be undone
  - **Comprehensive**: Removes ALL resources including Terraform state, RDS clusters, snapshots, S3 buckets
  - **Bulletproof**: Handles edge cases like deletion protection, orphaned resources, and AWS API rate limits
  - **Verification**: Confirms complete cleanup before declaring success
- **Maintenance Notes**:
  - Update resource cleanup logic as infrastructure evolves
  - Add new resource types to cleanup as they're deployed
  - Modify retry logic based on AWS API behavior changes
  - Test cleanup process after infrastructure changes

#### `validate-deployment.sh`

- **Purpose**: Pre-deployment validation and health checks for running deployments
- **Dependencies**: kubectl, aws, terraform
- **Key Features**:
  - Validates Kubernetes cluster connectivity and configuration
  - Checks resource availability and health status
  - Verifies storage and networking components
  - Validates security policies and RBAC configurations
  - Provides comprehensive deployment readiness assessment
- **Maintenance Notes**:
  - Update validation checks as infrastructure evolves
  - Add new resource types to validation as they're deployed
  - Modify health check criteria based on operational requirements

#### `validate-efs-csi.sh`

- **Purpose**: EFS CSI driver validation and troubleshooting
- **Dependencies**: kubectl, aws
- **Key Features**:
  - Validates EFS CSI driver installation and configuration
  - Tests EFS connectivity and mount capabilities
  - Checks storage class and persistent volume configurations
  - Provides troubleshooting information for EFS-related issues
  - Validates EFS access points and security groups
- **Maintenance Notes**:
  - Update validation criteria as EFS CSI driver versions change
  - Add new EFS features to validation as they're implemented
  - Modify troubleshooting steps based on common issues

### 2. Backup & Restore

#### `backup.sh`

- **Purpose**: Comprehensive backup system
- **Dependencies**: aws, kubectl, jq
- **Key Features**:
  - Creates Aurora RDS snapshots
  - Backs up application data on EFS
  - Backs up Kubernetes configurations
  - Backs up metadata regarding the application
  - Stores backups in S3 with versioning
  - Supports cross-region backup
- **Maintenance Notes**:
  - Update backup retention policies as needed
  - Modify backup naming conventions if required
  - Add new resource types to backup as infrastructure grows

#### `restore.sh`

- **Purpose**: Simple, reliable restore system from backups
- **Dependencies**: aws, kubectl, jq
- **Key Features**:
  - **Simplified workflow** - Single command restore with auto-detection
  - **Database restore** - Restores Aurora RDS from snapshots with cross-region support
  - **Application data restore** - Downloads and extracts app data from S3 to EFS
  - **Auto-reconfiguration** - Automatically updates database and Redis/Valkey connections
  - **Cluster auto-detection** - Automatically detects EKS cluster from Terraform
  - **Flexible options** - Modular restore (database, app data, or both)
  - **Manual fallback** - Provides manual restore instructions if automated process fails
- **Usage Examples**:
  ```bash
  # Basic restore
  ./restore.sh my-backup-bucket my-snapshot-id

  # Cross-region restore
  ./restore.sh my-backup-bucket my-snapshot-id us-east-1

  # Force restore (skip confirmations)
  ./restore.sh my-backup-bucket my-snapshot-id --force
  ```
- **Maintenance Notes**:
  - Script is now much simpler and more reliable
  - Uses existing OpenEMR pods for restore operations (no need to create temporary pods)
  - Automatically handles database configuration updates via sqlconf.php
  - Redis/Valkey reconfiguration is automatic and updates Kubernetes secrets
  - Manual restore instructions available via `--manual-instructions` flag

### 3. Security & Compliance

#### `cluster-security-manager.sh`

- **Purpose**: EKS cluster security management
- **Dependencies**: aws, kubectl
- **Key Features**:
  - Manages IP whitelisting for cluster access
  - Enables/disables public access
- **Maintenance Notes**:
  - Update security group rules as needed
  - Modify IP whitelisting logic for new requirements

#### `ssl-cert-manager.sh`

- **Purpose**: [ACM](https://aws.amazon.com/certificate-manager/) SSL certificate management
- **Dependencies**: kubectl, aws
- **Key Features**:
  - Manages SSL certificates for OpenEMR
  - Handles certificate renewal
  - Configures HTTPS redirects
- **Maintenance Notes**:
  - Update certificate renewal logic
  - Modify SSL configuration as needed

#### `ssl-renewal-manager.sh`

- **Purpose**: Automated SSL certificate renewal system for self-signed certificates
- **Dependencies**: kubectl, openssl, aws
- **Key Features**:
  - Automates renewal of self-signed certificates used by OpenEMR
  - Handles encryption between load balancer and OpenEMR pods
  - Manages self-signed (**note:** and **only** self-signed certificates unlike the ssl-cert-manager.sh script which **only** manages [ACM](https://aws.amazon.com/certificate-manager/)) certificates) certificate lifecycle and rotation
  - Updates Kubernetes secrets with new certificates
  - Provides certificate validation and health checks
- **Maintenance Notes**:
  - Update certificate renewal schedules as needed
  - Modify certificate validation criteria as needed
  - Adjust renewal thresholds based on operational requirements
  - Test certificate rotation process after infrastructure changes

### 4. Feature Management

#### `openemr-feature-manager.sh`

- **Purpose**: OpenEMR feature flag management
- **Dependencies**: kubectl, aws
- **Key Features**:
  - Enables/disables OpenEMR features
  - Manages feature configurations
  - Updates feature flags
- **Maintenance Notes**:
  - Add new feature flags as OpenEMR updates
  - Update feature configuration logic as needed

#### `check-openemr-versions.sh`

- **Purpose**: OpenEMR version checking and awareness
- **Dependencies**: kubectl, aws, curl, jq
- **Key Features**:
  - Checks current OpenEMR version in running deployment
  - Identifies available updates from Docker Hub
  - Provides version upgrade recommendations
  - Generates detailed version reports
  - Supports both manual and automated checking (manual via a call from the command line and automated via crontab or something similar)
- **Maintenance Notes**:
  - Modify upgrade procedures as OpenEMR evolves
  - Adjust version comparison criteria as needed

### 5. Version Management

#### `version-manager.sh`

- **Purpose**: Comprehensive version awareness and checking system (read-only)
- **Dependencies**: curl, jq, yq, aws (optional), kubectl, terraform
- **Key Features**:
  - **Dual run modes**: Monthly automated and manual timestamped runs
  - **Component selection**: Choose specific component types for manual runs
  - **Comprehensive search**: Automatically searches codebase for version strings when updates are found
  - **AWS integration**: Uses AWS CLI for definitive version lookups when credentials are available
  - **Graceful fallback**: Works without AWS credentials, reporting what cannot be checked
  - **GitHub integration**: Creates timestamped issues for manual runs, monthly issues for scheduled runs
  - **Flexible reporting**: Option to run checks without creating issues
  - **Multi-component support**: Applications, infrastructure, Terraform modules, GitHub workflows, monitoring, EKS add-ons
- **Usage Examples**:
  ```bash
  # Check all components
  ./version-manager.sh check

  # Check specific component types
  ./version-manager.sh check --components applications
  ./version-manager.sh check --components eks_addons

  # Create GitHub issue with custom title
  ./version-manager.sh check --create-issue --month="Custom Report Title"

  # Show current status
  ./version-manager.sh status
  ```
- **Maintenance Notes**:
  - Update version fetching logic for new components
  - Add new component types as needed
  - Modify AWS CLI integration as services change
  - Update codebase search patterns for new file types


### 6. Testing & Validation

#### `run-test-suite.sh`

- **Purpose**: Comprehensive test suite runner
- **Dependencies**: kubectl, aws, helm, jq
- **Key Features**:
  - Runs all test categories
  - Generates test reports
  - Validates deployment health
- **Maintenance Notes**:
  - Add new test categories as needed
  - Update test validation logic as needed

#### `test-end-to-end-backup-restore.sh`

- **Purpose**: End-to-end backup/restore testing
- **Dependencies**: kubectl, aws, helm, terraform, jq
- **Key Features**:
  - Tests complete backup/restore cycle
  - Validates data integrity
  - Tests infrastructure recreation
- **Maintenance Notes**:
  - Update test data as needed
  - Modify test validation criteria as needed

#### `test-config.yaml`

- **Purpose**: Test configuration for CI/CD pipeline
- **Dependencies**: yq, kubectl, aws
- **Key Features**:
  - Centralized test configuration management
  - Defines test environments and parameters
  - Configures test data and validation criteria
  - Supports multiple test scenarios and environments
  - Integrates with automated testing workflows
- **Maintenance Notes**:
  - Update test parameters as infrastructure changes
  - Add new test scenarios as features are added
  - Modify validation criteria based on operational requirements
  - Ensure configuration compatibility with CI/CD pipeline updates

## Maintenance Guidelines

### Adding New Scripts

1. **Follow Naming Conventions**:
   - Use descriptive names with hyphens
   - Include purpose in filename (e.g., `backup-`, `restore-`, `validate-`)

2. **Include Standard Headers**:
   - Script description and purpose
   - Dependencies list
   - Usage examples
   - Error handling

3. **Implement Logging**:
   - Use consistent color coding (RED, GREEN, YELLOW, BLUE)
   - Include timestamps in log messages
   - Provide clear success/failure indicators

4. **Add Help Functions**:
   - Include `--help` option
   - Document all parameters
   - Provide usage examples

### Updating Existing Scripts

1. **Version Control**:
   - Update version numbers in script headers (assume script starts at v1.0.0 if not declared)
   - Document changes in commit messages
   - Test changes thoroughly

2. **Dependency Management**:
   - Update dependency lists when adding new tools
   - Ensure backward compatibility
   - Document new requirements

3. **Configuration Updates**:
   - Update default values as needed
   - Modify resource names if infrastructure changes
   - Update API calls for new AWS services

### Testing Scripts

1. **Pre-deployment Testing**:
   - Run `validate-deployment.sh` before any changes
   - Test scripts in isolated environments
   - Validate error handling

2. **Post-deployment Testing**:
   - Run `run-test-suite.sh` after changes
   - Validate security configurations

3. **Before any modifications are merged**:
   - Run `test-end-to-end-backup-restore.sh` after changes
   - Test backup/restore functionality
   - Script must run successfully before anything can be merged to main.

### Security Considerations

1. **Access Control**:
   - Ensure scripts have minimal required permissions
   - Use IAM roles with least privilege
   - Implement proper error handling

2. **Data Protection**:
   - Encrypt sensitive data in transit and at rest
   - Use secure communication protocols
   - Implement proper backup encryption

3. **Audit Logging**:
   - Log all script executions
   - Monitor for unauthorized access
   - Implement alerting for security events

## Troubleshooting

### Common Issues

1. **Permission Errors**:
   - Check AWS credentials and permissions
   - Verify kubectl context
   - Ensure proper IAM role configuration

2. **Resource Not Found**:
   - Verify resource names and regions
   - Check Terraform state
   - Validate cluster connectivity

3. **Timeout Issues**:
   - Increase timeout values for long-running operations
   - Check network connectivity
   - Verify resource availability

### Debug Mode

Most scripts support debug mode:

```bash
# Enable debug logging
export DEBUG=true
./script-name.sh

# Or use verbose flag
./script-name.sh --verbose
```

### Log Analysis

Scripts generate logs in various locations:

- **Kubernetes logs**: `kubectl logs -n openemr deployment/openemr`
- **AWS CloudWatch**: Check service-specific log groups
- **Script logs**: Check console output and error messages

## Best Practices

### Development

1. **Code Quality**:
   - Use consistent indentation and formatting
   - Include comprehensive error handling
   - Write self-documenting code

2. **Testing**:
   - Test all code paths
   - Validate error conditions
   - Test with different configurations

3. **Documentation**:
   - Keep README files updated
   - Document all parameters and options
   - Include usage examples

### Operations

1. **Monitoring**:
   - Set up alerts for script failures
   - Monitor resource usage
   - Track script execution times

2. **Maintenance**:
   - Regular script updates
   - Dependency updates
   - Security patches

3. **Backup**:
   - Regular backup testing
   - Document restore procedures
   - Maintain backup schedules

## Support

For issues or questions:

1. Check script help: `./script-name.sh --help`
2. Review logs for error messages
3. Consult troubleshooting guides
4. Check AWS and Kubernetes documentation
5. Review OpenEMR documentation for application-specific issues
