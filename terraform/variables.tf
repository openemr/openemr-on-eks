# =============================================================================
# INFRASTRUCTURE CONFIGURATION VARIABLES
# =============================================================================
# These variables control the basic infrastructure setup and deployment region

# AWS region where all resources will be deployed
# Choose a region close to your users for optimal performance
# Common regions: us-east-1, us-west-2, eu-west-1, ap-southeast-1
variable "aws_region" {
  description = "AWS region where all resources will be deployed"
  type        = string
  default     = "us-west-2" # Oregon - good balance of performance and cost
}

# Environment identifier for resource naming and tagging
# Used to distinguish between different deployment environments
variable "environment" {
  description = "Environment identifier (dev, staging, production, etc.)"
  type        = string
  default     = "production"
}

# Name of the EKS cluster - must be unique within the AWS account and region
# This name will be used in resource names and DNS entries
variable "cluster_name" {
  description = "Name of the EKS cluster (must be unique within account/region)"
  type        = string
  default     = "openemr-eks"
}

# Kubernetes version for the EKS cluster
# Use a stable version that supports the features you need
# Check AWS documentation for supported versions: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
# Release notes: https://kubernetes.io/blog/2025/08/27/kubernetes-v1-34-release/
variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35" # Latest stable version (DRA GA, Cgroup autoconfiguration GA)
}

# =============================================================================
# NETWORKING CONFIGURATION VARIABLES
# =============================================================================
# These variables control the VPC and subnet configuration for the infrastructure

# VPC CIDR block - the main IP address range for the entire network
# Choose a large enough range to accommodate all subnets and future growth
variable "vpc_cidr" {
  description = "CIDR block for the VPC (main network address range)"
  type        = string
  default     = "10.0.0.0/16" # Provides 65,536 IP addresses (10.0.0.0 - 10.0.255.255)
}

# Private subnet CIDR blocks - where worker nodes and databases will be deployed
# These subnets have no direct internet access for security
# Should be distributed across multiple availability zones for high availability
variable "private_subnets" {
  description = "Private subnet CIDR blocks (no direct internet access)"
  type        = list(string)
  default = [
    "10.0.1.0/24", # Private subnet in AZ-a (256 IPs: 10.0.1.0 - 10.0.1.255)
    "10.0.2.0/24", # Private subnet in AZ-b (256 IPs: 10.0.2.0 - 10.0.2.255)
    "10.0.3.0/24"  # Private subnet in AZ-c (256 IPs: 10.0.3.0 - 10.0.3.255)
  ]
}

# Public subnet CIDR blocks - where load balancers and NAT gateways will be deployed
# These subnets have direct internet access
# Should be distributed across multiple availability zones for high availability
variable "public_subnets" {
  description = "Public subnet CIDR blocks (direct internet access)"
  type        = list(string)
  default = [
    "10.0.101.0/24", # Public subnet in AZ-a (256 IPs: 10.0.101.0 - 10.0.101.255)
    "10.0.102.0/24", # Public subnet in AZ-b (256 IPs: 10.0.102.0 - 10.0.102.255)
    "10.0.103.0/24"  # Public subnet in AZ-c (256 IPs: 10.0.103.0 - 10.0.103.255)
  ]
}

# =============================================================================
# DATABASE AND CACHE CONFIGURATION VARIABLES
# =============================================================================
# These variables control the RDS Aurora and ElastiCache configuration

# Aurora Serverless V2 minimum capacity in Aurora Capacity Units (ACUs)
# Each ACU is a combination of processing and memory capacity
# Minimum of 0.5 ACU provides cost-effective baseline for light workloads
variable "aurora_min_capacity" {
  description = "Aurora Serverless V2 minimum capacity in ACUs (Aurora Capacity Units)"
  type        = number
  default     = 0.5 # Minimum for cost-effective operation
}

# Aurora Serverless V2 maximum capacity in Aurora Capacity Units (ACUs)
# Maximum capacity determines the peak performance available
# 16 ACUs provides significant processing power for high-traffic workloads
variable "aurora_max_capacity" {
  description = "Aurora Serverless V2 maximum capacity in ACUs (Aurora Capacity Units)"
  type        = number
  default     = 16 # High capacity for production workloads
}

# ElastiCache Serverless maximum data storage in gigabytes
# This determines how much data can be stored in the cache
# 20GB provides substantial caching capacity for session data and frequently accessed records
variable "redis_max_data_storage" {
  description = "ElastiCache Serverless maximum data storage capacity in GB"
  type        = number
  default     = 20 # 20GB storage capacity
}

# ElastiCache Serverless maximum ECPUs (ElastiCache Processing Units) per second
# ECPUs determine the processing capacity available for cache operations
# 5000 ECPUs provides high throughput for cache operations
variable "redis_max_ecpu_per_second" {
  description = "ElastiCache Serverless maximum ECPUs per second (processing capacity)"
  type        = number
  default     = 5000 # High throughput capacity
}

# =============================================================================
# SECURITY AND ACCESS CONFIGURATION VARIABLES
# =============================================================================
# These variables control security settings, access permissions, and domain configuration


# Enable AWS WAF (Web Application Firewall) for additional security
# WAF provides protection against common web exploits and DDoS attacks
# Highly recommended for production environments
variable "enable_waf" {
  description = "Enable AWS WAF for web application security (recommended for production)"
  type        = bool
  default     = true # Enabled by default for security
}

# Enable public endpoint access for the EKS cluster
# When disabled, cluster endpoint is only accessible from within the VPC
# Disable for maximum security in highly regulated environments
variable "enable_public_access" {
  description = "Enable public endpoint access (disable for maximum security)"
  type        = bool
  default     = true # Enabled by default for ease of access
}

# CIDR blocks allowed to access the EKS cluster endpoint
# If empty, will auto-detect current public IP address
# Add specific CIDR blocks for office networks, VPN ranges, etc.
variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the EKS cluster endpoint (auto-detected if empty)"
  type        = list(string)
  default     = [] # Empty list triggers auto-detection of current IP
}

# =============================================================================
# BACKUP AND RETENTION CONFIGURATION VARIABLES
# =============================================================================
# These variables control backup retention policies and data lifecycle management


# Enable deletion protection for RDS cluster
# Prevents accidental deletion of the database cluster
# Disable only for testing or temporary environments
variable "rds_deletion_protection" {
  description = "Enable deletion protection for RDS cluster (disable for testing only)"
  type        = bool
  default     = true # Enabled by default for production safety
}

# Number of days to retain ALB (Application Load Balancer) access logs in S3
# ALB logs provide detailed information about HTTP requests and responses
# 90 days provides good balance for security analysis and compliance
variable "alb_logs_retention_days" {
  description = "Number of days to retain ALB access logs in S3"
  type        = number
  default     = 90 # 90 days for security analysis and compliance
}

# Number of days to retain application logs in CloudWatch
# Application logs include OpenEMR system logs, error logs, and operational logs
# 30 days provides good balance between troubleshooting needs and storage costs
variable "app_logs_retention_days" {
  description = "Number of days to retain application logs in CloudWatch"
  type        = number
  default     = 30 # 30 days for application troubleshooting
}

# Number of days to retain audit logs in CloudWatch
# Audit logs are critical for compliance and security monitoring
# 365 days (1 year) meets most compliance requirements for healthcare data
variable "audit_logs_retention_days" {
  description = "Number of days to retain audit logs in CloudWatch (compliance requirement)"
  type        = number
  default     = 365 # 1 year for compliance and security monitoring
}

# =============================================================================
# DATABASE ENGINE CONFIGURATION
# =============================================================================
# Configuration for the database engine version and compatibility

# RDS Aurora MySQL engine version
# Use a stable version that provides good performance and security features
# Check AWS documentation for available versions and compatibility
variable "rds_engine_version" {
  description = "Aurora MySQL engine version (check AWS docs for available versions)"
  type        = string
  default     = "8.0.mysql_aurora.3.12.0" # Stable Aurora MySQL 8.0 version (compatible with MySQL 8.0.44)
}

# =============================================================================
# OPENEMR AUTOSCALING CONFIGURATION VARIABLES
# =============================================================================
# These variables control the horizontal pod autoscaling behavior for OpenEMR

# Minimum number of OpenEMR pod replicas
# Ensures high availability and handles baseline load
# Minimum of 2 replicas recommended for production high availability
variable "openemr_min_replicas" {
  description = "Minimum number of OpenEMR pod replicas (recommended: 2 for HA)"
  type        = number
  default     = 2 # 2 replicas minimum for high availability

  # Validation ensures reasonable bounds for minimum replicas
  validation {
    condition     = var.openemr_min_replicas >= 1 && var.openemr_min_replicas <= 20
    error_message = "Minimum replicas must be between 1 and 20 for reasonable resource usage."
  }
}

# Maximum number of OpenEMR pod replicas
# Determines the maximum scale-out capacity for handling peak loads
# Set based on expected traffic patterns and cost considerations
variable "openemr_max_replicas" {
  description = "Maximum number of OpenEMR pod replicas (adjust based on expected peak load)"
  type        = number
  default     = 10 # 10 replicas maximum for cost-effective scaling

  # Validation ensures reasonable bounds for maximum replicas
  validation {
    condition     = var.openemr_max_replicas >= 2 && var.openemr_max_replicas <= 50
    error_message = "Maximum replicas must be between 2 and 50 for reasonable resource usage."
  }
}

# CPU utilization threshold for triggering horizontal pod autoscaling
# When average CPU usage across all pods exceeds this percentage, scale up
# Lower values trigger scaling sooner, higher values wait for more load
variable "openemr_cpu_utilization_threshold" {
  description = "CPU utilization percentage to trigger scaling (recommended: 60-80%)"
  type        = number
  default     = 70 # 70% CPU threshold for responsive scaling

  # Validation ensures reasonable CPU threshold bounds
  validation {
    condition     = var.openemr_cpu_utilization_threshold >= 30 && var.openemr_cpu_utilization_threshold <= 90
    error_message = "CPU utilization threshold must be between 30% and 90% for effective scaling."
  }
}

# Memory utilization threshold for triggering horizontal pod autoscaling
# When average memory usage across all pods exceeds this percentage, scale up
# Memory-based scaling helps handle memory-intensive workloads
variable "openemr_memory_utilization_threshold" {
  description = "Memory utilization percentage to trigger scaling (recommended: 70-85%)"
  type        = number
  default     = 80 # 80% memory threshold for responsive scaling

  # Validation ensures reasonable memory threshold bounds
  validation {
    condition     = var.openemr_memory_utilization_threshold >= 50 && var.openemr_memory_utilization_threshold <= 95
    error_message = "Memory utilization threshold must be between 50% and 95% for effective scaling."
  }
}

# Scale down stabilization period in seconds
# Prevents rapid scaling down when load temporarily decreases
# Longer periods are recommended for healthcare workloads to maintain stability
variable "openemr_scale_down_stabilization_seconds" {
  description = "Seconds to wait before scaling down (recommended: 300-600 for healthcare workloads)"
  type        = number
  default     = 300 # 5 minutes stabilization for healthcare workloads

  # Validation ensures reasonable stabilization period
  validation {
    condition     = var.openemr_scale_down_stabilization_seconds >= 60 && var.openemr_scale_down_stabilization_seconds <= 3600
    error_message = "Scale down stabilization must be between 60 and 3600 seconds for stable operation."
  }
}

# Scale up stabilization period in seconds
# Prevents rapid scaling up when load temporarily increases
# Shorter periods provide more responsive scaling for user experience
variable "openemr_scale_up_stabilization_seconds" {
  description = "Seconds to wait before scaling up (recommended: 60-120 for responsive scaling)"
  type        = number
  default     = 60 # 1 minute stabilization for responsive scaling

  # Validation ensures reasonable stabilization period
  validation {
    condition     = var.openemr_scale_up_stabilization_seconds >= 30 && var.openemr_scale_up_stabilization_seconds <= 300
    error_message = "Scale up stabilization must be between 30 and 300 seconds for effective scaling."
  }
}

# =============================================================================
# OPENEMR APPLICATION CONFIGURATION VARIABLES
# =============================================================================
# These variables control the OpenEMR application version and feature configuration

# OpenEMR Docker image version to deploy
# Use specific version tags for production stability
# 'latest' tag should only be used in development environments
variable "openemr_version" {
  description = "OpenEMR Docker image version to deploy (use specific versions for production)"
  type        = string
  default     = "8.0.0" # Stable OpenEMR version

  # Validation ensures proper version format
  validation {
    condition     = can(regex("^(latest|[0-9]+\\.[0-9]+\\.[0-9]+(-[a-zA-Z0-9]+)?)$", var.openemr_version))
    error_message = "OpenEMR version must be 'latest' or follow semantic versioning (e.g., '8.0.0', '8.0.0-dev')."
  }
}

# =============================================================================
# OPENEMR FEATURE CONFIGURATION VARIABLES
# =============================================================================
# These variables control optional OpenEMR features for security and functionality

# Enable OpenEMR REST API endpoints (FHIR, REST API)
# These APIs provide programmatic access to patient data
# Disable if not needed to reduce attack surface and improve security
variable "enable_openemr_api" {
  description = "Enable OpenEMR REST API endpoints (FHIR, REST API) - SECURITY: Disable if not needed"
  type        = bool
  default     = false # Disabled by default for security
}

# Enable OpenEMR patient portal functionality
# Patient portal allows patients to access their own medical records
# Disable if not needed to reduce complexity and potential security risks
variable "enable_patient_portal" {
  description = "Enable OpenEMR patient portal functionality - SECURITY: Disable if not needed"
  type        = bool
  default     = false # Disabled by default for security
}
