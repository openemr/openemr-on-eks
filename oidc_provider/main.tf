# =============================================================================
# GITHUB OIDC PROVIDER TERRAFORM CONFIGURATION
# =============================================================================
# This Terraform module adds GitHub → AWS OIDC support for GitHub Actions.
# Preferred over static AWS access keys/secrets.
# Keep static creds only for legacy workflows or when OIDC cannot be enabled.
#
# This module provisions:
# 1. GitHub OIDC provider for AWS (well-known GitHub URL)
# 2. Example IAM role for GitHub Actions with trust policy scoped to specific repo
# 3. Example policy attachment (replace with actual permissions needed)
#
# IMPORTANT: The attached IAM role/permissions can be edited if you want to grant
# additional IAM permissions to future GitHub workflows securely.
# =============================================================================

terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.16.0"
    }
  }
}

# =============================================================================
# AWS PROVIDER CONFIGURATION
# =============================================================================
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "OpenEMR"
      ManagedBy   = "Terraform"
      Purpose     = "GitHub-Actions-OIDC"
    }
  }
}

# =============================================================================
# DATA SOURCES
# =============================================================================
# Get current AWS account information for ARN construction
data "aws_caller_identity" "current" {}

# Get current AWS region (for provider configuration)
data "aws_region" "current" {}

# =============================================================================
# GITHUB OIDC PROVIDER
# =============================================================================
# Creates the GitHub OIDC identity provider in AWS IAM.
# This allows GitHub Actions to authenticate using OpenID Connect.
# GitHub's well-known OIDC URL: https://token.actions.githubusercontent.com
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1", # GitHub's OIDC certificate thumbprint
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd", # GitHub's backup certificate thumbprint
  ]

  tags = {
    Name        = "GitHub-Actions-OIDC-Provider"
    Description = "OIDC provider for GitHub Actions authentication"
  }
}

# =============================================================================
# GITHUB ACTIONS IAM ROLE
# =============================================================================
# Example IAM role that GitHub Actions can assume via OIDC.
# Trust policy is scoped to a specific repository and branch by default (main branch).
# Set github_branch to empty string ("") in variables.tf to allow all branches.
# Customize the condition values in variables.tf for your use case.
resource "aws_iam_role" "github_actions" {
  name = var.github_actions_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = length(var.github_branch) > 0 ? {
          # Branch restriction: Scoped to specific branch
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:${var.github_branch}"
          }
          } : {
          # No branch restriction: Allow all branches in repository
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "GitHub-Actions-Role"
    Description = "IAM role for GitHub Actions OIDC authentication"
    Repository  = var.github_repository
  }
}

# =============================================================================
# IAM POLICY ATTACHMENT
# =============================================================================
# This policy grants the minimal permissions needed for the monthly-version-check
# workflow to query AWS service versions for version awareness checking.
#
# Current permissions:
# - eks:DescribeAddonVersions - For checking EKS add-on versions (EFS CSI, Metrics Server)
# - rds:DescribeDBEngineVersions - For checking Aurora MySQL versions
# - sts:GetCallerIdentity - For AWS credential validation
#
# To add more permissions for other workflows, edit this policy section.
# See docs/GITHUB_AWS_CREDENTIALS.md for examples of additional permissions.
resource "aws_iam_role_policy" "github_actions_version_check" {
  name = "${var.github_actions_role_name}-version-check-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VersionCheckEKSReadOnly"
        Effect = "Allow"
        Action = [
          "eks:DescribeAddonVersions"
        ]
        Resource = "*"
      },
      {
        Sid    = "VersionCheckRDSReadOnly"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBEngineVersions"
        ]
        Resource = "*"
      },
      {
        Sid    = "VersionCheckSTSReadOnly"
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

# Optional: Attach existing managed policies instead of inline policy
# Example: Attach ReadOnlyAccess for testing (replace with actual policies)
# resource "aws_iam_role_policy_attachment" "github_actions_readonly" {
#   role       = aws_iam_role.github_actions.name
#   policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
# }

