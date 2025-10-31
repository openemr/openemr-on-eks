# =============================================================================
# GITHUB OIDC PROVIDER OUTPUTS
# =============================================================================
# Output values from the GitHub OIDC provider Terraform module.
# These outputs are used by GitHub Actions workflows and documentation.

# ARN of the IAM role that GitHub Actions can assume via OIDC
# Use this ARN in your GitHub repository secrets as AWS_OIDC_ROLE_ARN
output "github_actions_role_arn" {
  description = "ARN of the IAM role that GitHub Actions can assume via OIDC. Add this to GitHub secrets as AWS_OIDC_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}

# ARN of the GitHub OIDC provider
output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider in AWS IAM"
  value       = aws_iam_openid_connect_provider.github.arn
}

# URL of the GitHub OIDC provider
output "oidc_provider_url" {
  description = "URL of the GitHub OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github.url
}

# Summary output for easy reference
output "summary" {
  description = "Summary of OIDC provider configuration"
  value = {
    role_arn          = aws_iam_role.github_actions.arn
    repository        = var.github_repository
    oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
    instructions      = "Add the role_arn value to your GitHub repository secrets as AWS_OIDC_ROLE_ARN"
  }
}

