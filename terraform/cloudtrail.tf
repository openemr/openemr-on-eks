# =============================================================================
# CLOUDTRAIL CONFIGURATION
# =============================================================================
# This configuration creates CloudTrail for auditing and monitoring AWS API calls
# and resource changes across the OpenEMR infrastructure. CloudTrail provides
# comprehensive logging for security, compliance, and troubleshooting.

# Unique suffix for CloudTrail resource names to ensure global uniqueness
resource "random_id" "cloudtrail_suffix" {
  byte_length = 4
}

# S3 bucket for storing CloudTrail logs
# This bucket receives detailed API call logs from CloudTrail for audit and compliance purposes
# tfsec:ignore:AVD-AWS-0089 This is a log destination bucket - logging it would be recursive
resource "aws_s3_bucket" "cloudtrail" {
  # checkov:skip=CKV_AWS_18: Access logging a CloudTrail log destination to itself would recurse.
  # checkov:skip=CKV_AWS_144: Multi-region CloudTrail, versioning, retention, and AWS Backup protect this centralized audit bucket.
  # checkov:skip=CKV2_AWS_62: No event-driven consumer exists for CloudTrail objects; CloudTrail delivery and validation are monitored directly.
  bucket        = "${var.cluster_name}-cloudtrail-logs-${random_id.cloudtrail_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "${var.cluster_name}-cloudtrail-logs"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Enable encryption on the CloudTrail S3 bucket
# Uses KMS encryption with the CloudWatch KMS key for enhanced security
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudwatch.arn
    }
  }
}

# Block public access to the CloudTrail S3 bucket
# This ensures that audit logs remain private and secure, preventing unauthorized access
resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudTrail S3 bucket policy
# This policy allows CloudTrail to write logs to the S3 bucket while maintaining
# security through proper conditions and enforcing SSL-only access
data "aws_iam_policy_document" "cloudtrail" {
  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "EnforceSSLRequestsOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "AllowGetBucketAclForCloudTrail"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail.json
}

# Enable versioning for the CloudTrail S3 bucket
# This provides protection against accidental deletion and allows for point-in-time recovery
resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle policy for the CloudTrail S3 bucket
# This manages log retention, version cleanup, and incomplete multipart upload cleanup
# to optimize storage costs and maintain compliance requirements
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    expiration {
      days = 365
    }

    filter {
      prefix = ""
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# CloudTrail configuration for comprehensive AWS API logging
# This CloudTrail captures all API calls and resource changes across the AWS account
# for security monitoring, compliance auditing, and operational troubleshooting
resource "aws_cloudtrail" "openemr" {
  # checkov:skip=CKV2_AWS_10: Audit logs use KMS-encrypted, versioned S3 with validation; real-time alerts are provided by the optional monitoring stack.
  name           = "${var.cluster_name}-cloudtrail"
  s3_bucket_name = aws_s3_bucket.cloudtrail.bucket

  enable_logging                = true
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  kms_key_id = aws_kms_key.cloudwatch.arn

  event_selector {
    read_write_type                  = "All"
    include_management_events        = true
    exclude_management_event_sources = []

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3"] # This will capture all S3 objects
    }
  }
}
