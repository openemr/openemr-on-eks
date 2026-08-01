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
# tfsec:ignore:AVD-AWS-0089 This is a log destination bucket - logging it would be recursive
resource "aws_s3_bucket" "alb_logs" {
  # checkov:skip=CKV_AWS_18: Access logging an ALB log destination to itself would recurse.
  # checkov:skip=CKV_AWS_144: Versioning, lifecycle retention, and AWS Backup protect these reproducible access logs.
  # checkov:skip=CKV2_AWS_62: No event-driven consumer exists; ALB log delivery is monitored at the load balancer.
  # checkov:skip=CKV_AWS_145: ALB access logging supports SSE-S3, not SSE-KMS.
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
    object_ownership = "BucketOwnerEnforced"
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
# ALB access-log delivery supports only Amazon S3-managed keys (SSE-S3).
# trivy:ignore:AVD-AWS-0132 ALB access-log delivery does not support customer-managed KMS keys.
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Configure lifecycle rules for the ALB logs bucket
# This manages log retention, version cleanup, and incomplete multipart upload cleanup
# to optimize storage costs and maintain compliance requirements.
resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  # Rule for ALB logs with prefix
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
  }

  # Rule for aborting incomplete multipart uploads (applies to all objects)
  rule {
    id     = "abort_incomplete_multipart_uploads"
    status = "Enabled"

    filter {} # Empty filter applies to all objects

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
data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid     = "AllowALBPutObject"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.alb_logs.arn}/alb-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:elasticloadbalancing:${var.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"
      ]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]

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
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket_ownership_controls.alb_logs]
  policy     = data.aws_iam_policy_document.alb_logs.json
}

############################
# WAF Logs Bucket
############################

# S3 bucket for storing WAF (Web Application Firewall) logs
# This bucket receives detailed logs from the WAF, including blocked requests,
# allowed requests, and security events for monitoring and analysis.
# tfsec:ignore:AVD-AWS-0089 This is a log destination bucket - logging it would be recursive
resource "aws_s3_bucket" "waf_logs" {
  # checkov:skip=CKV_AWS_18: Access logging a WAF log destination to itself would recurse.
  # checkov:skip=CKV_AWS_144: Versioning, lifecycle retention, and AWS Backup protect these reproducible security logs.
  # checkov:skip=CKV2_AWS_62: No event-driven consumer exists; WAF log delivery is monitored by its logging configuration.
  # checkov:skip=CKV2_AWS_6: The matching conditional public-access-block resource enables all four controls.
  # checkov:skip=CKV2_AWS_61: The matching conditional lifecycle resource expires logs and incomplete uploads.
  # checkov:skip=CKV_AWS_145: The matching conditional encryption resource uses the S3 customer-managed KMS key.
  # checkov:skip=CKV_AWS_21: The matching conditional versioning resource enables versioning.
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
    object_ownership = "BucketOwnerEnforced"
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

  # Rule for WAF logs with prefix
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
  }

  # Rule for aborting incomplete multipart uploads (applies to all objects)
  rule {
    id     = "abort_incomplete_multipart_uploads"
    status = "Enabled"

    filter {} # Empty filter applies to all objects

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
locals {
  waf_logs_policy_bucket_arn = var.enable_waf ? aws_s3_bucket.waf_logs[0].arn : "arn:aws:s3:::disabled-waf-logs"
}

data "aws_iam_policy_document" "waf_logs" {
  statement {
    sid     = "AllowWAFPutObject"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    # WAF writes to AWSLogs/<account-id>/WAFLogs/<region>/ - not custom prefixes
    resources = [
      "${local.waf_logs_policy_bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid       = "AllowWAFGetBucketAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.waf_logs_policy_bucket_arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.waf_logs_policy_bucket_arn, "${local.waf_logs_policy_bucket_arn}/*"]

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
}

resource "aws_s3_bucket_policy" "waf_logs" {
  count      = var.enable_waf ? 1 : 0
  bucket     = aws_s3_bucket.waf_logs[0].id
  depends_on = [aws_s3_bucket_ownership_controls.waf_logs]
  # KICS cannot resolve the conditional WAF policy data source; its document above denies insecure transport.
  # kics-scan ignore-line
  policy = data.aws_iam_policy_document.waf_logs.json
}

############################
# Loki Storage Bucket
############################

# S3 bucket for storing Loki logs and chunks
# This bucket stores all log data managed by Loki for long-term retention
# tfsec:ignore:AVD-AWS-0089 Observability data storage - access controlled via IAM
resource "aws_s3_bucket" "loki_storage" {
  # checkov:skip=CKV_AWS_18: A separate access-log bucket would duplicate high-volume observability data; IAM and CloudTrail audit access.
  # checkov:skip=CKV_AWS_144: Versioning, lifecycle retention, and AWS Backup provide recovery without cross-region replication cost.
  # checkov:skip=CKV2_AWS_62: Loki manages object ingestion and retention directly; no S3 event consumer is required.
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
data "aws_iam_policy_document" "loki_storage" {
  statement {
    sid    = "AllowLokiAccess"
    effect = "Allow"
    # This role is scoped to Loki's dedicated bucket and cannot read other S3 data.
    # kics-scan ignore-line
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.loki_storage.arn, "${aws_s3_bucket.loki_storage.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.loki_s3.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.loki_storage.arn, "${aws_s3_bucket.loki_storage.arn}/*"]

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
}

resource "aws_s3_bucket_policy" "loki_storage" {
  bucket     = aws_s3_bucket.loki_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.loki_storage]
  policy     = data.aws_iam_policy_document.loki_storage.json
}

############################
# Tempo Storage Bucket
############################

# S3 bucket for storing Tempo traces
# This bucket stores all trace data managed by Tempo for distributed tracing
# tfsec:ignore:AVD-AWS-0089 Observability data storage - access controlled via IAM
resource "aws_s3_bucket" "tempo_storage" {
  # checkov:skip=CKV_AWS_18: A separate access-log bucket would duplicate high-volume observability data; IAM and CloudTrail audit access.
  # checkov:skip=CKV_AWS_144: Versioning, lifecycle retention, and AWS Backup provide recovery without cross-region replication cost.
  # checkov:skip=CKV2_AWS_62: Tempo manages object ingestion and retention directly; no S3 event consumer is required.
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
data "aws_iam_policy_document" "tempo_storage" {
  statement {
    sid    = "AllowTempoAccess"
    effect = "Allow"
    # This role is scoped to Tempo's dedicated bucket and cannot read other S3 data.
    # kics-scan ignore-line
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.tempo_storage.arn, "${aws_s3_bucket.tempo_storage.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.tempo_s3.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tempo_storage.arn, "${aws_s3_bucket.tempo_storage.arn}/*"]

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
}

resource "aws_s3_bucket_policy" "tempo_storage" {
  bucket     = aws_s3_bucket.tempo_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.tempo_storage]
  policy     = data.aws_iam_policy_document.tempo_storage.json
}

############################
# Mimir Blocks Storage Bucket
############################

# S3 bucket for storing Mimir blocks (metrics data)
# This bucket stores all metrics blocks managed by Mimir for long-term retention
# tfsec:ignore:AVD-AWS-0089 Observability data storage - access controlled via IAM
resource "aws_s3_bucket" "mimir_blocks_storage" {
  # checkov:skip=CKV_AWS_18: A separate access-log bucket would duplicate high-volume observability data; IAM and CloudTrail audit access.
  # checkov:skip=CKV_AWS_144: Versioning, lifecycle retention, and AWS Backup provide recovery without cross-region replication cost.
  # checkov:skip=CKV2_AWS_62: Mimir manages block ingestion and retention directly; no S3 event consumer is required.
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
data "aws_iam_policy_document" "mimir_blocks_storage" {
  statement {
    sid    = "AllowMimirAccess"
    effect = "Allow"
    # This role is scoped to Mimir's blocks bucket and cannot read other S3 data.
    # kics-scan ignore-line
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.mimir_blocks_storage.arn,
      "${aws_s3_bucket.mimir_blocks_storage.arn}/*"
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.mimir_s3.arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.mimir_blocks_storage.arn,
      "${aws_s3_bucket.mimir_blocks_storage.arn}/*"
    ]

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
}

resource "aws_s3_bucket_policy" "mimir_blocks_storage" {
  bucket     = aws_s3_bucket.mimir_blocks_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.mimir_blocks_storage]
  policy     = data.aws_iam_policy_document.mimir_blocks_storage.json
}

############################
# Mimir Ruler Storage Bucket
############################

# S3 bucket for storing Mimir ruler data (recording rules and alerting rules)
# This bucket stores ruler state and rule evaluation results
# tfsec:ignore:AVD-AWS-0089 Observability data storage - access controlled via IAM
resource "aws_s3_bucket" "mimir_ruler_storage" {
  # checkov:skip=CKV_AWS_18: A separate access-log bucket would duplicate observability state; IAM and CloudTrail audit access.
  # checkov:skip=CKV_AWS_144: Versioning, lifecycle retention, and AWS Backup provide recovery without cross-region replication cost.
  # checkov:skip=CKV2_AWS_62: Mimir manages ruler state directly; no S3 event consumer is required.
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
data "aws_iam_policy_document" "mimir_ruler_storage" {
  statement {
    sid    = "AllowMimirAccess"
    effect = "Allow"
    # This role is scoped to Mimir's ruler bucket and cannot read other S3 data.
    # kics-scan ignore-line
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.mimir_ruler_storage.arn,
      "${aws_s3_bucket.mimir_ruler_storage.arn}/*"
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.mimir_s3.arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.mimir_ruler_storage.arn,
      "${aws_s3_bucket.mimir_ruler_storage.arn}/*"
    ]

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
}

resource "aws_s3_bucket_policy" "mimir_ruler_storage" {
  bucket     = aws_s3_bucket.mimir_ruler_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.mimir_ruler_storage]
  policy     = data.aws_iam_policy_document.mimir_ruler_storage.json
}

############################
# AlertManager State Storage Bucket
############################

# S3 bucket for storing AlertManager state
# This bucket stores AlertManager cluster state for high availability
# tfsec:ignore:AVD-AWS-0089 Observability data storage - access controlled via IAM
resource "aws_s3_bucket" "alertmanager_storage" {
  # checkov:skip=CKV_AWS_18: A separate access-log bucket would duplicate observability state; IAM and CloudTrail audit access.
  # checkov:skip=CKV_AWS_144: Versioning, lifecycle retention, and AWS Backup provide recovery without cross-region replication cost.
  # checkov:skip=CKV2_AWS_62: Alertmanager manages state directly; no S3 event consumer is required.
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

# Mimir's embedded Alertmanager bucket policy
data "aws_iam_policy_document" "alertmanager_storage" {
  statement {
    sid    = "AllowMimirAlertManagerAccess"
    effect = "Allow"
    # This role is scoped to Mimir's Alertmanager bucket and cannot read other S3 data.
    # kics-scan ignore-line
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.alertmanager_storage.arn,
      "${aws_s3_bucket.alertmanager_storage.arn}/*"
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.mimir_s3.arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alertmanager_storage.arn,
      "${aws_s3_bucket.alertmanager_storage.arn}/*"
    ]

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
}

resource "aws_s3_bucket_policy" "alertmanager_storage" {
  bucket     = aws_s3_bucket.alertmanager_storage.id
  depends_on = [aws_s3_bucket_ownership_controls.alertmanager_storage]
  policy     = data.aws_iam_policy_document.alertmanager_storage.json
}
