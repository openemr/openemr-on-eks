# S3 Storage Configuration
# This file defines the S3 buckets used for storing ALB access logs and WAF logs,
# providing centralized logging capabilities for the OpenEMR deployment.

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
    ignore_changes = [bucket]
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
