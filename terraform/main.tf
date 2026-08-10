# =============================================================================
# TERRAFORM CONFIGURATION BLOCK
# =============================================================================
# This block defines the Terraform version requirements and provider constraints
# for the OpenEMR on EKS deployment. It ensures consistent infrastructure
# provisioning across different environments and team members.
terraform {
  # Minimum Terraform version required for this configuration
  required_version = ">= 1.15.8"

  # Provider version constraints to ensure consistent behavior
  # Pinning to specific versions prevents unexpected breaking changes
  required_providers {
    # AWS Provider - Core infrastructure provider for AWS services
    # Version 6.52.0 satisfies EKS module 21.24.1 constraint (>= 6.52.0)
    aws = {
      source  = "hashicorp/aws"
      version = "6.52.0"
    }
    # Kubernetes Provider - For managing Kubernetes resources
    # Version 3.0.1 supports current Kubernetes API versions and features
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.0.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.0"
    }
  }
}

# =============================================================================
# AWS PROVIDER CONFIGURATION
# =============================================================================
# Configures the AWS provider with region and default tagging strategy
# Default tags are automatically applied to all AWS resources created by Terraform
# When var.aws_endpoint_url is set (Floci CI), static test creds + skip flags
# redirect the provider at the local emulator. Leave unset for real AWS.
provider "aws" {
  # AWS region where all resources will be deployed
  # This should match the region specified in your AWS CLI configuration
  region = var.aws_region

  access_key = local.use_floci ? "test" : null
  secret_key = local.use_floci ? "test" : null

  skip_credentials_validation = local.use_floci
  skip_metadata_api_check     = local.use_floci
  skip_requesting_account_id  = local.use_floci
  s3_use_path_style           = local.use_floci

  # Prefer explicit endpoints when targeting Floci; AWS_ENDPOINT_URL alone is
  # not always honored by every AWS provider service client path.
  dynamic "endpoints" {
    for_each = local.use_floci ? [var.aws_endpoint_url] : []
    content {
      acm                  = endpoints.value
      autoscaling          = endpoints.value
      backup               = endpoints.value
      cloudformation       = endpoints.value
      cloudtrail           = endpoints.value
      cloudwatch           = endpoints.value
      cloudwatchlogs       = endpoints.value
      ec2                  = endpoints.value
      ecr                  = endpoints.value
      ecs                  = endpoints.value
      efs                  = endpoints.value
      eks                  = endpoints.value
      elasticache          = endpoints.value
      elasticloadbalancing = endpoints.value
      iam                  = endpoints.value
      kms                  = endpoints.value
      lambda               = endpoints.value
      rds                  = endpoints.value
      s3                   = endpoints.value
      secretsmanager       = endpoints.value
      ssm                  = endpoints.value
      sns                  = endpoints.value
      sqs                  = endpoints.value
      sts                  = endpoints.value
      wafv2                = endpoints.value
    }
  }

  # Default tags applied to all AWS resources
  # These tags help with cost allocation, resource management, and compliance
  default_tags {
    tags = {
      Environment = var.environment # Environment identifier (dev, staging, prod)
      Project     = "OpenEMR"       # Project name for resource identification
      ManagedBy   = "Terraform"     # Infrastructure management tool
    }
  }
}

# =============================================================================
# GLOBAL RESOURCE UNIQUENESS
# =============================================================================
# Creates a random suffix to ensure global resource names are unique
# This prevents naming conflicts when deploying multiple environments
# or when resources with global names (like S3 buckets) already exist
resource "random_id" "global_suffix" {
  # 4 bytes = 8 hex characters for sufficient uniqueness
  byte_length = 4
}

# =============================================================================
# KUBERNETES PROVIDER CONFIGURATION
# =============================================================================
# Configures the Kubernetes provider to manage resources in the EKS cluster
# Uses AWS CLI for authentication via EKS token-based authentication.
# Under Floci there are no kubernetes_* resources today; use an inert host so provider
# init does not require a live API server during apply/destroy.
provider "kubernetes" {
  host                   = local.use_floci ? "https://127.0.0.1:6443" : module.eks.cluster_endpoint
  cluster_ca_certificate = local.use_floci ? null : base64decode(module.eks.cluster_certificate_authority_data)
  insecure               = local.use_floci

  dynamic "exec" {
    for_each = local.use_floci ? [] : [1]
    content {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
      command     = "aws"
    }
  }
}

# =============================================================================
# DATA SOURCES
# =============================================================================
# Data sources retrieve information from existing AWS resources or external APIs
# These provide dynamic values that can be used throughout the configuration

# Retrieve available AWS availability zones in the specified region
# Filters out zones that require opt-in (like us-west-2-lax-1a)
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # Only include zones that don't require opt-in
  }
}

# Get current AWS account information (account ID, user ARN, etc.)
# Used for constructing ARNs and IAM policies
data "aws_caller_identity" "current" {}

# Retrieve current public IP address from external service
# Used for security group rules to allow access from current location
data "http" "myip" {
  url = "https://checkip.amazonaws.com"
}

# =============================================================================
# LOCAL VALUES
# =============================================================================
# Local values provide computed values that can be referenced throughout the configuration
# These help reduce duplication and maintain consistency

locals {
  use_floci = var.aws_endpoint_url != null && var.aws_endpoint_url != ""

  # EKS module output cluster_security_group_id is null when create_security_group=false
  # (Floci path). Prefer the inline Floci SGs in that case.
  eks_cluster_security_group_id = local.use_floci ? aws_security_group.floci_eks_cluster[0].id : module.eks.cluster_security_group_id
  eks_node_security_group_id    = local.use_floci ? aws_security_group.floci_eks_node[0].id : module.eks.node_security_group_id

  # Common tags applied to resources for consistency
  # These tags help with cost allocation, resource management, and compliance
  common_tags = {
    Environment = var.environment # Environment identifier (dev, staging, prod)
    Project     = "OpenEMR"       # Project name for resource identification
    ManagedBy   = "Terraform"     # Infrastructure management tool
  }
}
