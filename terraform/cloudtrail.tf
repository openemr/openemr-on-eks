# S3 bucket for CloudTrail
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.cluster_name}-cloudtrail-logs-${random_id.cloudtrail_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "${var.cluster_name}-cloudtrail-logs"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "random_id" "cloudtrail_suffix" {
  byte_length = 4
}

# Enable encryption on the bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudwatch.arn
    }
  }
}

# Block public access to the bucket
resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Attach bucket policy to CloudTrail bucket
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid : "AWSCloudTrailWrite",
        Effect : "Allow",
        Principal : {
          Service : "cloudtrail.amazonaws.com"
        },
        Action : "s3:PutObject",
        Resource : "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
        Condition : {
          StringEquals : {
            "s3:x-amz-acl" : "bucket-owner-full-control"
          }
        }
      },
      {
        Sid : "EnforceSSLRequestsOnly",
        Effect : "Deny",
        Principal : "*",
        Action : "s3:*",
        Resource : [
          "${aws_s3_bucket.cloudtrail.arn}",
          "${aws_s3_bucket.cloudtrail.arn}/*"
        ],
        Condition : {
          Bool : {
            "aws:SecureTransport" : "false"
          }
        }
      },
      {
        Sid : "AllowGetBucketAclForCloudTrail",
        Effect : "Allow",
        Principal : {
          Service : "cloudtrail.amazonaws.com"
        },
        Action : "s3:GetBucketAcl",
        Resource : "${aws_s3_bucket.cloudtrail.arn}"
      }
    ]
  })
}

# Versioning for CloudTrail S3 bucket
resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle policy for CloudTrail S3 bucket
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

# CloudTrail for logging
resource "aws_cloudtrail" "openemr" {
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
