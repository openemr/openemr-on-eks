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
          "secretsmanager:GetSecretValue", # Retrieve secret values
          "secretsmanager:DescribeSecret"  # Describe secret metadata
        ]
        Resource = "*" # Allow access to all secrets (can be restricted for production)
      },
      {
        # CloudWatch Logs permissions for application and Fluent Bit logging
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",     # Create log groups for OpenEMR and Fluent Bit
          "logs:CreateLogStream",    # Create log streams within log groups
          "logs:PutLogEvents",       # Write log events to CloudWatch
          "logs:DescribeLogGroups",  # List and describe log groups
          "logs:DescribeLogStreams", # List and describe log streams
          "logs:GetLogGroupFields",  # Get fields from log groups for Grafana
          "logs:StartQuery",         # Start CloudWatch Insights queries from Grafana
          "logs:StopQuery",          # Stop CloudWatch Insights queries
          "logs:GetQueryResults",    # Get CloudWatch Insights query results
          "logs:GetLogEvents",       # Get log events for Grafana
          "logs:FilterLogEvents"     # Filter log events in Grafana
        ]
        Resource = [
          # OpenEMR application log groups
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/openemr/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/openemr/*:*",
          # Fluent Bit log groups
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/fluent-bit/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/fluent-bit/*:*"
        ]
      },
      {
        # S3 permissions for backup access during restore operations
        Effect = "Allow"
        Action = [
          "s3:GetObject", # Download backup files
          "s3:ListBucket" # List backup bucket contents
        ]
        Resource = [
          # Backup bucket - using pattern for backup buckets
          "arn:aws:s3:::openemr-backups-*",
          "arn:aws:s3:::openemr-backups-*/*"
        ]
      },
      {
        # S3 permissions for Warp dataset access (OMOP/CCDA data sources)
        # Default: synpuf-omop bucket (public OMOP dataset)
        # To add additional dataset buckets, add more Resource entries
        Effect = "Allow"
        Action = [
          "s3:GetObject", # Download dataset files
          "s3:ListBucket" # List dataset bucket contents
        ]
        Resource = [
          # synpuf-omop bucket (https://registry.opendata.aws/cmsdesynpuf-omop/)
          # Public OMOP dataset for testing and development
          "arn:aws:s3:::synpuf-omop",
          "arn:aws:s3:::synpuf-omop/*"
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

# =============================================================================
# IAM ROLE AND POLICY FOR GRAFANA CLOUDWATCH ACCESS
# =============================================================================
# This configuration creates IAM role and policy for Grafana to access CloudWatch
# metrics and logs for monitoring visualization

# IAM Role for Grafana - Service account role for CloudWatch datasource
# This role allows Grafana pods to query CloudWatch metrics and logs
resource "aws_iam_role" "grafana_cloudwatch" {
  name        = "${var.cluster_name}-grafana-cloudwatch-role"
  description = "IAM role for Grafana to access CloudWatch metrics and logs"

  # Trust policy for IRSA (IAM Roles for Service Accounts)
  # Allows the Grafana service account in monitoring namespace to assume this role
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
            # Restrict to Grafana service account in monitoring namespace
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:prometheus-stack-grafana"
            # Restrict to STS audience for security
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-grafana-cloudwatch-role"
    Component   = "monitoring"
    Description = "Grafana CloudWatch datasource access"
  }
}

# IAM Policy for Grafana CloudWatch access - Read-only permissions
# This policy grants Grafana the necessary permissions to query CloudWatch
resource "aws_iam_policy" "grafana_cloudwatch" {
  name        = "${var.cluster_name}-grafana-cloudwatch-policy"
  description = "Read-only policy for Grafana to access CloudWatch metrics and logs"

  # Policy document defining CloudWatch read permissions
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch Metrics permissions
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric", # Describe alarms for metrics
          "cloudwatch:DescribeAlarmHistory",    # Get alarm history
          "cloudwatch:DescribeAlarms",          # List and describe alarms
          "cloudwatch:ListMetrics",             # List available metrics
          "cloudwatch:GetMetricStatistics",     # Get metric statistics (time series data)
          "cloudwatch:GetMetricData",           # Get metric data (more efficient API)
          "cloudwatch:GetInsightRuleReport"     # Get CloudWatch Insights reports
        ]
        Resource = "*" # CloudWatch metrics don't support resource-level permissions
      },
      {
        # CloudWatch Logs permissions
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups", # List and describe log groups
          "logs:GetLogGroupFields", # Get fields from log groups for queries
          "logs:StartQuery",        # Start CloudWatch Logs Insights queries
          "logs:StopQuery",         # Stop running queries
          "logs:GetQueryResults",   # Get query results
          "logs:GetLogEvents",      # Get log events from streams
          "logs:FilterLogEvents"    # Filter log events for visualization
        ]
        # Allow access to all log groups for comprehensive monitoring
        # Can be restricted to specific log groups for production
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
      },
      {
        # EC2 permissions for resource discovery
        Effect = "Allow"
        Action = [
          "ec2:DescribeTags",      # Describe EC2 resource tags
          "ec2:DescribeInstances", # Describe EC2 instances for context
          "ec2:DescribeRegions"    # List available regions
        ]
        Resource = "*" # EC2 describe actions don't support resource-level permissions
      },
      {
        # Resource Groups Tagging API for resource discovery
        Effect = "Allow"
        Action = [
          "tag:GetResources" # Get resources by tags for filtering
        ]
        Resource = "*" # Tag API doesn't support resource-level permissions
      }
    ]
  })

  tags = {
    Name      = "${var.cluster_name}-grafana-cloudwatch-policy"
    Component = "monitoring"
  }
}

# Attach the CloudWatch policy to the Grafana IAM role
# This grants the role the permissions defined in the policy
resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana_cloudwatch.name
  policy_arn = aws_iam_policy.grafana_cloudwatch.arn
}

# =============================================================================
# IAM ROLE AND POLICY FOR LOKI S3 STORAGE
# =============================================================================
# This configuration creates an IAM role and policy for Loki to access S3 storage
# for log aggregation and long-term retention.

# IAM Role for Loki - Service account role for S3 storage access
# This role allows Loki pods to read and write to S3 for log storage
resource "aws_iam_role" "loki_s3" {
  name        = "${var.cluster_name}-loki-s3-role"
  description = "IAM role for Loki to access S3 storage for log aggregation"

  # Trust policy for IRSA (IAM Roles for Service Accounts)
  # Allows the Loki service account in monitoring namespace to assume this role
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
            # Restrict to Loki service account in monitoring namespace
            # Note: Service account name may vary based on Loki deployment mode
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:loki"
            # Restrict to STS audience for security
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-loki-s3-role"
    Component   = "monitoring"
    Description = "Loki S3 storage access"
  }
}

# IAM Policy for Loki S3 access - Read/write permissions for Loki storage bucket
# This policy grants Loki the necessary permissions to read and write to S3
resource "aws_iam_policy" "loki_s3" {
  name        = "${var.cluster_name}-loki-s3-policy"
  description = "Policy for Loki to access S3 storage bucket"

  # Policy document defining S3 permissions for Loki
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3 bucket permissions
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning"
        ]
        Resource = aws_s3_bucket.loki_storage.arn
      },
      {
        # S3 object permissions
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectVersion",
          "s3:RestoreObject"
        ]
        Resource = "${aws_s3_bucket.loki_storage.arn}/*"
      }
    ]
  })

  tags = {
    Name      = "${var.cluster_name}-loki-s3-policy"
    Component = "monitoring"
  }
}

# Attach the S3 policy to the Loki IAM role
# This grants the role the permissions defined in the policy
resource "aws_iam_role_policy_attachment" "loki_s3" {
  role       = aws_iam_role.loki_s3.name
  policy_arn = aws_iam_policy.loki_s3.arn
}
