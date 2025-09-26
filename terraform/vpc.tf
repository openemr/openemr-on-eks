# =============================================================================
# VPC (VIRTUAL PRIVATE CLOUD) CONFIGURATION
# =============================================================================
# This module creates a VPC with public and private subnets across multiple
# availability zones, configured for EKS with proper networking and compliance features.

# VPC Module Configuration using terraform-aws-modules/vpc/aws
# This module provides a production-ready VPC setup with best practices
module "vpc" {
  # Source module for VPC creation with EKS-specific configurations
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.2.0"  # Latest stable version with EKS support

  # VPC naming and CIDR configuration
  name = "${var.cluster_name}-vpc"  # VPC name based on cluster name
  cidr = var.vpc_cidr               # Main IP address range (default: 10.0.0.0/16)

  # Availability zones and subnet configuration
  # Use first 3 availability zones for high availability
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = var.private_subnets  # Private subnets for worker nodes and databases
  public_subnets  = var.public_subnets   # Public subnets for load balancers and NAT gateways

  # Network gateway configuration
  enable_nat_gateway   = true   # NAT gateway for private subnet internet access
  enable_vpn_gateway   = false  # No VPN gateway needed for this setup
  enable_dns_hostnames = true   # Enable DNS hostnames for internal resolution
  enable_dns_support   = true   # Enable DNS resolution within VPC

  # VPC Flow Logs for regulatory compliance and security monitoring
  # Flow logs capture network traffic information for audit and troubleshooting
  enable_flow_log                      = true   # Enable VPC flow logging
  create_flow_log_cloudwatch_iam_role  = true   # Create IAM role for flow logs
  create_flow_log_cloudwatch_log_group = true   # Create CloudWatch log group

  # Kubernetes-specific subnet tagging
  # These tags enable the AWS Load Balancer Controller to automatically
  # discover and use the appropriate subnets for load balancers

  # Public subnet tags for external load balancers (internet-facing)
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1  # Tag for external load balancers
  }

  # Private subnet tags for internal load balancers (VPC-internal)
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1  # Tag for internal load balancers
  }
}
