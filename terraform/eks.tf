# =============================================================================
# EKS (ELASTIC KUBERNETES SERVICE) CLUSTER CONFIGURATION
# =============================================================================
# This module creates an EKS cluster with Auto Mode for simplified node management,
# including security configurations, networking, and essential add-ons.

# EKS Cluster Module Configuration using terraform-aws-modules/eks/aws
# This module provides a production-ready EKS setup with Auto Mode for simplified operations
module "eks" {
  # Source module for EKS cluster creation with Auto Mode support
  source  = "terraform-aws-modules/eks/aws"
  version = "21.15.1" # Latest stable version with Auto Mode support

  # Cluster identification and version configuration
  name               = var.cluster_name       # EKS cluster name
  kubernetes_version = var.kubernetes_version # Kubernetes version (default: 1.35)

  # EKS Auto Mode Configuration
  # Auto Mode automatically manages compute nodes and scaling
  compute_config = {
    enabled    = true                          # Enable Auto Mode for simplified node management
    node_pools = ["general-purpose", "system"] # Two node pools: general workloads and system pods

    # Instance Metadata Service (IMDS) configuration for security
    # IMDS allows pods to access instance metadata for AWS service integration
    metadata_options = {
      http_put_response_hop_limit = 2          # Limit metadata access to 2 network hops
      http_tokens                 = "required" # Require IMDSv2 for enhanced security
    }
  }

  # VPC and networking configuration
  vpc_id     = module.vpc.vpc_id          # VPC where EKS cluster will be deployed
  subnet_ids = module.vpc.private_subnets # Private subnets for worker nodes

  # Dependency management - ensure VPC infrastructure is ready
  # VPC infrastructure (including NAT gateways) must be fully provisioned before EKS deployment
  depends_on = [time_sleep.wait_for_vpc]

  # Cluster endpoint access configuration
  endpoint_public_access  = var.enable_public_access # Control public endpoint access
  endpoint_private_access = true                     # Always enable private endpoint access

  # Public endpoint CIDR restrictions for security
  # If no specific CIDR blocks provided, auto-detect current public IP
  endpoint_public_access_cidrs = length(var.allowed_cidr_blocks) > 0 ? var.allowed_cidr_blocks : [
    "${chomp(data.http.myip.response_body)}/32" # Auto-detect current public IP
  ]

  # IAM and security configuration
  # Keep IRSA (IAM Roles for Service Accounts) enabled for workloads that need it
  # EFS CSI driver will use Pod Identity instead of IRSA
  enable_irsa                              = true # Enable IRSA for service account integration
  enable_cluster_creator_admin_permissions = true # Grant cluster creator admin permissions

  # Encryption configuration for cluster secrets
  # Use dedicated KMS key for encrypting Kubernetes secrets at rest
  encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn # KMS key for secrets encryption
    resources        = ["secrets"]         # Encrypt Kubernetes secrets
  }

  # CloudWatch logging configuration
  # Enable comprehensive logging for security monitoring and troubleshooting
  enabled_log_types = [
    "api",               # API server logs
    "audit",             # Audit logs for security monitoring
    "authenticator",     # Authentication logs
    "controllerManager", # Controller manager logs
    "scheduler"          # Scheduler logs
  ]

  # --- Managed Add-ons Configuration ---
  # Note: Add-ons are deployed as separate resources to ensure proper dependency ordering
  # This ensures compute nodes are ready before add-ons are deployed

  # Timeout configuration for add-on operations
  # Longer timeouts accommodate the time needed for add-on deployment
  addons_timeouts = {
    create = "30m" # 30 minutes for add-on creation
    update = "30m" # 30 minutes for add-on updates
    delete = "30m" # 30 minutes for add-on deletion
  }

  # Timeout configuration for cluster operations
  # Longer timeout accommodates the time needed for cluster provisioning
  timeouts = {
    create = "30m" # 30 minutes for cluster creation
  }

  # Resource tagging for cost allocation and resource management
  tags = local.common_tags
}

# =============================================================================
# DEPENDENCY MANAGEMENT AND TIMING CONTROLS
# =============================================================================
# These resources ensure proper ordering of infrastructure creation

# Wait for VPC infrastructure (including NAT gateways) to be fully ready
# This prevents EKS cluster creation from starting before networking is complete
resource "time_sleep" "wait_for_vpc" {
  depends_on = [module.vpc]

  create_duration = "30s" # 30 seconds to ensure VPC components are fully provisioned
}

# Wait for compute infrastructure to be fully ready before proceeding
# This ensures managed node groups are available for add-on scheduling
resource "time_sleep" "wait_for_compute" {
  depends_on = [module.eks, time_sleep.wait_for_vpc]

  create_duration = "60s" # 60 seconds to ensure compute nodes are ready for add-ons
}

# =============================================================================
# EKS MANAGED ADD-ONS CONFIGURATION
# =============================================================================
# These add-ons provide essential functionality for the EKS cluster

# Deploy Metrics Server add-on after compute nodes are ready
# Metrics Server provides resource utilization metrics for HPA (Horizontal Pod Autoscaler)
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "metrics-server"    # Essential for autoscaling
  addon_version               = "v0.8.0-eksbuild.6" # Latest stable version for Kubernetes 1.35
  resolve_conflicts_on_create = "OVERWRITE"         # Overwrite any existing conflicts
  resolve_conflicts_on_update = "OVERWRITE"         # Overwrite any existing conflicts

  # Wait for compute infrastructure to be ready
  # Metrics Server needs compute nodes to collect metrics from
  depends_on = [time_sleep.wait_for_compute]

  # Timeout configuration for add-on operations
  timeouts {
    create = "30m" # 30 minutes for creation
    update = "30m" # 30 minutes for updates
    delete = "30m" # 30 minutes for deletion
  }

  # Resource tagging for cost allocation and resource management
  tags = local.common_tags
}

# Deploy EFS CSI driver after compute nodes are ready and EFS is available
# EFS CSI driver enables Kubernetes to provision and mount EFS volumes for persistent storage
resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver" # CSI driver for EFS integration
  addon_version               = "v2.3.0-eksbuild.1" # Latest stable version for Kubernetes 1.35
  resolve_conflicts_on_create = "OVERWRITE"          # Overwrite any existing conflicts
  resolve_conflicts_on_update = "OVERWRITE"          # Overwrite any existing conflicts

  # Wait for compute infrastructure and EFS file system to be ready
  # EFS CSI driver needs both compute nodes and EFS file system to function
  depends_on = [
    time_sleep.wait_for_compute, # Ensure compute nodes are ready
    aws_efs_file_system.openemr, # Ensure EFS file system exists
    aws_efs_mount_target.openemr # Ensure EFS mount targets are configured
  ]

  # Timeout configuration for add-on operations
  timeouts {
    create = "30m" # 30 minutes for creation
    update = "30m" # 30 minutes for updates
    delete = "30m" # 30 minutes for deletion
  }

  # Resource tagging for cost allocation and resource management
  tags = local.common_tags
}

# =============================================================================
# EKS POD IDENTITY CONFIGURATION
# =============================================================================
# Pod Identity provides secure AWS service access for Kubernetes pods
# This replaces the older IRSA (IAM Roles for Service Accounts) approach

# Note: Pod Identity is automatically handled by EKS Auto Mode
# No separate add-on configuration needed for basic Pod Identity functionality

# EKS Pod Identity role and association for EFS CSI driver
# This enables the EFS CSI driver to access AWS EFS service securely
module "aws_efs_csi_pod_identity" {
  # Source module for Pod Identity configuration
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.7.0"

  name = "aws-efs-csi" # Name for the Pod Identity configuration

  # Attach AWS-managed policy required by the EFS CSI driver
  # This policy provides the necessary permissions for EFS operations
  attach_aws_efs_csi_policy = true

  # Security hardening: Limit trust policy to current AWS account
  # This reduces the blast radius in case of security incidents
  trust_policy_conditions = [
    {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id] # Restrict to current account
    }
  ]

  # Create association that binds the EFS controller service account to the IAM role
  # This enables the EFS CSI driver pods to assume the IAM role for AWS API access
  associations = {
    efs = {
      cluster_name    = module.eks.cluster_name # EKS cluster name
      namespace       = "kube-system"           # Namespace where EFS CSI driver runs
      service_account = "efs-csi-controller-sa" # Service account name for EFS CSI driver
      # Note: If role_arn is left unset, this module automatically wires its created role
      # role_arn      = module.aws_efs_csi_pod_identity.iam_role_arn  # (optional explicit wiring)
    }
  }

  # Ensure the cluster, add-ons, and compute infrastructure exist prior to association
  # Pod Identity associations require the cluster and add-ons to be fully provisioned
  depends_on = [
    module.eks,                   # Ensure EKS cluster exists
    aws_eks_addon.metrics_server, # Ensure Metrics Server add-on is deployed
    aws_eks_addon.efs_csi_driver, # Ensure EFS CSI driver add-on is deployed
    time_sleep.wait_for_compute   # Ensure compute infrastructure is ready
  ]

  # Resource tagging for cost allocation and resource management
  tags = local.common_tags
}

# Note: The EFS CSI controller service account is now managed by the pod-identity module
# The kubernetes_annotations resource has been removed as it's not needed with Pod Identity
# Pod Identity automatically handles the service account configuration
