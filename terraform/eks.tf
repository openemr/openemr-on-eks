# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.9"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Auto Mode
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]

    # Configure IMDS to allow pods to access instance metadata
    metadata_options = {
      http_put_response_hop_limit = 2
      http_tokens                 = "required"
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Ensure VPC infrastructure (including NAT gateways) is ready before EKS deployment
  depends_on = [time_sleep.wait_for_vpc]

  endpoint_public_access  = var.enable_public_access
  endpoint_private_access = true

  endpoint_public_access_cidrs = length(var.allowed_cidr_blocks) > 0 ? var.allowed_cidr_blocks : [
    "${chomp(data.http.myip.response_body)}/32"
  ]

  # Keep IRSA on for other workloads; EFS will use Pod Identity
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # --- Managed Add-ons ---
  # Note: Addons are now deployed as separate resources to ensure proper dependency ordering
  # This ensures compute nodes are ready before addons are deployed

  # Separate addon configuration for EFS CSI to ensure proper dependencies
  # This will be added after compute nodes are ready and have internet access
  addons_timeouts = {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  # Increase timeout for cluster deployment
  timeouts = {
    create = "30m"
  }



  tags = local.common_tags
}

# Wait for VPC infrastructure (including NAT gateways) to be fully ready
resource "time_sleep" "wait_for_vpc" {
  depends_on = [module.vpc]

  create_duration = "30s"
}

# Wait for compute infrastructure to be fully ready before proceeding
# This ensures managed node groups are available for add-on scheduling
resource "time_sleep" "wait_for_compute" {
  depends_on = [module.eks, time_sleep.wait_for_vpc]

  create_duration = "60s"
}

# Deploy Metrics Server addon after compute nodes are ready
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "metrics-server"
  addon_version               = "v0.8.0-eksbuild.2"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Wait for compute infrastructure to be ready
  depends_on = [time_sleep.wait_for_compute]

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  tags = local.common_tags
}

# Deploy EFS CSI driver after compute nodes are ready and EFS is available
resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  addon_version               = "v2.1.11-eksbuild.1"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Wait for compute infrastructure and EFS file system to be ready
  depends_on = [
    time_sleep.wait_for_compute,
    aws_efs_file_system.openemr,
    aws_efs_mount_target.openemr
  ]

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  tags = local.common_tags
}

# Note: Pod Identity is automatically handled by EKS Auto Mode
# No separate addon configuration needed

# EKS Pod Identity role + association (for EFS CSI)
module "aws_efs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.0.0"

  name = "aws-efs-csi"

  # Attach AWS-managed policy required by the driver
  attach_aws_efs_csi_policy = true

  # (Optional hardening) Limit to this account to reduce blast radius
  trust_policy_conditions = [
    {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  ]

  # Create association that binds the EFS controller SA to the IAM role created by this module
  associations = {
    efs = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "efs-csi-controller-sa"
      # If left unset, this module wires its created role automatically
      # role_arn      = module.aws_efs_csi_pod_identity.iam_role_arn  # (optional explicit wire)
    }
  }

  # Ensure the cluster, add-ons, and compute infrastructure exist prior to association
  depends_on = [
    module.eks,
    aws_eks_addon.metrics_server,
    aws_eks_addon.efs_csi_driver,
    time_sleep.wait_for_compute
  ]

  tags = local.common_tags
}

# Note: The EFS CSI controller service account is now managed by the pod-identity module
# The kubernetes_annotations resource has been removed as it's not needed with Pod Identity
