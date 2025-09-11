# AWS WAFv2 for OpenEMR (REGIONAL) + S3 Logging

# toggle with var.enable_waf (bool) and set var.cluster_name (string)

# Unique suffix for resource names
resource "random_id" "waf_logs" {
  byte_length = 4
}

# -----------------------------
# Regex Pattern Set (UA filter)
# -----------------------------
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

# Web ACL
resource "aws_wafv2_web_acl" "openemr" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.cluster_name}-waf-acl"
  description = "WAF Web ACL for OpenEMR application"
  scope       = "REGIONAL"

  # Rule 1: AWS Managed Rules - Core Rule Set
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

  # Rule 2: AWS Managed Rules - SQL Injection
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

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-waf-acl-metric"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

# Attach WAF Logging to the Web ACL (S3)
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
