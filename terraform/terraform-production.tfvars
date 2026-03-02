# Production Terraform variables
# This file shows the secure production defaults
# DO NOT use this file for testing - it has deletion protection enabled

# Enable deletion protection for production safety
rds_deletion_protection = true

# Production backup retention
backup_retention_days = 30

# Production Aurora capacity
aurora_min_capacity = 0.5
aurora_max_capacity = 16

# Database Monitoring - CloudWatch Database Insights
# Use "advanced" for 465-day retention and enhanced diagnostics in production
database_insights_mode = "advanced"

# Enable WAF for production security
enable_waf = true

# Restrict public access for production security
enable_public_access = false

# Production environment
environment = "production"
