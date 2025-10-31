# =============================================================================
# GITHUB OIDC PROVIDER VARIABLES
# =============================================================================
# Input variables for the GitHub OIDC provider Terraform module.
# These variables control repository scope, role naming, and AWS configuration.

# =============================================================================
# AWS CONFIGURATION VARIABLES
# =============================================================================

# AWS region where OIDC provider and IAM role will be created
variable "aws_region" {
  description = "AWS region where OIDC provider and IAM role will be created"
  type        = string
  default     = "us-west-2" # Match your main infrastructure region
}

# Environment identifier for resource naming and tagging
variable "environment" {
  description = "Environment identifier (dev, staging, production, etc.)"
  type        = string
  default     = "production"
}

# =============================================================================
# GITHUB REPOSITORY CONFIGURATION
# =============================================================================

# GitHub repository in format 'owner/repo' (e.g., 'Jmevorach/openemr-on-eks')
variable "github_repository" {
  description = "GitHub repository in format 'owner/repo' (e.g., 'Jmevorach/openemr-on-eks')"
  type        = string
  default     = "Jmevorach/openemr-on-eks"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$", var.github_repository))
    error_message = "GitHub repository must be in format 'owner/repo' (e.g., 'Jmevorach/openemr-on-eks')."
  }
}

# GitHub branch to allow in trust policy (optional, defaults to main branch)
# Use format 'refs/heads/main' for branch restriction (e.g., 'refs/heads/main' or 'refs/heads/develop')
# Set to empty string ("") to allow all branches in the repository
variable "github_branch" {
  description = "GitHub branch to allow (e.g., 'refs/heads/main'). Set to empty string (\"\") to allow all branches."
  type        = string
  default     = "refs/heads/main"
}

# =============================================================================
# IAM ROLE CONFIGURATION
# =============================================================================

# Name of the IAM role for GitHub Actions
variable "github_actions_role_name" {
  description = "Name of the IAM role for GitHub Actions (must be unique within AWS account)"
  type        = string
  default     = "GitHubActionsOpenEMROIDCRole"

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]+$", var.github_actions_role_name))
    error_message = "IAM role name must match AWS IAM naming requirements (alphanumeric and +=,.@_- only)."
  }
}

