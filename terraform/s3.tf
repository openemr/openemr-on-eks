# =============================================================================
# S3 STORAGE CONFIGURATION
# =============================================================================
# This configuration creates S3 buckets for storing ALB access logs and WAF logs,
# providing centralized logging capabilities for the OpenEMR deployment with
# encryption, versioning, and lifecycle policies.

# Data sources for S3 bucket policies
data "aws_elb_service_account" "main" {}

# Random suffix for bucket names to ensure global uniqueness
# S3 bucket names must be globally unique across all AWS accounts and regions
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

############################
# ALB Access Logs Bucket
############################

# S3 bucket for storing ALB (Application Load Balancer) access logs
# This bucket receives detailed access logs from the ALB, including request details,
# response codes, and timing information for monitoring and troubleshooting.
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.cluster_name}-alb-logs-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-alb-logs"
    Purpose     = "ALB Access Logs"
    Environment = var.environment
  }
}

# CRITICAL: Set object ownership before applying bucket policies
# This ensures that objects uploaded by the ALB service are owned by the bucket owner
# rather than the service, which is required for proper access control.
resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Enable versioning for the ALB logs bucket
# This provides protection against accidental deletion and allows for point-in-time recovery
resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption for the ALB logs bucket
# Uses KMS encryption with the S3-specific KMS key for enhanced security
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Configure lifecycle rules for the ALB logs bucket
# This manages log retention, version cleanup, and incomplete multipart upload cleanup
# to optimize storage costs and maintain compliance requirements.
resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "alb_logs_lifecycle"
    status = "Enabled"

    filter {
      prefix = "alb-logs/"
    }

    expiration {
      days = var.alb_logs_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Block public access to the ALB logs bucket
# This ensures that log data remains private and secure, preventing unauthorized access
resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB bucket policy with proper conditions and dependencies
# This policy allows the ALB service to write access logs to the bucket while maintaining
# security through proper conditions and source account validation.
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket_ownership_controls.alb_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowALBPutObject"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/alb-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/${var.aws_region}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = "${data.aws_caller_identity.current.account_id}"
          }
          StringLike = {
            "aws:SourceArn" = "arn:aws:elasticloadbalancing:${var.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"
          }
        }
      },
      {
        Sid    = "AllowALBPutObjectAcl"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObjectAcl"
        Resource = "${aws_s3_bucket.alb_logs.arn}/alb-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/${var.aws_region}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid    = "AllowALBGetBucketAcl"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.alb_logs.arn
      }
    ]
  })
}

############################
# WAF Logs Bucket
############################

# S3 bucket for storing WAF (Web Application Firewall) logs
# This bucket receives detailed logs from the WAF, including blocked requests,
# allowed requests, and security events for monitoring and analysis.
resource "aws_s3_bucket" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = "aws-waf-logs-${var.cluster_name}-${random_id.bucket_suffix.hex}"

  # Handle existing buckets gracefully
  lifecycle {
    ignore_changes  = [bucket]
    prevent_destroy = false
  }

  tags = {
    Name        = "${var.cluster_name}-waf-logs"
    Purpose     = "WAF Logs"
    Environment = var.environment
  }
}

# Set object ownership for the WAF logs bucket
# This ensures that objects uploaded by the WAF service are owned by the bucket owner
resource "aws_s3_bucket_ownership_controls" "waf_logs" {
  count  = var.enable_waf ? 1 : 0
  bucket = aws_s3_bucket.waf_logs[0].id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Enable versioning for the WAF logs bucket
# This provides protection against accidental deletion and allows for point-in-time recovery
resource "aws_s3_bucket_versioning" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = aws_s3_bucket.waf_logs[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption for the WAF logs bucket
# Uses KMS encryption with the S3-specific KMS key for enhanced security
resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = aws_s3_bucket.waf_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Configure lifecycle rules for the WAF logs bucket
# This manages log retention, version cleanup, and incomplete multipart upload cleanup
# to optimize storage costs and maintain compliance requirements.
resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = aws_s3_bucket.waf_logs[0].id

  rule {
    id     = "waf_logs_lifecycle"
    status = "Enabled"

    filter {
      prefix = "waf-logs/"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Block public access to the WAF logs bucket
# This ensures that log data remains private and secure, preventing unauthorized access
resource "aws_s3_bucket_public_access_block" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = aws_s3_bucket.waf_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Fixed WAF bucket policy - allows official AWS log delivery paths
# This policy allows the WAF service to write logs to the bucket while maintaining
# security through proper conditions and source account validation.
resource "aws_s3_bucket_policy" "waf_logs" {
  count      = var.enable_waf ? 1 : 0
  bucket     = aws_s3_bucket.waf_logs[0].id
  depends_on = [aws_s3_bucket_ownership_controls.waf_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowWAFPutObject"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        # WAF writes to AWSLogs/<account-id>/WAFLogs/<region>/ - not custom prefixes
        Resource = "${aws_s3_bucket.waf_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = "${data.aws_caller_identity.current.account_id}"
          }
        }
      },
      {
        Sid    = "AllowWAFGetBucketAcl"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.waf_logs[0].arn
      }
    ]
  })
}

############################
# Loki Storage Bucket
############################

# S3 bucket for storing Loki logs and chunks
# This bucket stores all log data managed by Loki for long-term retention
resource "aws_s3_bucket" "loki_storage" {
  bucket = "${var.cluster_name}-loki-storage-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-loki-storage"
    Purpose     = "Loki Log Storage"
    Environment = var.environment
    Component   = "monitoring"
  }
}

# Set object ownership for the Loki storage bucket
# This ensures proper access control for Loki service account
resource "aws_s3_bucket_ownership_controls" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Enable versioning for the Loki storage bucket
# This provides protection against accidental deletion and allows for recovery
resource "aws_s3_bucket_versioning" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption for the Loki storage bucket
# Uses KMS encryption with the S3-specific KMS key for enhanced security
resource "aws_s3_bucket_server_side_encryption_configuration" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Configure lifecycle rules for the Loki storage bucket
# This manages log retention to optimize storage costs and maintain compliance
resource "aws_s3_bucket_lifecycle_configuration" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    id     = "loki_storage_lifecycle"
    status = "Enabled"

    # Transition older logs to Intelligent-Tiering after 30 days
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    # Transition to Glacier after 90 days
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # Delete after 720 days (30 days retention as configured in Loki)
    expiration {
      days = 720
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Block public access to the Loki storage bucket
# This ensures that log data remains private and secure
resource "aws_s3_bucket_public_access_block" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Loki bucket policy - allows Loki service account to read/write
# This policy is attached via IAM role, but this ensures bucket-level permissions
resource "aws_s3_bucket_policy" "loki_storage" {
  bucket     = aws_s3_bucket.loki_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.loki_storage]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLokiAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.loki_s3.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.loki_storage.arn,
          "${aws_s3_bucket.loki_storage.arn}/*"
        ]
      }
    ]
  })
}

############################
# Tempo Storage Bucket
############################

# S3 bucket for storing Tempo traces
# This bucket stores all trace data managed by Tempo for distributed tracing
resource "aws_s3_bucket" "tempo_storage" {
  bucket = "${var.cluster_name}-tempo-storage-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-tempo-storage"
    Purpose     = "Tempo Trace Storage"
    Environment = var.environment
    Component   = "monitoring"
  }
}

# Set object ownership for the Tempo storage bucket
resource "aws_s3_bucket_ownership_controls" "tempo_storage" {
  bucket = aws_s3_bucket.tempo_storage.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Enable versioning for the Tempo storage bucket
resource "aws_s3_bucket_versioning" "tempo_storage" {
  bucket = aws_s3_bucket.tempo_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption for the Tempo storage bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "tempo_storage" {
  bucket = aws_s3_bucket.tempo_storage.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Configure lifecycle rules for the Tempo storage bucket
resource "aws_s3_bucket_lifecycle_configuration" "tempo_storage" {
  bucket = aws_s3_bucket.tempo_storage.id

  rule {
    id     = "tempo_storage_lifecycle"
    status = "Enabled"

    # Transition older traces to Intelligent-Tiering after 30 days
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    # Delete after 90 days (trace retention)
    # Note: Expiration must be greater than all transition days, so we only use Intelligent-Tiering
    # and delete at 90 days to meet retention requirements
    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Block public access to the Tempo storage bucket
resource "aws_s3_bucket_public_access_block" "tempo_storage" {
  bucket = aws_s3_bucket.tempo_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Tempo bucket policy
resource "aws_s3_bucket_policy" "tempo_storage" {
  bucket     = aws_s3_bucket.tempo_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.tempo_storage]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowTempoAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.tempo_s3.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.tempo_storage.arn,
          "${aws_s3_bucket.tempo_storage.arn}/*"
        ]
      }
    ]
  })
}

############################
# Mimir Blocks Storage Bucket
############################

# S3 bucket for storing Mimir blocks (metrics data)
# This bucket stores all metrics blocks managed by Mimir for long-term retention
resource "aws_s3_bucket" "mimir_blocks_storage" {
  bucket = "${var.cluster_name}-mimir-blocks-storage-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-mimir-blocks-storage"
    Purpose     = "Mimir Blocks Storage"
    Environment = var.environment
    Component   = "monitoring"
  }
}

# Set object ownership for the Mimir blocks storage bucket
resource "aws_s3_bucket_ownership_controls" "mimir_blocks_storage" {
  bucket = aws_s3_bucket.mimir_blocks_storage.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Enable versioning for the Mimir blocks storage bucket
resource "aws_s3_bucket_versioning" "mimir_blocks_storage" {
  bucket = aws_s3_bucket.mimir_blocks_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption for the Mimir blocks storage bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "mimir_blocks_storage" {
  bucket = aws_s3_bucket.mimir_blocks_storage.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Configure lifecycle rules for the Mimir blocks storage bucket
resource "aws_s3_bucket_lifecycle_configuration" "mimir_blocks_storage" {
  bucket = aws_s3_bucket.mimir_blocks_storage.id

  rule {
    id     = "mimir_blocks_storage_lifecycle"
    status = "Enabled"

    # Transition older metrics to Intelligent-Tiering after 30 days
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    # Transition to Glacier after 90 days
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # Delete after 365 days (1 year retention)
    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Block public access to the Mimir blocks storage bucket
resource "aws_s3_bucket_public_access_block" "mimir_blocks_storage" {
  bucket = aws_s3_bucket.mimir_blocks_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Mimir blocks storage bucket policy
resource "aws_s3_bucket_policy" "mimir_blocks_storage" {
  bucket     = aws_s3_bucket.mimir_blocks_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.mimir_blocks_storage]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMimirAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.mimir_s3.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.mimir_blocks_storage.arn,
          "${aws_s3_bucket.mimir_blocks_storage.arn}/*"
        ]
      }
    ]
  })
}

############################
# Mimir Ruler Storage Bucket
############################

# S3 bucket for storing Mimir ruler data (recording rules and alerting rules)
# This bucket stores ruler state and rule evaluation results
resource "aws_s3_bucket" "mimir_ruler_storage" {
  bucket = "${var.cluster_name}-mimir-ruler-storage-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-mimir-ruler-storage"
    Purpose     = "Mimir Ruler Storage"
    Environment = var.environment
    Component   = "monitoring"
  }
}

# Set object ownership for the Mimir ruler storage bucket
resource "aws_s3_bucket_ownership_controls" "mimir_ruler_storage" {
  bucket = aws_s3_bucket.mimir_ruler_storage.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Enable versioning for the Mimir ruler storage bucket
resource "aws_s3_bucket_versioning" "mimir_ruler_storage" {
  bucket = aws_s3_bucket.mimir_ruler_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption for the Mimir ruler storage bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "mimir_ruler_storage" {
  bucket = aws_s3_bucket.mimir_ruler_storage.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Configure lifecycle rules for the Mimir ruler storage bucket
resource "aws_s3_bucket_lifecycle_configuration" "mimir_ruler_storage" {
  bucket = aws_s3_bucket.mimir_ruler_storage.id

  rule {
    id     = "mimir_ruler_storage_lifecycle"
    status = "Enabled"

    # Transition older data to Intelligent-Tiering after 30 days
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    # Transition to Glacier after 90 days
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # Delete after 365 days (1 year retention)
    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Block public access to the Mimir ruler storage bucket
resource "aws_s3_bucket_public_access_block" "mimir_ruler_storage" {
  bucket = aws_s3_bucket.mimir_ruler_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Mimir ruler storage bucket policy
resource "aws_s3_bucket_policy" "mimir_ruler_storage" {
  bucket     = aws_s3_bucket.mimir_ruler_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.mimir_ruler_storage]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMimirAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.mimir_s3.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.mimir_ruler_storage.arn,
          "${aws_s3_bucket.mimir_ruler_storage.arn}/*"
        ]
      }
    ]
  })
}

############################
# AlertManager State Storage Bucket
############################

# S3 bucket for storing AlertManager state
# This bucket stores AlertManager cluster state for high availability
resource "aws_s3_bucket" "alertmanager_storage" {
  bucket = "${var.cluster_name}-alertmanager-storage-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-alertmanager-storage"
    Purpose     = "AlertManager State Storage"
    Environment = var.environment
    Component   = "monitoring"
  }
}

# Set object ownership for the AlertManager storage bucket
resource "aws_s3_bucket_ownership_controls" "alertmanager_storage" {
  bucket = aws_s3_bucket.alertmanager_storage.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Enable versioning for the AlertManager storage bucket
resource "aws_s3_bucket_versioning" "alertmanager_storage" {
  bucket = aws_s3_bucket.alertmanager_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption for the AlertManager storage bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "alertmanager_storage" {
  bucket = aws_s3_bucket.alertmanager_storage.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Configure lifecycle rules for the AlertManager storage bucket
# AlertManager state is small but should be retained for disaster recovery
resource "aws_s3_bucket_lifecycle_configuration" "alertmanager_storage" {
  bucket = aws_s3_bucket.alertmanager_storage.id

  rule {
    id     = "alertmanager_storage_lifecycle"
    status = "Enabled"

    # Transition older state files to Intelligent-Tiering after 30 days
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    # Delete after 365 days (1 year retention for state files)
    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Block public access to the AlertManager storage bucket
resource "aws_s3_bucket_public_access_block" "alertmanager_storage" {
  bucket = aws_s3_bucket.alertmanager_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# AlertManager bucket policy
resource "aws_s3_bucket_policy" "alertmanager_storage" {
  bucket     = aws_s3_bucket.alertmanager_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.alertmanager_storage]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAlertManagerAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.alertmanager_s3.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.alertmanager_storage.arn,
          "${aws_s3_bucket.alertmanager_storage.arn}/*"
        ]
      }
    ]
  })
}
