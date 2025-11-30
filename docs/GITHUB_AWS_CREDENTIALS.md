# OpenEMR on EKS GitHub → AWS Credentials Configuration

This guide explains how to configure GitHub Actions to authenticate with AWS using either GitHub OIDC (recommended) or static IAM credentials (legacy fallback).

## 📋 Table of Contents

### **🎯 Getting Started**
- [Overview](#overview)

### **✅ Option 1: GitHub OIDC (Recommended)**
- [Option 1 (Recommended): GitHub OIDC → AWS IAM Role](#option-1-recommended-github-oidc--aws-iam-role)
  - [Prerequisites](#prerequisites)
  - [Step 1: Deploy OIDC Provider](#step-1-deploy-oidc-provider)
  - [Step 2: Get Role ARN](#step-2-get-role-arn)
  - [Step 3: Configure GitHub Secret](#step-3-configure-github-secret)
  - [Step 4: Enjoy Using the Version Management GitHub Workflow](#step-4-enjoy-using-the-version-management-github-workflow-)

### **⚠️ Option 2: Static IAM Credentials (Legacy)**
- [Option 2: Static IAM Credentials (Legacy)](#option-2-static-iam-credentials-legacy)
  - [Step 1: Follow IAM User Instructions](#step-1-follow-these-instructions-for-creating-iam-user-credentials-with-appropriate-permissions)
  - [Step 2: Configure GitHub Secrets](#step-2-configure-github-secrets)
  - [Step 3: Consider Using OIDC](#step-3-consider-using-oidc-credentials-instead)

### **🔧 Long-term Maintenance**
- [Repository Renamed](#repository-renamed)
- [GitHub Organization Changed](#github-organization-changed)
- [AWS Account Changed](#aws-account-changed)
- [Updating IAM Permissions](#updating-iam-permissions)

### **🚨 Troubleshooting**
- [OIDC Authentication Fails](#oidc-authentication-fails)
- [Missing Permissions](#missing-permissions)
- [Workflow Falls Back to Static Credentials](#workflow-falls-back-to-static-credentials)
- [Trust Policy Validation Errors](#trust-policy-validation-errors)

### **🛡️ Security & Best Practices**
- [Security Best Practices](#security-best-practices)

### **📚 Additional Resources**
- [External Documentation Links](#additional-resources)

---

## Overview

This project supports **two authentication methods** for GitHub Actions to access AWS resources:

1. **✅ Preferred**: GitHub → AWS OIDC (OpenID Connect)
2. **⚠️ Legacy / Fallback**: Static IAM user access keys stored in GitHub secrets

> **⚠️ IMPORTANT**: Whenever possible, use OIDC. Static secrets are for compatibility only.

**Why OIDC is Better:**
- No long-lived credentials stored in GitHub
- Automatic token rotation per workflow run
- Better security posture (short-lived tokens)
- Complete audit trail (each token traced to specific workflow)

---

## Option 1 (Recommended): GitHub OIDC → AWS IAM Role

### Prerequisites

- Terraform 1.14.0 (see main README for installation)
- AWS CLI 2.15+ configured with credentials
- IAM permissions to create OIDC providers and roles

### Step 1: Deploy OIDC Provider

```bash
cd oidc_provider
terraform init
terraform apply
```

This creates:
- GitHub OIDC identity provider in AWS IAM
- IAM role that GitHub Actions can assume
- Example IAM policy (replace with actual permissions)

### Step 2: Get Role ARN

After deployment, Terraform outputs the role ARN:

```bash
terraform output github_actions_role_arn
```

Example output:
```
arn:aws:iam::123456789012:role/GitHubActionsOpenEMROIDCRole
```

### Step 3: Configure GitHub Secret

1. Go to your GitHub repository: **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Name: `AWS_OIDC_ROLE_ARN`
4. Value: Paste the ARN from Step 2
5. Click **Add secret**

### Step 4: Enjoy Using the [Version Management GitHub Workflow](../.github/workflows/monthly-version-check.yml) 🎉! 

**Key Points:**
- `permissions: id-token: write` is required for OIDC to work
- The workflow tries OIDC first, falls back to static credentials if OIDC is not configured
- The role ARN is read from GitHub secrets (set in Step 3)

---

## Option 2: Static IAM Credentials (Legacy)

> **⚠️ WARNING**: Use this only if you cannot enable OIDC in your AWS account yet.

This is the traditional approach using long-lived AWS access keys.

### Step 1: Follow [these instructions](VERSION_MANAGEMENT.md#-configuration-1) for creating IAM user credentials with appropriate permissions.
Follow the link above for step by step instructions on how to create an IAM user, grant that IAM user appropriate permissions and then generate access keys for that user for use in GitHub workflows.

### Step 2: Configure GitHub Secrets

1. Go to your GitHub repository: **Settings** → **Secrets and variables** → **Actions**
2. Create these secrets:
   - `AWS_ACCESS_KEY_ID`: Your IAM user access key ID
   - `AWS_SECRET_ACCESS_KEY`: Your IAM user secret access key
   - `AWS_REGION`: AWS region (e.g., `us-west-2`)

### Step 3: Consider using OIDC credentials instead!

---

## Long-term Maintenance

### Repository Renamed

If your GitHub repository is renamed:

1. Update `oidc_provider/variables.tf`:
   ```hcl
   variable "github_repository" {
     default = "NEW_ORG/NEW_REPO"  # Update this
   }
   ```

2. Run `terraform apply` in `oidc_provider/`

### GitHub Organization Changed

If your GitHub organization changes:

1. Update the repository variable (same as above)
2. Update the trust policy condition in `main.tf`
3. Run `terraform apply`

### AWS Account Changed

If you move to a different AWS account:

1. Update AWS credentials configuration
2. Run `terraform apply` in `oidc_provider/` (will create new resources)
3. Update GitHub secret `AWS_OIDC_ROLE_ARN` with the new role ARN
4. (Optional) Destroy old resources in the previous account (after **THOROUGHLY** verifying those resources are not being used)

### Updating IAM Permissions

The default policy in `oidc_provider/main.tf` grants minimal permissions needed for the `monthly-version-check.yml` workflow:

- `eks:DescribeAddonVersions` - For checking EKS add-on versions
- `rds:DescribeDBEngineVersions` - For checking Aurora MySQL versions  
- `sts:GetCallerIdentity` - For AWS credential validation

**To add more permissions** for other workflows (e.g., Terraform deployments, backups):

1. Edit `oidc_provider/main.tf`
2. Find the `aws_iam_role_policy.github_actions_version_check` resource
3. Add additional statement blocks to the policy:

```hcl
resource "aws_iam_role_policy" "github_actions_version_check" {
  name = "${var.github_actions_role_name}-version-check-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Existing version check permissions (keep these)
      {
        Sid    = "VersionCheckEKSReadOnly"
        Effect = "Allow"
        Action = ["eks:DescribeAddonVersions"]
        Resource = "*"
      },
      {
        Sid    = "VersionCheckRDSReadOnly"
        Effect = "Allow"
        Action = ["rds:DescribeDBEngineVersions"]
        Resource = "*"
      },
      {
        Sid    = "VersionCheckSTSReadOnly"
        Effect = "Allow"
        Action = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
      # Add your additional permissions here
      {
        Sid    = "AdditionalSpecifiedPermissions"
        Effect = "Allow"
        Action = [
          "eks:*",
          "ec2:*",
          "s3:*",
          # Add your actual permissions here
        ]
        Resource = "*"
      }
    ]
  })
}
```

4. Run `terraform apply` in `oidc_provider/`

---

## Troubleshooting

### OIDC Authentication Fails

**Error**: `Could not assume role with OIDC`

**Solutions:**
1. Verify the role ARN in GitHub secret matches Terraform output
2. Check the trust policy allows your repository (exact match required)
3. Ensure workflow has `permissions: id-token: write`
4. Verify the branch matches the trust policy condition (if restricted)

### Missing Permissions

**Error**: `AccessDenied` when running workflows

**Solutions:**
1. Review the IAM policy attached to the OIDC role
2. Check CloudTrail logs to see what permissions are being denied
3. Update the policy in `oidc_provider/main.tf` with required permissions

### Workflow Falls Back to Static Credentials

**Causes:**
- `AWS_OIDC_ROLE_ARN` secret not set in GitHub
- OIDC provider not deployed yet
- Trust policy doesn't match repository/branch

**Solution:**
- Follow Option 1 setup steps above
- Verify GitHub secret is set correctly
- Check Terraform outputs for correct role ARN

### Trust Policy Validation Errors

**Error**: `Invalid principal in policy`

**Solutions:**
1. Verify repository format: `OWNER/REPO` (case-sensitive)
2. Verify branch format: `refs/heads/BRANCH` (not just `BRANCH`)
3. Check for typos in repository or organization names

---

## Security Best Practices

1. **Use OIDC whenever possible** - Prevents credential leaks
2. **Scope trust policies tightly** - Restrict to specific repositories and branches
3. **Use GitHub environments** - Add additional restrictions for production
4. **Rotate static credentials regularly** - If you must use static keys, rotate every 90 days
5. **Monitor CloudTrail logs** - Track all OIDC token usage
6. **Follow principle of [least privilege](https://csrc.nist.gov/glossary/term/least_privilege)** - Only grant necessary IAM permissions

---

## Additional Resources

- **OIDC Provider Setup**: [oidc_provider/README.md](../oidc_provider/README.md)
- **AWS Blog**: [Use IAM roles to connect GitHub Actions to actions in AWS](https://aws.amazon.com/blogs/security/use-iam-roles-to-connect-github-actions-to-actions-in-aws/)
- **AWS Documentation**: [Creating OpenID Connect identity providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- **GitHub Documentation**: [Security hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)

