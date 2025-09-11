# Data sources
data "aws_elb_service_account" "main" {}

# Random suffix for bucket names
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

############################
# ALB Access Logs Bucket
############################

resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.cluster_name}-alb-logs-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-alb-logs"
    Purpose     = "ALB Access Logs"
    Environment = var.environment
  }
}

# CRITICAL: Set object ownership before applying bucket policies
resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

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

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB bucket policy with proper conditions and dependencies
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

resource "aws_s3_bucket" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = "aws-waf-logs-${var.cluster_name}-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.cluster_name}-waf-logs"
    Purpose     = "WAF Logs"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_ownership_controls" "waf_logs" {
  count  = var.enable_waf ? 1 : 0
  bucket = aws_s3_bucket.waf_logs[0].id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_versioning" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = aws_s3_bucket.waf_logs[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

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

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  count = var.enable_waf ? 1 : 0

  bucket = aws_s3_bucket.waf_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Fixed WAF bucket policy - allows official AWS log delivery paths
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
