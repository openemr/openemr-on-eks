# RDS Subnet Group
resource "aws_db_subnet_group" "openemr" {
  name       = "${var.cluster_name}-db-subnet-group"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "${var.cluster_name}-db-subnet-group"
  }
}

# RDS Security Group - Updated for Auto Mode
resource "aws_security_group" "rds" {
  name_prefix = "${var.cluster_name}-rds-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 3306
    to_port   = 3306
    protocol  = "tcp"
    # Auto Mode nodes will be in the cluster security group
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-rds-sg"
  }
}

# Aurora Serverless V2 Cluster
resource "aws_rds_cluster" "openemr" {
  cluster_identifier = "${var.cluster_name}-aurora"

  engine         = "aurora-mysql"
  engine_version = var.rds_engine_version

  master_username = "openemr"
  master_password = random_password.db_password.result

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.openemr.name

  backup_retention_period      = 30
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  # Regulatory compliance
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.rds.arn

  # Serverless V2 scaling
  serverlessv2_scaling_configuration {
    max_capacity = var.aurora_max_capacity
    min_capacity = var.aurora_min_capacity
  }

  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.cluster_name}-aurora-final-snapshot-${formatdate("YYYYMMDD-HHMM", timestamp())}"

  tags = {
    Name = "${var.cluster_name}-aurora"
  }
}

# Aurora Serverless V2 Instance
resource "aws_rds_cluster_instance" "openemr" {
  count              = 2
  identifier         = "${var.cluster_name}-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.openemr.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.openemr.engine
  engine_version     = aws_rds_cluster.openemr.engine_version

  # Regulatory compliance
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.rds.arn

  tags = {
    Name = "${var.cluster_name}-aurora-${count.index}"
  }
}

# Random password for RDS - alphanumeric only (no punctuation or spaces)
resource "random_password" "db_password" {
  length  = 32
  special = false
  upper   = true
  lower   = true
  numeric = true
}

# RDS Monitoring Role
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.cluster_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
