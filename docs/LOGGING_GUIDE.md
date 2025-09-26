# OpenEMR 7.0.3.4 Logging Guide

This comprehensive guide covers the enhanced logging configuration for OpenEMR 7.0.3.4 on Amazon EKS, including CloudWatch integration, Fluent Bit configuration, and troubleshooting.

## 📋 Table of Contents

- [Overview](#overview)
- [Logging Architecture](#logging-architecture)
- [CloudWatch Log Groups](#cloudwatch-log-groups)
- [Fluent Bit Configuration](#fluent-bit-configuration)
- [IRSA Authentication](#irsa-authentication)
- [OpenEMR Logging](#openemr-logging)
- [Log Directory Structure](#log-directory-structure)
- [Compliance and Security](#compliance-and-security)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## Overview

OpenEMR 7.0.3.4 includes comprehensive logging capabilities designed for healthcare compliance and operational monitoring:

- **Multi-layer logging**: Application, system, audit, and infrastructure logs
- **Real-time processing**: Fluent Bit with 5-second refresh intervals
- **CloudWatch integration**: Centralized log management with KMS encryption
- **Compliance ready**: audit trails and retention policies
- **IRSA authentication**: Secure AWS service integration using IAM Roles for Service Accounts
- **Sidecar deployment**: Fluent Bit runs as a sidecar container for reliable log collection

## Logging Architecture

```mermaid
graph TB
    subgraph "OpenEMR Application"
        A[EventAuditLogger] --> D[Database Tables]
        B[SystemLogger] --> E[System Logs]
        C[Custom ADODB Wrapper] --> F[SQL Audit Logs]
    end

    subgraph "File System"
        D --> G[var-log-openemr]
        E --> H[openemr-logs-and-misc]
        F --> I[var-log-apache2]
        H --> J
        I --> J
    end

    subgraph "Fluent Bit Sidecar"
        G --> J[Fluent Bit Container]
        J --> K[CloudWatch Logs]
    end

    subgraph "AWS CloudWatch"
        K --> L[aws-eks-cluster-openemr-test]
        K --> M[aws-eks-cluster-openemr-apache]
        K --> N[aws-eks-cluster-openemr-application]
        K --> O[aws-eks-cluster-openemr-system]
        K --> P[aws-eks-cluster-openemr-audit]
        K --> Q[aws-eks-cluster-openemr-php_error]
        K --> R[aws-eks-cluster-fluent-bit-metrics]
    end

    %% Add descriptive labels
    L -.-> L1["/aws/eks/CLUSTER_NAME/openemr/test"]
    M -.-> M1["/aws/eks/CLUSTER_NAME/openemr/apache"]
    N -.-> N1["/aws/eks/CLUSTER_NAME/openemr/application"]
    O -.-> O1["/aws/eks/CLUSTER_NAME/openemr/system"]
    P -.-> P1["/aws/eks/CLUSTER_NAME/openemr/audit"]
    Q -.-> Q1["/aws/eks/CLUSTER_NAME/openemr/php_error"]
    R -.-> R1["/aws/eks/CLUSTER_NAME/fluent-bit/metrics"]
```

## CloudWatch Log Groups

### Current Log Groups

| Log Group | Purpose | Retention | Encryption | Status |
|-----------|---------|-----------|------------|---------|
| `/aws/eks/${CLUSTER_NAME}/openemr/test` | Test logs for verification | 30 days | KMS | ✅ Working |
| `/aws/eks/${CLUSTER_NAME}/openemr/apache` | Apache access and error logs | 30 days | KMS | 🔄 Monitoring |
| `/aws/eks/${CLUSTER_NAME}/openemr/forward` | Forward protocol logs | 30 days | KMS | 🔄 Monitoring |
| `/aws/eks/${CLUSTER_NAME}/openemr/application` | OpenEMR application logs | 30 days | KMS | 🔄 Monitoring |
| `/aws/eks/${CLUSTER_NAME}/openemr/system` | System-level operational logs | 30 days | KMS | 🔄 Monitoring |
| `/aws/eks/${CLUSTER_NAME}/openemr/audit` | Basic audit trail | 365 days | KMS | 🔄 Monitoring |
| `/aws/eks/${CLUSTER_NAME}/openemr/php_error` | PHP application errors | 30 days | KMS | 🔄 Monitoring |
| `/aws/eks/${CLUSTER_NAME}/fluent-bit/metrics` | Fluent Bit operational metrics | 30 days | KMS | ✅ Working |

**Status Legend:**

- ✅ **Working**: Logs are actively flowing to CloudWatch
- 🔄 **Monitoring**: Paths are monitored, waiting for log files to be generated

### Log Group Features

- **Auto-creation**: `auto_create_group: true` allows Fluent Bit to create log groups automatically
- **Dynamic naming**: Uses environment variables for cluster-specific naming
- **IRSA integration**: Role-based authentication for secure access
- **Retry handling**: Configurable retry limits for reliable log delivery

## Fluent Bit Configuration

### Current Configuration Overview

The Fluent Bit configuration is deployed as a ConfigMap (`fluent-bit-sidecar-config`) and includes:

- **Test logs**: Dummy input for verification
- **Apache logs**: Access and error logs from `/var/log/apache2/`
- **OpenEMR logs**: Application, system, and audit logs
- **PHP errors**: PHP application error logs
- **Forward protocol**: External log ingestion via port 24224
- **Metrics**: Fluent Bit operational metrics using `node_exporter_metrics`

### Input Configuration

```yaml
# Test log input to verify functionality
[INPUT]
    Name              dummy
    Tag               test.logs
    Dummy            {"message": "Fluent Bit sidecar is working!", "timestamp": "2025-08-26", "level": "INFO"}
    Rate             1

# Collect Apache access logs
[INPUT]
    Name              tail
    Path              /var/log/apache2/access.log
    Tag               apache.access
    Refresh_Interval  5
    Mem_Buf_Limit     50MB
    Skip_Empty_Lines  On

# Collect Apache error logs
[INPUT]
    Name              tail
    Path              /var/log/apache2/error.log
    Tag               apache.error
    Refresh_Interval  5
    Mem_Buf_Limit     50MB
    Skip_Empty_Lines  On

# Collect OpenEMR application logs
[INPUT]
    Name              tail
    Path              /var/log/openemr/*.log
    Tag               openemr.application
    Refresh_Interval  5
    Mem_Buf_Limit     50MB
    Skip_Empty_Lines  On

# Collect OpenEMR system logs
[INPUT]
    Name              tail
    Path              /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/system_logs/*.log
    Tag               openemr.system
    Refresh_Interval  5
    Mem_Buf_Limit     50MB
    Skip_Empty_Lines  On

# Collect OpenEMR audit logs
[INPUT]
    Name              tail
    Path              /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/audit_logs/*.log
    Tag               openemr.audit
    Refresh_Interval  5
    Mem_Buf_Limit     50MB
    Skip_Empty_Lines  On

# Collect PHP error logs
[INPUT]
    Name              tail
    Path              /var/log/php_errors.log
    Tag               openemr.php_error
    Refresh_Interval  5
    Mem_Buf_Limit     50MB
    Skip_Empty_Lines  On

# Forward protocol for external log sources
[INPUT]
    Name              forward
    Listen            0.0.0.0
    Port              24224
    Tag               forward.logs

# Fluent Bit Metrics
[INPUT]
    Name              node_exporter_metrics
    Tag               fluent-bit.metrics
    Scrape_Interval   30
```

### Output Configuration

The current configuration uses hardcoded values for reliability:

```yaml
# Test logs output
[OUTPUT]
    Name                cloudwatch_logs
    Match               test.logs
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/openemr/test
    log_stream_prefix   test-
    auto_create_group   true
    retry_limit         3

# Apache logs output
[OUTPUT]
    Name                cloudwatch_logs
    Match               apache.*
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/openemr/apache
    log_stream_prefix   apache-
    auto_create_group   true
    retry_limit         3

# Forward logs output
[OUTPUT]
    Name                cloudwatch_logs
    Match               forward.logs
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/openemr/forward
    log_stream_prefix   forward-
    auto_create_group   true
    retry_limit         3

# OpenEMR Application Logs
[OUTPUT]
    Name                cloudwatch_logs
    Match               openemr.application
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/openemr/application
    log_stream_prefix   application-
    auto_create_group   true
    retry_limit         3

# OpenEMR System Logs
[OUTPUT]
    Name                cloudwatch_logs
    Match               openemr.system
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/openemr/system
    log_stream_prefix   system-
    auto_create_group   true
    retry_limit         3

# OpenEMR Audit Logs
[OUTPUT]
    Name                cloudwatch_logs
    Match               openemr.audit
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/openemr/audit
    log_stream_prefix   audit-
    auto_create_group   true
    retry_limit         3

# PHP Error Logs
[OUTPUT]
    Name                cloudwatch_logs
    Match               openemr.php_error
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/openemr/php_error
    log_stream_prefix   php-error-
    auto_create_group   true
    retry_limit         3

# Fluent Bit Metrics
[OUTPUT]
    Name                cloudwatch_logs
    Match               fluent-bit.metrics
    region              ${AWS_REGION}
    log_group_name      /aws/eks/${CLUSTER_NAME}/fluent-bit/metrics
    log_stream_prefix   metrics-
    auto_create_group   true
    retry_limit         3
```

### Sidecar Deployment Pattern

Fluent Bit is deployed as a sidecar container within each OpenEMR pod, providing:

- **Reliable log collection**: No dependency on external DaemonSets
- **Pod-level isolation**: Each pod manages its own logging
- **Automatic scaling**: Logging scales with application replicas
- **Resource efficiency**: Shared pod resources and networking
- **Root access**: Runs as root user for comprehensive file access

### Container Configuration

```yaml
- name: fluent-bit-sidecar
  image: fluent/fluent-bit:4.1.0
  ports:
  - containerPort: 2020
    name: fluent-bit-http
    protocol: TCP
  - containerPort: 24224
    name: fluent-bit-fwd
    protocol: TCP
  env:
  - name: AWS_REGION
    value: "${AWS_REGION}"
  - name: CLUSTER_NAME
    value: "${CLUSTER_NAME}"
  - name: AWS_WEB_IDENTITY_TOKEN_FILE
    value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
  - name: AWS_ROLE_ARN
    value: "arn:aws:iam::${AWS_ACCOUNT}:role/openemr-service-account-role"
  resources:
    limits:
      cpu: "200m"
      memory: "256Mi"
    requests:
      cpu: "50m"
      memory: "64Mi"
  volumeMounts:
  - name: fluent-bit-config
    mountPath: /fluent-bit/etc/
  - name: tmp
    mountPath: /tmp
```

## IRSA Authentication

### Service Account Configuration

The logging configuration uses IAM Role for Service Accounts (IRSA) for secure AWS authentication:

```yaml
# Service account with CloudWatch permissions
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openemr-sa
  namespace: openemr
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${AWS_ACCOUNT}:role/openemr-service-account-role
```

### Required IAM Permissions

The `openemr-service-account-role` includes comprehensive CloudWatch Logs permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams"
            ],
            "Resource": [
                "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT}:log-group:/aws/eks/${CLUSTER_NAME}/openemr/*",
                "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT}:log-group:/aws/eks/${CLUSTER_NAME}/openemr/*:*",
                "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT}:log-group:/aws/eks/${CLUSTER_NAME}/fluent-bit/*",
                "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT}:log-group:/aws/eks/${CLUSTER_NAME}/fluent-bit/*:*"
            ]
        }
    ]
}
```

### Trust Policy

The IAM role trust policy allows the EKS OIDC provider to assume the role:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/EXAMPLETOKEN"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.${AWS_REGION}.amazonaws.com/id/EXAMPLETOKEN:sub": "system:serviceaccount:openemr:openemr-sa",
                    "oidc.eks.${AWS_REGION}.amazonaws.com/id/EXAMPLETOKEN:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
```

## OpenEMR Logging

### EventAuditLogger

The `EventAuditLogger` class provides comprehensive audit logging:

```php
// Located in: src/Common/Logging/EventAuditLogger.php
class EventAuditLogger
{
    // Logs audited events to database tables
    public function newEvent($event, $status, $comments = '', $user = '', $group = '', $success = '1', $log_from = '', $patient_id = '', $log_user = '', $log_group = '')

    // Records log items with RFC3881 compliance
    public function recordLogItem($event, $status, $comments = '', $user = '', $group = '', $success = '1', $log_from = '', $patient_id = '', $log_user = '', $log_group = '')
}
```

### SystemLogger

The `SystemLogger` class implements PSR-3 logging interface:

```php
// Located in: src/Common/Logging/SystemLogger.php
class SystemLogger implements LoggerInterface
{
    // Uses Monolog ErrorLogHandler for system logging
    // Configurable log levels based on $GLOBALS['system_error_logging']
    // Default level: WARNING
}
```

### Database Logging

OpenEMR uses custom ADODB wrapper for SQL auditing:

```php
// Located in: library/ADODB_mysqli_log.php
class ADODB_mysqli_log extends ADODB_mysqli
{
    // Logs all SQL operations using EventAuditLogger
    // Captures queries, parameters, and execution results
    // Integrates with audit trail for compliance
}
```

## Log Directory Structure

### Standard Log Directories

```
/var/log/
├── openemr/
│   ├── placeholder.log      # Placeholder for application logs
├── apache2/
│   ├── access.log           # Web server access logs
│   ├── error.log            # Web server error logs
│   └── ssl_error.log        # SSL error logs
└── php_errors.log           # PHP application error logs
```

### OpenEMR-Specific Directories

```
/var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/
├── system_logs/             # System-level operational logs
│   └── placeholder.log      # Placeholder for system logs
├── audit_logs/              # Detailed audit trails
│   └── placeholder.log      # Placeholder for audit logs
└── methods/                 # Legacy method logs
    └── existing_logs.log
```

## Compliance and Security

### Compliance

- **Audit trails**: Comprehensive logging of all patient data access
- **User authentication**: Logged user actions and system access
- **Data integrity**: Immutable log records with retention policies
- **Access controls**: Role-based permissions for log access

### Security Features

- **IRSA authentication**: Secure AWS service integration
- **KMS encryption**: CloudWatch logs encrypted at rest
- **IAM policies**: Least-privilege access to CloudWatch resources
- **Network isolation**: Logs transmitted over secure AWS infrastructure

### Retention Policies

- **Application logs**: 30 days retention
- **Audit logs**: 365 days retention (compliance requirement)
- **System logs**: 30 days retention
- **Metrics**: 30 days retention

## Monitoring and Alerting

### CloudWatch Metrics

Fluent Bit provides operational metrics via the `node_exporter_metrics` plugin:

- **Input metrics**: Records processed, bytes received
- **Output metrics**: Records sent, bytes transmitted
- **Error metrics**: Failed operations, retry counts
- **Performance metrics**: Processing latency, buffer usage

### Health Checks

Fluent Bit includes comprehensive health monitoring:

```yaml
livenessProbe:
  httpGet:
    path: /
    port: 2020
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 1
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /api/v1/health
    port: 2020
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 1
  failureThreshold: 3
```

### Log Verification

To verify logging is working correctly:

```bash
# Check Fluent Bit container status
kubectl get pods -n openemr -l app=openemr

# View Fluent Bit logs
kubectl logs <pod-name> -c fluent-bit-sidecar -n openemr

# Verify CloudWatch log groups
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" --region ${AWS_REGION}

# Check specific log streams
aws logs describe-log-streams --log-group-name "/aws/eks/${CLUSTER_NAME}/openemr/test" --region ${AWS_REGION}
```

## Troubleshooting

### Common Issues

#### 1. Permission Errors for Log Files

**Symptoms**: Fluent Bit logs show "read error, check permissions"

**Cause**: Log directories or files don't exist yet

**Solution**:

```bash
# Create missing directories and placeholder files
kubectl exec <pod-name> -c openemr -n openemr -- mkdir -p /var/log/openemr /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/system_logs /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/audit_logs

kubectl exec <pod-name> -c openemr -n openemr -- touch /var/log/openemr/placeholder.log /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/system_logs/placeholder.log /var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/audit_logs/placeholder.log
```

#### 2. IRSA Authentication Issues

**Symptoms**: "AccessDeniedException: Unauthorized Exception! EKS does not have permissions to assume the associated role"

**Cause**: Incorrect IAM role trust policy or missing IRSA annotation

**Solution**: Verify service account annotation and IAM role trust policy

#### 3. Missing Log Groups

**Symptoms**: CloudWatch log groups not created

**Cause**: Fluent Bit configuration issues or IAM permissions

**Solution**: Check Fluent Bit logs and IAM policy permissions

### Debugging Steps

1. **Check pod status**: Ensure Fluent Bit sidecar is running
2. **Review container logs**: Look for error messages in Fluent Bit logs
3. **Verify IAM permissions**: Check CloudWatch Logs permissions
4. **Test authentication**: Verify IRSA token and role assumption
5. **Monitor CloudWatch**: Check if log groups are being created

## Recent Improvements (August 28, 2025)

### Enhanced Health Checks

- **Improved probe configuration**: Better timing and failure thresholds for production workloads
- **User-Agent headers**: Added health check identification for better monitoring
- **Optimized intervals**: Reduced unnecessary health check overhead

### Resource Optimization

- **Better resource allocation**: Increased CPU and memory limits for improved performance
- **Fluent Bit optimization**: Enhanced resource allocation for better log processing
- **Security context improvements**: Added proper group permissions for compliance

### Performance Enhancements

- **Startup probe optimization**: Better handling of slow-starting containers
- **Readiness probe tuning**: Faster detection of ready state
- **Liveness probe improvements**: More resilient to temporary issues

## Best Practices

### Configuration

- **Use hardcoded values**: Avoid environment variable substitution for critical paths
- **Monitor all inputs**: Include health checks for all log sources
- **Set appropriate limits**: Configure memory and CPU limits for Fluent Bit
- **Enable health checks**: Use liveness and readiness probes

### Security

- **Least privilege**: Grant only necessary CloudWatch permissions
- **Encrypt logs**: Enable KMS encryption for all log groups
- **Monitor access**: Log all authentication and authorization events

### Performance

- **Optimize buffer sizes**: Set appropriate `Mem_Buf_Limit` values
- **Use skip empty lines**: Reduce processing overhead for empty log entries
- **Monitor metrics**: Track Fluent Bit performance metrics
- **Set refresh intervals**: Balance real-time processing with resource usage

### Maintenance

- **Regular verification**: Periodically check log flow to CloudWatch
- **Update configurations**: Keep Fluent Bit configuration current
- **Monitor resource usage**: Track CPU and memory consumption
- **Review retention policies**: Ensure compliance with data retention requirements
