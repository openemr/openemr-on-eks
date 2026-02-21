# OpenEMR on EKS Troubleshooting Guide

This comprehensive guide helps diagnose and resolve issues with OpenEMR on EKS Auto Mode, with specific focus on healthcare compliance and Auto Mode-specific challenges.

## 📋 Table of Contents

### **🔧 Quick Diagnostics**

- [Essential Validation Scripts](#essential-validation-scripts)
- [Complete Scripts Reference for Troubleshooting](#complete-scripts-reference-for-troubleshooting)
- [Script-Based Troubleshooting Workflow](#script-based-troubleshooting-workflow)
- [Auto Mode Health Check](#auto-mode-health-check)

### **🚨 Common Issues and Solutions**

- [Monitoring Installation Warnings](#1-monitoring-installation-warnings)
- [Cannot Access Cluster](#2-cannot-access-cluster)
- [Terraform Deployment Failures](#3-terraform-deployment-failures)
- [Pods Not Starting](#4-pods-not-starting)
- [Database Connection Issues](#5-database-connection-issues)
- [EKS Auto Mode Specific Issues](#6-eks-auto-mode-specific-issues)
- [HPA Metrics Server Issues](#7-hpa-metrics-server-issues)
- [Logging and Monitoring Issues](#8-logging-and-monitoring-issues)
  - [Loki Logs Not Appearing](#issue-loki-logs-not-appearing-in-grafana)
  - [Tempo Traces Not Appearing](#issue-tempo-traces-not-appearing)
- [Common Error Messages Reference](#-common-error-messages-reference)

### **💰 Cost and Performance**

- [Unexpected High Costs](#unexpected-high-costs)
- [Performance Degradation](#performance-degradation)

### **🔍 Advanced Debugging**

- [Security Incident Response](#-security-incident-response)
- [Best Practices for Error Prevention](#️-best-practices-for-error-prevention)

### **📞 Getting Help**

- [Getting Help](#-getting-help-1)

---

## Essential Validation Scripts

### Run These First

```bash
# 1. Comprehensive system validation
cd scripts
./validate-deployment.sh

# 2. Storage-specific validation (if pods are pending)
./validate-efs-csi.sh

# 3. Cluster access check
./cluster-security-manager.sh check-ip

# 4. Clean deployment if corrupted
# WARNING: ONLY USE IN DEVELOPMENT OR AFTER BACKING UP DATA! This will result in data loss.
./clean-deployment.sh
```

### Complete Scripts Reference for Troubleshooting

#### **Application Issues**

```bash
# Check OpenEMR version and available updates
./check-openemr-versions.sh --latest

# Verify feature configuration
./openemr-feature-manager.sh status all

# Enable/disable features for testing
./openemr-feature-manager.sh disable api   # Disable API if causing issues
./openemr-feature-manager.sh enable portal # Enable portal for testing
```

#### **Infrastructure Issues**

```bash
# Comprehensive deployment validation
./validate-deployment.sh

# Storage system validation
./validate-efs-csi.sh

# Clean and reset deployment
# WARNING: ONLY USE IN DEVELOPMENT OR AFTER BACKING UP DATA! This will result in data loss.
./clean-deployment.sh
```

#### **Security and Access Issues**

```bash
# Check cluster access status
./cluster-security-manager.sh status

# Check if IP changed
./cluster-security-manager.sh check-ip

# Temporarily enable access (DEVELOPMENT ONLY)
./cluster-security-manager.sh enable

# Check SSL certificate status
./ssl-cert-manager.sh status

# Check self-signed certificate renewal
./ssl-renewal-manager.sh status
```

#### **Backup and Recovery Issues**

See comprehensive documentation on the backup and restore system [here](../docs/BACKUP_RESTORE_GUIDE.md).

```bash
# Create emergency backup
./backup.sh

# Restore from backup (disaster recovery)
./restore.sh <backup-bucket> <snapshot-id> <backup-region>
```

### Script-Based Troubleshooting Workflow

#### **Step 1: Initial Diagnosis**

```bash
cd scripts

# Run comprehensive validation
./validate-deployment.sh

# If validation fails, check specific areas:
# - AWS credentials
# - Cluster connectivity
# - Infrastructure status
# - Application health
```

#### **Step 2: Specific Issue Diagnosis**

```bash
# For pod/storage issues:
./validate-efs-csi.sh

# For access issues:
./cluster-security-manager.sh check-ip
./cluster-security-manager.sh status

# For feature-related issues:
./openemr-feature-manager.sh status all

# For SSL/certificate issues:
./ssl-cert-manager.sh status
./ssl-renewal-manager.sh status
```

#### **Step 3: Resolution Actions**

```bash
# Clean deployment if corrupted:
# WARNING: ONLY USE IN DEVELOPMENT OR AFTER BACKING UP DATA! This will result in data loss.
./clean-deployment.sh

# DEVELOPMENT ONLY! In production this should never be enabled; use more secure management methods instead.
# Reset cluster access:
./cluster-security-manager.sh enable  # Then disable after work

# Update OpenEMR version:
./check-openemr-versions.sh --latest
# Update terraform.tfvars with new version
# Run terraform apply and k8s/deploy.sh

# Restore deployment files to clean state:
./restore-defaults.sh --backup

# Restore from backup if needed:
./restore.sh <backup-bucket> <snapshot-id> <backup-region>
```

### Auto Mode Health Check

```bash
#!/bin/bash
# Save as check-auto-mode.sh

echo "=== EKS Auto Mode Health Check ==="

# Check cluster compute configuration
echo "Checking Auto Mode status..."
aws eks describe-cluster --name openemr-eks \
  --query 'cluster.computeConfig' \
  --output json

# Check for nodeclaims
echo "Checking nodeclaims..."
kubectl get nodeclaim

# Check for node pools
echo "Checking node pools..."
kubectl get nodepool

# Check for pending pods that might need Auto Mode provisioning
echo "Checking for pending pods..."
kubectl get pods --all-namespaces --field-selector=status.phase=Pending
```

## 🚨 Common Issues and Solutions

### 1. Monitoring Installation Warnings

#### **Warning: "OpenEMR dashboard not configured"**

```
[WARN] ⚠️ OpenEMR dashboard not configured
```

**Explanation:** This is a non-critical warning indicating that a custom OpenEMR Grafana dashboard hasn't been created yet.

For more information search [install-monitoring.sh](../monitoring/install-monitoring.sh) for "OpenEMR dashboard not configured".

**Impact:**

- ✅ All monitoring functionality works normally
- ✅ Prometheus collects OpenEMR metrics
- ✅ Grafana displays standard Kubernetes dashboards
- ⚠️ No OpenEMR-specific dashboard available

**Resolution:**

- This warning can be safely ignored
- The monitoring stack is fully functional
- Custom OpenEMR dashboards can be added later if needed
- This warning will go away if you specify a specific "grafana-dashboard-openemr" configmap to make a custom dashboard for OpenEMR and it will be applied automatically as part of the install-monitoring.sh script.

### 2. Cannot Access Cluster

#### Symptoms

```
Unable to connect to the server: dial tcp: i/o timeout
error: You must be logged in to the server (Unauthorized)
The connection to the server was refused
```

#### Root Causes

- **IP address change**
- **Cluster endpoint disabled**
- **AWS credentials expired**
- **Network connectivity issues**

#### Solutions

**Quick Fix - Update IP Access:**

```bash
# Check your current IP vs allowed
cd scripts
./cluster-security-manager.sh check-ip

# If different, update access
./cluster-security-manager.sh enable

# Verify connection
kubectl get nodes
```

### 3. Terraform Deployment Failures

#### Issue: Auto Mode Not Available

**Error:**

```
Error: error creating EKS Cluster: InvalidParameterException:
Compute config is not supported for Kubernetes version 1.28
```

**Solution:**

```hcl
# In terraform.tfvars, ensure:
kubernetes_version = "1.35"  # Must be 1.29 or higher
```

#### Issue: Insufficient IAM Permissions

**Error:**

```
Error: error creating EKS Cluster: AccessDeniedException
```

**Solution:**

Verify you have the appropriate IAM permissions.

- [AWS Troubleshooting IAM Guide](https://docs.aws.amazon.com/IAM/latest/UserGuide/troubleshoot.html)
- [AWS IAM Policy Simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)

#### Issue: VPC CIDR Conflicts

**Error:**

```
Error: error creating VPC: VpcAlreadyExists: The VPC with CIDR block 10.0.0.0/16 already exists.

```

**Solution:**

```bash
# Check existing VPCs
aws ec2 describe-vpcs --query 'Vpcs[].CidrBlock'

# Use different CIDR in terraform.tfvars
vpc_cidr = "10.1.0.0/16"  # Avoid conflicts
```

### 4. Pods Not Starting

#### Issue: Pods Pending with Auto Mode

**Symptoms:**

```
NAME                      READY   STATUS    RESTARTS   AGE
openemr-7d8b9c6f5-x2klm   0/1     Pending   0          10m
```

**Diagnosis:**

```bash
# Check pod events
kubectl describe pod openemr-7d8b9c6f5-x2klm -n openemr

# Common Auto Mode events:
# "pod didn't match Pod Security Standards"
# "Insufficient cpu"
# "node(s) had volume node affinity conflict"
```

**Solutions:**

**1. Pod Security Standards Issue:**
See [deployment.yaml](../k8s/deployment.yaml) for correct configurations.

```yaml
# Update pod spec with correct configuration
    spec:
      securityContext:
        runAsNonRoot: false
        fsGroup: 0
        seccompProfile:
          type: RuntimeDefault
      serviceAccountName: openemr-sa

      containers:
      - name: openemr
        image: openemr/openemr:${OPENEMR_VERSION}
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: true
          readOnlyRootFilesystem: false
          runAsUser: 0
          runAsGroup: 0
          capabilities:
            drop:
            - ALL
            add:
            - NET_BIND_SERVICE
            - CHOWN
            - SETUID
            - SETGID
            - FOWNER
            - DAC_OVERRIDE
```

**2. Resource Requests Too High:**

```yaml
# Auto Mode has instance type limits
# Adjust resource requests
resources:
  requests:
    cpu: 500m   # Reduced from 2000m
    memory: 1Gi # Reduced from 4Gi
  limits:
    cpu: 2000m
    memory: 2Gi
```

**3. Storage Issues with EFS:**

```bash
# Validate EFS CSI driver
cd scripts
./validate-efs-csi.sh

# Common fix - restart EFS CSI controller
kubectl rollout restart deployment efs-csi-controller -n kube-system
kubectl rollout status deployment efs-csi-controller -n kube-system

# Check PVC binding
kubectl get pvc -n openemr
```

### 5. Database Connection Issues

#### Symptoms

```
Database connection failed
SQLSTATE[HY000] [2002] Connection refused
ERROR 1045 (28000): Access denied for user 'openemr'@'10.0.1.23'
```

#### Diagnosis

```bash
# Check Aurora cluster status
aws rds describe-db-clusters \
  --db-cluster-identifier openemr-eks-aurora \
  --query 'DBClusters[0].Status'

# Check endpoints
aws rds describe-db-clusters \
  --db-cluster-identifier openemr-eks-aurora \
  --query 'DBClusters[0].Endpoint'

# Test connectivity from pod
kubectl exec -it deployment/openemr -n openemr -- /bin/sh
```

#### Solutions

**1. Security Group Issue:**

```bash
# Get Aurora security group
SG_ID=$(aws rds describe-db-clusters \
  --db-cluster-identifier openemr-eks-aurora \
  --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text)

# Add EKS nodes to security group
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 3306 \
  --source-group <eks-node-security-group>
```

**2. Wrong Password in Secret:**

```bash
# Get correct password from Terraform
cd terraform
terraform output -raw aurora_password

# Update Kubernetes secret
kubectl create secret generic openemr-db-credentials \
  --namespace=openemr \
  --from-literal=mysql-password="<correct-password>" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart OpenEMR pods
kubectl rollout restart deployment openemr -n openemr
```

### 6. EKS Auto Mode Specific Issues

#### Issue: Nodes Not Provisioning

**Symptoms:**

```
Pods remain pending
No nodes visible with kubectl get nodes
```

**Diagnosis:**

```bash
# Check Auto Mode events
kubectl get events --all-namespaces | grep -i "auto-mode"

# Check compute configuration
aws eks describe-cluster --name openemr-eks \
  --query 'cluster.computeConfig'

# Verify service quotas
# See documentation: https://docs.aws.amazon.com/servicequotas/latest/userguide/gs-request-quota.html
```

**Solutions:**

**1. Enable Auto Mode (if not enabled):**

```bash
aws eks update-cluster-config \
  --name openemr-eks \
  --compute-config enabled=true \
  --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":true}}' \
  --storage-config '{"blockStorage":{"enabled":true}}'
```

**2. Raise Service Quotas (if necessary):**

See documentation [here](https://docs.aws.amazon.com/servicequotas/latest/userguide/request-quota-increase.html).

#### Issue: 21-Day Node Rotation Disruption

**Symptoms:**

```
Pods restarting every 21 days
Brief service interruptions
```

**Solution:**

```yaml
# Configure Pod Disruption Budget
# NOTE: This is already done for you by default in the deployment.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: openemr-pdb
  namespace: openemr
spec:
  minAvailable: 1  # Always keep 1 pod running
  selector:
    matchLabels:
      app: openemr
```

### 7. HPA Metrics Server Issues

#### Issue: HPA Cannot Collect Metrics

**Symptoms:**

```
Warning   FailedGetResourceMetric        horizontalpodautoscaler/openemr-hpa
failed to get cpu utilization: unable to get metrics for resource cpu:
unable to fetch metrics from resource metrics API: the server could not find
the requested resource (get pods.metrics.k8s.io)
```

**Root Cause:**

The Kubernetes Metrics Server is not installed in the EKS cluster, which is required for HPA to collect resource metrics.

**Diagnosis:**

```bash
# Check if metrics-server is running
kubectl get pods -n kube-system | grep metrics-server

# Check HPA status
kubectl describe hpa -n openemr openemr-hpa

# Test metrics API
kubectl top nodes
kubectl top pods -n openemr
```

**Solution:**

The EKS cluster configuration now includes the Metrics Server addon by default. After deploying with the updated configuration:

1. **Verify Metrics Server is running:**

   ```bash
   kubectl get pods -n kube-system | grep metrics-server
   ```

2. **Test metrics collection:**

   ```bash
   kubectl top nodes
   kubectl top pods -n openemr
   ```

3. **Check HPA status:**

   ```bash
   kubectl describe hpa -n openemr openemr-hpa
   ```

**Prevention:**

- The Metrics Server addon is now included in the EKS cluster configuration
- This ensures HPA can collect the necessary metrics for autoscaling decisions
- The addon is automatically managed by EKS and kept up to date

### 8. Logging and Monitoring Issues

#### Issue: Loki Logs Not Appearing in Grafana

**Symptoms:**
- No logs visible in Grafana when querying Loki datasource
- Loki console shows "Log volume has not been configured"
- Fluent Bit logs show HTTP 500 errors when sending to Loki

**Troubleshooting Steps:**

**1. Verify Loki Volume Configuration**

The Loki volume configuration must be enabled. Check and fix if needed:

```bash
# Check current Loki configuration
helm get values loki -n monitoring

# Upgrade Loki to enable volume
helm upgrade loki grafana/loki \
  --namespace monitoring \
  --version 6.51.0 \
  --reuse-values \
  --set loki.limits_config.volume_enabled=true

# Verify the configuration
kubectl get configmap loki -n monitoring -o yaml | grep -A 5 "volume_enabled"

# Restart Loki components to apply changes
kubectl rollout restart statefulset loki-backend -n monitoring
kubectl rollout restart deployment loki-gateway -n monitoring
kubectl rollout restart deployment loki-read -n monitoring
kubectl rollout restart deployment loki-write -n monitoring
```

**2. Verify Fluent Bit is Running**

```bash
# Check if Fluent Bit sidecar is running in OpenEMR pods
kubectl get pods -n openemr -l app=openemr -o jsonpath='{.items[*].spec.containers[*].name}'

# Check Fluent Bit logs (container name is fluent-bit-sidecar)
kubectl logs -n openemr -l app=openemr --container=fluent-bit-sidecar --tail=50
```

**3. Verify Fluent Bit Configuration**

Check that Fluent Bit is configured to send logs to Loki:

```bash
# View Fluent Bit configuration
kubectl get configmap fluent-bit-sidecar-config -n openemr -o yaml

# Verify Loki output configuration exists
kubectl get configmap fluent-bit-sidecar-config -n openemr -o yaml | grep -A 10 "loki"
```

**4. Test Loki Connectivity from OpenEMR Pods**

```bash
# Get an OpenEMR pod name
POD_NAME=$(kubectl get pods -n openemr -l app=openemr -o jsonpath='{.items[0].metadata.name}')

# Test connectivity to Loki gateway
kubectl exec -n openemr $POD_NAME --container=fluent-bit-sidecar -- wget -qO- --timeout=5 http://loki-gateway.monitoring.svc.cluster.local/ready
```

Expected output: `ready` (if successful)

**5. Check Fluent Bit Logs for Errors**

```bash
# Get Fluent Bit container logs
kubectl logs -n openemr -l app=openemr --container=fluent-bit-sidecar --tail=100 | grep -i "loki\|error\|warn"
```

Look for:
- Connection errors to `loki-gateway.monitoring.svc.cluster.local`
- HTTP 500 errors (indicates Loki volume_enabled issue)
- Network connectivity problems

**6. Verify Loki Service is Accessible**

```bash
# Check Loki gateway service
kubectl get svc loki-gateway -n monitoring

# Test from monitoring namespace
kubectl run test-pod --rm -i --tty --image=curlimages/curl --restart=Never -n monitoring -- \
  curl -s http://loki-gateway.monitoring.svc.cluster.local/ready
```

**7. Check Loki Pods Status**

```bash
# Verify Loki pods are running
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# Check Loki backend logs
kubectl logs -n monitoring -l app.kubernetes.io/name=loki,app.kubernetes.io/component=backend --tail=50
```

**Common Fixes:**

**Fix 1: Enable Volume Configuration**

If Loki console shows "Log volume has not been configured":

```bash
helm upgrade loki grafana/loki \
  --namespace monitoring \
  --reuse-values \
  --set loki.limits_config.volume_enabled=true

# Restart Loki pods to pick up new configuration
kubectl rollout restart statefulset loki-backend -n monitoring
kubectl rollout restart deployment loki-gateway -n monitoring
```

**Fix 2: Restart Fluent Bit Sidecar**

If Fluent Bit isn't sending logs:

```bash
# Restart OpenEMR deployment to restart Fluent Bit sidecars
kubectl rollout restart deployment openemr -n openemr
```

**Fix 3: Verify Container Name**

The Fluent Bit container is named `fluent-bit-sidecar`, not `fluent-bit`:

```bash
# List all containers in OpenEMR pods
kubectl get pod -n openemr -l app=openemr -o jsonpath='{.items[0].spec.containers[*].name}'

# Access logs using correct container name
kubectl logs -n openemr -l app=openemr --container=fluent-bit-sidecar
```

#### Issue: Tempo Traces Not Appearing

**Symptoms:**
- No traces visible in Grafana Tempo datasource
- Service Name filter shows no results for "openemr"

**Troubleshooting Steps:**

**1. Verify OTeBPF DaemonSet is Running**

```bash
# Check OTeBPF pods status
kubectl get pods -n monitoring -l app=otebpf
```

**2. Verify OTeBPF Configuration**

Check that OTeBPF is configured to send traces to Tempo:

```bash
# Check OTeBPF DaemonSet configuration
kubectl get daemonset otebpf -n monitoring -o yaml | grep -A 5 "OTEL_EXPORTER"

# Verify Tempo endpoint configuration
kubectl get daemonset otebpf -n monitoring -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")].value}'
```

Expected: `http://tempo-distributor.monitoring.svc.cluster.local:4318`

**3. Verify Tempo Services are Running**

```bash
# Check Tempo pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo

# Verify Tempo distributor is accessible
kubectl get svc tempo-distributor -n monitoring

# Test connectivity
kubectl run test-pod --rm -i --tty --image=curlimages/curl --restart=Never -n monitoring -- \
  curl -s http://tempo-distributor.monitoring.svc.cluster.local:4318
```

**4. Check OTeBPF Pod Logs**

```bash
# Get OTeBPF pod logs
kubectl logs -n monitoring -l app=otebpf --tail=50

# Look for:
# - Connection errors to Tempo
# - eBPF instrumentation errors
# - Service discovery issues
```

**5. Verify OpenEMR Pod Labels**

OTeBPF auto-instruments pods with label `app=openemr`. Verify:

```bash
# Check OpenEMR pod labels
kubectl get pods -n openemr -l app=openemr --show-labels
```

Expected: `app=openemr` label should be present.

**6. Check Tempo Distributor Logs**

```bash
# Check Tempo distributor for incoming traces
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo,app.kubernetes.io/component=distributor --tail=50

# Look for incoming trace requests
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo,app.kubernetes.io/component=distributor | grep -i "trace\|openemr"
```

**Common Fixes:**

**Fix 1: Restart OTeBPF DaemonSet**

If OTeBPF pods are running but not sending traces:

```bash
# Restart OTeBPF DaemonSet
kubectl rollout restart daemonset otebpf -n monitoring
```

**Fix 2: Verify Service Name Configuration**

Ensure OTeBPF is configured with the correct service name:

```bash
# Check service name in OTeBPF configuration
kubectl get daemonset otebpf -n monitoring -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OTEL_SERVICE_NAME")].value}'
```

Expected: `openemr`

**Fix 3: OTeBPF Pods in ImagePullBackOff**

If OTeBPF pods fail to start:

```bash
# Reinstall with correct OTeBPF configuration
cd monitoring
export OTEBPF_ENABLED="1"
./install-monitoring.sh install
```

**Verifying Log and Trace Flow:**

**Test Log Flow:**

1. Generate test logs in OpenEMR:
```bash
# Access OpenEMR pod
POD_NAME=$(kubectl get pods -n openemr -l app=openemr -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n openemr $POD_NAME -- sh -c 'echo "Test log entry $(date)" >> /var/log/test.log'
```

2. Check Fluent Bit processed it:
```bash
kubectl logs -n openemr $POD_NAME --container=fluent-bit-sidecar --tail=20 | grep -i "test log"
```

3. Query Loki in Grafana:
   - Go to Explore → Select Loki datasource
   - Query: `{namespace="openemr", job="openemr"}`

**Test Trace Flow:**

1. Generate HTTP traffic to OpenEMR:
```bash
# Get OpenEMR LoadBalancer URL
LB_URL=$(kubectl get svc openemr-service -n openemr -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Make a request
curl -k https://$LB_URL
```

2. Check OTeBPF detected it:
```bash
kubectl logs -n monitoring -l app=otebpf --tail=20 | grep -i "openemr\|trace"
```

3. Query Tempo in Grafana:
   - Go to Explore → Select Tempo datasource
   - Service Name: `openemr`
   - Click "Run query"

#### Issue: CloudWatch Logs Not Appearing

**Symptoms:**

```
No logs visible in CloudWatch
Fluent Bit pods showing errors
OpenEMR logs not being captured
```

**Diagnosis:**

```bash
# Check Fluent Bit pod status
kubectl get pods -n openemr -l app=fluent-bit

# Check Fluent Bit logs
kubectl logs -n openemr -l app=fluent-bit

# Verify log groups exist
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/openemr-eks/openemr" \
  --region us-west-2

# Check Fluent Bit configuration
kubectl get configmap fluent-bit-config -n openemr -o yaml
```

**Solutions:**

**1. Restart Fluent Bit:**

```bash
# Restart Fluent Bit daemonset
kubectl rollout restart daemonset fluent-bit -n openemr

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=fluent-bit -n openemr --timeout=300s
```

**2. Verify Log Directory Permissions:**

```bash
# Check log directory permissions in OpenEMR pod
kubectl exec -n openemr deployment/openemr -- ls -la /var/log/openemr/

# Fix permissions if needed
kubectl exec -n openemr deployment/openemr -- chown -R www-data:www-data /var/log/openemr/
kubectl exec -n openemr deployment/openemr -- chmod 755 /var/log/openemr/
```

**3. Check CloudWatch IAM Permissions:**

```bash
# Verify Fluent Bit service account has proper permissions
kubectl get serviceaccount fluent-bit -n openemr -o yaml

# Check if IAM role is attached
kubectl get serviceaccount fluent-bit -n openemr -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

#### Issue: OpenEMR Logging Configuration Missing

**Symptoms:**

```
OpenEMR not writing to expected log locations
Log files not being created
Application errors not captured
```

**Diagnosis:**

```bash
# Check OpenEMR configuration
kubectl exec -n openemr deployment/openemr -- cat /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php | grep -A 10 "Logging Configuration"

# Check log directory structure
kubectl exec -n openemr deployment/openemr -- find /var/log/openemr -type f -name "*.log"

# Check OpenEMR error logs
kubectl exec -n openemr deployment/openemr -- tail -f /var/log/openemr/error.log
```

**Solutions:**

**1. Reconfigure Logging During Restore:**

```bash
# Enable logging configuration during restore
CONFIGURE_LOGGING=true ./restore.sh <backup-bucket> <snapshot-id>

# Or manually configure logging
kubectl exec -n openemr deployment/openemr -- bash -c '
mkdir -p /var/log/openemr /var/log/apache2
chown -R www-data:www-data /var/log/openemr /var/log/apache2
touch /var/log/openemr/error.log /var/log/openemr/access.log /var/log/openemr/system.log
chmod 644 /var/log/openemr/*.log
'
```

**2. Update OpenEMR Configuration:**

```bash
# Add logging configuration to sqlconf.php
kubectl exec -n openemr deployment/openemr -- bash -c '
echo "" >> /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
echo "// OpenEMR 8.0.0 Logging Configuration" >> /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
echo "\$sqlconf[\"log_dir\"] = \"/var/log/openemr\";" >> /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
echo "\$sqlconf[\"error_log\"] = \"/var/log/openemr/error.log\";" >> /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
echo "\$sqlconf[\"access_log\"] = \"/var/log/openemr/access.log\";" >> /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
echo "\$sqlconf[\"system_log\"] = \"/var/log/openemr/system.log\";" >> /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
'
```

#### Issue: High Log Volume or Performance Impact

**Symptoms:**

```
CloudWatch costs increasing rapidly
Application performance degradation
High Fluent Bit resource usage
```

**Diagnosis:**

```bash
# Check log volume in CloudWatch
aws logs describe-log-streams \
  --log-group-name "/aws/eks/openemr-eks/openemr/application" \
  --region us-west-2

# Check Fluent Bit resource usage
kubectl top pods -n openemr -l app=fluent-bit

# Review log retention settings
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/openemr-eks/openemr" \
  --region us-west-2 \
  --query 'logGroups[*].[logGroupName,retentionInDays]'
```

**Solutions:**

**1. Adjust Log Retention:**

```bash
# Reduce retention for non-critical logs
aws logs put-retention-policy \
  --log-group-name "/aws/eks/openemr-eks/openemr/access" \
  --retention-in-days 7

aws logs put-retention-policy \
  --log-group-name "/aws/eks/openemr-eks/openemr/error" \
  --retention-in-days 14
```

**2. Optimize Fluent Bit Configuration:**

```bash
# Update Fluent Bit config to reduce buffer sizes
kubectl patch configmap fluent-bit-config -n openemr -p '{
  "data": {
    "fluent-bit.conf": "..."  # Reduce Mem_Buf_Limit and Buffer_Chunk_Size
  }
}'

# Restart Fluent Bit to apply changes
kubectl rollout restart daemonset fluent-bit -n openemr
```

**3. Filter Unnecessary Logs:**

```bash
# Add filters in Fluent Bit config to exclude verbose logs
# Example: Exclude health check logs, debug logs, etc.
```

## 📊 Common Error Messages Reference

| Error Message | Likely Cause | Solution |
|--------------|-------------|----------|
| `dial tcp: i/o timeout` | IP address changed | Update cluster access with new IP |
| `Pending 0/0 nodes are available` | Auto Mode provisioning | Wait 2-3 minutes for node provisioning |
| `pod didn't match Pod Security Standards` | Security context missing | Add proper securityContext |
| `InvalidParameterException: Compute config` | Wrong K8s version | Use version 1.29+ |
| `SQLSTATE[HY000] [2002]` | Database connection | Check security groups |
| `EFS mount timeout` | EFS CSI issue | Restart EFS CSI controller |
| `403 Forbidden` | IAM permissions | Check pod service account |
| `OOMKilled` | Memory limit exceeded | Increase memory limits |
| `CrashLoopBackOff` | Application startup failure | Check pod logs |
| `ImagePullBackOff` | Can't pull container image | Check image name/registry |

## 💰 Cost and Performance Issues

### Unexpected High Costs

#### Diagnosis

```bash
# Check Auto Mode compute costs (change time range to be one of interest)
aws ce get-cost-and-usage \
  --time-period Start=2025-01-01,End=2025-01-31 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --filter '{
    "Dimensions": {
      "Key": "SERVICE",
      "Values": ["Amazon Elastic Container Service for Kubernetes"]
    }
  }'

# Check Aurora Serverless usage (change time range to be one of interest)
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ServerlessDatabaseCapacity \
  --dimensions Name=DBClusterIdentifier,Value=openemr-eks-aurora \
  --start-time 2025-01-01T00:00:00Z \
  --end-time 2025-01-31T23:59:59Z \
  --period 3600 \
  --statistics Average
```

#### Solutions

**1. Right-size Pod Resources:**

```bash
# Check actual vs requested

# Update if over-provisioned
kubectl patch deployment openemr -n openemr -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "openemr",
          "resources": {
            "requests": {"cpu": "250m", "memory": "512Mi"},
            "limits": {"cpu": "1000m", "memory": "1Gi"}
          }
        }]
      }
    }
  }
}'
```

**2. Optimize Aurora Serverless:**

```bash
# Reduce minimum ACUs if appropriate
aws rds modify-db-cluster \
  --db-cluster-identifier openemr-eks-aurora \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=8
```

### Performance Degradation

#### Symptoms

- Slow page loads (>3 seconds)
- Database timeout errors
- High CPU/memory usage

#### Diagnosis

```bash
# Check HPA status
kubectl get hpa -n openemr
```

#### Solutions

```bash
# Scale up immediately
kubectl scale deployment openemr --replicas=5 -n openemr

# Make adjustments to the autoscaling configuration
```

For documentation on how to adjust the autoscaling configuration see [here](AUTOSCALING_GUIDE.md).

## 🔒 Security Incident Response

### If You Suspect a Breach

```bash
#!/bin/bash
# Security incident response

# 1. Block public access
aws eks update-cluster-config \
  --name openemr-eks \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true

# 2. Preserve evidence
kubectl get events --all-namespaces > security-events.txt
kubectl get pods -n openemr -o name | xargs -I {} kubectl logs --all-containers --timestamps -n openemr {} >> security-logs.txt

# 3. Check for unauthorized access
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --max-items 100

# 4. Totally isolate the cluster.

## Get the cluster security group (the SG attached to the control-plane ENIs)
CLUSTER_SG=$(aws eks describe-cluster --name openemr-eks \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

## Remove ALL inbound rules
aws ec2 revoke-security-group-ingress \
  --group-id "$CLUSTER_SG" \
  --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$CLUSTER_SG" \
    --query 'SecurityGroups[0].IpPermissions' --output json)"

## (Optional) Remove ALL egress rules too
aws ec2 revoke-security-group-egress \
  --group-id "$CLUSTER_SG" \
  --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$CLUSTER_SG" \
    --query 'SecurityGroups[0].IpPermissionsEgress' --output json)"

# 5. Rotate all credentials

# 6. Notify compliance officer
```

## 🎯 Best Practices for Error Prevention

### 🔒 **MANDATORY: End-to-End Testing Before Any Changes**

**Before making any changes to the repository or infrastructure, the end-to-end backup/restore test MUST pass successfully.** This is a core requirement that ensures disaster recovery capabilities remain intact.

#### **Testing Process**

```bash
# Run the complete end-to-end test
./scripts/test-end-to-end-backup-restore.sh --cluster-name openemr-eks-test

# Expected outcome: All 10 test steps must pass
# ✅ Infrastructure deployment
# ✅ OpenEMR installation
# ✅ Test data creation
# ✅ Backup creation
# ✅ Monitoring stack test
# ✅ Infrastructure destruction
# ✅ Infrastructure recreation
# ✅ Backup restoration
# ✅ Verification
# ✅ Final cleanup
```

#### **Why This Is Critical**

- **Disaster Recovery**: Ensures backup/restore functionality works correctly
- **Infrastructure Validation**: Validates Terraform and Kubernetes configurations
- **Regression Prevention**: Prevents changes that could break recovery procedures
- **Compliance**: Demonstrates disaster recovery capabilities for audits
- **Quality Assurance**: Ensures all changes are thoroughly tested

#### **Test Requirements**

- **All test steps must pass**: No exceptions or partial failures allowed
- **Complete infrastructure cycle**: Test must validate full create/destroy/restore cycle
- **Data integrity verification**: Proof files must be correctly restored
- **Connectivity validation**: Database and application connectivity must work after restore
- **Resource cleanup**: All test resources must be properly cleaned up

#### **Failure Handling**

- **If any test step fails**: Changes must be reverted or fixed before proceeding
- **No exceptions**: This testing is mandatory for all development workflows
- **Re-test required**: After fixes, complete test must pass again
- **Documentation required**: All changes must include test results

### Daily Health Checks

```bash
#!/bin/bash
# Daily health check script

echo "=== Daily OpenEMR Health Check ==="
date

# Check cluster
echo "Cluster Status:"
kubectl get nodes

# Check pods
echo "OpenEMR Pods:"
kubectl get pods -n openemr

# Check HPA
echo "Autoscaling Status:"
kubectl get hpa -n openemr

# Check storage
echo "Storage Status:"
kubectl get pvc -n openemr

# Check recent errors
echo "Recent Errors (last hour):"
kubectl logs -n openemr -l app=openemr --since=1h | grep ERROR | tail -5
```

### Weekly Maintenance

```bash

# 1. Update container images, add-ons and other components (if new versions available; test in a development environment before doing any upgrades to production)

# 2. Review and optimize HPA settings

# 3. Check for security updates
aws eks describe-addon-versions --kubernetes-version 1.35 \
  --query 'addons[].{AddonName:addonName,LatestVersion:addonVersions[0].addonVersion}'
```

## 📞 Getting Help

### Before Asking for Help

1. **Run validation scripts**

   ```bash
   cd scripts
   ./validate-deployment.sh
   ./validate-efs-csi.sh
   ```

2. **Document the issue**
   - What were you trying to do?
   - What error did you see?
   - What changed recently?
   - Include relevant logs

### Support Channels

- **[OpenEMR Community Support Section:](https://community.open-emr.org/c/support/16)** For OpenEMR specific support questions.
- **[AWS Support:](https://aws.amazon.com/contact-us/)** For AWS specific support questions.
- **[GitHub Issues for This Project:](../../../issues)** For issues specific to this deployment/project.
