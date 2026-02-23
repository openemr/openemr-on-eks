# OpenEMR Monitoring Stack for EKS Auto Mode

A production-ready monitoring solution for OpenEMR on EKS Auto Mode, featuring automated deployment, intelligent autoscaling, and deep observability.

> **⚠️ Important**: This is an **optional** monitoring stack. The core OpenEMR deployment includes CloudWatch logging. This stack adds enterprise-grade observability with Prometheus, AlertManager, Grafana, Grafana Loki (log aggregation), Grafana Tempo (distributed tracing), Grafana Mimir (long-term metrics storage), and OTeBPF (eBPF auto-instrumentation).

## 📋 Table of Contents

<img src="../images/monitoring_table_of_contents_section_picture.png" alt="Monitoring table of contents section picture" width="300">

- [Architecture Overview](#%EF%B8%8F-architecture-overview)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Cost Analysis](#-cost-analysis)
- [Configuration](#️-configuration)
- [Access Methods](#-access-methods)
- [Dashboards](#-dashboards)
- [Security & Compliance](#-security--compliance)
- [Maintenance](#-maintenance)
- [Additional Resources](#-additional-resources)

## 🏗️ Architecture Overview

### Monitoring Stack Components

```mermaid
graph TB
    subgraph EKS["EKS Auto Mode Cluster"]
        subgraph MON["monitoring namespace"]
            direction TB
            PROM["Prometheus<br/>Metrics Collection"]
            GRAF["Grafana<br/>Visualization"]
            LOKI["Loki<br/>Log Aggregation"]
            TEMPO["Tempo<br/>Distributed Tracing"]
            MIMIR["Mimir<br/>Long-term Metrics"]
            OTEBPF["OTeBPF<br/>eBPF Auto-instrumentation"]
            ALERT["AlertManager<br/>Alert Routing"]
        end

        subgraph OE_NS["openemr namespace"]
            direction TB
            OE_POD["OpenEMR Pods<br/>Application"]
            FB["Fluent Bit Sidecar<br/>Log Forwarding"]
            SM["ServiceMonitor<br/>CRD"]
            PR["PrometheusRules<br/>CRD"]
        end
    end

    subgraph S3["AWS S3 Storage<br/>(IRSA Authentication)"]
        direction LR
        S3_LOKI[("Loki S3 Bucket<br/>720h retention")]
        S3_TEMPO[("Tempo S3 Bucket<br/>90 day retention")]
        S3_MIMIR[("Mimir S3 Bucket<br/>365 day retention")]
        S3_AM[("AlertManager S3<br/>State Storage")]
    end

    subgraph EXT["External Access"]
        PF["Port Forward<br/>kubectl port-forward"]
    end

    %% Data Collection Flow
    OE_POD -->|"Application Logs"| FB
    FB -->|"HTTP :80<br/>/loki/api/v1/push"| LOKI
    OE_POD -->|"eBPF Traces"| OTEBPF
    OTEBPF -->|"OTLP HTTP :4318<br/>tempo-distributor"| TEMPO
    OE_POD -.->|"Metrics Scraping"| SM
    SM -->|"Prometheus Operator"| PROM

    %% Metrics Flow
    PROM -->|"Remote Write<br/>/api/v1/push"| MIMIR
    PROM -->|"Alerts"| ALERT

    %% Visualization Flow
    PROM -->|"Query API"| GRAF
    MIMIR -->|"Query API"| GRAF
    LOKI -->|"Query API"| GRAF
    TEMPO -->|"Query API"| GRAF

    %% Storage Flow
    LOKI -->|"IRSA<br/>S3 PutObject"| S3_LOKI
    TEMPO -->|"IRSA<br/>S3 PutObject"| S3_TEMPO
    MIMIR -->|"IRSA<br/>S3 PutObject"| S3_MIMIR
    ALERT -->|"IRSA<br/>S3 State"| S3_AM

    %% External Access
    PF -->|":3000"| GRAF

    %% Styling
    classDef monitoring fill:#e1f5ff,stroke:#01579b,stroke-width:2px
    classDef openemr fill:#fff3e0,stroke:#e65100,stroke-width:2px
    classDef storage fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef external fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px

    class PROM,GRAF,LOKI,TEMPO,MIMIR,OTEBPF,ALERT monitoring
    class OE_POD,FB,SM,PR openemr
    class S3_LOKI,S3_TEMPO,S3_MIMIR,S3_AM storage
    class PF external
```

### Storage Requirements

| Component | Storage Size | Retention | Storage Type | Cost Impact |
|-----------|-------------|-----------|---------------|-------------|
| **Prometheus** | 100Gi | 30 days | gp3-monitoring-encrypted (EBS) | $8/month    |
| **Grafana** | 20Gi | Persistent | gp3-monitoring-encrypted (EBS) | $1.60/month |
| **Loki** | N/A | 720 hours | AWS S3 (Object Storage) | Variable (lifecycle policies) |
| **Tempo** | N/A | 90 days | AWS S3 (Object Storage) | Variable (lifecycle policies) |
| **Mimir** | N/A | 365 days | AWS S3 (Object Storage) | Variable (lifecycle policies) |
| **AlertManager** | 5Gi | Persistent | gp3-monitoring-encrypted (EBS) + S3 state | $0.40/month + S3 |

**S3 Storage Architecture (Loki, Tempo, Mimir, AlertManager):**
- **Production-Grade Storage**: All components use AWS S3 for primary storage instead of filesystem storage
- **Recommendation**: As [recommended by Grafana](https://grafana.com/docs/loki/latest/setup/install/helm/configure-storage/), we configure object storage via cloud provider for production deployments
- **Benefits**:
  - **Durability**: 99.999999999% (11 nines) durability with S3
  - **Scalability**: Automatically scales with data volume without storage provisioning
  - **Cost-Effectiveness**: Lifecycle policies automatically transition to cheaper storage tiers (Intelligent-Tiering after 30 days, Glacier after 90 days)
  - **Lifecycle Management**: Automatic deletion based on retention policies
  - **Security**: KMS encryption and IAM role-based access (IRSA) - no credentials needed
- **IAM Integration**: Uses IRSA (IAM Roles for Service Accounts) for secure, credential-free S3 access
- **Setup**: Terraform automatically creates the S3 buckets and IAM roles, installation script retrieves and configures them
- **Components with S3 Storage**:
  - **Loki**: Log aggregation (720h retention, 720 day S3 lifecycle)
  - **Tempo**: Distributed tracing (90 day retention)
  - **Mimir**: Long-term metrics storage (365 day retention, Prometheus remote write)
  - **AlertManager**: Cluster state storage (high availability)

See pricing documentation for EBS [here](https://aws.amazon.com/ebs/pricing/).

### Unified Observability: Logs, Metrics, and Traces

This monitoring stack provides **full correlation** between logs, metrics, and traces, enabling faster root-cause analysis and long-term compliance.

```mermaid
graph TB
    subgraph COLLECT["Data Collection"]
        direction LR
        OE_APP["OpenEMR Application"]
        FB_SIDE["Fluent Bit Sidecar"]
        OTEBPF_DS["OTeBPF DaemonSet<br/>eBPF Auto-instrumentation"]
    end

    subgraph STORE["Storage & Processing"]
        direction TB
        LOKI_STORE[("Loki<br/>Log Aggregation<br/>720h retention")]
        TEMPO_STORE[("Tempo<br/>Distributed Tracing<br/>90 day retention")]
        PROM_STORE[("Prometheus<br/>Short-term Metrics<br/>30 day retention")]
        MIMIR_STORE[("Mimir<br/>Long-term Metrics<br/>365 day retention")]
    end

    subgraph CORR["Correlation & Query"]
        direction TB
        GRAF_UI["Grafana UI<br/>Unified Dashboard"]
        TRACE_ID["Trace ID Correlation"]
        EXEMPLARS["Metric Exemplars"]
        LABELS["Label-based Joins"]
    end

    %% Collection Flow
    OE_APP -->|"Application Logs"| FB_SIDE
    FB_SIDE -->|"HTTP Push"| LOKI_STORE
    OE_APP -->|"eBPF Instrumentation"| OTEBPF_DS
    OTEBPF_DS -->|"OTLP Traces"| TEMPO_STORE
    OE_APP -.->|"Metrics Scraping"| PROM_STORE
    PROM_STORE -->|"Remote Write"| MIMIR_STORE

    %% Correlation Flow
    LOKI_STORE -->|"Trace ID in Logs"| TRACE_ID
    TEMPO_STORE -->|"Trace Context"| TRACE_ID
    TRACE_ID -->|"Correlated View"| GRAF_UI
    
    TEMPO_STORE -->|"RED Metrics<br/>Rate/Errors/Duration"| MIMIR_STORE
    MIMIR_STORE -->|"Exemplars<br/>Link to Traces"| EXEMPLARS
    EXEMPLARS -->|"Trace Details"| TEMPO_STORE
    
    LOKI_STORE -->|"Labels<br/>job, namespace, pod"| LABELS
    PROM_STORE -->|"Labels"| LABELS
    LABELS -->|"Unified Query"| GRAF_UI

    %% Query Flow
    LOKI_STORE -->|"LogQL Queries"| GRAF_UI
    TEMPO_STORE -->|"TraceQL Queries"| GRAF_UI
    PROM_STORE -->|"PromQL Queries"| GRAF_UI
    MIMIR_STORE -->|"PromQL Queries"| GRAF_UI

    %% Styling
    classDef collection fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    classDef storage fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px
    classDef correlation fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px

    class OE_APP,FB_SIDE,OTEBPF_DS collection
    class LOKI_STORE,TEMPO_STORE,PROM_STORE,MIMIR_STORE storage
    class GRAF_UI,TRACE_ID,EXEMPLARS,LABELS correlation
```

### Autoscaling with EKS Auto Mode

```yaml
# Two-layer autoscaling architecture
Layer 1: Pod-level (HPA) - Fully Configurable
├── Grafana: 1-3 replicas (CPU 70%, Memory 80%) [Configurable]
├── Prometheus: 1-3 replicas (CPU 70%, Memory 80%) [Configurable]
├── Loki (distributed mode): Read/Write/Backend components, each 2-3 replicas (CPU 70%, Memory 80%) [Configurable]
├── Tempo: 1-3 replicas (CPU 70%, Memory 80%) [Configurable]
├── Mimir: 1-3 replicas (CPU 70%, Memory 80%) [Configurable]
├── AlertManager: 1-3 replicas (CPU 70%, Memory 80%) [Configurable]

Layer 2: Node-level (EKS Auto Mode)
├── Automatic EC2 provisioning when pods pending
├── 12% management fee on EC2 costs
└── 21-day node rotation for security

# Configuration via environment variables:
# ENABLE_AUTOSCALING="1"              # Enable/disable autoscaling
# GRAFANA_MIN_REPLICAS="1"            # Min replicas per component
# GRAFANA_MAX_REPLICAS="3"            # Max replicas per component
# TEMPO_MIN_REPLICAS="1"              # Min Tempo replicas
# TEMPO_MAX_REPLICAS="3"              # Max Tempo replicas
# MIMIR_MIN_REPLICAS="1"              # Min Mimir replicas
# MIMIR_MAX_REPLICAS="3"              # Max Mimir replicas
# OTEBPF_ENABLED="1"                  # Enable OTeBPF (0 or 1)
# HPA_CPU_TARGET="70"                 # CPU target percentage
# HPA_MEMORY_TARGET="80"              # Memory target percentage
```

## 📋 Prerequisites

### Required Components (From Core Deployment)

- ✅ EKS cluster with Auto Mode enabled (Kubernetes 1.29+)
- ✅ OpenEMR deployed and running
- ✅ Storage classes created (gp3-monitoring-encrypted)
- ✅ EFS CSI driver installed
- ✅ **Terraform applied** - Loki S3 bucket and IAM role must be created via Terraform before installation

### Required Tools

```bash
# Verify tools are installed
kubectl version --client # >= 1.29
helm version             # >= 3.12
jq --version             # >= 1.6
terraform version        # >= 1.0 (for S3 bucket and IAM role setup)

# Check cluster access
kubectl cluster-info
kubectl get nodes  # May be empty with Auto Mode
```

### Terraform Requirements for S3 Storage

Before installing the monitoring stack, ensure Terraform has been applied to create the S3 buckets and IAM roles for all components:

```bash
cd terraform

# Verify Terraform is initialized
terraform init

# Apply Terraform to create Loki S3 bucket and IAM role
terraform apply

# Verify outputs are available
terraform output loki_s3_bucket_name
terraform output loki_s3_role_arn
terraform output tempo_s3_bucket_name
terraform output tempo_s3_role_arn
terraform output mimir_s3_bucket_name
terraform output mimir_s3_role_arn
terraform output alertmanager_s3_bucket_name
terraform output alertmanager_s3_role_arn
```

The installation script will automatically retrieve the S3 bucket names and IAM role ARNs from Terraform outputs. Without these, component installations will fail.

### Cluster Capacity Requirements

```bash
# Minimum available resources needed:
# - CPU: 4 cores (across all nodes)
# - Memory: 8Gi (across all nodes)
# - Storage: 250Gi available

# Check current usage
kubectl describe nodes | grep -A 5 "Allocatable"
```

## 🚀 Quick Start

### Basic Installation (Recommended)

```bash
cd monitoring

# Install with defaults (CloudWatch integration, no ingress)
./install-monitoring.sh
```


### Access Credentials

```bash
# After installation, retrieve credentials
cat credentials/monitoring-credentials.txt

# Example output:
# Grafana Admin User: admin
# Grafana Admin Password: <auto-generated-password>
```

## 💰 Cost Analysis

### Monthly Cost Breakdown by Organization Size

**Note:** Loki now uses AWS S3 for primary storage, significantly reducing EBS storage costs while providing better durability and scalability. A small 10Gi EBS volume is used only for temporary files and local caching.

#### Small Clinic

| Component | Configuration                      | Monthly Cost     |
|-----------|------------------------------------|------------------|
| EC2 Compute (Auto Mode) | 2 t3.small equiv. AVG ($0.0208/hr) | $30.36           |
| Auto Mode Fee (12%) | Management overhead                | $3.64            |
| Storage (135Gi EBS + S3) | GP3 encrypted (Prometheus 100Gi, Grafana 20Gi, Loki 10Gi, AlertManager 5Gi) | $10.80           |
| **S3 Storage (Loki, Tempo, Mimir, AlertManager)** | Variable (lifecycle policies) | ~$10-30           |
| **Total** |                                    | **~$55-75/month** |

#### Hospital

| Component | Configuration                       | Monthly Cost     |
|-----------|-------------------------------------|------------------|
| EC2 Compute (Auto Mode) | 2 t3.medium equiv. AVG ($0.0416/hr) | $60.74           |
| Auto Mode Fee (12%) | Management overhead                 | $7.29            |
| Storage (135Gi EBS + S3) | GP3 encrypted (Prometheus 100Gi, Grafana 20Gi, Loki 10Gi, AlertManager 5Gi) | $10.80           |
| **S3 Storage (Loki, Tempo, Mimir, AlertManager)** | Variable (lifecycle policies) | ~$15-40          |
| **Total** |                                     | **~$94-119/month** |

#### Large Hospital

| Component | Configuration                      | Monthly Cost      |
|-----------|------------------------------------|-------------------|
| EC2 Compute (Auto Mode) | 2 t3.large equiv. AVG ($0.0832/hr) | $121.47           |
| Auto Mode Fee (12%) | Management overhead                | $14.58            |
| Storage (135Gi EBS + S3) | GP3 encrypted (Prometheus 100Gi, Grafana 20Gi, Loki 10Gi, AlertManager 5Gi) | $10.80            |
| **S3 Storage (Loki, Tempo, Mimir, AlertManager)** | Variable (lifecycle policies) | ~$25-60           |
| **Total** |                                    | **~$172-207/month** |

**S3 Storage Cost Notes:**
- **Intelligent-Tiering**: After 30 days, data automatically transitions to lower-cost tiers
- **Glacier**: After 90 days, data transitions to Glacier for archival storage
- **Lifecycle Management**: Automatic deletion based on component retention policies
  - Loki: 720 days (720h retention)
  - Tempo: 90 days (trace retention)
  - Mimir: 365 days (1 year metrics retention)
- **Actual costs depend on data volume**: Typical deployments see $10-60/month for S3 storage depending on ingestion rate
- **Benefits over EBS**: No need to pre-provision storage, automatic scaling, better durability (11 nines), and lower costs at scale

### Cost Optimization Strategies

```bash
# 1. Reduce retention periods
export PROMETHEUS_RETENTION="15d" # Default: 30d
export LOKI_RETENTION="360h"      # Default: 720h

# 2. S3 Lifecycle Policies (automatically configured)
# - Intelligent-Tiering after 30 days (reduces storage cost)
# - Glacier transition after 90 days (further cost reduction)
# - Automatic deletion after 720 days
# - No action needed - these are handled by Terraform

# 3. Reduce Loki EBS volume size (if needed)
# The Loki EBS volume is only for temporary files (10Gi default)
# This can be reduced if log volume is very low, but 10Gi is already minimal
```

**Storage Cost Optimization:**
- **Loki S3 Storage**: Reduced from 100Gi EBS ($8/month) to 10Gi EBS ($0.80/month) + variable S3 costs ($5-50/month depending on volume)
- **Automatic tiering**: S3 data automatically moves to cheaper storage tiers (no manual intervention needed)
- **Cost-effective at scale**: S3 storage scales with your log volume without upfront provisioning
- **Lifecycle management**: Old data is automatically archived and deleted according to retention policies

## ⚙️ Configuration

### Essential Environment Variables

See complete reference in this project at [monitoring/openemr-monitoring.conf.example](./openemr-monitoring.conf.example)

### Autoscaling Configuration

The monitoring stack includes comprehensive autoscaling capabilities that can be customized for your environment:

#### Basic Autoscaling Settings

```bash
# Enable/disable autoscaling (default: enabled)
export ENABLE_AUTOSCALING="1"

# CPU and Memory targets for scaling decisions
export HPA_CPU_TARGET="70"    # CPU usage percentage (default: 70%)
export HPA_MEMORY_TARGET="80" # Memory usage percentage (default: 80%)
```

#### Component-Specific Replica Limits

```bash
# Grafana autoscaling
export GRAFANA_MIN_REPLICAS="1" # Minimum replicas (default: 1)
export GRAFANA_MAX_REPLICAS="3" # Maximum replicas (default: 3)

# Prometheus autoscaling
export PROMETHEUS_MIN_REPLICAS="1" # Minimum replicas (default: 1)
export PROMETHEUS_MAX_REPLICAS="3" # Maximum replicas (default: 3)

# Loki autoscaling
export LOKI_MIN_REPLICAS="1" # Minimum replicas (default: 1)
export LOKI_MAX_REPLICAS="3" # Maximum replicas (default: 3)

# AlertManager autoscaling (when Slack alerts enabled)
export ALERTMANAGER_MIN_REPLICAS="1" # Minimum replicas (default: 1)
export ALERTMANAGER_MAX_REPLICAS="3" # Maximum replicas (default: 3)

# Tempo autoscaling
export TEMPO_MIN_REPLICAS="1" # Minimum replicas (default: 1)
export TEMPO_MAX_REPLICAS="3" # Maximum replicas (default: 3)

# Mimir autoscaling
export MIMIR_MIN_REPLICAS="1" # Minimum replicas (default: 1)
export MIMIR_MAX_REPLICAS="3" # Maximum replicas (default: 3)



# OTeBPF auto-instrumentation
export OTEBPF_ENABLED="1"         # Enable OTeBPF (default: 1)
```

#### Example Configurations

**High Availability Setup:**
```bash
export GRAFANA_MIN_REPLICAS="2"
export PROMETHEUS_MIN_REPLICAS="2"
export LOKI_MIN_REPLICAS="2"
export ALERTMANAGER_MIN_REPLICAS="2"
export TEMPO_MIN_REPLICAS="2"
export MIMIR_MIN_REPLICAS="2"
```

**Cost-Optimized Setup:**
```bash
export GRAFANA_MAX_REPLICAS="2"
export PROMETHEUS_MAX_REPLICAS="2"
export LOKI_MAX_REPLICAS="2"
export ALERTMANAGER_MAX_REPLICAS="2"
export TEMPO_MAX_REPLICAS="2"
export MIMIR_MAX_REPLICAS="2"
export HPA_CPU_TARGET="80"        # Higher threshold = less scaling
```

**High Performance Setup:**
```bash
export GRAFANA_MAX_REPLICAS="5"
export PROMETHEUS_MAX_REPLICAS="3"
export LOKI_MAX_REPLICAS="4"
export ALERTMANAGER_MAX_REPLICAS="3"
export TEMPO_MAX_REPLICAS="4"
export MIMIR_MAX_REPLICAS="4"
export HPA_CPU_TARGET="60"        # Lower threshold = more scaling
```

**Disable Autoscaling:**
```bash
export ENABLE_AUTOSCALING="0"     # All components run with minimum replicas
```

## 🌐 Access Methods

### Port-Forwarding (Recommended)

```bash
# Grafana (primary interface)
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80
# Access: http://localhost:3000
# Login: admin / <check credentials file>

# Prometheus (metrics exploration)
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090
# Access: http://localhost:9090

# AlertManager (alert management)
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-alertmanager 9093:9093
# Access: http://localhost:9093

# Loki (log exploration)
kubectl port-forward -n monitoring svc/loki 3100:3100
# Access: http://localhost:3100

# Tempo (distributed tracing)
kubectl port-forward -n monitoring svc/tempo-query 3200:3200
# Access: http://localhost:3200

# Mimir (long-term metrics)
kubectl port-forward -n monitoring svc/mimir-gateway 8080:8080
# Access: http://localhost:8080


# Access: http://localhost:8080
```


## 📊 Dashboards

### Pre-Configured Dashboards

After installation, these dashboards are automatically available:

#### System Dashboards

- **Kubernetes / Compute Resources / Cluster** - Overall cluster health
- **Kubernetes / Compute Resources / Namespace (Pods)** - Per-namespace metrics
- **Node Exporter / Nodes** - Host-level metrics
- **Kubernetes / Networking / Cluster** - Network performance

#### OpenEMR Monitoring

```bash
# In Grafana:
1. Open "Kubernetes / Compute Resources / Namespace (Pods)"
2. Set namespace filter to "openemr"
3. View all OpenEMR pod metrics
```

<details>
<summary><strong>Visual Examples</strong></summary>

<details>
<summary><strong>16 Built-in Grafana Dashboards</strong></summary>

<img src="../images/16_built_in_grafana_dashboards.png" alt="16 built-in Grafana dashboards" width="600">

The monitoring stack includes 16 pre-configured Grafana dashboards covering Kubernetes resources, node metrics, networking, and more.
</details>

<details>
<summary><strong>1531 Built-in Prometheus Metrics</strong></summary>

<img src="../images/1531_built_in_prometheus_metrics.png" alt="1531 built-in Prometheus metrics" width="600">

Prometheus automatically collects 1531+ metrics from your cluster, providing comprehensive visibility into system and application performance.
</details>

<details>
<summary><strong>218 Built-in Alerting Rules</strong></summary>

<img src="../images/218_built_in_alerting_rules.png" alt="218 built-in alerting rules" width="600">

The monitoring stack includes 218 pre-configured alerting rules that monitor cluster health, resource utilization, pod failures, and application metrics.
</details>

<details>
<summary><strong>Auto-Instrumented Traces</strong></summary>

<img src="../images/auto_instrumented_traces.png" alt="Auto-instrumented traces from OTeBPF" width="600">

OTeBPF automatically instruments OpenEMR pods without code changes, generating distributed traces visible in Grafana Tempo. This provides zero-code observability for request flows and performance analysis.
</details>

<details>
<summary><strong>Automated On-Call Escalations</strong></summary>

<img src="../images/automate_your_on_call_escalations.png" alt="Automated on-call escalation configuration" width="600">

Grafana and AlertManager together enable automated on-call escalation workflows, ensuring critical alerts reach the right team members at the right time with configurable escalation policies.
</details>

</details>

#### 📚 Data Source Reference

Your Grafana has **7 data sources** pre-configured:

| Data Source | Purpose |
|-------------|---------|
| **Prometheus** | Short-term metrics (CPU, memory, requests) |
| **Mimir** | Long-term metrics storage (remote write from Prometheus) |
| **Loki** | Logs (application, system) |
| **Tempo** | Distributed traces (replaces Jaeger) |
| **CloudWatch** | AWS CloudWatch logs and metrics (long-term compliance) |
| **X-Ray** | AWS X-Ray distributed tracing (via CloudWatch API) |
| **AlertManager** | Alert management and notification routing |

## 🔒 Security & Compliance

### Compliance Features

| Requirement | Implementation | Verification                                                                                                 |
|-------------|---------------|--------------------------------------------------------------------------------------------------------------|
| **Encryption at Rest** | GP3 encrypted storage | `kubectl get sc gp3-monitoring-encrypted -o yaml`                                                            |
| **Encryption in Transit** | TLS 1.2+ for all traffic | All traffic uses port-forwarding (local access only)                                                                              |
| **Access Control** | RBAC + Basic Auth + TLS | Review service accounts and secrets                                                                          |
| **Data Retention** | Configurable retention | Review and confirm configuration allows for necessary retention of data in compliance with relevant policies |
| **Network Isolation** | NetworkPolicies | `kubectl get networkpolicy -n monitoring`                                                                    |

### Security Hardening Checklist

- [ ] Use port-forwarding or another secure method for local access
- [ ] Configure cert-manager for automatic certificate renewal
- [ ] Set up authentication
- [ ] Apply NetworkPolicies
- [ ] Configure AlertManager for security alerts
- [ ] Review and restrict RBAC permissions
- [ ] Enable audit logging
- [ ] Set appropriate data retention policies
- [ ] Regularly update Helm charts
- [ ] Monitor for CVEs in container images

## 🔄 Maintenance

### Daily Tasks

```bash
# Check component health
kubectl get pods -n monitoring

# Review recent alerts
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-alertmanager 9093:9093
# Open http://localhost:9093
```

### Weekly Tasks

```bash
# Review autoscaling events and HPA status
kubectl get events -n monitoring --field-selector reason=ScalingReplicaSet
kubectl get hpa -n monitoring
kubectl describe hpa -n monitoring

# Check current replica counts
kubectl get pods -n monitoring -o wide

# Check storage usage
kubectl exec -n monitoring prometheus-prometheus-stack-kube-prom-prometheus-0 -- \
  df -h /prometheus

# Review Grafana dashboards usage
# Check which dashboards are most/least used

# Monitor autoscaling behavior
kubectl get hpa -n monitoring -o custom-columns=\
NAME:.metadata.name,\
REFERENCE:.spec.scaleTargetRef.name,\
TARGETS:.status.currentCPUUtilizationPercentage,\
MINPODS:.spec.minReplicas,\
MAXPODS:.spec.maxReplicas,\
REPLICAS:.status.currentReplicas
```

### Monthly Tasks

```bash
# Update Helm charts
helm repo update
helm list -n monitoring

# Check for new versions
helm search repo prometheus-community/kube-prometheus-stack --versions | head -5
helm search repo grafana/loki --versions | head -5

# Review and optimize retention
# Adjust based on storage costs and compliance needs
```

### Upgrade Procedures

```bash
# Backup current values
helm get values prometheus-stack -n monitoring > prometheus-stack-values-backup.yaml

# Upgrade Prometheus stack
helm upgrade prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version <new-version> \
  --values prometheus-values.yaml \
  --timeout 45m --atomic

# Upgrade Loki
helm upgrade loki grafana/loki \
  --namespace monitoring \
  --version <new-version> \
  --timeout 35m --atomic

# Upgrade Tempo
helm upgrade tempo grafana-community/tempo-distributed \
  --namespace monitoring \
  --version <new-version> \
  --timeout 35m --atomic

# Upgrade Mimir
helm upgrade mimir grafana/mimir-distributed \
  --namespace monitoring \
  --version <new-version> \
  --timeout 35m --atomic
```

## 📚 Additional Resources

### Documentation

- [Prometheus Best Practices](https://prometheus.io/docs/practices/)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
- [Loki Query Language](https://grafana.com/docs/loki/latest/logql/)
- [EKS Auto Mode Documentation](https://docs.aws.amazon.com/eks/latest/userguide/automode.html)

### Troubleshooting

- [Kubernetes Monitoring Guide](https://kubernetes.io/docs/tasks/debug/)
- [Prometheus Troubleshooting](https://prometheus-operator.dev/docs/platform/troubleshooting/)

### Support

- OpenEMR Community Forum: <https://community.open-emr.org>
- [Get an invite to join the Kubernetes Slack here!](https://communityinviter.com/apps/kubernetes/community)
- [#prometheus-operator](https://kubernetes.slack.com/archives/CFFDS2Z7F) channel on Kubernetes Slack.

---

**Remember**: This monitoring stack is optional but recommended for production healthcare environments requiring comprehensive observability beyond basic CloudWatch logging.
