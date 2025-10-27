# =============================================================================
# AWS WAFV2 CONFIGURATION
# =============================================================================
# This configuration creates a Web Application Firewall (WAF) for protecting the
# OpenEMR application against common web exploits and attacks. The WAF is configured
# as a regional resource and can be toggled on/off via the enable_waf variable.

# Unique suffix for WAF resource names to ensure global uniqueness
resource "random_id" "waf_logs" {
  byte_length = 4
}

# -----------------------------
# Regex Pattern Set (User-Agent Filter)
# -----------------------------
# This regex pattern set defines suspicious user-agent strings that should be blocked
# to protect against automated attacks, scrapers, and bots.
resource "aws_wafv2_regex_pattern_set" "ua_suspicious" {
  count = var.enable_waf ? 1 : 0

  name  = "${var.cluster_name}-ua-suspicious"
  scope = "REGIONAL"

  regular_expression {
    regex_string = "bot"
  }
  regular_expression {
    regex_string = "scraper"
  }
  regular_expression {
    regex_string = "crawler"
  }
  regular_expression {
    regex_string = "spider"
  }

  tags = local.common_tags
}

# Web ACL (Web Access Control List)
# This is the main WAF configuration that defines rules for protecting the OpenEMR application.
# It includes AWS managed rule sets and custom rules for comprehensive protection.
resource "aws_wafv2_web_acl" "openemr" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.cluster_name}-waf-acl"
  description = "WAF Web ACL for OpenEMR application"
  scope       = "REGIONAL"

  # Rule 1: AWS Managed Rules - Core Rule Set
  # This rule provides protection against common web exploits including OWASP Top 10 threats
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS Managed Rules - SQL Injection Protection
  # This rule specifically protects against SQL injection attacks targeting the database
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: AWS Managed Rules - Known Bad Inputs
  # This rule blocks requests containing known malicious input patterns and payloads
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: Rate Limiting
  # This rule implements rate limiting to protect against DDoS attacks and abuse
  # by limiting requests to 2000 per 5-minute window per IP address
  rule {
    name     = "RateLimitRule"
    priority = 4

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRuleMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 5: Suspicious User-Agent via Regex Pattern Set
  # This rule blocks requests from suspicious user-agents (bots, scrapers, crawlers, spiders)
  # to prevent automated attacks and unauthorized data collection
  rule {
    name     = "SuspiciousUserAgentRule"
    priority = 5

    action {
      block {}
    }

    statement {
      regex_pattern_set_reference_statement {
        arn = aws_wafv2_regex_pattern_set.ua_suspicious[0].arn

        field_to_match {
          single_header {
            name = "user-agent" # must be lower-case in Terraform for WAFv2
          }
        }

        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SuspiciousUserAgentRuleMetric"
      sampled_requests_enabled   = true
    }
  }

  # Default action for requests that don't match any rules
  default_action {
    allow {}
  }

  # Global visibility configuration for the Web ACL
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-waf-acl-metric"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

# WAF Logging Configuration
# This resource configures logging for the Web ACL to send logs to the S3 bucket
# for security monitoring, compliance, and troubleshooting purposes.
resource "aws_wafv2_web_acl_logging_configuration" "openemr" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_wafv2_web_acl.openemr[0].arn

  # IMPORTANT: Use the S3 bucket ARN with the required aws-waf-logs- prefix
  log_destination_configs = [
    aws_s3_bucket.waf_logs[0].arn
  ]

  # Ensure S3 bucket policy is created before WAF logging configuration
  depends_on = [aws_s3_bucket_policy.waf_logs]

  # Example filters/redactions (optional):
  # logging_filter {
  #   default_behavior = "KEEP"
  #   filter {
  #     behavior     = "DROP"
  #     requirement  = "MEETS_ALL"
  #     condition {
  #       action_condition { action = "ALLOW" }
  #     }
  #   }
  # }
  # redacted_fields {
  #   single_header { name = "authorization" }
  # }
}
