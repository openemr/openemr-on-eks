# Security Scanning Guide

This document describes the comprehensive security scanning configuration for the
OpenEMR on EKS project. The security scanning follows a **ZERO-TOLERANCE** policy
where any finding at any severity level will fail the CI/CD pipeline.

## Table of Contents

- [Overview](#overview)
- [Zero-Tolerance Policy](#zero-tolerance-policy)
  - [Why Zero-Tolerance?](#why-zero-tolerance)
- [Workflows](#workflows)
  - [Main Security Workflow](#main-security-workflow)
  - [Individual Scanner Workflows](#individual-scanner-workflows)
- [Configuration Files](#configuration-files)
  - [Trivy Configuration](#trivy-configuration)
  - [Trivy Ignore File](#trivy-ignore-file)
  - [Checkov Configuration](#checkov-configuration)
- [Pre-commit Hooks](#pre-commit-hooks)
  - [Manual Hooks](#manual-hooks)
- [Remediation Process](#remediation-process)
  - [Requesting Exceptions](#requesting-exceptions)
- [Scanner Details](#scanner-details)
  - [Trivy](#trivy)
  - [Checkov](#checkov)
  - [KICS](#kics)
  - [Bandit](#bandit)
  - [gosec](#gosec)
  - [ShellCheck](#shellcheck)
- [GitHub Security Tab](#github-security-tab)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Tool Versions](#tool-versions)
- [Further Reading](#further-reading)

## Overview

The project uses multiple industry-leading security scanners to provide comprehensive
coverage across different security domains:

| Scanner | Purpose | Scope |
|---------|---------|-------|
| **Trivy** | Vulnerability, secret, and misconfiguration scanning | All files |
| **Checkov** | Infrastructure as Code security | Terraform, K8s, Docker, GitHub Actions |
| **KICS** | IaC security analysis | All IaC files |
| **ShellCheck** | Shell script static analysis | All .sh files |
| **Bandit** | Python security linting | Python files |
| **gosec** | Go security checking | Go files |

## Zero-Tolerance Policy

All security scanners are configured with a **fail-fast, zero-tolerance** policy:

- **Severity Levels**: CRITICAL, HIGH, MEDIUM, LOW
- **Action on Finding**: Pipeline FAILS immediately
- **No Exceptions**: All findings must be remediated before merge

### Why Zero-Tolerance?

1. **Healthcare Compliance**: OpenEMR handles PHI (Protected Health Information)
2. **HIPAA Requirements**: Security vulnerabilities can lead to compliance violations
3. **Defense in Depth**: Multiple scanners catch different types of issues
4. **Shift Left**: Catch issues early in the development cycle

## Workflows

### Main Security Workflow

The comprehensive security workflow (`security-comprehensive.yml`) runs:

- **On every push** to `main` and `develop` branches
- **On every pull request** to `main` and `develop` branches
- **Weekly on Mondays at 2 AM UTC** for continuous monitoring
- **On manual trigger** with scanner selection

### Individual Scanner Workflows

Security scanning is also integrated into:

- `ci-cd-tests.yml` - Main CI/CD pipeline
- `console-ci.yml` - Console application CI
- `warp/.github/workflows/ci.yml` - Warp project CI

## Configuration Files

### Trivy Configuration

File: `trivy.yaml`

```yaml
severity:
  - CRITICAL
  - HIGH
  - MEDIUM
  - LOW

exit:
  code: 1  # Fail on any finding
```

### Trivy Ignore File

File: `.trivyignore`

Only add entries after security team review and approval. Each entry must include:

1. CVE ID or finding ID
2. Justification for ignoring
3. Compensating control or mitigation plan
4. Tracking ticket number

### Checkov Configuration

File: `.checkov.yaml`

```yaml
hard-fail-on:
  - CRITICAL
  - HIGH
  - MEDIUM

soft-fail-on:
  - LOW
```

## Pre-commit Hooks

Security scanning is also available as pre-commit hooks:

```bash
# Install pre-commit
pip install pre-commit

# Install hooks
pre-commit install

# Run all security hooks
pre-commit run --all-files

# Run specific security hook
pre-commit run checkov --all-files
pre-commit run trivy --all-files
pre-commit run bandit --all-files
```

### Manual Hooks

Some hooks require manual triggering due to tool installation requirements:

```bash
# Trivy filesystem scan
pre-commit run trivy-fs --all-files --hook-stage manual

# KICS scan
pre-commit run kics --all-files --hook-stage manual

# gosec scan
pre-commit run gosec --all-files --hook-stage manual
```

## Remediation Process

When a security scan fails:

1. **Review the finding** in the workflow logs or GitHub Security tab
2. **Assess the severity** and determine the root cause
3. **Remediate the issue**:
   - Update dependencies for vulnerability findings
   - Remove or rotate secrets for secret findings (see [Credential Rotation Guide](CREDENTIAL_ROTATION_GUIDE.md) for RDS database credentials)
   - Fix misconfigurations for config findings
4. **Verify the fix** by running the scanner locally
5. **Push the fix** and verify the pipeline passes

### Requesting Exceptions

If a finding is a verified false positive:

1. **Document the justification** in detail
2. **Implement compensating controls** if applicable
3. **Create a tracking ticket** for review
4. **Request security team review** and approval
5. **Add to ignore file** with full documentation

## Scanner Details

### Trivy

Trivy scans for:

- **Vulnerabilities**: OS packages, application dependencies
- **Secrets**: API keys, passwords, tokens
- **Misconfigurations**: IaC security issues
- **Licenses**: Open source license compliance

### Checkov

Checkov provides:

- **Terraform**: 700+ security checks
- **Kubernetes**: Pod security, RBAC, network policies
- **Dockerfile**: Best practices, security hardening
- **GitHub Actions**: Workflow security

### KICS

KICS (Keeping Infrastructure as Code Secure) checks:

- Cloud security posture
- Compliance violations
- Security misconfigurations
- Best practice deviations

### Bandit

Bandit analyzes Python code for:

- SQL injection
- Command injection
- Hardcoded passwords
- Insecure functions
- Cryptographic issues

### gosec

gosec analyzes Go code for:

- Memory safety issues
- Cryptographic problems
- Input validation
- SQL injection
- Command injection

### ShellCheck

ShellCheck analyzes shell scripts for:

- Syntax errors and common mistakes
- Quoting issues and word splitting
- Deprecated or dangerous commands
- Portability issues
- Style and best practices

Configuration: `.shellcheckrc`

## GitHub Security Tab

All SARIF results are uploaded to the GitHub Security tab, providing:

- Centralized view of all findings
- Trend analysis over time
- Integration with GitHub code scanning alerts
- PR annotations for new findings

## Monitoring and Alerting

The security workflow runs weekly on Mondays at 2 AM UTC to:

- Detect newly disclosed vulnerabilities
- Monitor for security regressions
- Ensure continuous compliance
- Generate security reports

## Tool Versions

Security tool versions are tracked in `versions.yaml` under `security_tools`:

## Further Reading

- [Trivy Documentation](https://aquasecurity.github.io/trivy/)
- [Checkov Documentation](https://www.checkov.io/)
- [KICS Documentation](https://docs.kics.io/)
- [Bandit Documentation](https://bandit.readthedocs.io/)
- [gosec Documentation](https://github.com/securego/gosec)
