# GitHub → AWS OIDC Provider

This Terraform module provisions the GitHub OIDC provider and IAM roles needed for GitHub Actions to authenticate with AWS using OpenID Connect (OIDC) instead of static access keys.

> **⚠️ IMPORTANT**: This project now supports GitHub → AWS OIDC for GitHub Actions.
>
> **Use OIDC whenever possible.** Static AWS secrets are still supported for backward compatibility.
>
> See `docs/GITHUB_AWS_CREDENTIALS.md` for complete setup instructions.

## 📋 Table of Contents

### **🚀 Getting Started**
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)

### **⚙️ Configuration**
- [Customizing the Trust Policy](#customizing-the-trust-policy)
- [Using GitHub Environments](#using-github-environments)

### **🔐 IAM & Permissions**
- [IAM Role Permissions](#iam-role-permissions)

### **📦 Deployment & Integration**
- [Outputs](#outputs)
- [Integration with Existing Workflows](#integration-with-existing-workflows)

### **🗑️ Operations**
- [Destruction](#destruction)

### **🚨 Troubleshooting**
- [OIDC Provider Already Exists](#oidc-provider-already-exists)
- [Role Trust Policy Issues](#role-trust-policy-issues)
- [Missing Permissions](#missing-permissions)

### **📚 Additional Resources**
- [Complete Documentation](#additional-resources)

---

## Overview

This Terraform module provisions the GitHub OIDC provider and IAM roles needed for GitHub Actions to authenticate with AWS using OpenID Connect (OIDC) instead of static access keys.

**Benefits:**
- **No long-lived credentials** - No AWS access keys stored in GitHub secrets
- **Automatic rotation** - OIDC tokens are automatically generated per workflow run
- **Better security** - Short-lived tokens reduce exposure risk
- **Audit trail** - Each token can be traced to a specific workflow run

---

## Prerequisites

- **Terraform 1.14.0** (see main README for installation instructions)
- **AWS CLI 2.15+** (must be installed and configured)
- **IAM permissions** to create OIDC providers and IAM roles:
  - `iam:CreateOpenIDConnectProvider`
  - `iam:CreateRole`
  - `iam:AttachRolePolicy`
  - `iam:GetRole`
  - `iam:TagRole`

---

## Quick Start

```bash
cd oidc_provider

# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Deploy the OIDC provider and roles
terraform apply
```

After deployment, Terraform will output the IAM role ARN(s) that you can use in your GitHub workflows.

---

## Configuration

### Customizing the Trust Policy

By default, the trust policy is scoped to:
- Repository: `openemr/openemr-on-eks`
- Branch: `refs/heads/main`

To customize for your repository:

1. Edit `variables.tf` to change the default values:

```hcl
variable "github_repository" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
  default     = "openemr/openemr-on-eks"  # Change this
}

variable "github_branch" {
  description = "GitHub branch to allow (e.g., 'refs/heads/main')"
  type        = string
  default     = "refs/heads/main"  # Change this
}
```

2. For multiple repositories or branches, edit `main.tf` to add additional conditions:

```hcl
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:sub"
  values   = [
    "repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main",
    "repo:YOUR_ORG/YOUR_REPO:pull_request",
    # Add more conditions as needed
  ]
}
```

### Using GitHub Environments

To restrict access to specific GitHub environments, add environment conditions:

```hcl
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:environment"
  values   = ["production"]
}
```

---

## IAM Role Permissions

The role created by this module has **minimal permissions** limited to what the `monthly-version-check.yml` workflow needs:

- `eks:DescribeAddonVersions` - For checking EKS add-on versions (EFS CSI, Metrics Server)
- `rds:DescribeDBEngineVersions` - For checking Aurora MySQL versions
- `sts:GetCallerIdentity` - For AWS credential validation

**To add more permissions** for other workflows (e.g., Terraform operations, deployment), edit the policy in `main.tf` at the `aws_iam_role_policy.github_actions_version_check` resource.

See `docs/GITHUB_AWS_CREDENTIALS.md` for examples of additional permissions.

---

## Outputs

After deployment, Terraform outputs:

- `github_actions_role_arn` - The ARN of the IAM role for GitHub Actions
- `oidc_provider_arn` - The ARN of the OIDC provider

Use these values in your GitHub workflows and secrets.

---

## Integration with Existing Workflows

This OIDC provider is designed to **coexist** with the existing static credential approach.

- **Existing workflows** using static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` will continue to work
- **New workflows** can use OIDC by setting `AWS_OIDC_ROLE_ARN` secret
- **Migrated workflows** can fall back to static credentials if OIDC is not configured

See `docs/GITHUB_AWS_CREDENTIALS.md` for migration instructions.

---

## Destruction

```bash
cd oidc_provider

# Destroy the OIDC provider and roles
terraform destroy
```

**Note**: Ensure no active workflows are using the OIDC role before destroying it.

---

## Troubleshooting

### OIDC Provider Already Exists

If you see an error about the OIDC provider already existing:

1. Check existing providers:
   ```bash
   aws iam list-open-id-connect-providers
   ```

2. Import the existing provider into Terraform state (see Terraform import docs)

### Role Trust Policy Issues

If GitHub Actions cannot assume the role:

1. Verify the repository name matches exactly (case-sensitive)
2. Check the branch name format (`refs/heads/main`, not just `main`)
3. Ensure the workflow has `permissions: id-token: write`

### Missing Permissions

If workflows fail with permission errors:

1. Review the IAM policy attached to the role
2. Ensure the policy grants all necessary permissions
3. Check CloudTrail logs for denied actions

---

## Additional Resources

- **Complete documentation**: [docs/GITHUB_AWS_CREDENTIALS.md](../docs/GITHUB_AWS_CREDENTIALS.md)
- **AWS Blog**: [Use IAM roles to connect GitHub Actions to actions in AWS](https://aws.amazon.com/blogs/security/use-iam-roles-to-connect-github-actions-to-actions-in-aws/)
- **AWS Documentation**: [Creating OpenID Connect identity providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)

