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

output "aurora_password" {
  description = "Aurora cluster master password"
  value       = random_password.db_password.result
  sensitive   = true
}

output "redis_endpoint" {
  description = "Redis Serverless endpoint"
  value       = aws_elasticache_serverless_cache.openemr.endpoint[0].address
  sensitive   = true
}

output "redis_port" {
  description = "Redis Serverless port"
  value       = aws_elasticache_serverless_cache.openemr.endpoint[0].port
}

output "redis_password" {
  description = "Redis OpenEMR user password"
  value       = random_password.redis_openemr_password.result
  sensitive   = true
}

output "efs_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.openemr.id
}

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

output "alb_logs_bucket_name" {
  description = "Name of the S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.bucket
}

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "openemr_role_arn" {
  description = "ARN of the OpenEMR IAM role for IRSA"
  value       = aws_iam_role.openemr.arn
}

output "alb_logs_bucket_arn" {
  description = "ARN of the S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.arn
}

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

output "efs_pod_identity_role_arn" {
  value = module.aws_efs_csi_pod_identity.iam_role_arn
}

# Note: EFS CSI driver role ARN is now available via efs_pod_identity_role_arn output

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

# WAF Configuration Outputs
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
