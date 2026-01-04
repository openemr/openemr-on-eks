# Dependency Management Guide

This guide explains how dependencies are managed in the OpenEMR on EKS project, including automated updates via Dependabot and manual version management.

## Table of Contents

- [Overview](#overview)
- [Automated Dependency Updates (Dependabot)](#automated-dependency-updates-dependabot)
- [Manual Version Management](#manual-version-management)
- [Dependency Categories](#dependency-categories)
- [Update Review Process](#update-review-process)
- [Security Updates](#security-updates)
- [Troubleshooting](#troubleshooting)

## Overview

The OpenEMR on EKS project uses a **hybrid approach** to dependency management:

1. **Automated Updates**: Dependabot automatically creates pull requests for dependency updates
2. **Centralized Tracking**: The `versions.yaml` file provides a single source of truth for all versions
3. **Monthly Checks**: Automated scripts check for version updates and create GitHub issues

This approach ensures dependencies stay up-to-date while maintaining control over critical infrastructure changes.

## Automated Dependency Updates (Dependabot)

### What is Dependabot?

Dependabot is a GitHub-native tool that automatically:
- Monitors your dependencies for updates
- Creates pull requests with version bumps
- Includes release notes and changelogs
- Checks for security vulnerabilities

### Configuration

Dependabot is configured in `.github/dependabot.yml` and monitors the following ecosystems:

#### 1. Python Dependencies (Warp Project)
- **Directory**: `/warp`
- **Schedule**: Weekly (Mondays at 9:00 AM)
- **Files monitored**: `warp/requirements.txt`
- **Dependencies**: `boto3`, `pymysql`

#### 2. Go Dependencies (Console TUI)
- **Directory**: `/console`
- **Schedule**: Weekly (Mondays at 9:00 AM)
- **Files monitored**: `console/go.mod`, `console/go.sum`
- **Dependencies**: `bubbletea`, `lipgloss`, and indirect dependencies

#### 3. Terraform Dependencies
- **Directories**: `/terraform`, `/oidc_provider`
- **Schedule**: Weekly (Mondays at 9:00 AM)
- **Dependencies**: AWS provider, Kubernetes provider, AWS modules (EKS, VPC, Pod Identity)

#### 4. GitHub Actions
- **Directory**: `/` (root)
- **Schedule**: Weekly (Mondays at 9:00 AM)
- **Dependencies**: `actions/checkout`, `actions/setup-python`, `actions/setup-go`, etc.

#### 5. Docker Images
- **Directory**: `/warp`
- **Schedule**: Monthly (First Monday at 9:00 AM)
- **Files monitored**: `warp/Dockerfile`
- **Dependencies**: Base Python image

### Pull Request Limits

To avoid overwhelming the team, Dependabot is configured with limits:
- **Python**: 5 open PRs maximum
- **Go**: 5 open PRs maximum
- **Terraform (main)**: 5 open PRs maximum
- **Terraform (OIDC)**: 3 open PRs maximum
- **GitHub Actions**: 5 open PRs maximum
- **Docker**: 3 open PRs maximum

### Ignored Updates

Some updates are ignored to prevent automatic major version bumps that could break functionality:

**Python**:
- `boto3` (major versions)
- `pymysql` (major versions)

**Go**:
- `github.com/charmbracelet/bubbletea` (major versions)
- `github.com/charmbracelet/lipgloss` (major versions)

**Terraform**:
- `hashicorp/aws` (major versions)
- `hashicorp/kubernetes` (major versions)

**Docker**:
- `python` base image (major versions)

These can still be updated manually when reviewed and tested.

## Manual Version Management

### versions.yaml File

The `versions.yaml` file is the **single source of truth** for version information across the project. It tracks:

- Core application versions (OpenEMR, Fluent Bit, Python)
- Infrastructure versions (EKS, Terraform)
- Database versions (Aurora MySQL)
- EKS add-ons (EFS CSI Driver, Metrics Server)
- Terraform modules
- GitHub workflow actions
- Pre-commit hooks
- Monitoring stack components (Prometheus, Loki, Tempo, Mimir, cert-manager)
- Python packages
- Go packages

### Automated Version Checking

A monthly automated script checks for updates:

```bash
./scripts/check-openemr-versions.sh
```

This script:
1. Queries Docker Hub, GitHub releases, and AWS APIs
2. Compares current versions with latest available
3. Creates a GitHub issue with update recommendations
4. Labels the issue with relevant tags

See [VERSION_MANAGEMENT.md](./VERSION_MANAGEMENT.md) for details.

## Dependency Categories

### Critical Dependencies

These require careful review and testing before updates:

- **Terraform AWS Provider**: Infrastructure changes can affect running resources
- **Terraform Kubernetes Provider**: Affects cluster configuration
- **EKS Version**: Requires coordinated upgrade across cluster
- **Aurora MySQL**: Database version upgrades need careful planning
- **Python Base Image**: Affects Warp job compatibility

### Standard Dependencies

These can typically be updated with standard review:

- **Python packages** (`boto3`, `pymysql`)
- **Go packages** (`bubbletea`, `lipgloss`)
- **GitHub Actions** (usually backward compatible)
- **Monitoring stack** (Prometheus, Grafana, Loki, Tempo)

### Security Dependencies

Security updates should be prioritized:
- Dependabot will flag security vulnerabilities
- Review and merge security PRs quickly
- Test in development before production

## Update Review Process

When Dependabot creates a PR or manual updates are needed:

### 1. Review the Changes

- Check the PR description for breaking changes
- Review release notes and changelogs
- Assess impact on existing deployments

### 2. Test Locally

```bash
# For Python dependencies
cd warp
pip install -r requirements.txt
python -m pytest

# For Go dependencies
cd console
go mod tidy
go build

# For Terraform changes
cd terraform
terraform init -upgrade
terraform plan
```

### 3. Run Test Suite

```bash
# Run the full test suite
./scripts/run-test-suite.sh

# Or run specific tests
./scripts/test-warp-end-to-end.sh
```

### 4. Update versions.yaml

After merging Dependabot PRs, update `versions.yaml` to reflect new versions:

```yaml
python_packages:
  boto3:
    current: "1.42.0"  # Update this
    # ... rest of config
```

### 5. Deploy to Development

Test the changes in a development environment:

```bash
# Deploy to development
./scripts/quick-deploy.sh

# Validate the deployment
./scripts/validate-deployment.sh
```

### 6. Merge and Deploy

After successful testing:
1. Merge the Dependabot PR
2. Deploy to staging (if applicable)
3. Deploy to production
4. Monitor for issues

## Security Updates

### Dependabot Security Alerts

GitHub will automatically:
- Flag dependencies with known vulnerabilities
- Create PRs to update vulnerable dependencies
- Display alerts in the Security tab

### Responding to Security Alerts

1. **Assess Severity**: Review the CVE details and CVSS score
2. **Check Applicability**: Determine if the vulnerability affects your usage
3. **Update Quickly**: Prioritize security updates
4. **Test Thoroughly**: Ensure the update doesn't break functionality
5. **Document**: Note security updates in release notes

### Monitoring Security

```bash
# Check for security vulnerabilities (if using safety or similar)
cd warp
pip install safety
safety check -r requirements.txt
```

## Troubleshooting

### Dependabot PR Failures

**Issue**: Dependabot PR shows failing checks

**Solution**:
1. Review the error logs in the PR
2. Check if the update introduces breaking changes
3. May need to update code to accommodate new version
4. Comment on the PR with `@dependabot recreate` to regenerate

### Version Conflicts

**Issue**: Dependabot suggests version incompatible with other dependencies

**Solution**:
1. Check dependency compatibility matrices
2. Update multiple dependencies together if needed
3. Use `ignore` rules in `dependabot.yml` if incompatible
4. Manual resolution may be required

### Too Many PRs

**Issue**: Dependabot creates overwhelming number of PRs

**Solution**:
1. Adjust `open-pull-requests-limit` in `dependabot.yml`
2. Batch-merge related updates
3. Use `@dependabot ignore this major version` for unwanted updates

### Stale PRs

**Issue**: Old Dependabot PRs become stale

**Solution**:
- Comment `@dependabot rebase` to update the PR
- Or close and let Dependabot recreate it
- Configure auto-rebase in `dependabot.yml` if needed

## Best Practices

1. **Review Weekly**: Check Dependabot PRs every Monday
2. **Batch Updates**: Merge related updates together when possible
3. **Test Thoroughly**: Always run tests before merging
4. **Monitor Production**: Watch metrics after deploying updates
5. **Keep versions.yaml Updated**: Maintain single source of truth
6. **Document Breaking Changes**: Note any required configuration changes
7. **Security First**: Prioritize security updates over feature updates

## Related Documentation

- [VERSION_MANAGEMENT.md](./VERSION_MANAGEMENT.md) - Detailed version management strategy
- [TESTING_GUIDE.md](./TESTING_GUIDE.md) - How to test updates
- [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) - Deployment procedures
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) - Common issues and solutions

## Additional Resources

- [Dependabot Documentation](https://docs.github.com/en/code-security/dependabot)
- [Terraform Provider Versioning](https://www.terraform.io/language/providers/requirements)
- [Go Modules Documentation](https://go.dev/doc/modules/managing-dependencies)
- [Python Packaging Guide](https://packaging.python.org/en/latest/)

---

For questions or issues with dependency management, please open a GitHub issue with the `dependencies` label.

