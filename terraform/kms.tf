# KMS Policy for all keys (except S3)
locals {
  kms_policy = {
    Version = "2012-10-17"
    Id      = "key-default-policy"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowEC2Use"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowElastiCacheServerlessUse"
        Effect = "Allow"
        Principal = {
          Service = "elasticache.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        Sid    = "AllowRDSUse"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        Sid    = "AllowElasticFileSystemUse"
        Effect = "Allow"
        Principal = {
          Service = "elasticfilesystem.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsUse"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      }
    ]
  }
}

# EKS KMS Key
resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = jsonencode(local.kms_policy)
  tags = {
    Name = "${var.cluster_name}-eks-encryption"
  }
}

# EFS KMS Key
resource "aws_kms_key" "efs" {
  description             = "EFS Encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = jsonencode(local.kms_policy)
  tags = {
    Name = "${var.cluster_name}-efs-encryption"
  }
}

# CloudWatch KMS Key
resource "aws_kms_key" "cloudwatch" {
  description             = "CloudWatch Logs Encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = jsonencode(local.kms_policy)
  tags = {
    Name = "${var.cluster_name}-cloudwatch-encryption"
  }
}

# RDS KMS Key
resource "aws_kms_key" "rds" {
  description             = "RDS Encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = jsonencode(local.kms_policy)
  tags = {
    Name = "${var.cluster_name}-rds-encryption"
  }
}

# ElastiCache KMS Key
resource "aws_kms_key" "elasticache" {
  description             = "ElastiCache Encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = jsonencode(local.kms_policy)
  tags = {
    Name = "${var.cluster_name}-elasticache-encryption"
  }
}

# S3 KMS Key - Special policy for S3 and log delivery services
resource "aws_kms_key" "s3" {
  description             = "S3 Encryption Key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow S3 Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      },
      # CRITICAL: Allow log delivery service to use KMS for ALB/WAF logs
      {
        Sid    = "AllowLogDeliveryUseOfKMS"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"    = "s3.${var.aws_region}.amazonaws.com"
            "aws:SourceAccount" = "${data.aws_caller_identity.current.account_id}"
          }
        }
      },
      # Additional principal for legacy ELB service account (if needed)
      {
        Sid    = "AllowELBServiceAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_elb_service_account.main.id}:root"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
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

# KMS Aliases
resource "aws_kms_alias" "s3" {
  name          = "alias/${var.cluster_name}-s3"
  target_key_id = aws_kms_key.s3.key_id
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_kms_alias" "efs" {
  name          = "alias/${var.cluster_name}-efs"
  target_key_id = aws_kms_key.efs.key_id
}

resource "aws_kms_alias" "cloudwatch" {
  name          = "alias/${var.cluster_name}-cloudwatch"
  target_key_id = aws_kms_key.cloudwatch.key_id
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.cluster_name}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_kms_alias" "elasticache" {
  name          = "alias/${var.cluster_name}-elasticache"
  target_key_id = aws_kms_key.elasticache.key_id
}
