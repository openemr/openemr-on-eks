# CloudWatch Log Groups for Application Logs
resource "aws_cloudwatch_log_group" "openemr_app" {
  name              = "/aws/eks/${var.cluster_name}/openemr/application"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-app-logs"
    Application = "OpenEMR"
    LogType     = "Application"
    Version     = "7.0.3.4"
  }
}

resource "aws_cloudwatch_log_group" "openemr_access" {
  name              = "/aws/eks/${var.cluster_name}/openemr/access"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-access-logs"
    Application = "OpenEMR"
    LogType     = "Access"
    Version     = "7.0.3.4"
  }
}

resource "aws_cloudwatch_log_group" "openemr_error" {
  name              = "/aws/eks/${var.cluster_name}/openemr/error"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-error-logs"
    Application = "OpenEMR"
    LogType     = "Error"
    Version     = "7.0.3.4"
  }
}

resource "aws_cloudwatch_log_group" "openemr_audit" {
  name              = "/aws/eks/${var.cluster_name}/openemr/audit"
  retention_in_days = var.audit_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-audit-logs"
    Application = "OpenEMR"
    LogType     = "Audit"
    Version     = "7.0.3.4"
  }
}

# New CloudWatch Log Groups for Enhanced OpenEMR 7.0.3.4 Logging
resource "aws_cloudwatch_log_group" "openemr_audit_detailed" {
  name              = "/aws/eks/${var.cluster_name}/openemr/audit_detailed"
  retention_in_days = var.audit_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-audit-detailed-logs"
    Application = "OpenEMR"
    LogType     = "AuditDetailed"
    Version     = "7.0.3.4"
    Description = "Detailed audit logs with patient ID and event categorization"
  }
}

resource "aws_cloudwatch_log_group" "openemr_system" {
  name              = "/aws/eks/${var.cluster_name}/openemr/system"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-system-logs"
    Application = "OpenEMR"
    LogType     = "System"
    Version     = "7.0.3.4"
    Description = "System-level logs with component status and operational events"
  }
}

resource "aws_cloudwatch_log_group" "openemr_php_error" {
  name              = "/aws/eks/${var.cluster_name}/openemr/php_error"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-php-error-logs"
    Application = "OpenEMR"
    LogType     = "PHPError"
    Version     = "7.0.3.4"
    Description = "PHP application errors with file and line information"
  }
}

# CloudWatch Log Group for Fluent Bit Metrics
resource "aws_cloudwatch_log_group" "fluent_bit_metrics" {
  name              = "/aws/eks/${var.cluster_name}/fluent-bit/metrics"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-fluent-bit-metrics"
    Application = "FluentBit"
    LogType     = "Metrics"
    Version     = "4.0.8"
    Description = "Fluent Bit operational metrics and health checks"
  }
}

# Additional CloudWatch Log Groups for Fluent Bit Sidecar
resource "aws_cloudwatch_log_group" "openemr_test" {
  name              = "/aws/eks/${var.cluster_name}/openemr/test"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-test-logs"
    Application = "OpenEMR"
    LogType     = "Test"
    Version     = "7.0.3.4"
    Description = "Test logs for Fluent Bit sidecar verification"
  }
}

resource "aws_cloudwatch_log_group" "openemr_apache" {
  name              = "/aws/eks/${var.cluster_name}/openemr/apache"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-apache-logs"
    Application = "OpenEMR"
    LogType     = "Apache"
    Version     = "7.0.3.4"
    Description = "Apache access and error logs"
  }
}

resource "aws_cloudwatch_log_group" "openemr_forward" {
  name              = "/aws/eks/${var.cluster_name}/openemr/forward"
  retention_in_days = var.app_logs_retention_days
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = {
    Name        = "${var.cluster_name}-openemr-forward-logs"
    Application = "OpenEMR"
    LogType     = "Forward"
    Version     = "7.0.3.4"
    Description = "Forward protocol logs from external sources"
  }
}
