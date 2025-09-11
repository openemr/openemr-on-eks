variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "openemr-eks"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "aurora_min_capacity" {
  description = "Aurora Serverless V2 minimum capacity (ACUs)"
  type        = number
  default     = 0.5
}

variable "aurora_max_capacity" {
  description = "Aurora Serverless V2 maximum capacity (ACUs)"
  type        = number
  default     = 16
}

variable "redis_max_data_storage" {
  description = "ElastiCache Serverless maximum data storage in GB"
  type        = number
  default     = 20
}

variable "redis_max_ecpu_per_second" {
  description = "ElastiCache Serverless maximum ECPUs per second"
  type        = number
  default     = 5000
}

variable "domain_name" {
  description = "Domain name for OpenEMR (leave empty for LoadBalancer access only)"
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^$|^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\\.[a-zA-Z]{2,}$", var.domain_name))
    error_message = "Domain name must be a valid FQDN or empty string."
  }
}

variable "enable_waf" {
  description = "Enable AWS WAF for additional security (recommended for production)"
  type        = bool
  default     = true
}

variable "enable_public_access" {
  description = "Enable public endpoint access (disable for maximum security)"
  type        = bool
  default     = true
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the cluster endpoint (auto-detected if empty)"
  type        = list(string)
  default     = []
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 30
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection for RDS cluster (disable for testing)"
  type        = bool
  default     = true
}

variable "alb_logs_retention_days" {
  description = "Number of days to retain ALB access logs in S3"
  type        = number
  default     = 90
}

variable "app_logs_retention_days" {
  description = "Number of days to retain application logs in CloudWatch"
  type        = number
  default     = 30
}

variable "audit_logs_retention_days" {
  description = "Number of days to retain audit logs in CloudWatch"
  type        = number
  default     = 365
}

variable "rds_engine_version" {
  description = "Version of the RDS engine to use; see here for available versions (https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_rds.AuroraMysqlEngineVersion.html)."
  type        = string
  default     = "8.0.mysql_aurora.3.10.0"
}

# OpenEMR Autoscaling Configuration
variable "openemr_min_replicas" {
  description = "Minimum number of OpenEMR replicas (recommended: 2 for HA)"
  type        = number
  default     = 2

  validation {
    condition     = var.openemr_min_replicas >= 1 && var.openemr_min_replicas <= 20
    error_message = "Minimum replicas must be between 1 and 20."
  }
}

variable "openemr_max_replicas" {
  description = "Maximum number of OpenEMR replicas (adjust based on expected peak load)"
  type        = number
  default     = 10

  validation {
    condition     = var.openemr_max_replicas >= 2 && var.openemr_max_replicas <= 50
    error_message = "Maximum replicas must be between 2 and 50."
  }
}

variable "openemr_cpu_utilization_threshold" {
  description = "CPU utilization percentage to trigger scaling (recommended: 60-80%)"
  type        = number
  default     = 70

  validation {
    condition     = var.openemr_cpu_utilization_threshold >= 30 && var.openemr_cpu_utilization_threshold <= 90
    error_message = "CPU utilization threshold must be between 30% and 90%."
  }
}

variable "openemr_memory_utilization_threshold" {
  description = "Memory utilization percentage to trigger scaling (recommended: 70-85%)"
  type        = number
  default     = 80

  validation {
    condition     = var.openemr_memory_utilization_threshold >= 50 && var.openemr_memory_utilization_threshold <= 95
    error_message = "Memory utilization threshold must be between 50% and 95%."
  }
}

variable "openemr_scale_down_stabilization_seconds" {
  description = "Seconds to wait before scaling down (recommended: 300-600 for healthcare workloads)"
  type        = number
  default     = 300

  validation {
    condition     = var.openemr_scale_down_stabilization_seconds >= 60 && var.openemr_scale_down_stabilization_seconds <= 3600
    error_message = "Scale down stabilization must be between 60 and 3600 seconds."
  }
}

variable "openemr_scale_up_stabilization_seconds" {
  description = "Seconds to wait before scaling up (recommended: 60-120 for responsive scaling)"
  type        = number
  default     = 60

  validation {
    condition     = var.openemr_scale_up_stabilization_seconds >= 30 && var.openemr_scale_up_stabilization_seconds <= 300
    error_message = "Scale up stabilization must be between 30 and 300 seconds."
  }
}

# OpenEMR Application Configuration
variable "openemr_version" {
  description = "OpenEMR Docker image version to deploy (e.g., '7.0.3', '7.0.2', 'latest')"
  type        = string
  default     = "7.0.3"

  validation {
    condition     = can(regex("^(latest|[0-9]+\\.[0-9]+\\.[0-9]+(-[a-zA-Z0-9]+)?)$", var.openemr_version))
    error_message = "OpenEMR version must be 'latest' or follow semantic versioning (e.g., '7.0.3', '7.0.2-dev')."
  }
}

# OpenEMR Feature Configuration
variable "enable_openemr_api" {
  description = "Enable OpenEMR REST API endpoints (FHIR, REST API) - SECURITY: Disable if not needed"
  type        = bool
  default     = false
}

variable "enable_patient_portal" {
  description = "Enable OpenEMR patient portal functionality - SECURITY: Disable if not needed"
  type        = bool
  default     = false
}
