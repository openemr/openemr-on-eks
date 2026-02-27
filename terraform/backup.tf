# =============================================================================
# AWS BACKUP CONFIGURATION
# =============================================================================
# This configuration creates a comprehensive AWS Backup setup for automatic
# backups of all critical infrastructure components with encryption, retention
# policies, and scheduled backup plans.
#
# AWS Backup provides centralized backup management for:
# - S3 buckets (ALB logs, WAF logs, Loki storage, CloudTrail logs)
# - EFS file systems (application data and configuration)
# - RDS Aurora clusters (database snapshots)
# - EKS clusters (using AWS Backup support for EKS)
#
# Encryption: All backups are encrypted using a dedicated KMS key defined in
# kms.tf (aws_kms_key.backup). This key has a custom policy to allow AWS Backup
# service access for encryption operations.
#
# Reference: https://docs.aws.amazon.com/prescriptive-guidance/latest/backup-recovery/aws-backup.html

# =============================================================================
# DATA SOURCES FOR AWS BACKUP
# =============================================================================
# Data sources retrieve information from existing AWS resources for use in
# backup configurations.

# Get EKS cluster ARN for backup selection
# The EKS cluster ARN is required for AWS Backup to identify the cluster
data "aws_eks_cluster" "openemr" {
  name       = var.cluster_name
  depends_on = [module.eks]
}

# =============================================================================
# AWS BACKUP VAULT
# =============================================================================
# Backup vault provides a centralized location for storing and organizing backups
# with encryption, access control, and backup plan associations.

# AWS Backup Vault - Centralized storage for all backups
# Uses global suffix for uniqueness (backup vault names must be unique within account/region)
resource "aws_backup_vault" "openemr" {
  name        = "${var.cluster_name}-backup-vault-${random_id.global_suffix.hex}" # Backup vault name with global suffix
  kms_key_arn = aws_kms_key.backup.arn                                            # KMS key for encryption

  tags = {
    Name        = "${var.cluster_name}-backup-vault"
    Purpose     = "AWS Backup Storage"
    Environment = var.environment
  }
}

# =============================================================================
# AWS BACKUP PLANS
# =============================================================================
# Backup plans define when backups are created and how long they are retained.
# Three backup plans are created:
# - Daily: Frequent backups for recent recovery needs (EFS backup transitioned to cold storage after 30 days)
# - Weekly: Weekly backups for intermediate recovery needs (EFS backup transitioned to cold storage after 90 days)
# - Monthly: Monthly backups for long-term retention (EFS backup transitioned to cold storage after 180 days)
# All of these plans create backups that last 7 years by default.
# You can alter the retention of each of these plans individually by changing "2555" to a number of days you'd prefer.

# Daily Backup Plan - Creates backups every day
# Uses global suffix for uniqueness and consistency with other resources
resource "aws_backup_plan" "daily" {
  name = "${var.cluster_name}-backup-plan-daily-${random_id.global_suffix.hex}"

  # Daily backup rule - runs every day at 2:00 AM UTC
  rule {
    rule_name                = "daily-backup-rule"
    target_vault_name        = aws_backup_vault.openemr.name
    schedule                 = "cron(0 2 * * ? *)" # Daily at 2:00 AM UTC
    enable_continuous_backup = false

    # Lifecycle configuration - transition to cold storage after 30 days, delete after 7 years
    lifecycle {
      cold_storage_after = 30   # Move to cold storage after 30 days
      delete_after       = 2555 # Delete after 7 years (365 * 7 = 2555 days)
    }

    # Recovery point tags for backup organization
    recovery_point_tags = {
      BackupPlan  = "daily"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name        = "${var.cluster_name}-backup-plan-daily"
    Purpose     = "Daily Backups"
    Environment = var.environment
  }
}

# Weekly Backup Plan - Creates backups every week
# Uses global suffix for uniqueness and consistency with other resources
resource "aws_backup_plan" "weekly" {
  name = "${var.cluster_name}-backup-plan-weekly-${random_id.global_suffix.hex}"

  # Weekly backup rule - runs every Sunday at 3:00 AM UTC
  rule {
    rule_name                = "weekly-backup-rule"
    target_vault_name        = aws_backup_vault.openemr.name
    schedule                 = "cron(0 3 ? * SUN *)" # Weekly on Sunday at 3:00 AM UTC
    enable_continuous_backup = false

    # Lifecycle configuration - transition to cold storage after 90 days, delete after 7 years
    lifecycle {
      cold_storage_after = 90   # Move to cold storage after 90 days
      delete_after       = 2555 # Delete after 7 years
    }

    # Recovery point tags for backup organization
    recovery_point_tags = {
      BackupPlan  = "weekly"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name        = "${var.cluster_name}-backup-plan-weekly"
    Purpose     = "Weekly Backups"
    Environment = var.environment
  }
}

# Monthly Backup Plan - Creates backups every month
# Uses global suffix for uniqueness and consistency with other resources
resource "aws_backup_plan" "monthly" {
  name = "${var.cluster_name}-backup-plan-monthly-${random_id.global_suffix.hex}"

  # Monthly backup rule - runs on the first day of each month at 4:00 AM UTC
  rule {
    rule_name                = "monthly-backup-rule"
    target_vault_name        = aws_backup_vault.openemr.name
    schedule                 = "cron(0 4 1 * ? *)" # Monthly on the 1st at 4:00 AM UTC
    enable_continuous_backup = false

    # Lifecycle configuration - transition to cold storage after 180 days, delete after 7 years
    lifecycle {
      cold_storage_after = 180  # Move to cold storage after 180 days
      delete_after       = 2555 # Delete after 7 years
    }

    # Recovery point tags for backup organization
    recovery_point_tags = {
      BackupPlan  = "monthly"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name        = "${var.cluster_name}-backup-plan-monthly"
    Purpose     = "Monthly Backups"
    Environment = var.environment
  }
}

# =============================================================================
# AWS BACKUP SELECTIONS
# =============================================================================
# Backup selections define which resources are backed up by each backup plan.
# Resources are explicitly selected using resource ARNs to ensure all critical
# resources are included in the backup plans.

# Daily Backup Selection - Selects all critical resources for daily backups
# Uses global suffix for uniqueness and consistency with other resources
resource "aws_backup_selection" "daily" {
  name         = "${var.cluster_name}-backup-selection-daily-${random_id.global_suffix.hex}"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.daily.id

  # Resources to backup - all S3 buckets, EFS, RDS, and EKS
  # Note: We explicitly list resources here instead of using tags
  # to ensure all critical resources are backed up
  resources = concat(
    # S3 buckets
    [
      aws_s3_bucket.alb_logs.arn,
      aws_s3_bucket.loki_storage.arn,
      aws_s3_bucket.cloudtrail.arn
    ],
    # Conditionally include WAF logs bucket if WAF is enabled
    var.enable_waf ? [aws_s3_bucket.waf_logs[0].arn] : [],
    # EFS file system
    [aws_efs_file_system.openemr.arn],
    # RDS cluster
    [aws_rds_cluster.openemr.arn],
    # EKS cluster
    [data.aws_eks_cluster.openemr.arn]
  )
}

# Weekly Backup Selection - Selects all critical resources for weekly backups
# Uses global suffix for uniqueness and consistency with other resources
resource "aws_backup_selection" "weekly" {
  name         = "${var.cluster_name}-backup-selection-weekly-${random_id.global_suffix.hex}"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.weekly.id

  # Resources to backup - same as daily
  # Note: We explicitly list resources here instead of using tags
  # to ensure all critical resources are backed up
  resources = concat(
    # S3 buckets
    [
      aws_s3_bucket.alb_logs.arn,
      aws_s3_bucket.loki_storage.arn,
      aws_s3_bucket.cloudtrail.arn
    ],
    # Conditionally include WAF logs bucket if WAF is enabled
    var.enable_waf ? [aws_s3_bucket.waf_logs[0].arn] : [],
    # EFS file system
    [aws_efs_file_system.openemr.arn],
    # RDS cluster
    [aws_rds_cluster.openemr.arn],
    # EKS cluster
    [data.aws_eks_cluster.openemr.arn]
  )
}

# Monthly Backup Selection - Selects all critical resources for monthly backups
# Uses global suffix for uniqueness and consistency with other resources
resource "aws_backup_selection" "monthly" {
  name         = "${var.cluster_name}-backup-selection-monthly-${random_id.global_suffix.hex}"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.monthly.id

  # Resources to backup - same as daily and weekly
  # Note: We explicitly list resources here instead of using tags
  # to ensure all critical resources are backed up
  resources = concat(
    # S3 buckets
    [
      aws_s3_bucket.alb_logs.arn,
      aws_s3_bucket.loki_storage.arn,
      aws_s3_bucket.cloudtrail.arn
    ],
    # Conditionally include WAF logs bucket if WAF is enabled
    var.enable_waf ? [aws_s3_bucket.waf_logs[0].arn] : [],
    # EFS file system
    [aws_efs_file_system.openemr.arn],
    # RDS cluster
    [aws_rds_cluster.openemr.arn],
    # EKS cluster
    [data.aws_eks_cluster.openemr.arn]
  )
}

# =============================================================================
# IAM ROLE FOR AWS BACKUP
# =============================================================================
# IAM role that AWS Backup uses to perform backup and restore operations.
# This role must have permissions to access the resources being backed up.

# IAM Role for AWS Backup - Service role for backup operations
# Uses global suffix for uniqueness (IAM role names must be unique within AWS account)
resource "aws_iam_role" "backup" {
  name        = "${var.cluster_name}-backup-role-${random_id.global_suffix.hex}"
  description = "IAM role for AWS Backup to perform backup and restore operations"

  # Trust policy allowing AWS Backup service to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        # Condition restricts access to current account
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-backup-role"
    Purpose     = "AWS Backup Service Role"
    Environment = var.environment
  }
}

# Attach AWS managed policy for AWS Backup service role
# This policy provides the necessary permissions for AWS Backup operations
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Attach AWS managed policy for AWS Backup restore operations
# This policy provides the necessary permissions for restore operations
resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Additional IAM policy for EKS backup permissions
# EKS backup requires additional permissions beyond the standard backup policies
# Uses global suffix for uniqueness (IAM policy names must be unique within AWS account)
resource "aws_iam_role_policy" "backup_eks" {
  name = "${var.cluster_name}-backup-eks-policy-${random_id.global_suffix.hex}"
  role = aws_iam_role.backup.id

  # Policy document for EKS backup permissions
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:DescribeNodegroup",
          "eks:ListNodegroups"
        ]
        Resource = data.aws_eks_cluster.openemr.arn
      }
    ]
  })
}

