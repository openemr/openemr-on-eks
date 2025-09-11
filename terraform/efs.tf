# EFS File System
resource "aws_efs_file_system" "openemr" {
  creation_token = "${var.cluster_name}-efs"

  throughput_mode = "elastic"

  encrypted  = true
  kms_key_id = aws_kms_key.efs.arn

  tags = {
    Name = "${var.cluster_name}-efs"
  }
}

# EFS Mount Targets
resource "aws_efs_mount_target" "openemr" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.openemr.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# EFS Security Group - Updated for Auto Mode
resource "aws_security_group" "efs" {
  name_prefix = "${var.cluster_name}-efs-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 2049
    to_port   = 2049
    protocol  = "tcp"
    # Auto Mode nodes will be in the cluster security group
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.cluster_name}-efs-sg"
  }
}
