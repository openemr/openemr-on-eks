# =============================================================================
# KMS (KEY MANAGEMENT SERVICE) CONFIGURATION
# =============================================================================
# This configuration creates KMS keys for encrypting data across all AWS services
# with proper policies for service access and security compliance.

# KMS Policy for all keys (except S3) - Standard policy for most services
# This policy allows AWS services to use KMS keys for encryption operations
locals {
  kms_policy = {
    Version = "2012-10-17"
    Id      = "key-default-policy"
    Statement = [
      {
        # Root account access - allows account administrators to manage the key
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"        # All KMS operations
        Resource = "*"
      },
      {
        # CloudTrail service access - allows CloudTrail to encrypt logs
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",  # Generate data keys for encryption
          "kms:Encrypt",           # Encrypt data
          "kms:Decrypt",           # Decrypt data
          "kms:DescribeKey"        # Describe key metadata
        ]
        Resource = "*"
      },
      {
        # EC2 service access - allows EC2 instances to use KMS for encryption
        Sid    = "AllowEC2Use"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",           # Encrypt data
          "kms:Decrypt",           # Decrypt data
          "kms:ReEncrypt*",        # Re-encrypt data with different keys
          "kms:GenerateDataKey*",  # Generate data keys for encryption
          "kms:DescribeKey"        # Describe key metadata
        ]
        Resource = "*"
      },
      {
        # ElastiCache service access - allows ElastiCache to encrypt cache data
        Sid    = "AllowElastiCacheServerlessUse"
        Effect = "Allow"
        Principal = {
          Service = "elasticache.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        # RDS service access - allows RDS to encrypt database storage
        Sid    = "AllowRDSUse"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        # EFS service access - allows EFS to encrypt file system data
        Sid    = "AllowElasticFileSystemUse"
        Effect = "Allow"
        Principal = {
          Service = "elasticfilesystem.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        # CloudWatch Logs service access - allows CloudWatch to encrypt log data
        Sid    = "AllowCloudWatchLogsUse"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
        # Condition restricts access to log groups in the current account and region
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      }
    ]
  }
}

# =============================================================================
# KMS KEYS FOR SERVICE-SPECIFIC ENCRYPTION
# =============================================================================
# These keys provide encryption for different AWS services used by OpenEMR

# EKS KMS Key - Encrypts Kubernetes secrets and cluster data
resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption"      # Key description for identification
  deletion_window_in_days = 7                            # 7-day deletion window for safety
  enable_key_rotation     = true                         # Enable automatic key rotation
  policy                  = jsonencode(local.kms_policy) # Use standard KMS policy
  tags = {
    Name = "${var.cluster_name}-eks-encryption"
  }
}

# EFS KMS Key - Encrypts EFS file system data
resource "aws_kms_key" "efs" {
  description             = "EFS Encryption"             # Key description for identification
  deletion_window_in_days = 7                            # 7-day deletion window for safety
  enable_key_rotation     = true                         # Enable automatic key rotation
  policy                  = jsonencode(local.kms_policy) # Use standard KMS policy
  tags = {
    Name = "${var.cluster_name}-efs-encryption"
  }
}

# CloudWatch KMS Key - Encrypts CloudWatch log data
resource "aws_kms_key" "cloudwatch" {
  description             = "CloudWatch Logs Encryption"  # Key description for identification
  deletion_window_in_days = 7                             # 7-day deletion window for safety
  enable_key_rotation     = true                          # Enable automatic key rotation
  policy                  = jsonencode(local.kms_policy)  # Use standard KMS policy
  tags = {
    Name = "${var.cluster_name}-cloudwatch-encryption"
  }
}

# RDS KMS Key - Encrypts RDS Aurora database storage
resource "aws_kms_key" "rds" {
  description             = "RDS Encryption"             # Key description for identification
  deletion_window_in_days = 7                            # 7-day deletion window for safety
  enable_key_rotation     = true                         # Enable automatic key rotation
  policy                  = jsonencode(local.kms_policy) # Use standard KMS policy
  tags = {
    Name = "${var.cluster_name}-rds-encryption"
  }
}

# ElastiCache KMS Key - Encrypts ElastiCache data
resource "aws_kms_key" "elasticache" {
  description             = "ElastiCache Encryption"     # Key description for identification
  deletion_window_in_days = 7                            # 7-day deletion window for safety
  enable_key_rotation     = true                         # Enable automatic key rotation
  policy                  = jsonencode(local.kms_policy) # Use standard KMS policy
  tags = {
    Name = "${var.cluster_name}-elasticache-encryption"
  }
}

# S3 KMS Key - Special policy for S3 and log delivery services
# This key has a custom policy to support S3 bucket encryption and log delivery services
resource "aws_kms_key" "s3" {
  description             = "S3 Encryption Key"          # Key description for identification
  deletion_window_in_days = 7                            # 7-day deletion window for safety
  enable_key_rotation     = true                         # Enable automatic key rotation

  # Custom policy for S3 and log delivery services
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Root account access - allows account administrators to manage the key
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"        # All KMS operations
        Resource = "*"
      },
      {
        # S3 service access - allows S3 to encrypt bucket contents
        Sid    = "Allow S3 Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",          # Decrypt encrypted objects
          "kms:GenerateDataKey"   # Generate data keys for new objects
        ]
        Resource = "*"
      },
      {
        # CRITICAL: Allow log delivery service to use KMS for ALB/WAF logs
        # This is essential for encrypted log delivery from ALB and WAF to S3
        Sid    = "AllowLogDeliveryUseOfKMS"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",          # Decrypt log data
          "kms:GenerateDataKey",  # Generate data keys for log encryption
          "kms:Encrypt",          # Encrypt log data
          "kms:DescribeKey"       # Describe key metadata
        ]
        Resource = "*"
        # Condition restricts access to current account and region
        Condition = {
          StringEquals = {
            "kms:ViaService"    = "s3.${var.aws_region}.amazonaws.com"
            "aws:SourceAccount" = "${data.aws_caller_identity.current.account_id}"
          }
        }
      },
      {
        # Additional principal for legacy ELB service account (if needed)
        # This supports older ELB configurations that might use service accounts
        Sid    = "AllowELBServiceAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_elb_service_account.main.id}:root"
        }
        Action = [
          "kms:Decrypt",          # Decrypt data
          "kms:GenerateDataKey",  # Generate data keys
          "kms:DescribeKey"       # Describe key metadata
        ]
        Resource = "*"
        # Condition restricts access to S3 in current region
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-s3-encryption"
  }
}

# =============================================================================
# KMS KEY ALIASES
# =============================================================================
# These aliases provide human-readable names for KMS keys, making them easier to reference

# KMS Aliases for easy key identification and reference
# Aliases provide stable, human-readable names that can be used instead of key IDs

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.cluster_name}-s3"          # Human-readable alias for S3 key
  target_key_id = aws_kms_key.s3.key_id                   # Reference to the actual KMS key
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"         # Human-readable alias for EKS key
  target_key_id = aws_kms_key.eks.key_id                  # Reference to the actual KMS key
}

resource "aws_kms_alias" "efs" {
  name          = "alias/${var.cluster_name}-efs"         # Human-readable alias for EFS key
  target_key_id = aws_kms_key.efs.key_id                  # Reference to the actual KMS key
}

resource "aws_kms_alias" "cloudwatch" {
  name          = "alias/${var.cluster_name}-cloudwatch"  # Human-readable alias for CloudWatch key
  target_key_id = aws_kms_key.cloudwatch.key_id           # Reference to the actual KMS key
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.cluster_name}-rds"         # Human-readable alias for RDS key
  target_key_id = aws_kms_key.rds.key_id                  # Reference to the actual KMS key
}

resource "aws_kms_alias" "elasticache" {
  name          = "alias/${var.cluster_name}-elasticache" # Human-readable alias for ElastiCache key
  target_key_id = aws_kms_key.elasticache.key_id          # Reference to the actual KMS key
}
