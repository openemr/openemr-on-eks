# =============================================================================
# IAM ROLES AND POLICIES FOR OPENEMR APPLICATION
# =============================================================================
# This configuration creates IAM roles and policies for OpenEMR to access AWS services
# including Secrets Manager, CloudWatch Logs, and other necessary permissions.

# Note: Fluent Bit now uses the OpenEMR service account role via Pod Identity
# The separate Fluent Bit role has been removed to simplify the configuration

# IAM Role for OpenEMR application - Service account role for Kubernetes workloads
# This role allows the OpenEMR application pods to access AWS services securely
resource "aws_iam_role" "openemr" {
  name = "openemr-service-account-role"

  # Trust policy for IRSA (IAM Roles for Service Accounts)
  # Allows the OpenEMR service account to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # OIDC provider for EKS cluster service account authentication
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Restrict to specific service account in OpenEMR namespace
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:openemr:openemr-sa"
            # Restrict to STS audience for security
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-openemr-role"
  }
}

# IAM Policy for OpenEMR application - Defines specific AWS service permissions
# This policy grants the OpenEMR application access to required AWS services
resource "aws_iam_policy" "openemr" {
  name        = "${var.cluster_name}-openemr-policy"
  description = "Policy for OpenEMR application to access AWS services (including Fluent Bit CloudWatch logging)"

  # Policy document defining specific permissions for OpenEMR
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Secrets Manager permissions for database credentials and other secrets
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",  # Retrieve secret values
          "secretsmanager:DescribeSecret"   # Describe secret metadata
        ]
        Resource = "*"  # Allow access to all secrets (can be restricted for production)
      },
      {
        # CloudWatch Logs permissions for application and Fluent Bit logging
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",      # Create log groups for OpenEMR and Fluent Bit
          "logs:CreateLogStream",     # Create log streams within log groups
          "logs:PutLogEvents",        # Write log events to CloudWatch
          "logs:DescribeLogGroups",   # List and describe log groups
          "logs:DescribeLogStreams"   # List and describe log streams
        ]
        Resource = [
          # OpenEMR application log groups
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/openemr/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/openemr/*:*",
          # Fluent Bit log groups
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/fluent-bit/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/fluent-bit/*:*"
        ]
      }
    ]
  })
}

# Attach the OpenEMR policy to the OpenEMR IAM role
# This grants the role the permissions defined in the policy
resource "aws_iam_role_policy_attachment" "openemr" {
  role       = aws_iam_role.openemr.name
  policy_arn = aws_iam_policy.openemr.arn
}

# Note: Using IRSA instead of Pod Identity for better reliability
# The service account will be annotated with the IAM role ARN in the Kubernetes manifests
