# =============================================================================
# EFS (ELASTIC FILE SYSTEM) CONFIGURATION
# =============================================================================
# This configuration creates an EFS file system for OpenEMR persistent storage
# with encryption, high availability, and integration with EKS.

# EFS File System - Main file system for OpenEMR persistent storage
# Provides shared storage across multiple EKS nodes for high availability
resource "aws_efs_file_system" "openemr" {
  # Creation token for unique file system identification
  creation_token = "${var.cluster_name}-efs"

  # Throughput mode: Elastic provides automatic scaling based on demand
  throughput_mode = "elastic"

  # Security and encryption configuration
  encrypted  = true                    # Enable encryption at rest
  kms_key_id = aws_kms_key.efs.arn     # KMS key for encryption

  tags = {
    Name = "${var.cluster_name}-efs"
  }
}

# EFS Mount Targets - Network endpoints for file system access
# Mount targets provide network access to the EFS file system from each availability zone
resource "aws_efs_mount_target" "openemr" {
  # Create one mount target per private subnet for high availability
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.openemr.id           # Reference to the EFS file system
  subnet_id       = module.vpc.private_subnets[count.index]  # Subnet for this mount target
  security_groups = [aws_security_group.efs.id]              # Security group for network access control
}

# EFS Security Group - Network access control for file system
# Restricts EFS access to resources within the VPC
resource "aws_security_group" "efs" {
  name_prefix = "${var.cluster_name}-efs-"  # Security group name with prefix
  vpc_id      = module.vpc.vpc_id           # Associate with the VPC

  # Ingress rule: Allow NFS connections from VPC
  ingress {
    from_port = 2049                        # NFS port (EFS uses NFS protocol)
    to_port   = 2049                        # NFS port
    protocol  = "tcp"                       # TCP protocol
    # Auto Mode nodes will be in the cluster security group
    cidr_blocks = [var.vpc_cidr]            # Allow access from entire VPC CIDR
  }

  tags = {
    Name = "${var.cluster_name}-efs-sg"
  }
}
