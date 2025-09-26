# =============================================================================
# ELASTICACHE VALKEY SERVERLESS CONFIGURATION
# =============================================================================
# This configuration creates an ElastiCache Valkey Serverless cache for OpenEMR
# with high availability, encryption, and user authentication features.

# ElastiCache Subnet Group for cache deployment
# Defines which subnets the ElastiCache cluster can be deployed across
resource "aws_elasticache_subnet_group" "openemr" {
  # Unique name with random suffix to prevent naming conflicts
  name       = "${var.cluster_name}-cache-subnet-${random_id.global_suffix.hex}"
  # Deploy cache cluster across private subnets for security
  subnet_ids = module.vpc.private_subnets
}

# ElastiCache Security Group for cache network access control
# Restricts cache access to EKS cluster nodes and provides fallback access
resource "aws_security_group" "elasticache" {
  name_prefix = "${var.cluster_name}-cache-"  # Security group name with prefix
  vpc_id      = module.vpc.vpc_id             # Associate with the VPC

  # Primary ingress rule: Allow Redis/Valkey connections from EKS cluster
  ingress {
    from_port = 6379                          # Standard Redis/Valkey port
    to_port   = 6379                          # Standard Redis/Valkey port
    protocol  = "tcp"                         # TCP protocol
    # Allow access from EKS cluster security group for Auto Mode
    security_groups = [module.eks.cluster_security_group_id]  # EKS cluster security group
  }

  # Fallback ingress rule: Allow Redis/Valkey connections from VPC CIDR
  # This provides backup access in case cluster security group doesn't cover all cases
  ingress {
    from_port   = 6379                        # Standard Redis/Valkey port
    to_port     = 6379                        # Standard Redis/Valkey port
    protocol    = "tcp"                       # TCP protocol
    cidr_blocks = [var.vpc_cidr]              # Allow access from entire VPC CIDR
  }

  tags = {
    Name = "${var.cluster_name}-cache-sg"
  }
}

# ElastiCache Serverless Cache - Main cache cluster for OpenEMR
# Valkey Serverless provides automatic scaling and high availability for caching
resource "aws_elasticache_serverless_cache" "openemr" {
  engine = "valkey"                                                                # Valkey engine (Redis-compatible)
  name   = "${var.cluster_name}-valkey-serverless-${random_id.global_suffix.hex}"  # Unique cache name

  # Cache usage limits for cost control and performance
  # These limits define the maximum resources the cache can consume
  cache_usage_limits {
    data_storage {
      maximum = var.redis_max_data_storage  # Maximum storage capacity (default: 20 GB)
      unit    = "GB"                        # Storage unit in gigabytes
    }
    ecpu_per_second {
      maximum = var.redis_max_ecpu_per_second  # Maximum ECPUs per second (default: 5000)
    }
  }

  # Backup and snapshot configuration
  daily_snapshot_time      = "03:00"                      # Daily snapshot time (UTC)
  snapshot_retention_limit = 7                            # Retain snapshots for 7 days

  # Cache configuration and security
  description              = "Valkey Serverless for OpenEMR"                   # Cache description
  kms_key_id               = aws_kms_key.elasticache.arn                       # KMS key for encryption
  major_engine_version     = "8"                                               # Valkey major version
  security_group_ids       = [aws_security_group.elasticache.id]               # Security group for network access
  subnet_ids               = module.vpc.private_subnets                        # Private subnets for deployment
  user_group_id            = aws_elasticache_user_group.openemr.user_group_id  # User group for authentication

  # Dependency management - ensure EKS cluster is created first
  # EKS cluster must exist for security group reference
  depends_on = [module.eks]

  tags = {
    Name = "${var.cluster_name}-valkey-serverless"
  }
}

# =============================================================================
# ELASTICACHE USER AUTHENTICATION CONFIGURATION
# =============================================================================
# These resources configure user authentication and access control for the cache

# ElastiCache OpenEMR User for Serverless authentication
# This user provides application-level access to the cache with specific permissions
resource "aws_elasticache_user" "openemr" {
  user_id       = "${var.cluster_name}-openemr-user"               # Unique user identifier
  user_name     = "openemr"                                        # Username for cache authentication
  access_string = "on ~* &* +@all"                                 # Full access permissions for OpenEMR
  engine        = "valkey"                                         # Valkey engine for user
  passwords     = [random_password.redis_openemr_password.result]  # Secure password

  tags = {
    Name = "${var.cluster_name}-openemr-valkey-user"
  }
}

# ElastiCache User Group for Serverless access control
# User groups provide a way to manage multiple users and their permissions
resource "aws_elasticache_user_group" "openemr" {
  engine        = "valkey"                                                                                # Valkey engine
  user_group_id = "${var.cluster_name}-valkey-user-group-${random_id.elasticache_user_group_suffix.hex}"  # Unique group ID
  user_ids      = [aws_elasticache_user.openemr.user_id]                                                  # Users in this group

  tags = {
    Name = "${var.cluster_name}-valkey-user-group"
  }
}

# =============================================================================
# SECURITY AND MONITORING CONFIGURATION
# =============================================================================
# These resources provide secure password generation and logging for the cache

# Random password generator for OpenEMR Valkey user
# Generates a secure password with alphanumeric characters only (no special characters)
resource "random_password" "redis_openemr_password" {
  length  = 32        # 32 character password for high entropy
  special = false     # No special characters to avoid compatibility issues
  upper   = true      # Include uppercase letters
  lower   = true      # Include lowercase letters
  numeric = true      # Include numbers
}

# Random password generator for Default Valkey User
# Generates a secure password with alphanumeric characters only (no special characters)
resource "random_password" "redis_default_password" {
  length  = 32        # 32 character password for high entropy
  special = false     # No special characters to avoid compatibility issues
  upper   = true      # Include uppercase letters
  lower   = true      # Include lowercase letters
  numeric = true      # Include numbers
}

# Random ID generator for ElastiCache user group uniqueness
# Ensures user group names are unique across deployments
resource "random_id" "elasticache_user_group_suffix" {
  byte_length = 4  # 4 bytes = 8 hex characters for sufficient uniqueness
}

# CloudWatch Log Group for Valkey cache logging
# Provides centralized logging for cache operations and troubleshooting
resource "aws_cloudwatch_log_group" "valkey" {
  name              = "/aws/elasticache/${var.cluster_name}-valkey"  # Log group name
  retention_in_days = 30                                             # 30 days log retention
  kms_key_id        = aws_kms_key.elasticache.arn                    # KMS key for log encryption
}
