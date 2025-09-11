# Scripts Directory

This directory contains all the operational scripts for the OpenEMR on EKS deployment. These scripts handle infrastructure management, application deployment, monitoring, security, and maintenance tasks.

## Directory Structure

### Core Deployment Scripts

- **`clean-deployment.sh`** - Cleanup script for removing all (application layer) deployment resources
- **`restore-defaults.sh`** - Resets Kubernetes manifests to default state with placeholders

### Infrastructure Management

- **`backup.sh`** - Comprehensive backup system for our deployment
- **`restore.sh`** - Restore system designed to work with the backup script
- **`validate-deployment.sh`** - Pre-deployment validation and health checks (also can be used to validate a running deployment
- **`validate-efs-csi.sh`** - EFS CSI driver validation and troubleshooting

### Security & Compliance

- **`cluster-security-manager.sh`** - EKS cluster security management (IP whitelisting, access control)
- **`ssl-cert-manager.sh`** - SSL certificate management and renewal
- **`ssl-renewal-manager.sh`** - Automated SSL certificate renewal system for self-signed certificates used by OpenEMR for encryption between the load balancer and the OpenEMR pods.

### Feature Management

- **`openemr-feature-manager.sh`** - OpenEMR feature flag management and configuration
- **`check-openemr-versions.sh`** - OpenEMR version checking and update management

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

- **Purpose**: SSL certificate management
- **Dependencies**: kubectl, aws
- **Key Features**:
  - Manages SSL certificates for OpenEMR
  - Handles certificate renewal
  - Configures HTTPS redirects
- **Maintenance Notes**:
  - Update certificate renewal logic
  - Modify SSL configuration as needed

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

- **Purpose**: OpenEMR version management
- **Dependencies**: kubectl, aws
- **Key Features**:
  - Checks current OpenEMR version
  - Identifies available updates
  - Helps manages version upgrades
- **Maintenance Notes**:
  - Update version checking logic if needed
  - Modify upgrade procedures if needed

### 5. Testing & Validation

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
