# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "openemr" {
  name       = "${var.cluster_name}-cache-subnet"
  subnet_ids = module.vpc.private_subnets
}

# ElastiCache Security Group - Updated for Auto Mode
resource "aws_security_group" "elasticache" {
  name_prefix = "${var.cluster_name}-cache-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 6379 # Standard Redis port
    to_port   = 6379
    protocol  = "tcp"
    # Allow access from EKS cluster security group for Auto Mode
    security_groups = [module.eks.cluster_security_group_id]
  }

  # Fallback rule for VPC CIDR (in case cluster security group doesn't cover all cases)
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.cluster_name}-cache-sg"
  }
}

# ElastiCache Serverless
resource "aws_elasticache_serverless_cache" "openemr" {
  engine = "valkey"
  name   = "${var.cluster_name}-valkey-serverless"

  cache_usage_limits {
    data_storage {
      maximum = var.redis_max_data_storage
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.redis_max_ecpu_per_second
    }
  }

  daily_snapshot_time      = "03:00"
  description              = "Valkey Serverless for OpenEMR"
  kms_key_id               = aws_kms_key.elasticache.arn
  major_engine_version     = "8"
  security_group_ids       = [aws_security_group.elasticache.id]
  snapshot_retention_limit = 7
  subnet_ids               = module.vpc.private_subnets
  user_group_id            = aws_elasticache_user_group.openemr.user_group_id

  # Ensure EKS cluster is created first for security group reference
  depends_on = [module.eks]

  tags = {
    Name = "${var.cluster_name}-valkey-serverless"
  }
}

# ElastiCache OpenEMR User for Serverless
resource "aws_elasticache_user" "openemr" {
  user_id       = "openemr-user"
  user_name     = "openemr"
  access_string = "on ~* &* +@all"
  engine        = "valkey"
  passwords     = [random_password.redis_openemr_password.result]

  tags = {
    Name = "${var.cluster_name}-openemr-valkey-user"
  }
}

# ElastiCache User Group for Serverless
resource "aws_elasticache_user_group" "openemr" {
  engine        = "valkey"
  user_group_id = "${var.cluster_name}-valkey-user-group"
  user_ids      = [aws_elasticache_user.openemr.user_id]

  tags = {
    Name = "${var.cluster_name}-valkey-user-group"
  }
}

# Random password for Valkey - alphanumeric only (no punctuation or spaces)
resource "random_password" "redis_openemr_password" {
  length  = 32
  special = false
  upper   = true
  lower   = true
  numeric = true
}

# Random password for Default Valkey User - alphanumeric only (no punctuation or spaces)
resource "random_password" "redis_default_password" {
  length  = 32
  special = false
  upper   = true
  lower   = true
  numeric = true
}

# CloudWatch Log Group for Valkey
resource "aws_cloudwatch_log_group" "valkey" {
  name              = "/aws/elasticache/${var.cluster_name}-valkey"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.elasticache.arn
}
