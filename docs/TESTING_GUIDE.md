# OpenEMR EKS Testing Guide

This guide covers the comprehensive testing strategy for the OpenEMR EKS deployment project, including automated CI/CD tests, pre-commit hooks, and manual testing procedures.

> **⚠️ AWS Resource Warning**: The end-to-end test script (`scripts/test-end-to-end-backup-restore.sh`) will create and delete resources in AWS, including backup buckets and RDS snapshots created as part of other tests that may not have finished. As a result, it should only be run in a development AWS account and **NOT** in an AWS account that runs production workloads.

## 📋 Table of Contents

### **🎯 Getting Started**

- [Testing Philosophy](#-testing-philosophy)
- [Quick Start](#-quick-start)

### **🧪 Test Suites**

- [Code Quality Tests](#1-code-quality-tests)
- [Kubernetes Manifest Tests](#2-kubernetes-manifest-tests)
- [Script Validation Tests](#3-script-validation-tests)
- [Documentation Tests](#4-documentation-tests)
- [End-to-End Backup/Restore Tests](#5-end-to-end-backuprestore-tests)

### **🚀 Running Tests**

- [Local Testing](#local-testing)
- [Test Options](#test-options)
- [Environment Variables](#environment-variables)
- [Test Examples](#test-examples)

### **🔄 CI/CD Integration**

- [GitHub Actions Workflow](#github-actions-workflow)
- [CI/CD Jobs](#cicd-jobs)
- [Test Results](#test-results)

### **🪝 Pre-commit Hooks**

- [Installation](#installation)
- [Available Hooks](#available-hooks)
- [Running Manually](#running-manually)
- [Configuration](#configuration)

### **📊 Results & Reporting**

- [Local Test Reports](#local-test-reports)
- [Report Format](#report-format)
- [CI/CD Artifacts](#cicd-artifacts)
- [Failure Analysis](#failure-analysis)

### **🛠️ Troubleshooting**

- [Common Issues](#common-issues)
- [Debug Mode](#debug-mode)

### **📈 Continuous Improvement**

- [Adding New Tests](#adding-new-tests)
- [Test Metrics](#test-metrics)
- [Feedback Loop](#feedback-loop)
- [Best Practices](#best-practices)

### **🔗 Resources & Support**

- [Related Documentation](#-related-documentation)
- [Contributing](#-contributing)
- [Community Support](#community-support)

---

## 🎯 Testing Philosophy

Our testing approach focuses on **code quality and validation** rather than infrastructure deployment, ensuring that:

- ✅ **All tests run automatically** in GitHub Actions CI/CD
- ✅ **No AWS access required** - tests are completely self-contained
- ✅ **Repository works anywhere** - clone and test without external dependencies
- ✅ **Catch issues early** - pre-commit hooks prevent bad code from being committed
- ✅ **Comprehensive coverage** - test all aspects of the codebase

## 🚀 Quick Start

Get up and running with testing in under 5 minutes:

### **1. Install Pre-commit Hooks (Recommended)**

```bash
# Install pre-commit
pip install pre-commit

# Install git hooks
pre-commit install
pre-commit install --hook-type commit-msg
```

### **2. Run Your First Test**

```bash
cd scripts

# Run all tests
./run-test-suite.sh

# Or run a specific test suite
./run-test-suite.sh -s code_quality
```

### **3. Verify Everything Works**

```bash
# Check test results (if test-results directory exists)
ls -la ../test-results/ 2>/dev/null || echo "No test results directory found"

# View latest report (if available)
cat ../test-results/test-report-*.txt 2>/dev/null | tail -20 || echo "No test reports found"
```

### **4. Set Up CI/CD (Automatic)**

- Push to `main` or `develop` branch
- Create a pull request
- Watch tests run automatically in GitHub Actions

**That's it!** Your repository now has comprehensive automated testing. 🎉

## 🧪 Test Suites

### 1. Code Quality Tests

Validates code quality, syntax, and best practices across all file types.

**Tests included:**

- Shell script syntax validation
- YAML syntax validation
- Terraform configuration validation
- Markdown documentation validation

**Files tested:**

- `scripts/*.sh` - All shell scripts
- `k8s/*.yaml` - Kubernetes manifests
- `monitoring/*.yaml` - Monitoring configurations
- `terraform/*.tf` - Terraform configurations
- `docs/*.md` - Documentation files

### 2. Kubernetes Manifest Tests

Ensures Kubernetes manifests are syntactically correct and follow best practices.

**Tests included:**

- Manifest syntax validation using `kubectl --dry-run`
- Best practices checking (resource limits, security contexts)
- Security policy validation

**Files tested:**

- `k8s/*.yaml` - All Kubernetes manifests
- `k8s/security.yaml` - Security policies
- `k8s/network-policies.yaml` - Network policies

### 3. Script Validation Tests

Validates script functionality and error handling.

**Tests included:**

- Shell script syntax checking
- Script logic validation
- Dependency checking

**Files tested:**

- `scripts/*.sh` - All shell scripts

### 4. Documentation Tests

Ensures documentation quality and consistency.

**Tests included:**

- Internal link validation
- Code example validation
- Documentation coverage checking

**Files tested:**

- `docs/*.md` - Documentation files
- `*.md` - Root-level markdown files

### 5. End-to-End Backup/Restore Tests

**Purpose:** Comprehensive testing of the complete backup and restore workflow from infrastructure deployment to application verification.

**What it tests:**

- Infrastructure deployment and teardown
- OpenEMR application deployment
- Database backup and restore
- Kubernetes resource backup and restore
- Cross-region backup capabilities
- Disaster recovery procedures
- Monitoring stack installation and uninstallation

**⚠️ Important Developer Warning:**

The end-to-end test script (`scripts/test-end-to-end-backup-restore.sh`) **automatically resets all Kubernetes manifests** to their default state using `restore-defaults.sh --force`. This means:

- **Any uncommitted changes** to files in the `k8s/` directory will be **permanently lost**
- The script restores manifests from git, overwriting local modifications
- This is necessary for the test to work with fresh infrastructure

**Before running the end-to-end test:**

1. **Commit your changes:**

   ```bash
   git add k8s/
   git commit -m "Save Kubernetes manifest changes before end-to-end test"
   ```

2. **Or stash your changes:**

   ```bash
   git stash push -m "Temporary stash before end-to-end test"
   ```

3. **After the test, restore your changes:**

   ```bash
   git stash pop  # If you used stash
   ```

**Directory affected by reset:**

- `k8s`

**Monitoring Stack Test Details:**

The end-to-end test now includes a comprehensive monitoring stack test (Step 5) that validates:

- **Installation**: Tests the complete monitoring stack installation including Prometheus, Grafana, Loki, and Jaeger
- **Functionality**: Verifies that all monitoring components are running and accessible
- **Integration**: Ensures monitoring components work correctly with the OpenEMR deployment
- **Uninstallation**: Tests clean removal of all monitoring components
- **Cleanup**: Validates that no orphaned monitoring resources remain after uninstall

This test ensures that the optional monitoring stack doesn't interfere with core OpenEMR functionality and can be safely installed/uninstalled as needed.

**Running the test:**

```bash
cd scripts
./test-end-to-end-backup-restore.sh
```

## 🚀 Running Tests

### Local Testing

Run the complete test suite locally:

```bash
cd scripts
./run-test-suite.sh
```

Run specific test suites:

```bash
# Code quality tests only
./run-test-suite.sh -s code_quality

# Kubernetes manifest tests only
./run-test-suite.sh -s kubernetes_manifests

# Script validation tests only
./run-test-suite.sh -s script_validation

# Documentation tests only
./run-test-suite.sh -s documentation
```

### Test Options

```bash
./run-test-suite.sh [OPTIONS]

Options:
  -s, --suite SUITE    Test suite to run (default: all)
  -p, --parallel       Enable parallel test execution
  -d, --dry-run        Show what tests would run without executing
  -v, --verbose        Enable verbose output
  -h, --help           Show help message
```

### Environment Variables

```bash
# Set test suite
export TEST_SUITE=code_quality

# Enable parallel execution
export PARALLEL=true

# Enable dry run mode
export DRY_RUN=true

# Enable verbose output
export VERBOSE=true
```

### **Test Examples**

#### **Basic Testing**

```bash
# Run all tests with default settings
./run-test-suite.sh

# Run specific test suite
./run-test-suite.sh -s kubernetes_manifests

# Enable verbose output for debugging
./run-test-suite.sh -v -s code_quality
```

#### **Advanced Testing**

```bash
# Dry run to see what would be tested
./run-test-suite.sh -d

# Disable parallel execution via environment variable
PARALLEL=false ./run-test-suite.sh

# Custom test suite via environment variable
TEST_SUITE=documentation ./run-test-suite.sh
```

## 🔄 Automated CI/CD Testing

### GitHub Actions Workflow

The CI/CD pipeline automatically runs on:

- **Push** to `main` or `develop` branches
- **Pull requests** to `main` or `develop` branches
- **Manual trigger** via workflow dispatch

### CI/CD Jobs

1. **Test Matrix** - Runs all test suites in parallel
2. **Lint and Validate** - Additional validation and linting
3. **Security Scan** - Vulnerability scanning with Trivy (always runs, SARIF upload optional)
4. **Code Quality** - Common issue detection
5. **Summary** - Comprehensive test results report

**Note**: The security scan runs automatically and displays results in the workflow logs. If GitHub Advanced Security is enabled, results are also uploaded to the Security tab for enhanced vulnerability tracking.

**Understanding Scan Results:**

- **Clean results** (no vulnerabilities found) are excellent and indicate good security practices
- **File counts** show how many files were scanned for context
- **Scanner details** confirm which security checks were performed
- **Severity levels** help prioritize any issues found (CRITICAL → HIGH → MEDIUM → LOW)

### Test Results

- **Artifacts** - Test results stored for 7 days
- **Security Tab** - Vulnerability scan results in GitHub Security
- **Summary** - Detailed test report in pull request comments

## 🪝 Pre-commit Hooks

### Installation

```bash
# Install pre-commit
pip install pre-commit

# Install git hooks
pre-commit install

# Install commit-msg hook
pre-commit install --hook-type commit-msg
```

### Available Hooks

- **Code Formatting** - Black, isort, flake8
- **Security** - Bandit, private key detection
- **Validation** - YAML, JSON, Terraform, Kubernetes
- **Documentation** - Markdown linting (relaxed rules)
- **Shell Scripts** - ShellCheck validation (errors only)
- **Git** - Commit message formatting

**Python Hooks Rationale:**

The pre-commit configuration includes Python-specific hooks (Black, isort, flake8, Bandit) even though the current codebase is primarily shell scripts and infrastructure-as-code. These are included because any future machine learning or analytics capabilities we add will almost certainly be written in Python. Having these hooks in place from the beginning ensures Python code quality, security, and consistency from day one.

**Note**: The current configuration uses relaxed linting rules to focus on critical issues while avoiding overly strict formatting requirements. Multi-document YAML files are properly supported.

### Running Manually

```bash
# Run all hooks on all files
pre-commit run --all-files

# Run specific hook
pre-commit run yamllint

# Run hooks on staged files only
pre-commit run
```

### **Configuration**

#### **Customizing Hook Behavior**

```bash
# Skip specific hooks for a commit
SKIP=yamllint git commit -m "message"

# Run hooks with specific arguments
pre-commit run --all-files --hook-stage manual

# Update hook versions
pre-commit autoupdate
```

#### **Hook Configuration File**

The `.pre-commit-config.yaml` file defines all hooks and their settings:

```yaml
# Example hook configuration
- repo: https://github.com/koalaman/shellcheck-precommit
  rev: v0.11.0
  hooks:
    - id: shellcheck
      args: ["--severity=error"]
```

#### **Per-Repository Overrides**

```bash
# Local overrides in .pre-commit-config.local.yaml
# Git ignore patterns
echo ".pre-commit-config.local.yaml" >> .gitignore

# Environment-specific settings
export PRE_COMMIT_HOME="$HOME/.cache/pre-commit"
```

## 📊 Test Results and Reporting

### Local Test Reports

Test results are stored in `test-results/` directory (created during testing, ignored by git):

```
test-results/
├── test-report-20241201-143022.txt
├── test-report-20241201-143156.txt
└── ...
```

**Note:** The `test-results/` directory is created during testing and is ignored by git to prevent test artifacts from being committed to the repository.

### Report Format

```
OpenEMR EKS CI/CD Test Report
Generated: Sat Dec 1 14:30:22 PST 2024
Test Suite: all
========================================

Test Results Summary:
  Passed: 12
  Failed: 0
  Skipped: 2
  Total: 14

Detailed Results:
==================
[PASS] Shell Script Syntax - Completed successfully (2s)
[PASS] YAML Validation - Completed successfully (1s)
[PASS] Terraform Validation - Completed successfully (5s)
...

========================================
🎉 All tests passed successfully!
```

### **CI/CD Artifacts**

#### **Test Results Storage**

- **Location**: GitHub Actions artifacts
- **Retention**: 7 days (configurable)
- **Format**: Text reports, JSON data, screenshots
- **Access**: Download from Actions tab or API

#### **Security Reports**

- **Trivy Results**: Available in GitHub Security tab
- **SARIF Format**: Compatible with security tools
- **Vulnerability Tracking**: Automatic issue creation
- **Remediation**: Links to CVE databases

#### **Quality Metrics**

- **Test Coverage**: Percentage of code tested
- **Execution Time**: Performance tracking
- **Failure Patterns**: Common issue identification
- **Trend Analysis**: Quality improvement tracking

### **Failure Analysis**

#### **Understanding Test Failures**

```bash
# View detailed error logs
./run-test-suite.sh -v -s kubernetes_manifests
```

#### **Common Failure Categories**

- **Syntax Errors**: Invalid YAML, shell script syntax
- **Validation Failures**: Kubernetes manifest issues
- **Security Issues**: Vulnerabilities detected
- **Performance Problems**: Tests timing out
- **Environment Issues**: Missing dependencies

## 🛠️ Troubleshooting

### Common Issues

#### 1. Test Failures

**Shell Script Syntax Errors:**

```bash
# Check specific script
bash -n k8s/deploy.sh

# Fix common issues
chmod +x scripts/*.sh
dos2unix scripts/*.sh  # Fix Windows line endings
```

**YAML Validation Errors:**

```bash
# Validate specific file
python3 -c "import yaml; yaml.safe_load(open('k8s/deployment.yaml'))"

# Check for tabs (use spaces instead)
grep -n $'\t' k8s/*.yaml
```

**Terraform Validation Errors:**

```bash
cd terraform
terraform init -backend=false
terraform validate
```

#### 2. Pre-commit Hook Failures

**Installation Issues:**

```bash
# Reinstall hooks
pre-commit uninstall
pre-commit install

# Update hooks
pre-commit autoupdate
```

**Hook-specific Issues:**

```bash
# Check hook configuration
pre-commit run --all-files --verbose

# Skip specific hooks
SKIP=yamllint git commit -m "message"
```

### Debug Mode

Enable verbose output for debugging:

```bash
# Test suite verbose mode
./run-test-suite.sh -v

# Pre-commit verbose mode
pre-commit run --verbose
```

## 📈 Continuous Improvement

### Adding New Tests

1. **Update Configuration** - Add test to `scripts/test-config.yaml`
2. **Implement Test** - Add test function to `scripts/run-test-suite.sh`
3. **Update CI/CD** - Add test to GitHub Actions workflow
4. **Document** - Update this guide

### Test Metrics

Track test performance and coverage:

- **Execution Time** - Monitor test duration
- **Coverage** - Track which files are tested
- **Failure Rate** - Monitor test reliability
- **False Positives** - Identify overly strict tests

### Feedback Loop

- **Developer Experience** - Ensure tests are fast and helpful
- **False Positives** - Minimize unnecessary failures
- **Documentation** - Keep testing guide up to date
- **Community** - Gather feedback from contributors

### **Best Practices**

#### **Writing Effective Tests**

- **Single Responsibility**: Each test should verify one specific aspect
- **Clear Naming**: Use descriptive test names that explain the purpose
- **Proper Assertions**: Test actual behavior, not implementation details
- **Error Handling**: Test both success and failure scenarios
- **Performance**: Keep tests fast to encourage frequent execution

#### **Test Organization**

- **Logical Grouping**: Organize tests by functionality or component
- **Consistent Structure**: Use the same pattern across all test suites
- **Dependencies**: Minimize test interdependencies
- **Cleanup**: Ensure tests don't leave side effects
- **Documentation**: Document complex test scenarios

#### **CI/CD Integration**

- **Fast Feedback**: Keep test execution under 10 minutes
- **Parallel Execution**: Run independent tests simultaneously
- **Fail Fast**: Stop on first failure to save time
- **Artifact Management**: Store results for analysis
- **Notification**: Alert teams on test failures

#### **Maintenance**

- **Regular Updates**: Keep test dependencies current
- **Performance Monitoring**: Track test execution times
- **Failure Analysis**: Investigate and fix recurring issues
- **Coverage Tracking**: Ensure all code paths are tested
- **Documentation**: Keep testing guide up to date

## 🔗 Related Documentation

- [Deployment Guide](DEPLOYMENT_GUIDE.md) - How to deploy OpenEMR
- [Backup & Restore Guide](BACKUP_RESTORE_GUIDE.md) - Backup and recovery procedures
- [Troubleshooting Guide](TROUBLESHOOTING.md) - Common issues and solutions
- [Monitoring Guide](LOGGING_GUIDE.md) - Logging and monitoring setup

## 📝 Contributing

When contributing to the testing framework:

1. **Follow Patterns** - Use existing test structure
2. **Add Documentation** - Update this guide for new tests
3. **Test Locally** - Verify tests work before submitting
4. **Consider Impact** - Ensure tests don't slow down development

### **Community Support**

#### **Getting Help**

- **GitHub Issues**: Report bugs or request features
- **Discussions**: Ask questions in GitHub Discussions
- **Documentation**: Check this guide and related docs first
- **Code Examples**: Review existing tests for patterns

#### **Contributing Back**

- **Bug Reports**: Provide detailed reproduction steps
- **Feature Requests**: Explain the use case and benefits
- **Pull Requests**: Follow the contribution guidelines
- **Documentation**: Help improve this testing guide

#### **Best Practices for Contributors**

- **Test Your Changes**: Ensure new tests pass locally
- **Update Documentation**: Keep guides current with changes
- **Follow Standards**: Use consistent formatting and naming
- **Be Patient**: Allow time for review and feedback

---

**Note:** This testing framework is designed to catch issues early and ensure code quality without requiring external infrastructure access. All tests run locally and in CI/CD environments automatically.
