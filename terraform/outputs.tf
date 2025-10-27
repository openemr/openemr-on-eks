# =============================================================================
# TERRAFORM OUTPUTS
# =============================================================================
# This configuration defines outputs that expose key information about the deployed
# infrastructure for use by other modules, scripts, and external systems that need
# to interact with the EKS cluster and associated resources.

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "cluster_iam_role_name" {
  description = "IAM role name associated with EKS cluster"
  value       = module.eks.cluster_iam_role_name
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

# Aurora Database Outputs
# These outputs expose key information about the Aurora Serverless v2 PostgreSQL cluster
# that serves as the primary database for OpenEMR. All database-related outputs are marked
# as sensitive to prevent accidental exposure of connection details.

output "aurora_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.openemr.endpoint
  sensitive   = true
}

output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.openemr.reader_endpoint
  sensitive   = true
}

output "aurora_port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.openemr.port
}

output "aurora_engine_version" {
  description = "Aurora cluster engine version"
  value       = aws_rds_cluster.openemr.engine_version
}

output "aurora_cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.openemr.cluster_identifier
}

output "aurora_db_subnet_group_name" {
  description = "Aurora database subnet group name"
  value       = aws_db_subnet_group.openemr.name
}

output "aurora_password" {
  description = "Aurora cluster master password"
  value       = random_password.db_password.result
  sensitive   = true
}

# ElastiCache Redis Outputs
# These outputs expose key information about the ElastiCache Serverless Redis cluster
# that serves as the session store and caching layer for OpenEMR. The try() function
# provides fallback values in case the ElastiCache resources are not yet available.

output "redis_endpoint" {
  description = "Redis Serverless endpoint"
  value       = try(aws_elasticache_serverless_cache.openemr.endpoint[0].address, "redis-not-available")
  sensitive   = true
}

output "redis_port" {
  description = "Redis Serverless port"
  value       = try(aws_elasticache_serverless_cache.openemr.endpoint[0].port, 6379)
}

output "redis_password" {
  description = "Redis OpenEMR user password"
  value       = random_password.redis_openemr_password.result
  sensitive   = true
}

# EFS Storage Outputs
# These outputs expose key information about the EFS file system that provides
# persistent storage for OpenEMR application data, user uploads, and configuration files.

output "efs_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.openemr.id
}

# VPC Network Outputs
# These outputs expose key information about the VPC and subnet configuration
# that provides the network infrastructure for the EKS cluster and associated resources.

output "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

# S3 Storage Outputs
# These outputs expose key information about the S3 buckets used for storing
# ALB access logs and WAF logs, providing centralized logging capabilities.

output "alb_logs_bucket_name" {
  description = "Name of the S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.bucket
}

output "alb_logs_bucket_arn" {
  description = "ARN of the S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.arn
}

# IAM and Security Outputs
# These outputs expose key information about IAM roles and policies that enable
# secure access to AWS services from within the EKS cluster using IRSA.

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "openemr_role_arn" {
  description = "ARN of the OpenEMR IAM role for IRSA"
  value       = aws_iam_role.openemr.arn
}

output "grafana_cloudwatch_role_arn" {
  description = "ARN of the Grafana IAM role for CloudWatch datasource access"
  value       = aws_iam_role.grafana_cloudwatch.arn
}

# CloudWatch Logging Outputs
# These outputs expose key information about the CloudWatch log groups that collect
# and store logs from OpenEMR and Fluent Bit, enabling centralized log management
# and monitoring capabilities.

output "cloudwatch_log_groups" {
  description = "CloudWatch log group names for OpenEMR 7.0.3.4"
  value = {
    application    = aws_cloudwatch_log_group.openemr_app.name
    access         = aws_cloudwatch_log_group.openemr_access.name
    error          = aws_cloudwatch_log_group.openemr_error.name
    audit          = aws_cloudwatch_log_group.openemr_audit.name
    audit_detailed = aws_cloudwatch_log_group.openemr_audit_detailed.name
    system         = aws_cloudwatch_log_group.openemr_system.name
    php_error      = aws_cloudwatch_log_group.openemr_php_error.name
    fluent_bit     = aws_cloudwatch_log_group.fluent_bit_metrics.name
  }
}

# EFS CSI Driver Pod Identity Outputs
# These outputs expose key information about the EFS CSI driver Pod Identity role
# that enables secure access to EFS from within the EKS cluster.

output "efs_pod_identity_role_arn" {
  description = "ARN of the EFS CSI driver Pod Identity role"
  value       = module.aws_efs_csi_pod_identity.iam_role_arn
}

# Note: EFS CSI driver role ARN is now available via efs_pod_identity_role_arn output

# OpenEMR Application Configuration Outputs
# These outputs expose key configuration parameters for the OpenEMR application,
# including autoscaling settings, feature flags, and version information.

# OpenEMR Autoscaling Configuration Outputs
output "openemr_autoscaling_config" {
  description = "OpenEMR autoscaling configuration parameters"
  value = {
    min_replicas                     = var.openemr_min_replicas
    max_replicas                     = var.openemr_max_replicas
    cpu_utilization_threshold        = var.openemr_cpu_utilization_threshold
    memory_utilization_threshold     = var.openemr_memory_utilization_threshold
    scale_down_stabilization_seconds = var.openemr_scale_down_stabilization_seconds
    scale_up_stabilization_seconds   = var.openemr_scale_up_stabilization_seconds
  }
}

# OpenEMR Application Configuration Outputs
output "openemr_app_config" {
  description = "OpenEMR application configuration parameters"
  value = {
    version                = var.openemr_version
    api_enabled            = var.enable_openemr_api
    patient_portal_enabled = var.enable_patient_portal
  }
}

# OpenEMR Feature Configuration Outputs (deprecated - use openemr_app_config)
output "openemr_features_config" {
  description = "OpenEMR feature configuration parameters (deprecated - use openemr_app_config)"
  value = {
    api_enabled            = var.enable_openemr_api
    patient_portal_enabled = var.enable_patient_portal
  }
}

# WAF Security Configuration Outputs
# These outputs expose key information about the WAF (Web Application Firewall)
# configuration that provides protection against common web exploits and attacks.
# All WAF-related outputs return null when WAF is disabled via the enable_waf variable.

output "waf_web_acl_arn" {
  description = "ARN of the WAF Web ACL (null if WAF is disabled)"
  value       = var.enable_waf ? aws_wafv2_web_acl.openemr[0].arn : null
}

output "waf_web_acl_id" {
  description = "ID of the WAF Web ACL (null if WAF is disabled)"
  value       = var.enable_waf ? aws_wafv2_web_acl.openemr[0].id : null
}

output "waf_logs_bucket_name" {
  description = "Name of the S3 bucket storing WAF logs (null if WAF is disabled)"
  value       = var.enable_waf ? aws_s3_bucket.waf_logs[0].bucket : null
}

output "waf_logs_bucket_arn" {
  description = "ARN of the S3 bucket storing WAF logs (null if WAF is disabled)"
  value       = var.enable_waf ? aws_s3_bucket.waf_logs[0].arn : null
}

output "waf_enabled" {
  description = "Whether WAF is enabled"
  value       = var.enable_waf
}
