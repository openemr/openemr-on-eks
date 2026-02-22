# =============================================================================
# TERRAFORM CONFIGURATION BLOCK
# =============================================================================
# This block defines the Terraform version requirements and provider constraints
# for the OpenEMR on EKS deployment. It ensures consistent infrastructure
# provisioning across different environments and team members.
terraform {
  # Minimum Terraform version required for this configuration
  required_version = ">= 1.14.5"

  # Provider version constraints to ensure consistent behavior
  # Pinning to specific versions prevents unexpected breaking changes
  required_providers {
    # AWS Provider - Core infrastructure provider for AWS services
    # Version 6.16.0 provides support for latest AWS services and features
    aws = {
      source  = "hashicorp/aws"
      version = "6.28.0"
    }
    # Kubernetes Provider - For managing Kubernetes resources
    # Version 2.38.0 supports latest Kubernetes API versions and features
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.0.1"
    }
  }
}

# =============================================================================
# AWS PROVIDER CONFIGURATION
# =============================================================================
# Configures the AWS provider with region and default tagging strategy
# Default tags are automatically applied to all AWS resources created by Terraform
provider "aws" {
  # AWS region where all resources will be deployed
  # This should match the region specified in your AWS CLI configuration
  region = var.aws_region

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
# Uses AWS CLI for authentication via EKS token-based authentication
provider "kubernetes" {
  # EKS cluster endpoint for API server communication
  host = module.eks.cluster_endpoint

  # Cluster CA certificate for secure TLS communication
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  # Authentication configuration using AWS CLI and EKS token
  exec {
    # Kubernetes client authentication API version
    api_version = "client.authentication.k8s.io/v1beta1"

    # AWS CLI command to get EKS authentication token
    args = ["eks", "get-token", "--cluster-name", var.cluster_name]

    # Use AWS CLI for authentication
    command = "aws"
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
  # Common tags applied to resources for consistency
  # These tags help with cost allocation, resource management, and compliance
  common_tags = {
    Environment = var.environment # Environment identifier (dev, staging, prod)
    Project     = "OpenEMR"       # Project name for resource identification
    ManagedBy   = "Terraform"     # Infrastructure management tool
  }
}
