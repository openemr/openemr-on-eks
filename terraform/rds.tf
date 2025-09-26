# =============================================================================
# RDS AURORA MYSQL CONFIGURATION
# =============================================================================
# This configuration creates an Aurora MySQL Serverless V2 cluster for OpenEMR
# with high availability, encryption, monitoring, and compliance features.

# RDS Subnet Group for Aurora cluster deployment
# Defines which subnets the Aurora cluster can be deployed across
resource "aws_db_subnet_group" "openemr" {
  # Unique name with random suffix to prevent naming conflicts
  name       = "${var.cluster_name}-db-subnet-group-${random_id.global_suffix.hex}"
  # Deploy Aurora cluster across private subnets for security
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "${var.cluster_name}-db-subnet-group"
  }
}

# RDS Security Group for Aurora cluster network access control
# Restricts database access to resources within the VPC
resource "aws_security_group" "rds" {
  name_prefix = "${var.cluster_name}-rds-"  # Security group name with prefix
  vpc_id      = module.vpc.vpc_id           # Associate with the VPC

  # Ingress rule: Allow MySQL/Aurora connections from VPC
  ingress {
    from_port = 3306                         # MySQL/Aurora port
    to_port   = 3306                         # MySQL/Aurora port
    protocol  = "tcp"                        # TCP protocol
    # Auto Mode nodes will be in the cluster security group
    cidr_blocks = [var.vpc_cidr]             # Allow access from entire VPC CIDR
  }

  # Egress rule: Allow all outbound traffic (required for Aurora operations)
  egress {
    from_port   = 0                          # All ports
    to_port     = 0                          # All ports
    protocol    = "-1"                       # All protocols
    cidr_blocks = ["0.0.0.0/0"]              # All destinations
  }

  tags = {
    Name = "${var.cluster_name}-rds-sg"
  }
}

# Aurora Serverless V2 Cluster - Main database cluster for OpenEMR
# Aurora Serverless V2 provides automatic scaling and high availability
resource "aws_rds_cluster" "openemr" {
  # Unique cluster identifier with random suffix to prevent naming conflicts
  cluster_identifier = "${var.cluster_name}-aurora-${random_id.global_suffix.hex}"

  # Aurora MySQL engine configuration
  engine         = "aurora-mysql"              # Aurora MySQL engine
  engine_version = var.rds_engine_version      # MySQL version (default: 8.0.mysql_aurora.3.10.0)

  # Master user credentials for database access
  master_username = "openemr"                          # Master username
  master_password = random_password.db_password.result # Secure random password

  # Network and security configuration
  vpc_security_group_ids = [aws_security_group.rds.id]       # Security group for network access
  db_subnet_group_name   = aws_db_subnet_group.openemr.name  # Subnet group for deployment

  # Backup and maintenance configuration
  backup_retention_period      = 30                    # 30 days backup retention
  preferred_backup_window      = "03:00-04:00"         # Backup window (UTC)
  preferred_maintenance_window = "sun:04:00-sun:05:00" # Maintenance window (UTC)

  # Regulatory compliance and security features
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]  # Export logs to CloudWatch
  storage_encrypted               = true                               # Encrypt storage at rest
  kms_key_id                      = aws_kms_key.rds.arn                # KMS key for encryption

  # Serverless V2 scaling configuration
  # Aurora automatically scales between min and max capacity based on demand
  serverlessv2_scaling_configuration {
    max_capacity = var.aurora_max_capacity  # Maximum scaling capacity (default: 16 ACUs)
    min_capacity = var.aurora_min_capacity  # Minimum scaling capacity (default: 0.5 ACUs)
  }

  # Data protection and snapshot configuration
  deletion_protection       = var.rds_deletion_protection  # Prevent accidental deletion
  skip_final_snapshot       = false                        # Create final snapshot on deletion
  final_snapshot_identifier = "${var.cluster_name}-aurora-final-snapshot-${formatdate("YYYYMMDD-HHMM", timestamp())}"

  # Lifecycle management for graceful handling of existing resources
  lifecycle {
    ignore_changes = [cluster_identifier, final_snapshot_identifier]  # Ignore identifier changes
    prevent_destroy = false                                           # Allow destruction for testing
  }

  tags = {
    Name = "${var.cluster_name}-aurora"
  }
}

# Aurora Serverless V2 Instances - Database instances within the cluster
# Multiple instances provide high availability and read scaling capabilities
resource "aws_rds_cluster_instance" "openemr" {
  count              = 2                                                     # Two instances for high availability
  identifier         = "${var.cluster_name}-aurora-${count.index}"           # Unique instance identifier
  cluster_identifier = aws_rds_cluster.openemr.id                            # Reference to the cluster
  instance_class     = "db.serverless"                                       # Serverless V2 instance class
  engine             = aws_rds_cluster.openemr.engine                        # Aurora MySQL engine
  engine_version     = aws_rds_cluster.openemr.engine_version                # Engine version

  # Enhanced monitoring and performance insights for operational visibility
  monitoring_interval             = 60                                   # 60-second monitoring interval
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn      # IAM role for enhanced monitoring
  performance_insights_enabled    = true                                 # Enable Performance Insights
  performance_insights_kms_key_id = aws_kms_key.rds.arn                  # KMS key for Performance Insights encryption

  tags = {
    Name = "${var.cluster_name}-aurora-${count.index}"
  }
}

# Random password generator for RDS master user
# Generates a secure password with alphanumeric characters only (no special characters)
resource "random_password" "db_password" {
  length  = 32        # 32 character password for high entropy
  special = false     # No special characters to avoid compatibility issues
  upper   = true      # Include uppercase letters
  lower   = true      # Include lowercase letters
  numeric = true      # Include numbers
}

# =============================================================================
# RDS MONITORING AND IAM CONFIGURATION
# =============================================================================
# IAM role and policies for RDS enhanced monitoring and Performance Insights

# RDS Monitoring IAM Role for enhanced monitoring
# This role allows RDS to send enhanced monitoring metrics to CloudWatch
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.cluster_name}-rds-monitoring-role"

  # Trust policy allowing RDS monitoring service to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"  # RDS monitoring service
        }
      }
    ]
  })
}

# Attach AWS managed policy for RDS enhanced monitoring
# This policy provides the necessary permissions for enhanced monitoring
resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
