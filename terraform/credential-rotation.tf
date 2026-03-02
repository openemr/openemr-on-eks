# =============================================================================
# CREDENTIAL ROTATION INFRASTRUCTURE
# =============================================================================
# Zero-downtime RDS credential rotation using a dual-slot (A/B) strategy.
# Secrets Manager holds two sets of application credentials; the rotation Job
# flips between them while keeping the application running.

# -----------------------------------------------------------------------------
# Secrets Manager: RDS slot secret (dual A/B credentials)
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "rds_slots" {
  name                    = "${var.cluster_name}/credential-rotation/rds-slots"
  description             = "Dual-slot (A/B) RDS credentials for zero-downtime rotation"
  kms_key_id              = aws_kms_key.rds.arn
  recovery_window_in_days = 0 # Immediate deletion on destroy — prevents "already scheduled for deletion" on recreate

  tags = {
    Name      = "${var.cluster_name}-rds-slots"
    Component = "credential-rotation"
  }
}

resource "aws_secretsmanager_secret_version" "rds_slots" {
  secret_id = aws_secretsmanager_secret.rds_slots.id
  secret_string = jsonencode({
    active_slot = "A"
    A = {
      username = "openemr_a"
      password = "PLACEHOLDER_SEEDED_BY_DEPLOY_SCRIPT"
      host     = aws_rds_cluster.openemr.endpoint
      port     = tostring(aws_rds_cluster.openemr.port)
      dbname   = "openemr"
    }
    B = {
      username = "openemr_b"
      password = "PLACEHOLDER_SEEDED_BY_DEPLOY_SCRIPT"
      host     = aws_rds_cluster.openemr.endpoint
      port     = tostring(aws_rds_cluster.openemr.port)
      dbname   = "openemr"
    }
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# -----------------------------------------------------------------------------
# Secrets Manager: RDS admin secret (master / dbadmin user)
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "rds_admin" {
  name                    = "${var.cluster_name}/credential-rotation/rds-admin"
  description             = "RDS admin (master) credentials for credential rotation management"
  kms_key_id              = aws_kms_key.rds.arn
  recovery_window_in_days = 0 # Immediate deletion on destroy — prevents "already scheduled for deletion" on recreate

  tags = {
    Name      = "${var.cluster_name}-rds-admin"
    Component = "credential-rotation"
  }
}

resource "aws_secretsmanager_secret_version" "rds_admin" {
  secret_id = aws_secretsmanager_secret.rds_admin.id
  secret_string = jsonencode({
    username = aws_rds_cluster.openemr.master_username
    password = random_password.db_password.result
    host     = aws_rds_cluster.openemr.endpoint
    port     = tostring(aws_rds_cluster.openemr.port)
    dbname   = "openemr"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# -----------------------------------------------------------------------------
# IAM Role for Credential Rotation Job (IRSA)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "credential_rotation" {
  name        = "${var.cluster_name}-credential-rotation-role"
  description = "IAM role for the credential rotation Kubernetes Job (IRSA)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:openemr:credential-rotation-sa"
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "${var.cluster_name}-credential-rotation-role"
    Component = "credential-rotation"
  }
}

resource "aws_iam_policy" "credential_rotation" {
  name        = "${var.cluster_name}-credential-rotation-policy"
  description = "Permissions for credential rotation: Secrets Manager read/write + KMS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerReadWrite"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage"
        ]
        Resource = [
          aws_secretsmanager_secret.rds_slots.arn,
          aws_secretsmanager_secret.rds_admin.arn
        ]
      },
      {
        Sid    = "KMSDecryptEncrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.rds.arn]
      }
    ]
  })

  tags = {
    Name      = "${var.cluster_name}-credential-rotation-policy"
    Component = "credential-rotation"
  }
}

resource "aws_iam_role_policy_attachment" "credential_rotation" {
  role       = aws_iam_role.credential_rotation.name
  policy_arn = aws_iam_policy.credential_rotation.arn
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "rds_slot_secret_arn" {
  description = "ARN of the dual-slot RDS credential secret"
  value       = aws_secretsmanager_secret.rds_slots.arn
}

output "rds_admin_secret_arn" {
  description = "ARN of the RDS admin credential secret"
  value       = aws_secretsmanager_secret.rds_admin.arn
}

output "credential_rotation_role_arn" {
  description = "ARN of the IAM role for the credential rotation Job"
  value       = aws_iam_role.credential_rotation.arn
}
