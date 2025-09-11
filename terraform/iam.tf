# Note: Fluent Bit now uses the OpenEMR service account role via Pod Identity
# The separate Fluent Bit role has been removed to simplify the configuration

# IAM Role for OpenEMR application
resource "aws_iam_role" "openemr" {
  name = "openemr-service-account-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:openemr:openemr-sa"
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

# IAM policy for OpenEMR to access AWS services (including Fluent Bit CloudWatch logging)
resource "aws_iam_policy" "openemr" {
  name        = "${var.cluster_name}-openemr-policy"
  description = "Policy for OpenEMR application to access AWS services (including Fluent Bit CloudWatch logging)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/openemr/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/openemr/*:*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/fluent-bit/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/fluent-bit/*:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "openemr" {
  role       = aws_iam_role.openemr.name
  policy_arn = aws_iam_policy.openemr.arn
}

# Note: Using IRSA instead of Pod Identity for better reliability
# The service account will be annotated with the IAM role ARN in the Kubernetes manifests
