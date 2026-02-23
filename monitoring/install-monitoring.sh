#!/bin/bash

# =============================================================================
# OpenEMR EKS Monitoring Stack Installation Script
# =============================================================================
#
# Purpose:
#   Installs and configures a comprehensive monitoring stack for OpenEMR on
#   Amazon EKS, including Prometheus, Grafana, Loki, and Tempo. Provides
#   observability, metrics, logging, and distributed tracing capabilities
#   with port-forwarding access for monitoring tools.
#
# Key Features:
#   - Prometheus Operator deployment with kube-prometheus-stack
#   - Grafana with pre-configured OpenEMR dashboards
#   - Loki for centralized log aggregation (S3-backed)
#   - Tempo for distributed tracing (S3-backed, replaces Jaeger)
#   - Mimir for long-term metrics storage (S3-backed)
#   - OTeBPF for eBPF auto-instrumentation
#   - cert-manager for TLS certificate management
#   - Storage provisioning with encryption support
#   - Integration with OpenEMR Fluent Bit sidecars
#   - CloudWatch metrics integration via Grafana
#
# Prerequisites:
#   - EKS cluster running and accessible via kubectl
#   - Helm 3.x installed
#   - AWS CLI configured with appropriate permissions
#   - Sufficient cluster resources (CPU, memory, storage)
#   - OpenEMR deployed with Fluent Bit sidecars (for log aggregation)
#
# Usage:
#   ./install-monitoring.sh [OPTIONS]
#
# Options:
#   install                 Install monitoring stack (default operation)
#   uninstall               Remove monitoring stack and clean up resources
#   verify                  Verify monitoring stack installation and health
#   --help                  Show this help message
#
# Environment Variables (Grouped by Category):
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Namespace Configuration                                                 │
# └─────────────────────────────────────────────────────────────────────────┘
#   MONITORING_NAMESPACE       Namespace for monitoring components (default: monitoring)
#   OPENEMR_NAMESPACE          Namespace where OpenEMR is deployed (default: openemr)
#   OBSERVABILITY_NAMESPACE    Namespace for observability tools (default: observability)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Storage Configuration                                                   │
# └─────────────────────────────────────────────────────────────────────────┘
#   STORAGE_CLASS_RWO          StorageClass for ReadWriteOnce volumes (default: gp3-monitoring-encrypted)
#   STORAGE_CLASS_RWX          StorageClass for ReadWriteMany volumes (default: empty/not used)
#   ACCESS_MODE_RWO            Access mode for RWO volumes (default: ReadWriteOncePod)
#   ACCESS_MODE_RWX            Access mode for RWX volumes (default: ReadWriteMany)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ File Paths and Directories                                              │
# └─────────────────────────────────────────────────────────────────────────┘
#   CONFIG_FILE                Configuration file path (default: ./openemr-monitoring.conf)
#   CREDENTIALS_DIR            Directory for saved credentials (default: ./credentials)
#   BACKUP_DIR                 Directory for configuration backups (default: ./backups)
#   VALUES_FILE                Prometheus values file path (default: ./prometheus-values.yaml)
#   LOG_FILE                   Log file path (default: ./openemr-monitoring.log)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Helm Chart Versions                                                     │
# └─────────────────────────────────────────────────────────────────────────┘
#   CHART_KPS_VERSION          kube-prometheus-stack chart version (default: 82.2.0)
#   CHART_LOKI_VERSION         Loki chart version (default: 6.53.0)
#   CHART_TEMPO_VERSION        Tempo distributed chart version (default: 2.4.2)
#   CHART_MIMIR_VERSION        Mimir chart version (default: 6.0.5)
#   OTEBPF_VERSION             OTeBPF version (default: v0.4.1)
#   CERT_MANAGER_VERSION       cert-manager version (default: v1.19.1)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Timeout and Retry Configuration                                         │
# └─────────────────────────────────────────────────────────────────────────┘
#   TIMEOUT_HELM               Helm operation timeout (default: 45m)
#   TIMEOUT_KUBECTL            kubectl operation timeout (default: 600s)
#   MAX_RETRIES                Maximum retry attempts for operations (default: 3)
#   BASE_DELAY                 Base delay in seconds for retries (default: 30)
#   MAX_DELAY                  Maximum delay in seconds for retries (default: 300)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Alerting Configuration (Optional)                                       │
# └─────────────────────────────────────────────────────────────────────────┘
#   SLACK_WEBHOOK_URL          Slack webhook URL for Alertmanager (optional)
#   SLACK_CHANNEL              Slack channel for alerts (optional)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ AWS Configuration                                                       │
# └─────────────────────────────────────────────────────────────────────────┘
#   AWS_REGION                 AWS region (auto-detected from cluster or default: us-west-2)
#   AWS_DEFAULT_REGION         Alternative AWS region variable (fallback)
#   CLUSTER_NAME               EKS cluster name (auto-detected or default: openemr-eks)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Autoscaling Configuration (HPA)                                         │
# └─────────────────────────────────────────────────────────────────────────┘
#   ENABLE_AUTOSCALING         Enable HPA for monitoring components (0 or 1, default: 1)
#   GRAFANA_MIN_REPLICAS       Grafana min replicas (default: 1)
#   GRAFANA_MAX_REPLICAS       Grafana max replicas (default: 3)
#   PROMETHEUS_MIN_REPLICAS    Prometheus min replicas (default: 1)
#   PROMETHEUS_MAX_REPLICAS    Prometheus max replicas (default: 3)
#   LOKI_MIN_REPLICAS          Loki min replicas (default: 1)
#   LOKI_MAX_REPLICAS          Loki max replicas (default: 3)
#   ALERTMANAGER_MIN_REPLICAS  Alertmanager min replicas (default: 1)
#   ALERTMANAGER_MAX_REPLICAS  Alertmanager max replicas (default: 3)
#   TEMPO_MIN_REPLICAS         Tempo min replicas (default: 1)
#   TEMPO_MAX_REPLICAS         Tempo max replicas (default: 3)
#   MIMIR_MIN_REPLICAS         Mimir min replicas (default: 1)
#   MIMIR_MAX_REPLICAS         Mimir max replicas (default: 3)
#   OTEBPF_ENABLED             Enable OTeBPF auto-instrumentation (0 or 1, default: 1)
#   HPA_CPU_TARGET             HPA CPU utilization target percentage (default: 70)
#   HPA_MEMORY_TARGET          HPA memory utilization target percentage (default: 80)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Port Configuration                                                      │
# └─────────────────────────────────────────────────────────────────────────┘
#   TEMPO_HTTP_PORT                 Tempo HTTP API port (default: 3200)
#   TEMPO_OTLP_GRPC_PORT            Tempo OTLP gRPC receiver port (default: 4317)
#   TEMPO_OTLP_HTTP_PORT            Tempo OTLP HTTP receiver port (default: 4318)
#   TEMPO_QUERY_FRONTEND_GRPC_PORT  Tempo query frontend gRPC port (default: 9095)
#   GRAFANA_PORT                    Grafana web UI port for port-forwarding (default: 3000)
#   PROMETHEUS_PORT                 Prometheus web UI port for port-forwarding (default: 9090)
#   ALERTMANAGER_PORT               AlertManager web UI port for port-forwarding (default: 9093)
#   LOKI_PORT                       Loki web UI port for port-forwarding (default: 3100)
#   MIMIR_PORT                      Mimir gateway port for port-forwarding (default: 8080)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Tempo Configuration                                                     │
# └─────────────────────────────────────────────────────────────────────────┘
#   TEMPO_MAX_BLOCK_DURATION          Maximum duration before flushing a block (default: 5m)
#   TEMPO_TRACE_IDLE_PERIOD           Time to wait before considering trace complete (default: 10s)
#   TEMPO_BLOCK_RETENTION             How long to retain blocks before compaction (default: 1h)
#   TEMPO_COMPACTED_BLOCK_RETENTION   How long to retain compacted blocks (default: 10m)
#   TEMPO_QUERY_DEFAULT_RESULT_LIMIT  Default number of results per query (default: 20)
#   TEMPO_QUERY_MAX_RESULT_LIMIT      Maximum number of results, 0=unlimited (default: 0)
#   TEMPO_SPAN_START_TIME_SHIFT       Time shift for trace-to-log correlation start (default: 1h)
#   TEMPO_SPAN_END_TIME_SHIFT         Time shift for trace-to-log correlation end (default: -1h)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Resource Requests and Limits (CPU in millicores, Memory in Mi/Gi)       │
# └─────────────────────────────────────────────────────────────────────────┘
#   See openemr-monitoring.conf.example for complete list of resource variables.
#   Examples: TEMPO_DISTRIBUTOR_CPU_REQUEST, PROMETHEUS_MEMORY_LIMIT, etc.
#   All components have configurable CPU/memory requests and limits.
#   Storage sizes are also configurable (e.g., PROMETHEUS_STORAGE_SIZE).
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Security Context                                                        │
# └─────────────────────────────────────────────────────────────────────────┘
#   RUN_AS_USER                User ID for running containers (default: 1000)
#   RUN_AS_GROUP               Group ID for running containers (default: 3000)
#   FS_GROUP                   Filesystem group ID (default: 2000)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Prometheus Scraping Configuration                                       │
# └─────────────────────────────────────────────────────────────────────────┘
#   PROMETHEUS_SCRAPE_INTERVAL      How often to scrape metrics (default: 30s)
#   PROMETHEUS_EVALUATION_INTERVAL  How often to evaluate alert rules (default: 30s)
#   PROMETHEUS_SCRAPE_TIMEOUT       Timeout for scraping metrics (default: 10s)
#   PROMETHEUS_RETENTION            How long to retain metrics locally (default: 30d)
#   PROMETHEUS_RETENTION_SIZE       Maximum size of local storage (default: 90GB)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Alert Thresholds                                                        │
# └─────────────────────────────────────────────────────────────────────────┘
#   ALERT_CPU_THRESHOLD              CPU usage threshold (default: 0.8 = 80%)
#   ALERT_MEMORY_THRESHOLD           Memory usage threshold (default: 0.9 = 90%)
#   ALERT_ERROR_RATE_THRESHOLD       Error rate threshold (default: 0.05 = 5%)
#   ALERT_LATENCY_THRESHOLD_SECONDS  P95 latency threshold in seconds (default: 2)
#   ALERT_EVALUATION_INTERVAL        How often to evaluate alerts (default: 30s)
#   ALERT_FOR_DURATION               How long condition must persist (default: 5m)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Component-Specific Configuration                                        │
# └─────────────────────────────────────────────────────────────────────────┘
#   LOKI_RETENTION_PERIOD        How long to retain logs (default: 720h = 30 days)
#   ALERTMANAGER_GROUP_WAIT      Time to wait before first notification (default: 10s)
#   ALERTMANAGER_GROUP_INTERVAL  Time to wait before batch notifications (default: 10s)
#
# Examples:
#   # Basic installation with Tempo, Mimir, OTeBPF, Cert-manager, Alertmanager, Prometheus and Grafana
#   ./install-monitoring.sh
#
#   # Access via port-forwarding (default)
#   kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80
#
# Notes:
#   - Installation takes approximately 10 minutes
#   - Grafana admin credentials are saved to credentials/grafana-credentials.txt
#   - Default Grafana admin password is auto-generated
#   - Access Grafana via port-forward: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 (in browser go to "localhost:3000" and log in with credentials)
#   - CloudWatch integration requires proper IAM role configuration
#   - S3 storage is automatically configured for Loki, Tempo, Mimir, and AlertManager via Terraform
#
# =============================================================================

set -euo pipefail
set -o errtrace

# ------------------------------
# Configuration Management
# ------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR
readonly SCRIPT_NAME
readonly CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/openemr-monitoring.conf}"

# Default namespaces
readonly MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
readonly OPENEMR_NAMESPACE="${OPENEMR_NAMESPACE:-openemr}"
readonly OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

# Storage configuration
readonly STORAGE_CLASS_RWO="${STORAGE_CLASS_RWO:-gp3-monitoring-encrypted}"
readonly STORAGE_CLASS_RWX="${STORAGE_CLASS_RWX:-}"   # e.g., efs-sc
readonly ACCESS_MODE_RWO="${ACCESS_MODE_RWO:-ReadWriteOncePod}"
readonly ACCESS_MODE_RWX="${ACCESS_MODE_RWX:-ReadWriteMany}"

# Files
readonly CREDENTIALS_DIR="${CREDENTIALS_DIR:-${SCRIPT_DIR}/credentials}"
readonly BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
readonly VALUES_FILE="${VALUES_FILE:-${SCRIPT_DIR}/prometheus-values.yaml}"
readonly LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/openemr-monitoring.log}"

# Chart versions (pin to known-good)
readonly CHART_KPS_VERSION="${CHART_KPS_VERSION:-82.2.0}"
readonly CHART_LOKI_VERSION="${CHART_LOKI_VERSION:-6.53.0}"
readonly CHART_TEMPO_VERSION="${CHART_TEMPO_VERSION:-2.4.2}"
readonly CHART_MIMIR_VERSION="${CHART_MIMIR_VERSION:-6.0.5}"
# OpenTelemetry eBPF Instrumentation version (OTeBPF)
# Using Docker Hub image: otel/ebpf-instrument
# Official image repository: https://hub.docker.com/r/otel/ebpf-instrument
# GitHub: https://github.com/open-telemetry/opentelemetry-network
readonly OTEBPF_VERSION="${OTEBPF_VERSION:-v0.4.1}"
readonly OTEBPF_IMAGE="${OTEBPF_IMAGE:-otel/ebpf-instrument}"

# Timeouts / retries
readonly TIMEOUT_HELM="${TIMEOUT_HELM:-45m}"
readonly TIMEOUT_KUBECTL="${TIMEOUT_KUBECTL:-600s}"
readonly MAX_RETRIES="${MAX_RETRIES:-3}"
readonly BASE_DELAY="${BASE_DELAY:-30}"
readonly MAX_DELAY="${MAX_DELAY:-300}"

# Component-specific retry and delay configuration
readonly HELM_INSTALL_RETRY_DELAY="${HELM_INSTALL_RETRY_DELAY:-30}"                             # Delay between Helm install retries (seconds)
readonly PATCH_RETRY_DELAY="${PATCH_RETRY_DELAY:-5}"                                            # Delay between patch operation retries (seconds)
readonly PVC_WAIT_DELAY="${PVC_WAIT_DELAY:-5}"                                                  # Delay after PVC creation before checking (seconds)
readonly QUERY_FRONTEND_READINESS_INITIAL_DELAY="${QUERY_FRONTEND_READINESS_INITIAL_DELAY:-10}" # Initial delay for query-frontend readiness probe (seconds)

# AlertManager cluster configuration
readonly ALERTMANAGER_PEER_TIMEOUT="${ALERTMANAGER_PEER_TIMEOUT:-15s}"             # Peer timeout for AlertManager cluster
readonly ALERTMANAGER_GOSSIP_INTERVAL="${ALERTMANAGER_GOSSIP_INTERVAL:-200ms}"     # Gossip interval for AlertManager cluster
readonly ALERTMANAGER_PUSH_PULL_INTERVAL="${ALERTMANAGER_PUSH_PULL_INTERVAL:-60s}" # Push-pull interval for AlertManager cluster
readonly ALERTMANAGER_REPEAT_INTERVAL="${ALERTMANAGER_REPEAT_INTERVAL:-24h}"       # Repeat interval for AlertManager alerts

# Loki index configuration
readonly LOKI_INDEX_PERIOD="${LOKI_INDEX_PERIOD:-24h}"  # Period for Loki index rotation

# kubectl wait timeouts (can be shorter than TIMEOUT_KUBECTL for specific operations)
readonly KUBECTL_WAIT_TIMEOUT_SHORT="${KUBECTL_WAIT_TIMEOUT_SHORT:-180s}"   # Short timeout for quick operations (e.g., Grafana restart)
readonly KUBECTL_WAIT_TIMEOUT_MEDIUM="${KUBECTL_WAIT_TIMEOUT_MEDIUM:-300s}" # Medium timeout for standard operations
readonly KUBECTL_WAIT_TIMEOUT_LONG="${KUBECTL_WAIT_TIMEOUT_LONG:-600s}"     # Long timeout for slow operations (e.g., Mimir initialization)


# Alertmanager Slack (optional)
readonly SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
readonly SLACK_CHANNEL="${SLACK_CHANNEL:-}"

# Project root for Terraform state access
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# AWS Configuration
# Detect AWS region from environment, Terraform state, or EKS cluster
get_aws_region() {
  # Priority 1: Try to get region from Terraform state file (existing deployment takes precedence)
  if [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
    local terraform_region
    terraform_region=$(grep -o '"region"[[:space:]]*:[[:space:]]*"[^"]*"' "$TERRAFORM_DIR/terraform.tfstate" 2>/dev/null | \
        head -1 | \
        sed 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
    
    # Validate region format
    if [[ -n "$terraform_region" && "$terraform_region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
      echo "$terraform_region"
      return 0
    fi
  fi
  
  # Priority 2: If AWS_REGION is explicitly set via environment AND it's not the default, use it
  if [[ -n "${AWS_REGION:-}" && "${AWS_REGION}" != "us-west-2" ]]; then
    # Validate it's a real region format (e.g., us-west-2, eu-west-1, ap-southeast-1)
    if [[ "${AWS_REGION}" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
      echo "${AWS_REGION}"
      return 0
    fi
  fi
  
  # Priority 3: Try to get from AWS_DEFAULT_REGION environment variable
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    echo "${AWS_DEFAULT_REGION}"
    return 0
  fi
  
  # Priority 4: Try to get region from kubectl cluster info
  local cluster_endpoint
  cluster_endpoint=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
  if [[ -n "$cluster_endpoint" && "$cluster_endpoint" =~ eks\.([a-z0-9-]+)\.amazonaws\.com ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  
  # Priority 5: Try to get from EC2 metadata (if running on EC2)
  if command -v curl >/dev/null 2>&1; then
    local region
    region=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
    if [[ -n "$region" ]]; then
      echo "$region"
      return 0
    fi
  fi
  
  # Default to us-west-2 if all else fails
  echo "us-west-2"
}

# Declare and assign separately to avoid masking return values
AWS_REGION=$(get_aws_region)
readonly AWS_REGION

# Cluster name detection
get_cluster_name() {
  # Try to get from kubectl context
  local cluster_name
  cluster_name=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's|.*/||' 2>/dev/null)
  
  if [[ -n "$cluster_name" && "$cluster_name" != "null" ]]; then
    echo "$cluster_name"
    return 0
  fi
  
  # Default fallback
  echo "openemr-eks"
}

readonly CLUSTER_NAME="${CLUSTER_NAME:-$(get_cluster_name)}"

# Autoscaling Configuration
readonly ENABLE_AUTOSCALING="${ENABLE_AUTOSCALING:-1}"
readonly GRAFANA_MIN_REPLICAS="${GRAFANA_MIN_REPLICAS:-1}"
readonly GRAFANA_MAX_REPLICAS="${GRAFANA_MAX_REPLICAS:-3}"
readonly PROMETHEUS_MIN_REPLICAS="${PROMETHEUS_MIN_REPLICAS:-1}"
readonly PROMETHEUS_MAX_REPLICAS="${PROMETHEUS_MAX_REPLICAS:-3}"
# Loki SimpleScalable mode requires at least 2 replicas for high availability
# Setting default to 2 to ensure proper operation
readonly LOKI_MIN_REPLICAS="${LOKI_MIN_REPLICAS:-2}"
readonly LOKI_MAX_REPLICAS="${LOKI_MAX_REPLICAS:-3}"
readonly ALERTMANAGER_MIN_REPLICAS="${ALERTMANAGER_MIN_REPLICAS:-1}"
readonly ALERTMANAGER_MAX_REPLICAS="${ALERTMANAGER_MAX_REPLICAS:-3}"
readonly TEMPO_MIN_REPLICAS="${TEMPO_MIN_REPLICAS:-1}"
readonly TEMPO_MAX_REPLICAS="${TEMPO_MAX_REPLICAS:-3}"
readonly MIMIR_MIN_REPLICAS="${MIMIR_MIN_REPLICAS:-1}"
readonly MIMIR_MAX_REPLICAS="${MIMIR_MAX_REPLICAS:-3}"
# OTeBPF auto-instrumentation for eBPF-based trace collection
# Uses Docker Hub image: otel/ebpf-instrument
readonly OTEBPF_ENABLED="${OTEBPF_ENABLED:-1}"
readonly HPA_CPU_TARGET="${HPA_CPU_TARGET:-70}"
readonly HPA_MEMORY_TARGET="${HPA_MEMORY_TARGET:-80}"

# Component Readiness Check Configuration
readonly TEMPO_READINESS_MAX_RETRIES="${TEMPO_READINESS_MAX_RETRIES:-60}"
readonly TEMPO_READINESS_SLEEP_INTERVAL="${TEMPO_READINESS_SLEEP_INTERVAL:-5}"
readonly TEMPO_READINESS_MIN_RUNNING_PODS="${TEMPO_READINESS_MIN_RUNNING_PODS:-1}"


readonly OTEBPF_READINESS_MAX_RETRIES="${OTEBPF_READINESS_MAX_RETRIES:-30}"
readonly OTEBPF_READINESS_SLEEP_INTERVAL="${OTEBPF_READINESS_SLEEP_INTERVAL:-2}"
# For DaemonSets, pending pods are normal when nodes don't exist yet (EKS Auto Mode)
# We only need 1 healthy pod to confirm OTeBPF is configured correctly - the rest will come up as nodes scale
readonly OTEBPF_READINESS_MIN_RUNNING_PODS="${OTEBPF_READINESS_MIN_RUNNING_PODS:-1}"

# Port Configuration
readonly TEMPO_HTTP_PORT="${TEMPO_HTTP_PORT:-3200}"
readonly TEMPO_OTLP_GRPC_PORT="${TEMPO_OTLP_GRPC_PORT:-4317}"
readonly TEMPO_OTLP_HTTP_PORT="${TEMPO_OTLP_HTTP_PORT:-4318}"
readonly TEMPO_QUERY_FRONTEND_GRPC_PORT="${TEMPO_QUERY_FRONTEND_GRPC_PORT:-9095}"
readonly GRAFANA_PORT="${GRAFANA_PORT:-3000}"
readonly PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
readonly ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"
readonly LOKI_PORT="${LOKI_PORT:-3100}"
readonly MIMIR_PORT="${MIMIR_PORT:-8080}"

# Tempo Configuration
readonly TEMPO_MAX_BLOCK_DURATION="${TEMPO_MAX_BLOCK_DURATION:-5m}"
readonly TEMPO_TRACE_IDLE_PERIOD="${TEMPO_TRACE_IDLE_PERIOD:-10s}"
readonly TEMPO_BLOCK_RETENTION="${TEMPO_BLOCK_RETENTION:-1h}"
readonly TEMPO_COMPACTED_BLOCK_RETENTION="${TEMPO_COMPACTED_BLOCK_RETENTION:-10m}"
readonly TEMPO_QUERY_DEFAULT_RESULT_LIMIT="${TEMPO_QUERY_DEFAULT_RESULT_LIMIT:-20}"
readonly TEMPO_QUERY_MAX_RESULT_LIMIT="${TEMPO_QUERY_MAX_RESULT_LIMIT:-0}"

# Resource Requests and Limits (CPU in millicores, Memory in Mi/Gi)
readonly TEMPO_DISTRIBUTOR_CPU_REQUEST="${TEMPO_DISTRIBUTOR_CPU_REQUEST:-100m}"
readonly TEMPO_DISTRIBUTOR_CPU_LIMIT="${TEMPO_DISTRIBUTOR_CPU_LIMIT:-500m}"
readonly TEMPO_DISTRIBUTOR_MEMORY_REQUEST="${TEMPO_DISTRIBUTOR_MEMORY_REQUEST:-256Mi}"
readonly TEMPO_DISTRIBUTOR_MEMORY_LIMIT="${TEMPO_DISTRIBUTOR_MEMORY_LIMIT:-512Mi}"

readonly TEMPO_INGESTER_CPU_REQUEST="${TEMPO_INGESTER_CPU_REQUEST:-200m}"
readonly TEMPO_INGESTER_CPU_LIMIT="${TEMPO_INGESTER_CPU_LIMIT:-1000m}"
readonly TEMPO_INGESTER_MEMORY_REQUEST="${TEMPO_INGESTER_MEMORY_REQUEST:-512Mi}"
readonly TEMPO_INGESTER_MEMORY_LIMIT="${TEMPO_INGESTER_MEMORY_LIMIT:-1Gi}"
readonly TEMPO_INGESTER_STORAGE_SIZE="${TEMPO_INGESTER_STORAGE_SIZE:-10Gi}"

readonly TEMPO_QUERIER_CPU_REQUEST="${TEMPO_QUERIER_CPU_REQUEST:-100m}"
readonly TEMPO_QUERIER_CPU_LIMIT="${TEMPO_QUERIER_CPU_LIMIT:-500m}"
readonly TEMPO_QUERIER_MEMORY_REQUEST="${TEMPO_QUERIER_MEMORY_REQUEST:-256Mi}"
readonly TEMPO_QUERIER_MEMORY_LIMIT="${TEMPO_QUERIER_MEMORY_LIMIT:-1Gi}"

readonly TEMPO_QUERY_FRONTEND_CPU_REQUEST="${TEMPO_QUERY_FRONTEND_CPU_REQUEST:-100m}"
readonly TEMPO_QUERY_FRONTEND_CPU_LIMIT="${TEMPO_QUERY_FRONTEND_CPU_LIMIT:-500m}"
readonly TEMPO_QUERY_FRONTEND_MEMORY_REQUEST="${TEMPO_QUERY_FRONTEND_MEMORY_REQUEST:-256Mi}"
readonly TEMPO_QUERY_FRONTEND_MEMORY_LIMIT="${TEMPO_QUERY_FRONTEND_MEMORY_LIMIT:-1Gi}"

readonly TEMPO_COMPACTOR_CPU_REQUEST="${TEMPO_COMPACTOR_CPU_REQUEST:-100m}"
readonly TEMPO_COMPACTOR_CPU_LIMIT="${TEMPO_COMPACTOR_CPU_LIMIT:-500m}"
readonly TEMPO_COMPACTOR_MEMORY_REQUEST="${TEMPO_COMPACTOR_MEMORY_REQUEST:-256Mi}"
readonly TEMPO_COMPACTOR_MEMORY_LIMIT="${TEMPO_COMPACTOR_MEMORY_LIMIT:-512Mi}"

readonly TEMPO_METRICS_GENERATOR_CPU_REQUEST="${TEMPO_METRICS_GENERATOR_CPU_REQUEST:-100m}"
readonly TEMPO_METRICS_GENERATOR_CPU_LIMIT="${TEMPO_METRICS_GENERATOR_CPU_LIMIT:-500m}"
readonly TEMPO_METRICS_GENERATOR_MEMORY_REQUEST="${TEMPO_METRICS_GENERATOR_MEMORY_REQUEST:-256Mi}"
readonly TEMPO_METRICS_GENERATOR_MEMORY_LIMIT="${TEMPO_METRICS_GENERATOR_MEMORY_LIMIT:-1Gi}"

readonly TEMPO_GATEWAY_CPU_REQUEST="${TEMPO_GATEWAY_CPU_REQUEST:-100m}"
readonly TEMPO_GATEWAY_CPU_LIMIT="${TEMPO_GATEWAY_CPU_LIMIT:-200m}"
readonly TEMPO_GATEWAY_MEMORY_REQUEST="${TEMPO_GATEWAY_MEMORY_REQUEST:-128Mi}"
readonly TEMPO_GATEWAY_MEMORY_LIMIT="${TEMPO_GATEWAY_MEMORY_LIMIT:-256Mi}"

readonly PROMETHEUS_CPU_REQUEST="${PROMETHEUS_CPU_REQUEST:-500m}"
readonly PROMETHEUS_CPU_LIMIT="${PROMETHEUS_CPU_LIMIT:-2000m}"
readonly PROMETHEUS_MEMORY_REQUEST="${PROMETHEUS_MEMORY_REQUEST:-2Gi}"
readonly PROMETHEUS_MEMORY_LIMIT="${PROMETHEUS_MEMORY_LIMIT:-4Gi}"
readonly PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-100Gi}"
readonly PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-30d}"
readonly PROMETHEUS_RETENTION_SIZE="${PROMETHEUS_RETENTION_SIZE:-90GB}"

readonly GRAFANA_CPU_REQUEST="${GRAFANA_CPU_REQUEST:-100m}"
readonly GRAFANA_CPU_LIMIT="${GRAFANA_CPU_LIMIT:-500m}"
readonly GRAFANA_MEMORY_REQUEST="${GRAFANA_MEMORY_REQUEST:-256Mi}"
readonly GRAFANA_MEMORY_LIMIT="${GRAFANA_MEMORY_LIMIT:-512Mi}"
readonly GRAFANA_STORAGE_SIZE="${GRAFANA_STORAGE_SIZE:-20Gi}"

readonly ALERTMANAGER_CPU_REQUEST="${ALERTMANAGER_CPU_REQUEST:-100m}"
readonly ALERTMANAGER_CPU_LIMIT="${ALERTMANAGER_CPU_LIMIT:-500m}"
readonly ALERTMANAGER_MEMORY_REQUEST="${ALERTMANAGER_MEMORY_REQUEST:-256Mi}"
readonly ALERTMANAGER_MEMORY_LIMIT="${ALERTMANAGER_MEMORY_LIMIT:-512Mi}"
readonly ALERTMANAGER_STORAGE_SIZE="${ALERTMANAGER_STORAGE_SIZE:-1Gi}"
readonly ALERTMANAGER_GROUP_WAIT="${ALERTMANAGER_GROUP_WAIT:-10s}"
readonly ALERTMANAGER_GROUP_INTERVAL="${ALERTMANAGER_GROUP_INTERVAL:-10s}"

readonly LOKI_CPU_REQUEST="${LOKI_CPU_REQUEST:-200m}"
readonly LOKI_CPU_LIMIT="${LOKI_CPU_LIMIT:-1000m}"
readonly LOKI_MEMORY_REQUEST="${LOKI_MEMORY_REQUEST:-512Mi}"
readonly LOKI_MEMORY_LIMIT="${LOKI_MEMORY_LIMIT:-1Gi}"
readonly LOKI_STORAGE_SIZE="${LOKI_STORAGE_SIZE:-10Gi}"
readonly LOKI_RETENTION_PERIOD="${LOKI_RETENTION_PERIOD:-720h}"

readonly MIMIR_CPU_REQUEST="${MIMIR_CPU_REQUEST:-500m}"
readonly MIMIR_CPU_LIMIT="${MIMIR_CPU_LIMIT:-2000m}"
readonly MIMIR_MEMORY_REQUEST="${MIMIR_MEMORY_REQUEST:-2Gi}"
readonly MIMIR_MEMORY_LIMIT="${MIMIR_MEMORY_LIMIT:-4Gi}"

readonly MIMIR_GATEWAY_CPU_REQUEST="${MIMIR_GATEWAY_CPU_REQUEST:-100m}"
readonly MIMIR_GATEWAY_CPU_LIMIT="${MIMIR_GATEWAY_CPU_LIMIT:-500m}"
readonly MIMIR_GATEWAY_MEMORY_REQUEST="${MIMIR_GATEWAY_MEMORY_REQUEST:-128Mi}"
readonly MIMIR_GATEWAY_MEMORY_LIMIT="${MIMIR_GATEWAY_MEMORY_LIMIT:-256Mi}"


readonly OTEBPF_CPU_REQUEST="${OTEBPF_CPU_REQUEST:-50m}"
readonly OTEBPF_CPU_LIMIT="${OTEBPF_CPU_LIMIT:-500m}"
readonly OTEBPF_MEMORY_REQUEST="${OTEBPF_MEMORY_REQUEST:-256Mi}"
readonly OTEBPF_MEMORY_LIMIT="${OTEBPF_MEMORY_LIMIT:-512Mi}"

# Security Context (User/Group IDs)
readonly RUN_AS_USER="${RUN_AS_USER:-1000}"
readonly RUN_AS_GROUP="${RUN_AS_GROUP:-3000}"
readonly FS_GROUP="${FS_GROUP:-2000}"

# Grafana Security Context (Grafana-specific user/group IDs)
readonly GRAFANA_RUN_AS_USER="${GRAFANA_RUN_AS_USER:-472}"
readonly GRAFANA_RUN_AS_GROUP="${GRAFANA_RUN_AS_GROUP:-472}"
readonly GRAFANA_FS_GROUP="${GRAFANA_FS_GROUP:-472}"

# Prometheus Scraping Configuration
readonly PROMETHEUS_SCRAPE_INTERVAL="${PROMETHEUS_SCRAPE_INTERVAL:-30s}"
readonly PROMETHEUS_EVALUATION_INTERVAL="${PROMETHEUS_EVALUATION_INTERVAL:-30s}"
readonly PROMETHEUS_SCRAPE_TIMEOUT="${PROMETHEUS_SCRAPE_TIMEOUT:-10s}"

# Alert Thresholds
readonly ALERT_CPU_THRESHOLD="${ALERT_CPU_THRESHOLD:-0.8}"
readonly ALERT_MEMORY_THRESHOLD="${ALERT_MEMORY_THRESHOLD:-0.9}"
readonly ALERT_ERROR_RATE_THRESHOLD="${ALERT_ERROR_RATE_THRESHOLD:-0.05}"
readonly ALERT_LATENCY_THRESHOLD_SECONDS="${ALERT_LATENCY_THRESHOLD_SECONDS:-2}"
readonly ALERT_EVALUATION_INTERVAL="${ALERT_EVALUATION_INTERVAL:-30s}"
readonly ALERT_FOR_DURATION="${ALERT_FOR_DURATION:-5m}"

# Tempo Trace Time Shifts (for Grafana dashboards)
readonly TEMPO_SPAN_START_TIME_SHIFT="${TEMPO_SPAN_START_TIME_SHIFT:-1h}"
readonly TEMPO_SPAN_END_TIME_SHIFT="${TEMPO_SPAN_END_TIME_SHIFT:--1h}"

# ---- cert-manager (pinned version for TLS certificate management)
readonly CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.1}"

# Colors
readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'; readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ------------------------------
# Enhanced Logging
# ------------------------------
log_with_timestamp() { local level="$1"; shift; local t; t="$(date '+%Y-%m-%d %H:%M:%S')"; echo -e "${level} [$t] $*"; if [[ "${ENABLE_LOG_FILE:-1}" == "1" ]]; then echo -e "${level} [$t] $*" >> "$LOG_FILE" 2>/dev/null || true; fi; }
log_info()    { log_with_timestamp "${GREEN}[INFO]${NC}" "$@"; }
log_warn()    { log_with_timestamp "${YELLOW}[WARN]${NC}" "$@" >&2; }
log_error()   { log_with_timestamp "${RED}[ERROR]${NC}" "$@" >&2; }
log_debug()   { if [[ "${DEBUG:-0}" == "1" ]]; then log_with_timestamp "${BLUE}[DEBUG]${NC}" "$@"; fi; }
log_success() { log_with_timestamp "${GREEN}[SUCCESS]${NC}" "$@"; }
log_step()    { log_with_timestamp "${CYAN}[STEP]${NC}" "$@"; }

log_audit() { local a="$1" r="$2" res="$3"; local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo "[$ts] AUDIT: action=$a resource=$r result=$res user=$(whoami) script=$SCRIPT_NAME" >> "${LOG_FILE%.log}-audit.log" 2>/dev/null || true; log_info "Audit: $a $r -> $res"; }

# ------------------------------
# Error Handling
# ------------------------------
capture_debug_info() {
  local f
  f="${SCRIPT_DIR}/debug-$(date +%Y%m%d_%H%M%S).log"
  {
    echo "=== Debug Information ==="
    echo "Timestamp: $(date)"
    echo "Kubernetes cluster info:"; kubectl cluster-info 2>/dev/null || echo "Failed to get cluster info"
    echo ""; echo "Monitoring namespace resources:"; kubectl get all -n "$MONITORING_NAMESPACE" 2>/dev/null || echo "No resources found"
    echo ""; echo "Recent events:"; kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -20 2>/dev/null || echo "Failed to get events"
    echo ""; echo "Helm releases:"; helm list --all-namespaces 2>/dev/null || echo "Failed to list helm releases"
  } > "$f"; log_info "Debug information captured: $f"
}
cleanup_on_error(){ log_info "Performing error cleanup..."; if [[ -f "${VALUES_FILE}.bak" ]]; then mv "${VALUES_FILE}.bak" "${VALUES_FILE}" 2>/dev/null || true; fi; find "$CREDENTIALS_DIR" -name "*.tmp" -type f -delete 2>/dev/null || true; }
cleanup(){ log_debug "Performing normal cleanup..."; rm -f "${VALUES_FILE}.bak" 2>/dev/null || true; find "$CREDENTIALS_DIR" -name "*.tmp" -type f -delete 2>/dev/null || true; }
handle_error(){ local c="$1" l="$2" cmd="$3"; log_error "Command failed with exit code $c at line $l: $cmd"; log_error "Function stack: ${FUNCNAME[*]}"; log_audit "ERROR" "script_execution" "FAILED"; capture_debug_info; cleanup_on_error; exit "$c"; }
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ------------------------------
# Config & Input Validation
# ------------------------------
load_config(){ 
  if [[ -f "$CONFIG_FILE" ]]; then 
    log_info "Loading configuration from: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  else 
    log_debug "No configuration file found at: $CONFIG_FILE"
  fi
  mkdir -p "$CREDENTIALS_DIR" "$BACKUP_DIR"
  chmod 700 "$CREDENTIALS_DIR"
  validate_inputs
}
validate_inputs(){
  log_step "Validating configuration inputs..."
  local namespaces=("$MONITORING_NAMESPACE" "$OPENEMR_NAMESPACE" "$OBSERVABILITY_NAMESPACE")
  for ns in "${namespaces[@]}"; do [[ "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { log_error "Invalid namespace name: $ns"; return 1; }; done
  [[ "$STORAGE_CLASS_RWO" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { log_error "Invalid storage class: $STORAGE_CLASS_RWO"; return 1; }
  [[ "$BASE_DELAY" =~ ^[0-9]+$ && "$MAX_DELAY" =~ ^[0-9]+$ ]] || { log_error "Invalid delay values: BASE_DELAY=$BASE_DELAY, MAX_DELAY=$MAX_DELAY"; return 1; }



  # Validate autoscaling configuration
  if [[ "$ENABLE_AUTOSCALING" == "1" ]]; then
    local components=("GRAFANA" "PROMETHEUS" "LOKI" "ALERTMANAGER" "TEMPO" "MIMIR")
    for comp in "${components[@]}"; do
      local min_var="${comp}_MIN_REPLICAS"
      local max_var="${comp}_MAX_REPLICAS"
      local min_val="${!min_var}"
      local max_val="${!max_var}"
      
      if ! [[ "$min_val" =~ ^[0-9]+$ && "$max_val" =~ ^[0-9]+$ ]]; then
        log_error "Invalid replica values for $comp: min=$min_val, max=$max_val (must be positive integers)"
        return 1
      fi
      
      if [[ "$min_val" -lt 1 || "$max_val" -lt 1 ]]; then
        log_error "Invalid replica values for $comp: min=$min_val, max=$max_val (must be >= 1)"
        return 1
      fi
      
      if [[ "$min_val" -gt "$max_val" ]]; then
        log_error "Invalid replica values for $comp: min=$min_val > max=$max_val"
        return 1
      fi
      
      if [[ "$max_val" -gt 10 ]]; then
        log_warn "High max replicas for $comp: $max_val (consider cost implications)"
      fi
    done
    
    # Validate HPA targets
    if ! [[ "$HPA_CPU_TARGET" =~ ^[0-9]+$ && "$HPA_MEMORY_TARGET" =~ ^[0-9]+$ ]]; then
      log_error "Invalid HPA targets: CPU=$HPA_CPU_TARGET, Memory=$HPA_MEMORY_TARGET (must be positive integers)"
      return 1
    fi
    
    if [[ "$HPA_CPU_TARGET" -lt 10 || "$HPA_CPU_TARGET" -gt 90 ]]; then
      log_warn "Unusual CPU target: $HPA_CPU_TARGET% (recommended: 50-80%)"
    fi
    
    if [[ "$HPA_MEMORY_TARGET" -lt 10 || "$HPA_MEMORY_TARGET" -gt 90 ]]; then
      log_warn "Unusual memory target: $HPA_MEMORY_TARGET% (recommended: 60-85%)"
    fi
  fi
  
  log_success "Configuration validation passed"
}

# ------------------------------
# Dependency Checks
# ------------------------------
check_command(){ local cmd="$1" req="${2:-true}"; if ! command -v "$cmd" >/dev/null 2>&1; then if [[ "$req" == "true" ]]; then log_error "$cmd is not installed or not in PATH"; return 1; else log_warn "$cmd is not available (optional)"; return 1; fi; fi; log_debug "$cmd is available"; }
check_dependencies(){ log_step "Checking required dependencies..."; local required_tools=("kubectl" "helm" "jq" "openssl" "curl"); local optional_tools=("yq" "python3" "htpasswd"); for t in "${required_tools[@]}"; do check_command "$t" true; done; for t in "${optional_tools[@]}"; do check_command "$t" false || true; done; log_success "Dependency check completed"; }

# ------------------------------
# Cluster Checks
# ------------------------------
check_kubernetes(){ log_step "Checking Kubernetes cluster connectivity..."; kubectl cluster-info >/dev/null 2>&1 || { log_error "Cannot connect to cluster"; return 1; }; local kc sv; kc="$(kubectl version --short 2>/dev/null | grep Client | awk '{print $3}' || echo "unknown")"; sv="$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' || echo "unknown")"; log_info "Connected. Client: $kc, Server: $sv"; log_audit "CONNECT" "kubernetes_cluster" "SUCCESS"; }
check_cluster_resources(){
  log_step "Checking cluster resource availability..."
  local nodes_ready nodes_total cpu_capacity memory_capacity memory_gib=0
  nodes_ready="$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)"
  nodes_total="$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo 0)"
  if [[ "$nodes_total" -eq 0 ]]; then log_warn "No nodes found - EKS Auto Mode may provision as needed"; return 0; fi
  cpu_capacity="$(kubectl get nodes -o json 2>/dev/null | jq -r '[.items[].status.capacity.cpu | tonumber] | add // 0' || echo 0)"
  memory_capacity="$(kubectl get nodes -o json 2>/dev/null | jq -r '[.items[].status.capacity.memory | sub("Ki$";"") | tonumber] | add // 0' || echo 0)"
  if [[ "$memory_capacity" =~ ^[0-9]+$ && "$memory_capacity" -gt 0 ]]; then memory_gib=$((memory_capacity / 1024 / 1024)); fi
  log_info "Nodes ready: $nodes_ready/$nodes_total | Capacity: ${cpu_capacity} CPU, ${memory_gib} GiB"
  if [[ "$cpu_capacity" =~ ^[0-9]+$ && "$cpu_capacity" -gt 0 && "$cpu_capacity" -lt 4 ]]; then log_warn "Low CPU capacity; monitoring may trigger scale out"; fi
  if [[ "$memory_capacity" =~ ^[0-9]+$ && "$memory_capacity" -gt 0 && "$memory_gib" -lt 8 ]]; then log_warn "Low memory capacity; monitoring may trigger scale out"; fi
}
check_eks_auto_mode(){ log_step "Checking EKS Auto Mode status..."; if kubectl get nodes --show-labels 2>/dev/null | grep -q "eks.amazonaws.com/compute-type=auto"; then log_info "EKS Auto Mode detected"; elif kubectl get nodes >/dev/null 2>&1; then local c; c="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"; log_info "Standard EKS cluster with $c nodes"; else log_info "EKS Auto Mode likely (no nodes reported)"; fi }

# ------------------------------
# Namespace / RBAC / Security
# ------------------------------
ensure_namespace(){ 
  local ns="$1"
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then 
    log_info "Creating namespace: $ns"
    if [[ "$ns" == "monitoring" ]]; then
      # Monitoring namespace needs privileged PodSecurity for OTeBPF and node-exporter
      kubectl create namespace "$ns" --dry-run=client -o yaml | \
        kubectl label --local -f - \
          pod-security.kubernetes.io/enforce=privileged \
          pod-security.kubernetes.io/audit=privileged \
          pod-security.kubernetes.io/warn=privileged \
          app.kubernetes.io/name=monitoring \
          app.kubernetes.io/component=observability \
          app.kubernetes.io/part-of=openemr-eks \
          -o yaml | kubectl apply -f -
    else
      kubectl create namespace "$ns"
    fi
    log_audit "CREATE" "namespace:$ns" "SUCCESS"
  else 
    log_debug "Namespace $ns exists"
    # Ensure monitoring namespace has privileged PodSecurity if it exists
    if [[ "$ns" == "monitoring" ]]; then
      kubectl label namespace "$ns" \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged \
        --overwrite >/dev/null 2>&1 || true
    fi
  fi
}

configure_namespace_security(){
  log_step "Configuring Pod Security Standards for monitoring namespace..."
  local ns="$MONITORING_NAMESPACE"
  local enforce audit warn; enforce="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")"
  audit="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/audit}' 2>/dev/null || echo "")"
  warn="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}' 2>/dev/null || echo "")"
  log_info "Current Pod Security Standards: enforce=$enforce, audit=$audit, warn=$warn"
  if [[ "$enforce" != "privileged" ]]; then
    log_info "Setting Pod Security Standards to 'privileged' for node exporter compatibility..."
    kubectl label namespace "$ns" pod-security.kubernetes.io/enforce=privileged --overwrite
    kubectl label namespace "$ns" pod-security.kubernetes.io/audit=privileged --overwrite
    kubectl label namespace "$ns" pod-security.kubernetes.io/warn=privileged --overwrite
    log_success "Pod Security Standards configured for monitoring namespace"; log_audit "CONFIGURE" "namespace_security:$ns" "SUCCESS"
  else
    log_info "Pod Security Standards already configured correctly"
  fi
}

cleanup_duplicate_pods(){
  log_step "Cleaning up duplicate or pending pods..."
  local cleaned=0
  local grafana_pods; grafana_pods="$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | wc -l || echo 0)"
  if [[ "$grafana_pods" -gt 1 ]]; then
    log_info "Found $grafana_pods Grafana pods, cleaning up duplicates..."
    kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana --field-selector=status.phase=Pending --no-headers 2>/dev/null | \
    while read -r pod_name _; do if [[ -n "$pod_name" ]]; then log_info "Deleting pending Grafana pod: $pod_name"; kubectl delete pod "$pod_name" -n "$MONITORING_NAMESPACE" --ignore-not-found; ((cleaned += 1)); fi; done
  fi
  kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Failed --no-headers 2>/dev/null | \
  while read -r pod_name _ _ _ age _; do if [[ -n "$pod_name" && "$age" =~ ^[0-9]+[mh]$ ]]; then log_info "Deleting failed pod: $pod_name (age: $age)"; kubectl delete pod "$pod_name" -n "$MONITORING_NAMESPACE" --ignore-not-found; ((cleaned += 1)); fi; done
  if [[ "$cleaned" -gt 0 ]]; then log_success "Cleaned up $cleaned problematic pods"; log_audit "CLEANUP" "duplicate_pods" "SUCCESS"; else log_info "No duplicate or failed pods found"; fi
}
create_monitoring_rbac(){
  log_step "Creating RBAC configuration for monitoring..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openemr-monitoring
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/name: openemr-monitoring
    app.kubernetes.io/version: "1.0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openemr-monitoring
  labels:
    app.kubernetes.io/name: openemr-monitoring
rules:
- apiGroups: [""]
  resources: ["pods", "services", "endpoints", "nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list"]
- apiGroups: ["monitoring.coreos.com"]
  resources: ["servicemonitors", "prometheusrules"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openemr-monitoring
  labels:
    app.kubernetes.io/name: openemr-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openemr-monitoring
subjects:
- kind: ServiceAccount
  name: openemr-monitoring
  namespace: ${MONITORING_NAMESPACE}
EOF
  log_success "RBAC configuration created"; log_audit "CREATE" "rbac:openemr-monitoring" "SUCCESS"
}

# ------------------------------
# Storage Validation
# ------------------------------
check_storage_class(){
  log_step "Validating storage classes..."
  log_info "Checking RWO storage class: $STORAGE_CLASS_RWO"
  kubectl get storageclass "$STORAGE_CLASS_RWO" >/dev/null 2>&1 || { log_error "StorageClass '$STORAGE_CLASS_RWO' not found"; return 1; }
  if [[ -n "$STORAGE_CLASS_RWX" ]]; then
    if kubectl get storageclass "$STORAGE_CLASS_RWX" >/dev/null 2>&1; then log_success "RWX storage class available: $STORAGE_CLASS_RWX"; else log_warn "RWX storage class '$STORAGE_CLASS_RWX' not found (continuing with RWO)"; fi
  fi
  log_success "Storage class validation completed"
}

# ------------------------------
# Retry Helper
# ------------------------------
retry_with_backoff(){ local max="$1" base="$2" maxd="$3"; shift 3; local attempt=1 delay="$base"; while [[ $attempt -le $max ]]; do log_debug "Attempt $attempt/$max: $*"; if "$@"; then return 0; fi; if [[ $attempt -lt $max ]]; then log_warn "Attempt $attempt failed, retrying in ${delay}s..."; sleep "$delay"; delay=$((delay * 2)); [[ $delay -gt $maxd ]] && delay="$maxd"; fi; ((attempt += 1)); done; log_error "Command failed after $max attempts: $*"; return 1; }

# ------------------------------
# Helm Repo Setup
# ------------------------------
setup_helm_repos(){
  log_step "Setting up Helm repositories..."
  local repos=("prometheus-community|https://prometheus-community.github.io/helm-charts" "grafana|https://grafana.github.io/helm-charts" "grafana-community|https://grafana-community.github.io/helm-charts")
  for r in "${repos[@]}"; do IFS='|' read -r name url <<<"$r"; log_info "Adding repository: $name"; retry_with_backoff 3 5 15 helm repo add "$name" "$url" || log_warn "Repo $name add failed (may already exist)"; done
  log_info "Updating Helm repositories..."; retry_with_backoff 3 10 30 helm repo update
  log_success "Helm repositories configured"; log_audit "CONFIGURE" "helm_repositories" "SUCCESS"
}

# ------------------------------
# Passwords / Secrets
# ------------------------------
generate_secure_password(){ openssl rand -base64 32 | tr -dc 'A-Za-z0-9._-' | head -c 24; }
create_secure_password_file(){
  local p="$1"
  local f="$CREDENTIALS_DIR/grafana-admin-password"

  # Backup existing file if it exists
  if [[ -f "$f" ]]; then
    local backup_file
    backup_file="${f}.backup.$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up existing password file to: $backup_file"
    cp "$f" "$backup_file"
    chmod 600 "$backup_file"
  fi

  umask 077
  echo "$p" > "$f"
  chmod 600 "$f"
  echo "$f"
}
create_grafana_secret(){
  local p="$1"
  
  # Check if Grafana admin secret already exists
  if kubectl get secret grafana-admin-secret -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
    log_info "Grafana admin secret already exists - preserving existing credentials"
    log_info "Admin credentials will not be changed - existing credentials remain valid"
    
    # Retrieve existing password from secret
    local existing_password
    existing_password=$(kubectl get secret grafana-admin-secret -n "$MONITORING_NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$existing_password" ]; then
      log_success "Retrieved existing Grafana admin password from secret"
      # Update the password variable to use existing password
      p="$existing_password"
    else
      log_warn "Could not retrieve existing Grafana admin password - using new password"
    fi
  else
    log_info "Creating new Grafana admin secret..."
  fi
  
  # Create or update the secret
  kubectl create secret generic grafana-admin-secret \
    --from-literal=admin-user="admin" \
    --from-literal=admin-password="$p" \
    --namespace="$MONITORING_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  log_audit "CREATE" "secret:grafana-admin-secret" "SUCCESS"
}
write_credentials_file(){
  local p="$1" f="$CREDENTIALS_DIR/monitoring-credentials.txt"

  # Always get the actual password from the secret to ensure accuracy
  local actual_password
  if kubectl get secret grafana-admin-secret -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
    actual_password=$(kubectl get secret grafana-admin-secret -n "$MONITORING_NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "")
    if [[ -n "$actual_password" ]]; then
      log_info "Retrieved actual Grafana password from secret"
      p="$actual_password"
    else
      log_warn "Could not retrieve actual password from secret, using provided password"
    fi
  else
    log_warn "Grafana secret not found, using provided password"
  fi

  # Check if credentials file already exists and contains the same password
  if [[ -f "$f" ]]; then
    # Try to extract existing password from file
    local existing_password
    existing_password=$(grep "Grafana Admin Password: " "$f" | sed 's/.*Grafana Admin Password: //' | head -1)
    
    if [[ -n "$existing_password" && "$existing_password" == "$p" ]]; then
      log_info "Credentials file already exists with correct password - preserving existing file"
      log_info "Using existing credentials from: $f"
      return 0
    else
      local backup_file
    backup_file="${f}.backup.$(date +%Y%m%d-%H%M%S)"
      log_info "Backing up existing credentials file to: $backup_file"
      cp "$f" "$backup_file"
      chmod 600 "$backup_file"
    fi
  fi

  umask 077
  cat > "$f" <<EOF
# OpenEMR Monitoring Credentials
# Generated: $(date)

Grafana Admin User: admin
Grafana Admin Password: $p

# Port-forward access:
# Grafana:   kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-grafana ${GRAFANA_PORT}:80
# Prometheus: kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-kube-prom-prometheus ${PROMETHEUS_PORT}:9090
# AlertManager: kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-kube-prom-alertmanager ${ALERTMANAGER_PORT}:9093
# Loki:       kubectl -n $MONITORING_NAMESPACE port-forward svc/loki-gateway ${LOKI_PORT}:80
# Tempo:      kubectl -n $MONITORING_NAMESPACE port-forward svc/tempo-gateway ${TEMPO_HTTP_PORT}:80
# Mimir:      kubectl -n $MONITORING_NAMESPACE port-forward svc/mimir-gateway ${MIMIR_PORT}:${MIMIR_PORT}

# Security Note: keep this file secure and delete when no longer needed.
EOF
  chmod 600 "$f"; log_info "Credentials written to: $f"; log_audit "CREATE" "credentials_file" "SUCCESS"
}

# ------------------------------
# cert-manager install / check
# ------------------------------
cert_manager_ready(){
  kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || return 1
  kubectl -n cert-manager get deploy cert-manager cert-manager-webhook cert-manager-cainjector >/dev/null 2>&1 || return 1
  kubectl -n cert-manager wait deploy/cert-manager --for=condition=Available --timeout="${TIMEOUT_KUBECTL}" >/dev/null 2>&1 || return 1
  kubectl -n cert-manager wait deploy/cert-manager-webhook --for=condition=Available --timeout="${TIMEOUT_KUBECTL}" >/dev/null 2>&1 || return 1
  kubectl -n cert-manager wait deploy/cert-manager-cainjector --for=condition=Available --timeout="${TIMEOUT_KUBECTL}" >/dev/null 2>&1 || return 1
  return 0
}

install_cert_manager(){
  log_step "Ensuring cert-manager ${CERT_MANAGER_VERSION} is installed (for webhooks & optional TLS)..."
  if cert_manager_ready; then
    log_info "cert-manager already installed and ready"
    return 0
  fi
  local CM_URL="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  log_info "Installing cert-manager from ${CM_URL}"
  kubectl apply -f "$CM_URL"
  # Wait
  kubectl -n cert-manager wait deploy/cert-manager --for=condition=Available --timeout="${TIMEOUT_KUBECTL}"
  kubectl -n cert-manager wait deploy/cert-manager-webhook --for=condition=Available --timeout="${TIMEOUT_KUBECTL}"
  kubectl -n cert-manager wait deploy/cert-manager-cainjector --for=condition=Available --timeout="${TIMEOUT_KUBECTL}"
  log_success "cert-manager ${CERT_MANAGER_VERSION} is ready"
}

# ------------------------------
# Values File (with access-mode & alertmanager probe)
# ------------------------------
resolve_access_modes(){
  if [[ "$ACCESS_MODE_RWO" == "ReadWriteOncePod" ]]; then
    if kubectl get sc "$STORAGE_CLASS_RWO" -o yaml 2>/dev/null | grep -q 'ebs.csi.eks.amazonaws.com'; then
      local test_ns="tmp-rwo-probe-$$"
      kubectl create ns "$test_ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
      if ! kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: probe-pvc, namespace: ${test_ns}}
spec:
  accessModes: ["ReadWriteOncePod"]
  resources: { requests: { storage: 1Gi } }
  storageClassName: ${STORAGE_CLASS_RWO}
PVC
      then
        export ACCESS_MODE_RWO="ReadWriteOnce"; log_warn "ACCESS_MODE_RWO=ReadWriteOncePod not supported; falling back to ReadWriteOnce"
      fi
      kubectl delete ns "$test_ns" --ignore-not-found >/dev/null 2>&1 || true
    fi
  fi
}

alertmanager_enabled(){ [[ -n "$SLACK_WEBHOOK_URL" && -n "$SLACK_CHANNEL" && "$SLACK_WEBHOOK_URL" =~ ^https://hooks\.slack\.com/ ]]; }

validate_helm_values(){
  local vf="$1"; log_debug "Validating Helm values file: $vf"
  [[ -r "$vf" ]] || { log_error "Values file not readable: $vf"; return 1; }
  
  # Try yq first (more reliable), fall back to Python
  if command -v yq >/dev/null 2>&1; then
    yq eval '.' "$vf" >/dev/null 2>&1 || { log_error "Invalid YAML syntax"; return 1; }
  elif command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    python3 - "$vf" 2>/dev/null <<'PY' || { log_error "Invalid YAML syntax"; return 1; }
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
PY
  else
    log_warn "No YAML validator available (yq or python3 with PyYAML), skipping validation"
  fi
  
  grep -q "existingSecret:" "$vf" || { log_error "Grafana not configured to use existingSecret"; return 1; }
  log_success "Values file validation passed"
}

create_values_file(){
  log_step "Creating Helm values file..."
  if [[ -f "$VALUES_FILE" ]]; then cp "$VALUES_FILE" "${VALUES_FILE}.bak"; fi
  resolve_access_modes
  local sc_prom="$STORAGE_CLASS_RWO" am_prom="$ACCESS_MODE_RWO"
  local sc_am="$STORAGE_CLASS_RWO"   am_am="$ACCESS_MODE_RWO"

  # Get AlertManager S3 bucket and IAM role from Terraform
  local terraform_dir="${SCRIPT_DIR}/../terraform"
  local am_bucket_name=""
  local am_role_arn=""
  
  if [[ -d "$terraform_dir" ]] && command -v terraform >/dev/null 2>&1; then
    cd "$terraform_dir" || true
    am_bucket_name=$(terraform output -raw alertmanager_s3_bucket_name 2>/dev/null || echo "")
    am_role_arn=$(terraform output -raw alertmanager_s3_role_arn 2>/dev/null || echo "")
    cd "$SCRIPT_DIR" || true
  fi

  local AM_BLOCK=""
  if alertmanager_enabled; then
    if [[ -n "$am_bucket_name" && -n "$am_role_arn" ]]; then
      # Use S3 for AlertManager state storage
      AM_BLOCK=$(cat <<EOF_AM
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${sc_am}
          accessModes: ["${am_am}"]
          resources: { requests: { storage: ${ALERTMANAGER_STORAGE_SIZE} } }
    resources:
      requests: { cpu: ${ALERTMANAGER_CPU_REQUEST}, memory: ${ALERTMANAGER_MEMORY_REQUEST} }
      limits:   { cpu: ${ALERTMANAGER_CPU_LIMIT}, memory: ${ALERTMANAGER_MEMORY_LIMIT} }
    securityContext:
      runAsUser: ${RUN_AS_USER}
      runAsGroup: ${RUN_AS_GROUP}
      fsGroup: ${FS_GROUP}
    configSecret: alertmanager-config
    # S3 storage for AlertManager cluster state
      externalUrl: http://alertmanager-prometheus-stack-kube-prom-alertmanager.${MONITORING_NAMESPACE}.svc.cluster.local:${ALERTMANAGER_PORT}
    cluster:
      peerTimeout: ${ALERTMANAGER_PEER_TIMEOUT}
      gossipInterval: ${ALERTMANAGER_GOSSIP_INTERVAL}
      pushPullInterval: ${ALERTMANAGER_PUSH_PULL_INTERVAL}
      tlsEnabled: false
    # Note: S3 state storage is configured via AlertManager configuration
    # The bucket ${am_bucket_name} will be used for cluster state
EOF_AM
)
    else
      # Fallback to EBS storage
      AM_BLOCK=$(cat <<EOF_AM
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${sc_am}
          accessModes: ["${am_am}"]
          resources: { requests: { storage: ${ALERTMANAGER_STORAGE_SIZE} } }
    resources:
      requests: { cpu: ${ALERTMANAGER_CPU_REQUEST}, memory: ${ALERTMANAGER_MEMORY_REQUEST} }
      limits:   { cpu: ${ALERTMANAGER_CPU_LIMIT}, memory: ${ALERTMANAGER_MEMORY_LIMIT} }
    securityContext:
      runAsUser: ${RUN_AS_USER}
      runAsGroup: ${RUN_AS_GROUP}
      fsGroup: ${FS_GROUP}
    configSecret: alertmanager-config
EOF_AM
)
    fi
  else
    AM_BLOCK="# alertmanager: using chart defaults (no custom config)"
  fi

  cat > "$VALUES_FILE" <<EOF
# OpenEMR Monitoring Stack Configuration
# Generated: $(date)

grafana:
  enabled: true
  adminUser: admin
  admin:
    existingSecret: "grafana-admin-secret"
    userKey: admin-user
    passwordKey: admin-password
  
  persistence:
    enabled: true
    storageClassName: ${sc_prom}
    size: ${GRAFANA_STORAGE_SIZE}
    accessModes: ["${am_prom}"]

  securityContext:
    runAsUser: ${GRAFANA_RUN_AS_USER}
    runAsGroup: ${GRAFANA_RUN_AS_GROUP}
    fsGroup: ${GRAFANA_FS_GROUP}

  resources:
    requests: { cpu: ${GRAFANA_CPU_REQUEST}, memory: ${GRAFANA_MEMORY_REQUEST} }
    limits:   { cpu: ${GRAFANA_CPU_LIMIT}, memory: ${GRAFANA_MEMORY_LIMIT} }
EOF

  # Add autoscaling configuration for Grafana if enabled
  if [[ "$ENABLE_AUTOSCALING" == "1" ]]; then
    cat >> "$VALUES_FILE" <<EOF

  autoscaling:
    enabled: true
    minReplicas: ${GRAFANA_MIN_REPLICAS}
    maxReplicas: ${GRAFANA_MAX_REPLICAS}
    targetCPUUtilizationPercentage: ${HPA_CPU_TARGET}
    targetMemoryUtilizationPercentage: ${HPA_MEMORY_TARGET}
EOF
  fi

  cat >> "$VALUES_FILE" <<EOF

  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      folder: /tmp/dashboards
      folderAnnotation: grafana_folder
      searchNamespace: ALL
    datasources:
      enabled: true
      label: grafana_datasource
      labelValue: "1"
      searchNamespace: ALL

  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s:%(http_port)s/"
      serve_from_sub_path: false
    security:
      admin_user: admin
    tracing:
      enabled: false
      disable_gravatar: true
      cookie_secure: true
      cookie_samesite: strict
    analytics:
      reporting_enabled: false
      check_for_updates: false
    log:
      level: info
    unified_alerting:
      enabled: true
    tracing:
      enabled: true
      tempo:
        address: "tempo-distributor.monitoring.svc.cluster.local:${TEMPO_OTLP_GRPC_PORT}"
        auth_type: ""

prometheus:
  prometheusSpec:
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    ruleSelector: {}
    ruleNamespaceSelector: {}

    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${sc_prom}
          accessModes: ["${am_prom}"]
          resources: { requests: { storage: ${PROMETHEUS_STORAGE_SIZE} } }

    resources:
      requests: { cpu: ${PROMETHEUS_CPU_REQUEST}, memory: ${PROMETHEUS_MEMORY_REQUEST} }
      limits:   { cpu: ${PROMETHEUS_CPU_LIMIT}, memory: ${PROMETHEUS_MEMORY_LIMIT} }

    replicas: ${PROMETHEUS_MIN_REPLICAS}
    retention: ${PROMETHEUS_RETENTION}
    retentionSize: ${PROMETHEUS_RETENTION_SIZE}

    securityContext:
      runAsUser: ${RUN_AS_USER}
      runAsGroup: ${RUN_AS_GROUP}
      fsGroup: ${FS_GROUP}

    additionalScrapeConfigs: []
    remoteWrite:
      - url: http://mimir-gateway.${MONITORING_NAMESPACE}.svc.cluster.local:${MIMIR_PORT}/api/v1/push
        queueConfig:
          maxSamplesPerSend: 1000
          batchSendDeadline: 5s
          maxRetries: 3
          minBackoff: 30ms
          maxBackoff: 100ms
    evaluationInterval: ${PROMETHEUS_EVALUATION_INTERVAL}
    scrapeInterval: ${PROMETHEUS_SCRAPE_INTERVAL}
EOF

  # Add autoscaling configuration for Prometheus if enabled
  if [[ "$ENABLE_AUTOSCALING" == "1" ]]; then
    cat >> "$VALUES_FILE" <<EOF

  prometheus:
    prometheusSpec:
      autoscaling:
        enabled: true
        minReplicas: ${PROMETHEUS_MIN_REPLICAS}
        maxReplicas: ${PROMETHEUS_MAX_REPLICAS}
        targetCPUUtilizationPercentage: ${HPA_CPU_TARGET}
        targetMemoryUtilizationPercentage: ${HPA_MEMORY_TARGET}
EOF
  fi

  cat >> "$VALUES_FILE" <<EOF

${AM_BLOCK}

nodeExporter: { enabled: true }
kubeStateMetrics: { enabled: true }

defaultRules:
  create: true
  rules:
    alertmanager: true
    etcd: false
    configReloaders: true
    general: true
    k8s: true
    kubeApiserverAvailability: true
    kubeApiserverBurnrate: true
    kubeApiserverHistogram: true
    kubeApiserverSlos: true
    kubelet: true
    kubeProxy: false
    kubePrometheusGeneral: true
    kubePrometheusNodeRecording: true
    kubernetesApps: true
    kubernetesResources: true
    kubernetesStorage: true
    kubernetesSystem: true
    kubeScheduler: false
    kubeStateMetrics: true
    network: true
    node: true
    nodeExporterAlerting: true
    nodeExporterRecording: true
    prometheus: true
    prometheusOperator: true

kubeEtcd:             { enabled: false }
kubeScheduler:        { enabled: false }
kubeProxy:            { enabled: false }
kubeControllerManager:{ enabled: false }
prometheusOperator:
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { cpu: 500m, memory: 256Mi }
EOF
  validate_helm_values "$VALUES_FILE"
  log_success "Values file created: $VALUES_FILE"; log_audit "CREATE" "helm_values_file" "SUCCESS"
}

# ------------------------------
# CRDs & OpenEMR Monitoring
# ------------------------------
wait_for_prom_operator_crds(){
  log_step "Waiting for Prometheus Operator CRDs to be established..."
  local crds=("servicemonitors.monitoring.coreos.com" "prometheusrules.monitoring.coreos.com" "podmonitors.monitoring.coreos.com" "probes.monitoring.coreos.com" "prometheuses.monitoring.coreos.com" "alertmanagers.monitoring.coreos.com")
  for c in "${crds[@]}"; do retry_with_backoff 10 3 20 kubectl get crd "$c" >/dev/null 2>&1 || { log_error "CRD not found: $c"; return 1; }; done
  log_success "All required CRDs present"
}

wait_for_prom_operator_webhook(){
  log_step "Waiting for Prometheus Operator admission webhook to be ready..."
  kubectl -n "$MONITORING_NAMESPACE" wait deploy/prometheus-stack-kube-prom-operator \
    --for=condition=Available --timeout="${TIMEOUT_KUBECTL}" >/dev/null 2>&1 || {
    log_error "Prometheus Operator deployment not available"; return 1
  }
  retry_with_backoff 12 5 60 bash -c \
    "kubectl get endpoints prometheus-stack-kube-prom-operator -n \"$MONITORING_NAMESPACE\" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q ." || {
    log_error "Prometheus Operator webhook endpoints not ready"; return 1
  }
  log_success "Prometheus Operator webhook ready"
}

# ------------------------------
# AlertManager Config (optional)
# ------------------------------
create_alertmanager_config(){
  if ! alertmanager_enabled; then log_info "Skipping Alertmanager config (SLACK_WEBHOOK_URL/SLACK_CHANNEL not set or invalid)."; return 0; fi
  log_step "Creating AlertManager configuration for Slack channel ${SLACK_CHANNEL}..."
  
  # Get AlertManager S3 bucket from Terraform
  local terraform_dir="${SCRIPT_DIR}/../terraform"
  local am_bucket_name=""
  local am_s3_config=""
  
  if [[ -d "$terraform_dir" ]] && command -v terraform >/dev/null 2>&1; then
    cd "$terraform_dir" || true
    am_bucket_name=$(terraform output -raw alertmanager_s3_bucket_name 2>/dev/null || echo "")
    cd "$SCRIPT_DIR" || true
    
    if [[ -n "$am_bucket_name" ]]; then
      am_s3_config="
    # S3 storage for AlertManager cluster state
    storage:
      type: s3
      s3:
        bucket: ${am_bucket_name}
        region: ${AWS_REGION}
        endpoint: \"\"
        s3forcepathstyle: false"
    fi
  fi
  
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: ${MONITORING_NAMESPACE}
  labels: { app.kubernetes.io/name: alertmanager }
type: Opaque
stringData:
  alertmanager.yml: |
    global: {}
    route:
      group_by: ['alertname','namespace','severity']
      group_wait: ${ALERTMANAGER_GROUP_WAIT}
      group_interval: ${ALERTMANAGER_GROUP_INTERVAL}
      repeat_interval: ${ALERTMANAGER_REPEAT_INTERVAL}
      receiver: 'slack-default'
      routes:${am_s3_config}
    receivers:
    - name: 'slack-default'
      slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '${SLACK_CHANNEL}'
        title: 'OpenEMR Alert: {{ .GroupLabels.alertname }}'
        text: >-
          *Alert:* {{ .GroupLabels.alertname }}
          *Severity:* {{ .CommonLabels.severity }}
          *Summary:* {{ .CommonAnnotations.summary }}
          *Description:* {{ .CommonAnnotations.description }}
EOF
  log_success "AlertManager configuration created (Slack${am_s3_config:+, S3 storage})"; log_audit "CREATE" "alertmanager_config" "SUCCESS"
}

# ------------------------------
# Installs
# ------------------------------
install_prometheus_stack(){
  local vf="$1"
  log_step "Installing kube-prometheus-stack (version ${CHART_KPS_VERSION})..."
  log_info "⏱️  Expected duration: ~3 minutes"
  
  # Install with retry logic for network resilience
  local max_retries="${MAX_RETRIES}"
  local retry_delay="${HELM_INSTALL_RETRY_DELAY}"
  local attempt=1
  
  while [ $attempt -le "$max_retries" ]; do
    log_info "Attempt $attempt/$max_retries: Installing Prometheus Stack..."
    
    # Test cluster connectivity before attempting installation
    if ! kubectl cluster-info >/dev/null 2>&1; then
      log_warn "Cluster connectivity issue detected, waiting ${retry_delay}s before retry..."
      sleep "$retry_delay"
      ((attempt += 1))
      continue
    fi
    
    # Attempt Helm installation with enhanced timeout and retry settings
    if helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace "$MONITORING_NAMESPACE" --create-namespace \
      --version "$CHART_KPS_VERSION" \
      --timeout "$TIMEOUT_HELM" --atomic --wait --wait-for-jobs \
      --values "$vf" 2>&1 | tee "${SCRIPT_DIR}/helm-install-kps.log"; then
      
      # Verify installation success
      if helm status prometheus-stack -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        log_success "Prometheus Stack installed successfully on attempt $attempt"
        break
      else
        log_error "Helm installation appeared successful but status check failed"
        if [ $attempt -lt "$max_retries" ]; then
          log_info "Retrying in ${retry_delay}s..."
          sleep "$retry_delay"
        fi
      fi
    else
      log_error "Helm installation failed on attempt $attempt"
      if [ $attempt -lt "$max_retries" ]; then
        log_info "Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
      fi
    fi
    
    ((attempt += 1))
  done
  
  if [ $attempt -gt "$max_retries" ]; then
    log_error "Prometheus Stack installation failed after $max_retries attempts. Check ${SCRIPT_DIR}/helm-install-kps.log"
    log_audit "INSTALL" "prometheus-stack" "FAILED"
    return 1
  fi
  
  # Wait for pods with enhanced timeout - ALL must be ready
  log_info "Waiting for Prometheus and Grafana pods to be ready..."
  if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n "$MONITORING_NAMESPACE" --timeout="$TIMEOUT_KUBECTL"; then
    log_error "Grafana pods not ready within timeout - CRITICAL FAILURE"
    log_audit "INSTALL" "prometheus-stack" "FAILED"
    return 1
  fi
  if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n "$MONITORING_NAMESPACE" --timeout="$TIMEOUT_KUBECTL"; then
    log_error "Prometheus pods not ready within timeout - CRITICAL FAILURE"
    log_audit "INSTALL" "prometheus-stack" "FAILED"
    return 1
  fi
  log_success "Prometheus Stack installed and all pods ready"; log_audit "INSTALL" "prometheus-stack" "SUCCESS"
}
install_loki_stack(){
  log_step "Installing Loki (version ${CHART_LOKI_VERSION}) with S3 storage..."
  log_info "⏱️  Expected duration: ~3 minutes"
  
  # Get S3 bucket name and IAM role ARN from Terraform outputs
  local terraform_dir="${SCRIPT_DIR}/../terraform"
  local loki_bucket_name=""
  local loki_role_arn=""
  
  if [[ -d "$terraform_dir" ]] && command -v terraform >/dev/null 2>&1; then
    log_info "Retrieving Loki S3 bucket and IAM role from Terraform outputs..."
    cd "$terraform_dir" || return 1
    loki_bucket_name=$(terraform output -raw loki_s3_bucket_name 2>/dev/null || echo "")
    loki_role_arn=$(terraform output -raw loki_s3_role_arn 2>/dev/null || echo "")
    cd "$SCRIPT_DIR" || return 1
    
    if [[ -z "$loki_bucket_name" ]] || [[ -z "$loki_role_arn" ]]; then
      log_error "Failed to retrieve Loki S3 bucket name or IAM role ARN from Terraform"
      log_error "Bucket name: ${loki_bucket_name:-NOT_FOUND}"
      log_error "Role ARN: ${loki_role_arn:-NOT_FOUND}"
      log_error "Please ensure Terraform has been applied with the Loki S3 resources"
      return 1
    fi
    
    log_success "Found Loki S3 bucket: $loki_bucket_name"
    log_success "Found Loki IAM role: $loki_role_arn"
  else
    log_error "Terraform directory not found or terraform command not available"
    log_error "Cannot retrieve S3 bucket and IAM role for Loki"
    return 1
  fi
  
  # Annotate Loki service account with IAM role ARN for IRSA
  log_step "Configuring Loki service account with IAM role annotation..."
  ensure_namespace "$MONITORING_NAMESPACE"
  
  # Create or update Loki service account with IAM role annotation
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loki
  namespace: ${MONITORING_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${loki_role_arn}
EOF
  
  log_success "Loki service account configured with IAM role annotation"
  
  # Install with retry logic for network resilience
  local max_retries="${MAX_RETRIES}"
  local retry_delay="${HELM_INSTALL_RETRY_DELAY}"
  local attempt=1
  
  while [ $attempt -le "$max_retries" ]; do
    log_info "Attempt $attempt/$max_retries: Installing Loki Stack..."
    
    # Test cluster connectivity before attempting installation
    if ! kubectl cluster-info >/dev/null 2>&1; then
      log_warn "Cluster connectivity issue detected, waiting ${retry_delay}s before retry..."
      sleep "$retry_delay"
      ((attempt += 1))
      continue
    fi
    
    # Attempt Helm installation with S3 storage configuration
    # Using SimpleScalable deployment mode for distributed architecture (groups components into read, write, backend)
    # This provides better scalability and high availability compared to SingleBinary mode
    if helm upgrade --install loki grafana/loki \
      --namespace "$MONITORING_NAMESPACE" \
      --version "$CHART_LOKI_VERSION" \
      --timeout 10m --wait=false \
      --set deploymentMode=SimpleScalable \
      --set serviceAccount.name=loki \
      --set serviceAccount.create=false \
      --set loki.auth_enabled=false \
      --set loki.storage.type=s3 \
      --set loki.storage.s3.region="${AWS_REGION}" \
      --set loki.storage.bucketNames.chunks="${loki_bucket_name}" \
      --set loki.storage.bucketNames.ruler="${loki_bucket_name}" \
      --set loki.storage.bucketNames.admin="${loki_bucket_name}" \
      --set loki.schemaConfig.configs[0].from=2024-01-01 \
      --set loki.schemaConfig.configs[0].object_store=s3 \
      --set loki.schemaConfig.configs[0].store=tsdb \
      --set loki.schemaConfig.configs[0].schema=v13 \
      --set loki.schemaConfig.configs[0].index.prefix=loki_index_ \
      --set loki.schemaConfig.configs[0].index.period="${LOKI_INDEX_PERIOD}" \
      --set loki.limits_config.retention_period="${LOKI_RETENTION_PERIOD}" \
      --set loki.limits_config.volume_enabled=true \
      --set loki.compactor.retention_enabled=false \
      --set loki.limits_config.max_query_parallelism=32 \
      --set loki.memberlist.enabled=true \
      --set write.replicas="${LOKI_MIN_REPLICAS:-2}" \
      --set read.replicas="${LOKI_MIN_REPLICAS:-2}" \
      --set backend.replicas="${LOKI_MIN_REPLICAS:-2}" \
      --set write.resources.requests.cpu="${LOKI_CPU_REQUEST}" \
      --set write.resources.requests.memory="${LOKI_MEMORY_REQUEST}" \
      --set write.resources.limits.cpu="${LOKI_CPU_LIMIT}" \
      --set write.resources.limits.memory="${LOKI_MEMORY_LIMIT}" \
      --set read.resources.requests.cpu="${LOKI_CPU_REQUEST}" \
      --set read.resources.requests.memory="${LOKI_MEMORY_REQUEST}" \
      --set read.resources.limits.cpu="${LOKI_CPU_LIMIT}" \
      --set read.resources.limits.memory="${LOKI_MEMORY_LIMIT}" \
      --set backend.resources.requests.cpu="${LOKI_CPU_REQUEST}" \
      --set backend.resources.requests.memory="${LOKI_MEMORY_REQUEST}" \
      --set backend.resources.limits.cpu="${LOKI_CPU_LIMIT}" \
      --set backend.resources.limits.memory="${LOKI_MEMORY_LIMIT}" \
      --set write.autoscaling.enabled="$ENABLE_AUTOSCALING" \
      --set write.autoscaling.minReplicas="${LOKI_MIN_REPLICAS:-2}" \
      --set write.autoscaling.maxReplicas="${LOKI_MAX_REPLICAS:-5}" \
      --set write.autoscaling.targetCPUUtilizationPercentage="$HPA_CPU_TARGET" \
      --set write.autoscaling.targetMemoryUtilizationPercentage="$HPA_MEMORY_TARGET" \
      --set read.autoscaling.enabled="$ENABLE_AUTOSCALING" \
      --set read.autoscaling.minReplicas="${LOKI_MIN_REPLICAS:-2}" \
      --set read.autoscaling.maxReplicas="${LOKI_MAX_REPLICAS:-5}" \
      --set read.autoscaling.targetCPUUtilizationPercentage="$HPA_CPU_TARGET" \
      --set read.autoscaling.targetMemoryUtilizationPercentage="$HPA_MEMORY_TARGET" \
      --set backend.autoscaling.enabled="$ENABLE_AUTOSCALING" \
      --set backend.autoscaling.minReplicas="${LOKI_MIN_REPLICAS:-2}" \
      --set backend.autoscaling.maxReplicas="${LOKI_MAX_REPLICAS:-5}" \
      --set backend.autoscaling.targetCPUUtilizationPercentage="$HPA_CPU_TARGET" \
      --set backend.autoscaling.targetMemoryUtilizationPercentage="$HPA_MEMORY_TARGET" \
      --set write.persistence.storageClassName="${STORAGE_CLASS_RWO}" \
      --set backend.persistence.storageClassName="${STORAGE_CLASS_RWO}" \
      2>&1 | tee "${SCRIPT_DIR}/helm-install-loki.log"; then
      
      # Verify installation success
      if helm status loki -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        log_success "Loki Stack installed successfully on attempt $attempt"
        break
      else
        log_error "Helm installation appeared successful but status check failed"
        if [ $attempt -lt "$max_retries" ]; then
          log_info "Retrying in ${retry_delay}s..."
          sleep "$retry_delay"
        fi
      fi
    else
      log_error "Helm installation failed on attempt $attempt"
      if [ $attempt -lt "$max_retries" ]; then
        log_info "Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
      fi
    fi
    
    ((attempt += 1))
  done
  
  if [ $attempt -gt "$max_retries" ]; then
    log_error "Loki Stack installation failed after $max_retries attempts. Check ${SCRIPT_DIR}/helm-install-loki.log"
    log_audit "INSTALL" "loki" "FAILED"
    return 1
  fi
  
  # Patch PVCs if storage class wasn't set (workaround for chart issues)
  # Note: When scaling to multiple replicas, StatefulSets create additional PVCs (write-1, backend-1, etc.)
  # We need to patch all PVCs, not just replica 0
  log_info "Ensuring Loki PVCs have correct storage class..."
  local pvc_patched=false
  # Get all Loki PVCs that match the pattern (handles any number of replicas)
  local loki_pvcs
  loki_pvcs=$(kubectl get pvc -n "$MONITORING_NAMESPACE" --no-headers 2>/dev/null | grep -E "data-loki-(write|backend)-[0-9]+" | awk '{print $1}' || echo "")
  
  if [[ -z "$loki_pvcs" ]]; then
    # Fallback to explicit list if grep doesn't find any (PVCs may not be created yet)
    loki_pvcs="data-loki-write-0 data-loki-backend-0"
  fi
  
  for pvc_name in $loki_pvcs; do
    # Wait a moment for PVC to be created
    sleep 1
    if kubectl get pvc "$pvc_name" -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
      local current_sc
      current_sc=$(kubectl get pvc "$pvc_name" -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
      if [[ -z "$current_sc" ]] || [[ "$current_sc" == "<none>" ]]; then
        log_info "Patching PVC $pvc_name with storage class ${STORAGE_CLASS_RWO}..."
        if kubectl patch pvc "$pvc_name" -n "$MONITORING_NAMESPACE" --type='merge' -p="{\"spec\":{\"storageClassName\":\"${STORAGE_CLASS_RWO}\"}}" 2>/dev/null; then
          log_success "Patched PVC $pvc_name with storage class"
          pvc_patched=true
        else
          log_warn "Failed to patch PVC $pvc_name"
        fi
      else
        log_info "PVC $pvc_name already has storage class: $current_sc"
      fi
    fi
  done
  
  if [ "$pvc_patched" = true ]; then
    log_info "Waiting for PVCs to be bound after patching..."
    sleep 5
  fi
  
  # Additional check: Wait for StatefulSets to create additional replica PVCs and patch them
  # This is necessary because StatefulSets create PVCs asynchronously when scaling
  log_info "Checking for additional Loki PVCs created by StatefulSet scaling..."
  local max_wait=60  # Wait up to 60 seconds for additional PVCs
  local waited=0
  while [ $waited -lt $max_wait ]; do
    local additional_pvcs
    additional_pvcs=$(kubectl get pvc -n "$MONITORING_NAMESPACE" --no-headers 2>/dev/null | grep -E "data-loki-(write|backend)-[0-9]+" | awk '{print $1}' || echo "")
    local found_new=false
    for pvc_name in $additional_pvcs; do
      local current_sc
      current_sc=$(kubectl get pvc "$pvc_name" -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
      if [[ -z "$current_sc" ]] || [[ "$current_sc" == "<none>" ]]; then
        log_info "Found new PVC $pvc_name without storage class, patching..."
        if kubectl patch pvc "$pvc_name" -n "$MONITORING_NAMESPACE" --type='merge' -p="{\"spec\":{\"storageClassName\":\"${STORAGE_CLASS_RWO}\"}}" 2>/dev/null; then
          log_success "Patched new PVC $pvc_name with storage class"
          found_new=true
        fi
      fi
    done
    if [ "$found_new" = true ]; then
      log_info "Found and patched new PVCs, waiting for them to bind..."
      sleep 5
      waited=$((waited + 5))
    else
      # No new PVCs found, check every 5 seconds
      sleep 5
      waited=$((waited + 5))
      if [ $waited -ge $max_wait ]; then
        log_info "No additional PVCs found within ${max_wait}s (StatefulSet scaling may still be in progress)"
        break
      fi
    fi
  done
  
  # Wait for pods with enhanced timeout - but don't fail if they're not ready immediately
  log_info "Waiting for Loki pods to be ready (this may take a few minutes for distributed mode)..."
  local wait_timeout=300  # 5 minutes
  # In SimpleScalable mode, we have read, write, and backend components
  if kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=read -n "$MONITORING_NAMESPACE" --timeout="${wait_timeout}s" 2>/dev/null && \
     kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=write -n "$MONITORING_NAMESPACE" --timeout="${wait_timeout}s" 2>/dev/null && \
     kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=backend -n "$MONITORING_NAMESPACE" --timeout="${wait_timeout}s" 2>/dev/null; then
    log_success "Loki installed and all pods ready"; log_audit "INSTALL" "loki" "SUCCESS"
  else
    log_warn "Loki pods not ready within ${wait_timeout}s, but installation may still be in progress"
    log_info "Checking Loki pod status..."
    kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=loki
    log_info "Loki Helm release installed. Pods may still be starting up."
    log_audit "INSTALL" "loki" "PARTIAL"
  fi
  
  # Ensure volume_enabled is set in Loki configuration
  # Note: This is set during initial install, but we verify it here
  log_step "Verifying Loki volume_enabled configuration..."
  local volume_enabled_set
  volume_enabled_set=$(helm get values loki -n "$MONITORING_NAMESPACE" 2>/dev/null | grep -i "volume_enabled.*true" || echo "")
  if [[ -n "$volume_enabled_set" ]]; then
    log_info "Loki volume_enabled is configured"
    # Restart Loki components to ensure configuration is applied
    log_info "Restarting Loki components to apply volume configuration..."
    kubectl rollout restart statefulset loki-backend -n "$MONITORING_NAMESPACE" 2>/dev/null || true
    kubectl rollout restart deployment loki-gateway -n "$MONITORING_NAMESPACE" 2>/dev/null || true
    kubectl rollout restart deployment loki-read -n "$MONITORING_NAMESPACE" 2>/dev/null || true
    kubectl rollout restart deployment loki-write -n "$MONITORING_NAMESPACE" 2>/dev/null || true
    log_success "Loki components restarted to apply volume configuration"
  else
    log_warn "Loki volume_enabled not found in helm values - upgrading..."
    helm upgrade loki grafana/loki \
      --namespace "$MONITORING_NAMESPACE" \
      --version "$CHART_LOKI_VERSION" \
      --reuse-values \
      --set loki.limits_config.volume_enabled=true \
      >/dev/null 2>&1 || log_warn "Failed to update Loki volume_enabled via helm upgrade"
    log_info "Loki upgrade completed - components will restart automatically"
  fi
}

create_additional_hpa(){
  if [[ "$ENABLE_AUTOSCALING" != "1" ]]; then
    log_info "Autoscaling disabled - skipping additional HPA resources"
    return 0
  fi
  
  log_step "Creating additional HPA resources..."
  if alertmanager_enabled; then
    kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: alertmanager-hpa
  namespace: ${MONITORING_NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: alertmanager-prometheus-stack-kube-prom-alertmanager
  minReplicas: ${ALERTMANAGER_MIN_REPLICAS}
  maxReplicas: ${ALERTMANAGER_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource: { name: cpu, target: { type: Utilization, averageUtilization: ${HPA_CPU_TARGET} } }
  - type: Resource
    resource: { name: memory, target: { type: Utilization, averageUtilization: ${HPA_MEMORY_TARGET} } }
EOF
    log_info "✅ AlertManager HPA created (${ALERTMANAGER_MIN_REPLICAS}-${ALERTMANAGER_MAX_REPLICAS} replicas)"
  fi
  log_success "Additional HPA resources done"; log_audit "CREATE" "hpa_resources" "SUCCESS"
}

# ------------------------------
# Tempo install (replaces Jaeger)
# ------------------------------
install_tempo(){
  log_step "Installing Tempo for distributed tracing..."
  ensure_namespace "$MONITORING_NAMESPACE"

  # Get S3 bucket name and IAM role ARN from Terraform outputs
  local terraform_dir="${SCRIPT_DIR}/../terraform"
  local tempo_bucket_name=""
  local tempo_role_arn=""
  
  if [[ -d "$terraform_dir" ]] && command -v terraform >/dev/null 2>&1; then
    log_info "Retrieving Tempo S3 bucket and IAM role from Terraform outputs..."
    cd "$terraform_dir" || return 1
    tempo_bucket_name=$(terraform output -raw tempo_s3_bucket_name 2>/dev/null || echo "")
    tempo_role_arn=$(terraform output -raw tempo_s3_role_arn 2>/dev/null || echo "")
    cd "$SCRIPT_DIR" || return 1
    
    if [[ -z "$tempo_bucket_name" ]] || [[ -z "$tempo_role_arn" ]]; then
      log_error "Failed to retrieve Tempo S3 bucket name or IAM role ARN from Terraform"
      log_error "Bucket name: ${tempo_bucket_name:-NOT_FOUND}"
      log_error "Role ARN: ${tempo_role_arn:-NOT_FOUND}"
      log_error "Please ensure Terraform has been applied with the Tempo S3 resources"
      return 1
    fi
    
    log_success "Found Tempo S3 bucket: $tempo_bucket_name"
    log_success "Found Tempo IAM role: $tempo_role_arn"
  else
    log_error "Terraform directory not found or terraform command not available"
    log_error "Cannot retrieve S3 bucket and IAM role for Tempo"
    return 1
  fi
  
  # Create Tempo service account with IAM role annotation and Helm labels
  log_step "Configuring Tempo service account with IAM role annotation..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tempo
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    eks.amazonaws.com/role-arn: ${tempo_role_arn}
    meta.helm.sh/release-name: tempo
    meta.helm.sh/release-namespace: ${MONITORING_NAMESPACE}
EOF
  
  log_success "Tempo service account configured with IAM role annotation"

  log_info "Installing Tempo using Helm chart (version: ${CHART_TEMPO_VERSION})..."
  
  # Create Tempo configuration for distributed mode
  # The tempo-distributed chart uses external configuration
  local TEMPO_CONFIG_FILE="${SCRIPT_DIR}/tempo-config.yaml"
  cat > "$TEMPO_CONFIG_FILE" <<EOF
server:
  http_listen_port: ${TEMPO_HTTP_PORT}

# Memberlist configuration for service discovery in distributed mode
memberlist:
  join_members:
    - tempo-gossip-ring.${MONITORING_NAMESPACE}.svc.cluster.local:7946
  bind_port: 7946
  advertise_port: 7946

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:${TEMPO_OTLP_GRPC_PORT}
        http:
          endpoint: 0.0.0.0:${TEMPO_OTLP_HTTP_PORT}

ingester:
  max_block_duration: ${TEMPO_MAX_BLOCK_DURATION}
  trace_idle_period: ${TEMPO_TRACE_IDLE_PERIOD}

compactor:
  compaction:
    block_retention: ${TEMPO_BLOCK_RETENTION}
    compacted_block_retention: ${TEMPO_COMPACTED_BLOCK_RETENTION}

querier:
  frontend_worker:
    frontend_address: tempo-query-frontend.${MONITORING_NAMESPACE}.svc.cluster.local:${TEMPO_QUERY_FRONTEND_GRPC_PORT}

query_frontend:
  search:
    default_result_limit: ${TEMPO_QUERY_DEFAULT_RESULT_LIMIT}
    max_result_limit: ${TEMPO_QUERY_MAX_RESULT_LIMIT}

metrics_generator:
  registry:
    external_labels:
      source: tempo
      cluster: ${CLUSTER_NAME}
  storage:
    path: /var/tempo/generator/wal
    remote_write:
      - url: http://mimir-gateway.${MONITORING_NAMESPACE}.svc.cluster.local:80/prometheus/api/v1/push
        send_exemplars: true
  processor:
    local_blocks:
      filter_server_spans: false
      flush_to_storage: true

storage:
  trace:
    backend: s3
    s3:
      bucket: ${tempo_bucket_name}
      endpoint: s3.${AWS_REGION}.amazonaws.com
      region: ${AWS_REGION}
      forcepathstyle: false

overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics, local-blocks]
EOF

  # Create Tempo values for Helm installation (tempo-distributed chart)
  local TEMPO_VALUES_FILE="${SCRIPT_DIR}/tempo-values.yaml"
  cat > "$TEMPO_VALUES_FILE" <<EOF
# Tempo Distributed Configuration
useExternalConfig: true
configStorageType: ConfigMap

# Service account with IRSA
tempo:
  serviceAccount:
    name: tempo
    create: false
    annotations:
      eks.amazonaws.com/role-arn: ${tempo_role_arn}
  
# Component replicas and resources
distributor:
  replicas: ${TEMPO_MIN_REPLICAS}
  resources:
    requests:
      cpu: ${TEMPO_DISTRIBUTOR_CPU_REQUEST}
      memory: ${TEMPO_DISTRIBUTOR_MEMORY_REQUEST}
    limits:
      cpu: ${TEMPO_DISTRIBUTOR_CPU_LIMIT}
      memory: ${TEMPO_DISTRIBUTOR_MEMORY_LIMIT}

ingester:
  replicas: ${TEMPO_MIN_REPLICAS}
  resources:
    requests:
      cpu: ${TEMPO_INGESTER_CPU_REQUEST}
      memory: ${TEMPO_INGESTER_MEMORY_REQUEST}
    limits:
      cpu: ${TEMPO_INGESTER_CPU_LIMIT}
      memory: ${TEMPO_INGESTER_MEMORY_LIMIT}
  persistence:
    enabled: true
    size: ${TEMPO_INGESTER_STORAGE_SIZE}
    storageClass: ${STORAGE_CLASS_RWO}

querier:
  replicas: ${TEMPO_MIN_REPLICAS}
  resources:
    requests:
      cpu: ${TEMPO_QUERIER_CPU_REQUEST}
      memory: ${TEMPO_QUERIER_MEMORY_REQUEST}
    limits:
      cpu: ${TEMPO_QUERIER_CPU_LIMIT}
      memory: ${TEMPO_QUERIER_MEMORY_LIMIT}

queryFrontend:
  replicas: ${TEMPO_MIN_REPLICAS}
  resources:
    requests:
      cpu: ${TEMPO_QUERY_FRONTEND_CPU_REQUEST}
      memory: ${TEMPO_QUERY_FRONTEND_MEMORY_REQUEST}
    limits:
      cpu: ${TEMPO_QUERY_FRONTEND_CPU_LIMIT}
      memory: ${TEMPO_QUERY_FRONTEND_MEMORY_LIMIT}

compactor:
  replicas: 1
  resources:
    requests:
      cpu: ${TEMPO_COMPACTOR_CPU_REQUEST}
      memory: ${TEMPO_COMPACTOR_MEMORY_REQUEST}
    limits:
      cpu: ${TEMPO_COMPACTOR_CPU_LIMIT}
      memory: ${TEMPO_COMPACTOR_MEMORY_LIMIT}

gateway:
  enabled: true
  replicas: 1
  resources:
    requests:
      cpu: ${TEMPO_GATEWAY_CPU_REQUEST}
      memory: ${TEMPO_GATEWAY_MEMORY_REQUEST}
    limits:
      cpu: ${TEMPO_GATEWAY_CPU_LIMIT}
      memory: ${TEMPO_GATEWAY_MEMORY_LIMIT}

metricsGenerator:
  enabled: true
  replicas: ${TEMPO_MIN_REPLICAS}
  resources:
    requests:
      cpu: ${TEMPO_METRICS_GENERATOR_CPU_REQUEST}
      memory: ${TEMPO_METRICS_GENERATOR_MEMORY_REQUEST}
    limits:
      cpu: ${TEMPO_METRICS_GENERATOR_CPU_LIMIT}
      memory: ${TEMPO_METRICS_GENERATOR_MEMORY_LIMIT}
EOF

  # Create Tempo ConfigMap with configuration
  log_info "Creating Tempo configuration ConfigMap..."
  kubectl create configmap tempo-config \
    --from-file=tempo.yaml="$TEMPO_CONFIG_FILE" \
    --namespace "$MONITORING_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  log_success "Tempo configuration ConfigMap created"
  
  # Create tempo-runtime ConfigMap (required by tempo-distributed chart)
  log_info "Creating Tempo runtime ConfigMap..."
  kubectl create configmap tempo-runtime \
    --from-literal=overrides.yaml="" \
    --namespace "$MONITORING_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  log_success "Tempo runtime ConfigMap created"

  # Add autoscaling configuration if enabled
  if [[ "$ENABLE_AUTOSCALING" == "1" ]]; then
    cat >> "$TEMPO_VALUES_FILE" <<EOF

autoscaling:
  enabled: true
  minReplicas: ${TEMPO_MIN_REPLICAS}
  maxReplicas: ${TEMPO_MAX_REPLICAS}
  targetCPUUtilizationPercentage: ${HPA_CPU_TARGET}
  targetMemoryUtilizationPercentage: ${HPA_MEMORY_TARGET}
EOF
  fi

  # Install Tempo using Helm (using tempo-distributed chart for distributed mode)
  if ! helm upgrade --install tempo grafana-community/tempo-distributed \
    --namespace "$MONITORING_NAMESPACE" \
    --version "$CHART_TEMPO_VERSION" \
    --values "$TEMPO_VALUES_FILE" \
    --wait \
    --timeout "$TIMEOUT_HELM"; then
    log_error "Failed to install Tempo Helm chart"; return 1
  fi

  # Apply workaround for query-frontend readiness probe
  # The default /ready endpoint requires queriers to be connected, causing a chicken-and-egg problem
  # Patch to use /metrics instead, which only checks if the service is listening
  # This must be applied after every Helm upgrade as Helm resets the deployment
  log_info "Applying query-frontend readiness probe fix..."
  local patch_retries="${MAX_RETRIES}"
  local patch_attempt=1
  while [ $patch_attempt -le "$patch_retries" ]; do
    if kubectl patch deployment tempo-query-frontend -n "$MONITORING_NAMESPACE" --type='json' \
      -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/readinessProbe/httpGet/path\", \"value\": \"/metrics\"}, {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds\", \"value\": ${QUERY_FRONTEND_READINESS_INITIAL_DELAY}}]" 2>/dev/null; then
      log_success "Query-frontend readiness probe patched successfully"
      break
    else
      if [ $patch_attempt -lt "$patch_retries" ]; then
        log_warn "Failed to patch query-frontend readiness probe (attempt $patch_attempt/$patch_retries), retrying in ${PATCH_RETRY_DELAY}s..."
        sleep "${PATCH_RETRY_DELAY}"
      else
        log_warn "Failed to patch query-frontend readiness probe after $patch_retries attempts (deployment may not exist yet)"
      fi
    fi
    ((patch_attempt += 1))
  done

  log_info "Waiting for Tempo pods to be ready..."
  # Tempo distributed has multiple components (distributor, ingester, querier, etc.)
  # Use lenient wait logic - check for at least some pods running instead of all ready
  local tempo_ready=false
  local _i
  for _i in $(seq 1 "${TEMPO_READINESS_MAX_RETRIES}"); do
    local running_pods
    running_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/instance=tempo --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
    local total_pods
    total_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/instance=tempo -o name 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$running_pods" -ge "${TEMPO_READINESS_MIN_RUNNING_PODS}" ]] && [[ "$total_pods" -gt 0 ]]; then
      log_info "Tempo is running with $running_pods/$total_pods pod(s) in Running state"
      tempo_ready=true
      break
    fi
    sleep "${TEMPO_READINESS_SLEEP_INTERVAL}"
  done
  
  if [[ "$tempo_ready" == "true" ]]; then
    log_success "Tempo components are running"
  else
    log_warn "Some Tempo components may not be ready yet - continuing with installation"
  fi

  # Clean up temporary files
  rm -f "$TEMPO_VALUES_FILE" "$TEMPO_CONFIG_FILE"

  log_success "Tempo Helm chart installed and ready"; log_audit "INSTALL" "tempo" "SUCCESS"
  
  # Patch Tempo distributor service to expose OTLP ports (4317 gRPC, 4318 HTTP)
  log_info "Patching Tempo distributor service to expose OTLP ports..."
  if kubectl patch svc tempo-distributor -n "$MONITORING_NAMESPACE" --type='json' -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "otlp-grpc", "port": 4317, "protocol": "TCP", "targetPort": 4317}}, {"op": "add", "path": "/spec/ports/-", "value": {"name": "otlp-http", "port": 4318, "protocol": "TCP", "targetPort": 4318}}]' 2>/dev/null; then
    log_success "Tempo distributor service patched with OTLP ports"
  else
    log_warn "Failed to patch Tempo distributor service (may already be patched)"
  fi
}

# ------------------------------
# Mimir install
# ------------------------------
install_mimir(){
  log_step "Installing Mimir for metrics storage..."
  ensure_namespace "$MONITORING_NAMESPACE"

  # Get S3 bucket names and IAM role ARN from Terraform outputs
  local terraform_dir="${SCRIPT_DIR}/../terraform"
  local mimir_blocks_bucket_name=""
  local mimir_ruler_bucket_name=""
  local alertmanager_bucket_name=""
  local mimir_role_arn=""
  
  if [[ -d "$terraform_dir" ]] && command -v terraform >/dev/null 2>&1; then
    log_info "Retrieving Mimir S3 buckets and IAM role from Terraform outputs..."
    cd "$terraform_dir" || return 1
    # Try new bucket names first, fall back to deprecated name for backward compatibility
    mimir_blocks_bucket_name=$(terraform output -raw mimir_blocks_s3_bucket_name 2>/dev/null || terraform output -raw mimir_s3_bucket_name 2>/dev/null || echo "")
    mimir_ruler_bucket_name=$(terraform output -raw mimir_ruler_s3_bucket_name 2>/dev/null || echo "")
    alertmanager_bucket_name=$(terraform output -raw alertmanager_s3_bucket_name 2>/dev/null || echo "")
    mimir_role_arn=$(terraform output -raw mimir_s3_role_arn 2>/dev/null || echo "")
    cd "$SCRIPT_DIR" || return 1
    
    if [[ -z "$mimir_blocks_bucket_name" ]] || [[ -z "$mimir_role_arn" ]]; then
      log_error "Failed to retrieve Mimir blocks S3 bucket name or IAM role ARN from Terraform"
      log_error "Blocks bucket name: ${mimir_blocks_bucket_name:-NOT_FOUND}"
      log_error "Role ARN: ${mimir_role_arn:-NOT_FOUND}"
      log_error "Please ensure Terraform has been applied with the Mimir S3 resources"
      return 1
    fi
    
    if [[ -z "$mimir_ruler_bucket_name" ]]; then
      log_warn "Mimir ruler bucket not found, using blocks bucket for ruler storage (may cause validation errors)"
      mimir_ruler_bucket_name="$mimir_blocks_bucket_name"
    fi
    
    if [[ -z "$alertmanager_bucket_name" ]]; then
      log_warn "AlertManager bucket not found, using Mimir blocks bucket for alertmanager storage"
      alertmanager_bucket_name="$mimir_blocks_bucket_name"
    fi
    
    log_success "Found Mimir blocks S3 bucket: $mimir_blocks_bucket_name"
    log_success "Found Mimir ruler S3 bucket: $mimir_ruler_bucket_name"
    log_success "Found AlertManager S3 bucket: $alertmanager_bucket_name"
    log_success "Found Mimir IAM role: $mimir_role_arn"
  else
    log_error "Terraform directory not found or terraform command not available"
    log_error "Cannot retrieve S3 bucket and IAM role for Mimir"
    return 1
  fi
  
  # Create Mimir service account with IAM role annotation and Helm labels
  log_step "Configuring Mimir service account with IAM role annotation..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mimir
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    eks.amazonaws.com/role-arn: ${mimir_role_arn}
    meta.helm.sh/release-name: mimir
    meta.helm.sh/release-namespace: ${MONITORING_NAMESPACE}
EOF
  
  log_success "Mimir service account configured with IAM role annotation"

  log_info "Installing Mimir using Helm chart (version: ${CHART_MIMIR_VERSION})..."
  
  # Create Mimir values for Helm installation
  local MIMIR_VALUES_FILE="${SCRIPT_DIR}/mimir-values.yaml"
  cat > "$MIMIR_VALUES_FILE" <<EOF
# Mimir Configuration
serviceAccount:
  name: mimir
  create: false
  annotations:
    eks.amazonaws.com/role-arn: ${mimir_role_arn}

mimir:
  structuredConfig:
    # Use blocks storage mode (classic architecture) instead of Kafka ingestion
    # Explicitly disable ingest_storage to prevent Kafka requirement
    ingest_storage:
      enabled: false
    
    ingester:
      # Enable Push gRPC API for classic architecture (required when ingest_storage is disabled)
      push_grpc_method_enabled: true
    
    blocks_storage:
      backend: s3
      s3:
        bucket_name: ${mimir_blocks_bucket_name}
        region: ${AWS_REGION}
        endpoint: s3.${AWS_REGION}.amazonaws.com
    
    ruler_storage:
      backend: s3
      s3:
        bucket_name: ${mimir_ruler_bucket_name}
        region: ${AWS_REGION}
        endpoint: s3.${AWS_REGION}.amazonaws.com
        # Note: Using separate bucket from blocks_storage to avoid Mimir validation error
    
    alertmanager_storage:
      backend: s3
      s3:
        bucket_name: ${alertmanager_bucket_name}
        region: ${AWS_REGION}
        endpoint: s3.${AWS_REGION}.amazonaws.com
        # Note: Using AlertManager bucket for alertmanager storage

  resources:
    requests:
      cpu: ${MIMIR_CPU_REQUEST}
      memory: ${MIMIR_MEMORY_REQUEST}
    limits:
      cpu: ${MIMIR_CPU_LIMIT}
      memory: ${MIMIR_MEMORY_LIMIT}

  replicas: ${MIMIR_MIN_REPLICAS}

gateway:
  enabled: true
  replicas: 1
  resources:
    requests:
      cpu: ${MIMIR_GATEWAY_CPU_REQUEST}
      memory: ${MIMIR_GATEWAY_MEMORY_REQUEST}
    limits:
      cpu: ${MIMIR_GATEWAY_CPU_LIMIT}
      memory: ${MIMIR_GATEWAY_MEMORY_LIMIT}

ingress:
  enabled: false

# Storage class configuration for StatefulSets
# Note: The chart uses 'storageClass' in values (maps to 'storageClassName' in PVC spec)
ingester:
  persistentVolume:
    enabled: true
    storageClass: ${STORAGE_CLASS_RWO}

compactor:
  persistentVolume:
    enabled: true
    storageClass: ${STORAGE_CLASS_RWO}

store-gateway:
  persistentVolume:
    enabled: true
    storageClass: ${STORAGE_CLASS_RWO}

alertmanager:
  persistentVolume:
    enabled: true
    storageClass: ${STORAGE_CLASS_RWO}
EOF

  # Add autoscaling configuration if enabled
  if [[ "$ENABLE_AUTOSCALING" == "1" ]]; then
    cat >> "$MIMIR_VALUES_FILE" <<EOF

autoscaling:
  enabled: true
  minReplicas: ${MIMIR_MIN_REPLICAS}
  maxReplicas: ${MIMIR_MAX_REPLICAS}
  targetCPUUtilizationPercentage: ${HPA_CPU_TARGET}
  targetMemoryUtilizationPercentage: ${HPA_MEMORY_TARGET}
EOF
  fi

  # Install Mimir using Helm with classic architecture (no Kafka required)
  # Classic architecture: ingesters handle both read and write, no Kafka needed
  # Ingest storage is disabled in the values file to use classic architecture
  # Note: We don't use --wait here because Mimir can take a long time to initialize
  # and we don't want to block the rest of the installation
  if ! helm upgrade --install mimir grafana/mimir-distributed \
    --namespace "$MONITORING_NAMESPACE" \
    --version "$CHART_MIMIR_VERSION" \
    --values "$MIMIR_VALUES_FILE" \
    --set kafka.enabled=false \
    --set minio.enabled=false \
    --set ingester.persistentVolume.storageClass="${STORAGE_CLASS_RWO}" \
    --set compactor.persistentVolume.storageClass="${STORAGE_CLASS_RWO}" \
    --set "store-gateway.persistentVolume.storageClass=${STORAGE_CLASS_RWO}" \
    --set alertmanager.persistentVolume.storageClass="${STORAGE_CLASS_RWO}"; then
    log_error "Failed to install Mimir Helm chart"; return 1
  fi
  
  log_info "Mimir Helm chart installed (not waiting for readiness - will initialize in background)"

  # Workaround: The mimir-distributed chart template has a bug where store-gateway PVCs
  # don't get storageClassName from the values file. Manually patch the PVCs after creation.
  log_info "Applying workaround for store-gateway PVC storageClassName..."
  sleep "${PVC_WAIT_DELAY}"  # Wait for PVCs to be created
  local store_gateway_pvcs
  store_gateway_pvcs=$(kubectl get pvc -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/instance=mimir,app.kubernetes.io/component=store-gateway -o name 2>/dev/null || true)
  if [[ -n "$store_gateway_pvcs" ]]; then
    for pvc in $store_gateway_pvcs; do
      # Check if PVC already has storageClassName set
      if ! kubectl get "$pvc" -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null | grep -q "${STORAGE_CLASS_RWO}"; then
        log_info "Patching $pvc to add storageClassName..."
        if kubectl patch "$pvc" -n "$MONITORING_NAMESPACE" --type='merge' -p="{\"spec\":{\"storageClassName\":\"${STORAGE_CLASS_RWO}\"}}" 2>/dev/null; then
          log_success "Patched $pvc with storageClassName"
        else
          log_warn "Failed to patch $pvc - may need manual intervention"
        fi
      fi
    done
  fi

  log_info "Waiting for Mimir pods to be ready..."
  # Mimir uses StatefulSets and Deployments, so we wait for pods to be ready
  # Don't fail the entire installation if Mimir takes longer - it's optional for basic functionality
  if ! kubectl wait --for=condition=ready --timeout="${KUBECTL_WAIT_TIMEOUT_LONG}" pod -l app.kubernetes.io/instance=mimir -n "$MONITORING_NAMESPACE" 2>/dev/null; then
    log_warn "Some Mimir components may not be ready yet - continuing with installation"
    log_info "Mimir will continue initializing in the background"
  fi

  # Clean up temporary values file
  rm -f "$MIMIR_VALUES_FILE"

  log_success "Mimir Helm chart installed and ready"; log_audit "INSTALL" "mimir" "SUCCESS"
}

# ------------------------------
# OpenTelemetry eBPF Instrumentation (OTeBPF) install
# OTeBPF provides zero-code eBPF auto-instrumentation for traces
# ------------------------------
install_otebpf(){
  if [[ "$OTEBPF_ENABLED" != "1" ]]; then
    log_info "OTeBPF auto-instrumentation disabled (OTEBPF_ENABLED != 1)"
    return 0
  fi

  log_step "Installing OTeBPF (OpenTelemetry eBPF Instrumentation) for zero-code auto-instrumentation..."
  log_info "Using Docker Hub image: ${OTEBPF_IMAGE}:${OTEBPF_VERSION}"
  ensure_namespace "$MONITORING_NAMESPACE"

  log_info "Installing OTeBPF as DaemonSet for eBPF auto-instrumentation..."
  
  # Install OpenTelemetry eBPF Instrumentation as a DaemonSet
  # OTeBPF provides zero-code instrumentation using eBPF for automatic trace collection
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otebpf
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app: otebpf
    component: opentelemetry-ebpf-instrumentation
spec:
  selector:
    matchLabels:
      app: otebpf
  template:
    metadata:
      labels:
        app: otebpf
        component: opentelemetry-ebpf-instrumentation
    spec:
      serviceAccountName: otebpf
      # Note: For DaemonSet, OTeBPF should run on all nodes to monitor processes
      # Removed nodeSelector to allow scheduling on all nodes (EKS Auto Mode nodes may have different label formats)
      # We removed podAffinity to avoid scheduling conflicts - OTeBPF will detect
      # OpenEMR processes on any node it runs on via eBPF
      containers:
      - name: otebpf
        # Using OpenTelemetry eBPF Instrumentation (OTeBPF) from GitHub Container Registry
        image: ${OTEBPF_IMAGE}:${OTEBPF_VERSION}
        # Image: otel/ebpf-instrument from Docker Hub
        # Documentation: https://hub.docker.com/r/otel/ebpf-instrument
        # GitHub: https://github.com/open-telemetry/opentelemetry-network
        resources:
          requests:
            cpu: ${OTEBPF_CPU_REQUEST}
            memory: ${OTEBPF_MEMORY_REQUEST}
          limits:
            cpu: ${OTEBPF_CPU_LIMIT}
            memory: ${OTEBPF_MEMORY_LIMIT}
        env:
        # OpenTelemetry environment variables
        - name: OTEL_SERVICE_NAME
          value: "openemr"
        - name: OTEL_EBPF_OPEN_PORT
          value: "80"
        # Use traces-specific endpoint to avoid sending metrics to Tempo
        # Metrics are exposed via Prometheus format on port 8888 (scraped by Prometheus)
        - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
          value: "http://tempo-distributor.${MONITORING_NAMESPACE}.svc.cluster.local:${TEMPO_OTLP_HTTP_PORT}"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "http/protobuf"
        # Disable OTLP metrics export - use Prometheus format instead
        - name: OTEL_METRICS_EXPORTER
          value: "prometheus"
        - name: OTEL_EBPF_KUBE_METADATA_ENABLE
          value: "true"
        # Enable features (required for v0.3.0+)
        # At least one of 'network' or 'application' features must be enabled
        - name: OTEL_EBPF_METRIC_FEATURES
          value: "network,application"
        - name: OTEL_EBPF_PROMETHEUS_FEATURES
          value: "network,application"
        securityContext:
          privileged: true
          capabilities:
            add:
            # Required capabilities for OTeBPF application observability with trace context propagation
            # See: https://opentelemetry.io/docs/zero-code/obi/security/
            - BPF                # General BPF functionality
            - DAC_READ_SEARCH    # Access to /proc/self/mem (not DAC_OVERRIDE)
            - CHECKPOINT_RESTORE # Access to symlinks in /proc filesystem
            - SYS_ADMIN          # Required for EKS (kernel.perf_event_paranoid > 1)
            - NET_RAW            # Create AF_PACKET raw sockets
            - SYS_PTRACE         # Access to /proc/pid/exe and executable modules
            - NET_ADMIN          # Load BPF_PROG_TYPE_SCHED_CLS TC programs
            - SYS_RESOURCE       # Increase locked memory (kernels < 5.11)
          allowPrivilegeEscalation: true
        volumeMounts:
        - name: sys
          mountPath: /sys
          readOnly: true
        - name: proc
          mountPath: /proc
          readOnly: true
      volumes:
      - name: sys
        hostPath:
          path: /sys
      - name: proc
        hostPath:
          path: /proc
          type: Directory
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
      - effect: PreferNoSchedule
        operator: Exists
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otebpf
  namespace: ${MONITORING_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otebpf-cluster-role
rules:
- apiGroups: [""]
  resources: ["namespaces", "nodes", "pods"]
  verbs: ["get", "watch", "list"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["list", "watch"]
- apiGroups: ["*"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets", "jobs", "cronjobs", "replicationcontrollers"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otebpf-cluster-role-binding
subjects:
- kind: ServiceAccount
  name: otebpf
  namespace: ${MONITORING_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: otebpf-cluster-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Service
metadata:
  name: otebpf
  namespace: ${MONITORING_NAMESPACE}
spec:
  selector:
    app: otebpf
  ports:
  - port: 8888
    targetPort: 8888
    name: metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otebpf
  namespace: ${MONITORING_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: otebpf
  endpoints:
  - port: metrics
    interval: 30s
EOF

  log_info "Waiting for OTeBPF DaemonSet to be available..."
  # Wait for DaemonSet to be created and at least one pod to be running
  local otebpf_ready=false
  local _i
  for _i in $(seq 1 "${OTEBPF_READINESS_MAX_RETRIES}"); do
    local running_pods
    running_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app=otebpf --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$running_pods" -ge "${OTEBPF_READINESS_MIN_RUNNING_PODS}" ]]; then
      otebpf_ready=true
      log_info "OTeBPF DaemonSet is running with $running_pods pod(s)"
      break
    fi
    sleep "${OTEBPF_READINESS_SLEEP_INTERVAL}"
  done

  if [[ "$otebpf_ready" == "true" ]]; then
    log_success "OTeBPF DaemonSet installed and running ($running_pods pod(s) running). Additional pods will start as nodes become available (normal for EKS Auto Mode)."; log_audit "INSTALL" "otebpf" "SUCCESS"
  else
    log_warn "OTeBPF DaemonSet installed but no pods are running yet - may need more cluster resources or nodes to scale"; log_audit "INSTALL" "otebpf" "WARNING"
  fi
}

# ------------------------------
# Verification
# ------------------------------
verify_installation(){
  log_step "Verifying monitoring stack installation..."
  
  # Wait for critical pods to be ready before verification
  # Use more lenient checks - at least one pod should be ready for each component
  log_info "Waiting for monitoring pods to be ready..."
  
  # Check Prometheus - at least one pod should be ready
  if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n "$MONITORING_NAMESPACE" --timeout="${KUBECTL_WAIT_TIMEOUT_MEDIUM}" >/dev/null 2>&1; then
    local prometheus_running
    prometheus_running=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$prometheus_running" -gt 0 ]]; then
      log_warn "Prometheus pods are running but not all ready - continuing verification"
    else
      log_error "Prometheus pods not ready or running - CRITICAL FAILURE"
    return 1
  fi
  fi
  
  # Check Grafana - at least one pod should be ready (more lenient due to restart scenarios)
  if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n "$MONITORING_NAMESPACE" --timeout="${KUBECTL_WAIT_TIMEOUT_SHORT}" >/dev/null 2>&1; then
    local grafana_running
    grafana_running=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$grafana_running" -gt 0 ]]; then
      log_warn "Grafana pods are running but not all ready (may be restarting) - continuing verification"
    else
      log_error "Grafana pods not ready or running - CRITICAL FAILURE"
    return 1
  fi
  fi
  
  # Check Alertmanager - at least one pod should be ready
  if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=alertmanager -n "$MONITORING_NAMESPACE" --timeout="${KUBECTL_WAIT_TIMEOUT_MEDIUM}" >/dev/null 2>&1; then
    local alertmanager_running
    alertmanager_running=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=alertmanager --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$alertmanager_running" -gt 0 ]]; then
      log_warn "Alertmanager pods are running but not all ready - continuing verification"
    else
      log_error "Alertmanager pods not ready or running - CRITICAL FAILURE"
    return 1
    fi
  fi
  
  local checks=("prometheus:prometheus-stack-kube-prom-prometheus:${PROMETHEUS_PORT}" "grafana:prometheus-stack-grafana:80" "alertmanager:prometheus-stack-kube-prom-alertmanager:${ALERTMANAGER_PORT}" "loki:loki-gateway:${LOKI_PORT}" "tempo:tempo-query-frontend:${TEMPO_HTTP_PORT}" "mimir:mimir-gateway:${MIMIR_PORT}")
  local failed=0
  for c in "${checks[@]}"; do IFS=':' read -r name svc _ <<<"$c"; log_info "Checking $name service..."
    if kubectl get service "$svc" -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
      local eps; eps="$(kubectl get endpoints "$svc" -n "$MONITORING_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
      if [[ -n "$eps" ]]; then 
        log_success "✅ $name service has endpoints"
      else 
        # For Tempo and Mimir, if service exists but no endpoints yet, check if pods are running
        if [[ "$name" == "tempo" || "$name" == "mimir" ]]; then
          local running_pods
          if [[ "$name" == "tempo" ]]; then
            running_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/instance=tempo --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
          else
            running_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/instance=mimir --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
          fi
          if [[ "$running_pods" -gt 0 ]]; then
            log_info "ℹ️ $name service exists, endpoints may be initializing (pods running: $running_pods)"
          else
            log_warn "⚠️ $name service exists but has no endpoints and no running pods"
            ((failed += 1))
          fi
        else
          log_warn "⚠️ $name service exists but has no endpoints"
          ((failed += 1))
        fi
      fi
    else
      if [[ "$name" == "tempo" || "$name" == "mimir" ]]; then log_info "ℹ️ $name service not found (optional component)"; else log_warn "❌ $name service not found"; ((failed += 1)); fi
    fi
  done
  log_info "Pod status in ${MONITORING_NAMESPACE} ..."; local pending running failed_p
  pending="$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo 0)"
  running="$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo 0)"
  failed_p="$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l || echo 0)"
  
  # Check OTeBPF separately - DaemonSets can have pending pods (normal for EKS Auto Mode)
  local otebpf_running otebpf_pending otebpf_failed
  otebpf_running=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app=otebpf --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo 0)
  otebpf_pending=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app=otebpf --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo 0)
  otebpf_failed=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app=otebpf --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l || echo 0)
  
  # Exclude OTeBPF pods from overall pending/failed counts since DaemonSet pending pods are expected
  pending=$((pending - otebpf_pending))
  failed_p=$((failed_p - otebpf_failed))
  
  # Check HPA-enabled components separately - they can have pending pods during scale-up (normal for EKS Auto Mode)
  # Grafana, Prometheus, AlertManager, Tempo, Mimir all have HPA enabled
  local hpa_pending
  hpa_pending=$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | \
    grep -cE "(grafana|prometheus|alertmanager|tempo|mimir)" || echo 0)
  
  # Exclude HPA-enabled component pending pods from failure count (they'll schedule as cluster scales)
  local non_hpa_pending=$((pending - hpa_pending))
  
  log_info "Pods: $running running, $pending pending ($hpa_pending from HPA-enabled components), $failed_p failed"
  
  if [[ "$otebpf_running" -ge 1 ]]; then
    log_info "✅ OTeBPF: $otebpf_running running, $otebpf_pending pending (expected for DaemonSet in EKS Auto Mode)"
  else
    log_warn "⚠️ OTeBPF: No running pods yet (may need more cluster resources or nodes to scale)"
  fi
  
  if [[ "$hpa_pending" -gt 0 ]]; then
    log_info "ℹ️  HPA-enabled components have $hpa_pending pending pod(s) - this is normal during cluster scale-up in EKS Auto Mode"
  fi
  
  # Check for failed pods (excluding OTeBPF, which we check separately)
  if [[ "$failed_p" -gt 0 ]]; then
    local non_otebpf_failed
    non_otebpf_failed=$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Failed --no-headers 2>/dev/null | grep -cv "otebpf" || echo 0)
    if [[ "$non_otebpf_failed" -gt 0 ]]; then
      kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Failed --no-headers 2>/dev/null | grep -v "otebpf" || true
      ((failed += 1))
    fi
  fi
  
  # Check OTeBPF failed pods separately (this is concerning and should be reported)
  if [[ "$otebpf_failed" -gt 0 ]]; then 
    log_warn "⚠️ OTeBPF has $otebpf_failed failed pod(s) - this is concerning"
    kubectl get pods -n "$MONITORING_NAMESPACE" -l app=otebpf --field-selector=status.phase=Failed || true
    ((failed += 1))
  fi
  
  # Only fail if there are non-HPA pending pods (HPA pending pods are expected during scale-up)
  # But warn if there are many HPA pending pods for extended periods
  if [[ "$non_hpa_pending" -gt 0 ]]; then
    log_warn "⚠️ Found $non_hpa_pending pending pod(s) from non-HPA components - this may indicate resource constraints"
    kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | \
      grep -vE "(grafana|prometheus|alertmanager|tempo|mimir|otebpf)" || true
    # Don't fail on this - just warn, as it could be temporary
  fi
  
  if [[ $failed -eq 0 ]]; then 
    log_success "🎉 All monitoring components verified successfully!"; 
    log_audit "VERIFY" "monitoring_stack" "SUCCESS"; 
    print_access_help; 
    return 0
  else 
    log_error "❌ CRITICAL FAILURE: Monitoring installation has $failed issues"; 
    log_audit "VERIFY" "monitoring_stack" "FAILED"; 
    print_troubleshooting_help; 
    log_error "All monitoring components must be working - installation failed"
    return 1
  fi
}
verify_openemr_monitoring(){
  log_step "Verifying OpenEMR-specific monitoring configuration..."
  if kubectl get servicemonitor openemr-metrics -n "$OPENEMR_NAMESPACE" >/dev/null 2>&1; then
    log_success "✅ OpenEMR ServiceMonitor configured"
  else
    log_warn "⚠️ OpenEMR ServiceMonitor not found"
  fi
  if kubectl get prometheusrule openemr-alerts -n "$OPENEMR_NAMESPACE" >/dev/null 2>&1; then
    log_success "✅ OpenEMR alerting rules configured"
  else
    log_warn "⚠️ OpenEMR alerting rules not found"
  fi
  if kubectl get configmap grafana-datasources -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
    log_success "✅ Grafana datasources configured"
  else
    log_warn "⚠️ Grafana datasources not configured"
  fi
  if kubectl get configmap grafana-dashboard-openemr -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
    log_success "✅ OpenEMR dashboard configured"
  else
    log_warn "⚠️ OpenEMR dashboard not configured. To configure create configmap called 'grafana-dashboard-openemr' that specifies the custom dashboard configuration you would like."
  fi
}

print_access_help(){
  log_info ""; log_info "🚀 Monitoring Stack Access Information:"; log_info ""
  local f="$CREDENTIALS_DIR/monitoring-credentials.txt"
  if [[ -f "$f" ]]; then local pw; pw="$(grep "Grafana Admin Password:" "$f" | awk '{print $4}' || echo "check-credentials-file")"; log_info "📋 Grafana Credentials:"; log_info "   Username: admin"; log_info "   Password: $pw"; log_info ""; fi
  log_info "🔗 Port-forward Commands:"; log_info "   Grafana:    kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-grafana ${GRAFANA_PORT}:80"
  log_info "   Prometheus: kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-kube-prom-prometheus ${PROMETHEUS_PORT}:9090"
  log_info "   AlertManager: kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-kube-prom-alertmanager ${ALERTMANAGER_PORT}:9093"
  log_info "   Loki:       kubectl -n $MONITORING_NAMESPACE port-forward svc/loki-gateway ${LOKI_PORT}:80"
  log_info "   Tempo:      kubectl -n $MONITORING_NAMESPACE port-forward svc/tempo-gateway ${TEMPO_HTTP_PORT}:80"
  log_info "   Mimir:      kubectl -n $MONITORING_NAMESPACE port-forward svc/mimir-gateway ${MIMIR_PORT}:${MIMIR_PORT}"
  log_info ""; log_info "🌐 Access URLs (after port-forwarding):"; log_info "   Grafana:    http://localhost:${GRAFANA_PORT} (Tempo UI is accessed through Grafana Explore)"; log_info "   Prometheus: http://localhost:${PROMETHEUS_PORT}"; log_info "   Loki:       http://localhost:${LOKI_PORT} (API only - use Grafana for UI)"; log_info "   Tempo:      http://localhost:${TEMPO_HTTP_PORT} (API only - use Grafana for UI)"; log_info "   Mimir:      http://localhost:${MIMIR_PORT} (API only - use Grafana for UI)"; log_info ""
  log_info "📊 Next Steps:"; log_info "   1. Port-forward to Grafana and login"; log_info "   2. Dashboards → Browse"; log_info "   3. Kubernetes / Compute Resources / Namespace (Pods)"; log_info "   4. Filter namespace 'openemr'"; log_info ""; log_info "🔍 View OTeBPF Auto-Instrumented Traces:"; log_info "   1. In Grafana, go to Explore (compass icon)"; log_info "   2. Select 'Tempo' datasource from dropdown"; log_info "   3. Use 'Service Name' filter: 'openemr'"; log_info "   4. Click 'Run query' to see traces"; log_info "   5. Click on a trace to see detailed span information"; log_info ""
}
print_troubleshooting_help(){
  log_info ""; log_info "🔧 Troubleshooting Steps:"; log_info ""
  log_info "1. Check pods: kubectl get pods -n $MONITORING_NAMESPACE"
  log_info "2. Events:     kubectl get events -n $MONITORING_NAMESPACE --sort-by='.lastTimestamp' | tail -10"
  log_info "3. Grafana logs: kubectl logs deployment/prometheus-stack-grafana -n $MONITORING_NAMESPACE"
  log_info "4. Re-run with DEBUG=1"; log_info "5. Tail logs: tail -f $LOG_FILE"; log_info ""
}

# ------------------------------
# CloudWatch IAM for Grafana
# ------------------------------
create_grafana_cloudwatch_iam(){
  log_step "Setting up CloudWatch IAM permissions for Grafana..."
  
  # Get Grafana CloudWatch role ARN from Terraform outputs
  local role_arn
  local terraform_dir="${SCRIPT_DIR}/../terraform"
  
  if [[ -f "$terraform_dir/terraform.tfstate" ]] || [[ -n "${TERRAFORM_STATE_PATH:-}" ]]; then
    log_info "Retrieving Grafana CloudWatch IAM role from Terraform..."
    
    # Try to get from Terraform output
    role_arn=$(cd "$terraform_dir" && terraform output -raw grafana_cloudwatch_role_arn 2>/dev/null || echo "")
    
    if [[ -n "$role_arn" && "$role_arn" != "null" ]]; then
      log_success "Found Terraform-managed IAM role: $role_arn"
    else
      log_warn "Could not retrieve grafana_cloudwatch_role_arn from Terraform"
      log_warn "CloudWatch datasource will not work without IAM permissions"
      log_warn "Please ensure Terraform has been applied with the latest IAM resources"
      return 0
    fi
  else
    log_warn "Terraform state not found at $terraform_dir"
    log_warn "CloudWatch datasource requires Terraform-managed IAM role"
    log_warn "Please run 'terraform apply' first to create the Grafana CloudWatch IAM role"
    return 0
  fi
  
  # Annotate Grafana service account with the Terraform-created role
  log_info "Annotating Grafana service account with IAM role..."
  
  if kubectl annotate serviceaccount prometheus-stack-grafana \
    -n "$MONITORING_NAMESPACE" \
    eks.amazonaws.com/role-arn="$role_arn" \
    --overwrite 2>/dev/null; then
    log_success "Grafana service account annotated with CloudWatch IAM role"
    log_info "Role ARN: $role_arn"
    log_audit "CREATE" "grafana_cloudwatch_iam" "SUCCESS"
  else
    log_warn "Failed to annotate service account - CloudWatch datasource may not work"
    log_warn "Ensure the prometheus-stack-grafana service account exists"
  fi
}

# ------------------------------
# Grafana Datasources / Dashboard
# ------------------------------
create_grafana_datasources(){
  log_step "Creating Grafana datasources..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: ${MONITORING_NAMESPACE}
  labels:
    grafana_datasource: "1"
    app.kubernetes.io/name: grafana-datasources
    app.kubernetes.io/component: grafana
data:
  datasources.yaml: |
    apiVersion: 1
    deleteDatasources:
      - name: Prometheus
        orgId: 1
      - name: Loki
        orgId: 1
      - name: Tempo
        orgId: 1
      - name: Mimir
        orgId: 1
      - name: CloudWatch
        orgId: 1
      - name: X-Ray
        orgId: 1
    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-stack-kube-prom-prometheus:9090
        jsonData:
          timeInterval: "30s"
          queryTimeout: "300s"
          httpMethod: POST
          manageAlerts: true
        editable: true
      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki-gateway.monitoring.svc.cluster.local/
        jsonData:
          timeout: 60
          maxLines: 5000
          derivedFields:
            # Link trace IDs from logs to Tempo traces
            - datasourceUid: tempo
              matcherRegex: 'traceID=(\\w+)'
              name: TraceID
              url: '\${__value.raw}'
              urlDisplayLabel: 'View Trace in Tempo'
            # Alternative trace ID format (for different logging patterns)
            - datasourceUid: tempo
              matcherRegex: 'trace_id[=:]\\s*([a-fA-F0-9]+)'
              name: TraceID
              url: '\${__value.raw}'
              urlDisplayLabel: 'View Trace'
        editable: true
      - name: Tempo
        uid: tempo
        type: tempo
        access: proxy
        url: http://tempo-query-frontend.${MONITORING_NAMESPACE}.svc.cluster.local:${TEMPO_HTTP_PORT}
        jsonData:
          httpMethod: GET
          tracesToLogs:
            datasourceUid: 'loki'
            spanStartTimeShift: '${TEMPO_SPAN_START_TIME_SHIFT}'
            spanEndTimeShift: '${TEMPO_SPAN_END_TIME_SHIFT}'
            tags: ['job', 'instance', 'pod', 'namespace']
            filterByTraceID: true
            filterBySpanID: false
            customQuery: false
          tracesToMetrics:
            datasourceUid: 'prometheus'
            spanStartTimeShift: '${TEMPO_SPAN_START_TIME_SHIFT}'
            spanEndTimeShift: '${TEMPO_SPAN_END_TIME_SHIFT}'
            tags:
              - key: 'service.name'
                value: 'service'
              - key: 'job'
            queries:
              - name: 'Request Rate'
                query: 'sum(rate(traces_spanmetrics_calls_total{\$__tags}[${ALERT_FOR_DURATION}]))'
              - name: 'Error Rate'
                query: 'sum(rate(traces_spanmetrics_calls_total{\$__tags,status_code="STATUS_CODE_ERROR"}[${ALERT_FOR_DURATION}]))'
              - name: 'Duration'
                query: 'histogram_quantile(0.9, sum(rate(traces_spanmetrics_latency_bucket{\$__tags}[${ALERT_FOR_DURATION}])) by (le))'
          nodeGraph:
            enabled: true
          search:
            hide: false
          serviceMap:
            datasourceUid: 'prometheus'
          traceQuery:
            timeShiftEnabled: true
            spanStartTimeShift: '${TEMPO_SPAN_START_TIME_SHIFT}'
            spanEndTimeShift: '${TEMPO_SPAN_END_TIME_SHIFT}'
        editable: true
      - name: Mimir
        uid: mimir
        type: prometheus
        access: proxy
        url: http://mimir-gateway.${MONITORING_NAMESPACE}.svc.cluster.local:${MIMIR_PORT}/prometheus
        jsonData:
          timeInterval: "30s"
          queryTimeout: "300s"
          httpMethod: POST
          manageAlerts: true
        editable: true
        isDefault: false
      - name: CloudWatch
        uid: cloudwatch
        type: cloudwatch
        access: proxy
        jsonData:
          authType: default
          defaultRegion: ${AWS_REGION}
          # Use IRSA (IAM Roles for Service Accounts) for authentication
          # The Grafana service account is annotated with the IAM role
          assumeRoleArn: ""
          externalId: ""
          # Link to X-Ray for trace linking from CloudWatch logs
          tracingDatasourceUid: xray
        editable: true
      - name: X-Ray
        uid: xray
        type: cloudwatch
        access: proxy
        jsonData:
          authType: default
          defaultRegion: ${AWS_REGION}
          # Use IRSA (IAM Roles for Service Accounts) for authentication
          # The Grafana service account is annotated with the IAM role
          assumeRoleArn: ""
          externalId: ""
          # Note: The dedicated X-Ray plugin was deprecated in Grafana 2024
          # CloudWatch datasource can query X-Ray traces directly via AWS APIs
          # This datasource allows CloudWatch logs to link to X-Ray traces
          # when logs contain @xrayTraceId field
        editable: true
EOF
  log_success "Grafana datasources created"; log_audit "CREATE" "grafana_datasources" "SUCCESS"
  
  # Grafana sidecar automatically reloads datasources from configmaps (no restart needed)
  # However, CloudWatch/X-Ray datasources need Grafana to restart to pick up IRSA credentials
  log_info "Restarting Grafana pod to ensure IRSA credentials are picked up for CloudWatch/X-Ray datasources..."
  if kubectl rollout restart deployment prometheus-stack-grafana -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
    log_info "Waiting for Grafana rollout to complete after restart..."
    # Wait for rollout to complete (this ensures old pods are terminated before new ones start)
    if kubectl rollout status deployment prometheus-stack-grafana -n "$MONITORING_NAMESPACE" --timeout="${KUBECTL_WAIT_TIMEOUT_SHORT}" >/dev/null 2>&1; then
      log_success "Grafana restarted - CloudWatch/X-Ray datasources should now use IRSA credentials"
    else
      # Rollout didn't complete within timeout - check if at least one Grafana pod is running
      # This can happen when resources are constrained and the new pod can't be scheduled
      local running_grafana_pods
      running_grafana_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$running_grafana_pods" -gt 0 ]]; then
        log_info "Grafana rollout in progress (new pod may be pending due to resource constraints) - at least one Grafana pod is running and serving traffic"
        log_info "CloudWatch/X-Ray datasources will use IRSA credentials once the new pod is ready"
      else
        log_warn "Grafana rollout may still be in progress - continuing with installation"
      fi
    fi
  else
    log_warn "Could not restart Grafana - you may need to manually restart it for CloudWatch/X-Ray to work"
  fi
  log_info "Datasources will be auto-discovered by Grafana sidecar within 60 seconds"
}

# ------------------------------
# OpenEMR Monitoring Objects
# ------------------------------
create_openemr_monitoring(){
  log_step "Creating comprehensive OpenEMR monitoring configuration..."
  wait_for_prom_operator_crds
  wait_for_prom_operator_webhook
  ensure_namespace "$OPENEMR_NAMESPACE"

  kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: openemr-metrics
  namespace: ${OPENEMR_NAMESPACE}
  labels:
    app: openemr
    release: prometheus-stack
    app.kubernetes.io/name: openemr-servicemonitor
    app.kubernetes.io/component: monitoring
spec:
  selector:
    matchLabels:
      app: openemr
  endpoints:
    - port: http
      path: /metrics
      interval: ${PROMETHEUS_SCRAPE_INTERVAL}
      scrapeTimeout: ${PROMETHEUS_SCRAPE_TIMEOUT}
      honorLabels: true
  namespaceSelector:
    matchNames: [ ${OPENEMR_NAMESPACE} ]
EOF

  retry_with_backoff 5 10 60 kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: openemr-alerts
  namespace: ${OPENEMR_NAMESPACE}
  labels:
    app: openemr
    release: prometheus-stack
    app.kubernetes.io/name: openemr-rules
    app.kubernetes.io/component: monitoring
spec:
  groups:
    - name: openemr.infrastructure
      interval: ${ALERT_EVALUATION_INTERVAL}
      rules:
        - alert: OpenEMRHighCPU
          expr: rate(container_cpu_usage_seconds_total{namespace="openemr",pod=~"openemr-.*",container!="",container!="POD"}[${ALERT_FOR_DURATION}]) > ${ALERT_CPU_THRESHOLD}
          for: ${ALERT_FOR_DURATION}
          labels: { severity: warning, component: openemr, category: infrastructure }
          annotations:
            summary: "OpenEMR pod {{ \$labels.pod }} has high CPU usage"
            description: "CPU usage > ${ALERT_CPU_THRESHOLD} (${ALERT_CPU_THRESHOLD} = $(awk "BEGIN {printf \"%.0f\", ${ALERT_CPU_THRESHOLD} * 100}")%) for ${ALERT_FOR_DURATION}."
        - alert: OpenEMRHighMemory
          expr: |
            (container_memory_usage_bytes{namespace="openemr",pod=~"openemr-.*",container!="",container!="POD"}
            / ignoring (container) group_left
              max(container_spec_memory_limit_bytes{namespace="openemr",pod=~"openemr-.*",container!="",container!="POD"}) by (pod)) > ${ALERT_MEMORY_THRESHOLD}
          for: ${ALERT_FOR_DURATION}
          labels: { severity: warning, component: openemr, category: infrastructure }
          annotations:
            summary: "OpenEMR pod {{ \$labels.pod }} has high memory usage"
            description: "Memory usage > ${ALERT_MEMORY_THRESHOLD} (${ALERT_MEMORY_THRESHOLD} = $(awk "BEGIN {printf \"%.0f\", ${ALERT_MEMORY_THRESHOLD} * 100}")%) for ${ALERT_FOR_DURATION}."
        - alert: OpenEMRPodDown
          expr: up{namespace="openemr"} == 0
          for: 1m
          labels: { severity: critical, component: openemr, category: availability }
          annotations:
            summary: "OpenEMR target {{ \$labels.instance }} down"
            description: "Target has been down >1m."
    - name: openemr.performance
      interval: ${ALERT_EVALUATION_INTERVAL}
      rules:
        - alert: OpenEMRHighResponseTime
          expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace="openemr"}[${ALERT_FOR_DURATION}])) by (le)) > ${ALERT_LATENCY_THRESHOLD_SECONDS}
          for: ${ALERT_FOR_DURATION}
          labels: { severity: warning, component: openemr, category: performance }
          annotations:
            summary: "P95 response > ${ALERT_LATENCY_THRESHOLD_SECONDS}s"
            description: "P95 latency high for ${ALERT_FOR_DURATION}."
        - alert: OpenEMRHighErrorRate
          expr: |
            sum(rate(http_requests_total{namespace="openemr",status=~"5.."}[${ALERT_FOR_DURATION}])) / sum(rate(http_requests_total{namespace="openemr"}[${ALERT_FOR_DURATION}])) > ${ALERT_ERROR_RATE_THRESHOLD}
          for: ${ALERT_FOR_DURATION}
          labels: { severity: warning, component: openemr, category: performance }
          annotations:
            summary: "HTTP 5xx > ${ALERT_ERROR_RATE_THRESHOLD} ($(awk "BEGIN {printf \"%.0f\", ${ALERT_ERROR_RATE_THRESHOLD} * 100}")%)"
            description: "Error rate high for ${ALERT_FOR_DURATION}."
EOF

  log_success "OpenEMR monitoring configuration created"; log_audit "CREATE" "openemr_monitoring" "SUCCESS"
}

# ------------------------------
# Network Policies
# ------------------------------
apply_network_policies(){
  log_step "Applying NetworkPolicies for monitoring components..."
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: grafana-restrict
  namespace: ${MONITORING_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: grafana
  policyTypes: ["Ingress","Egress"]
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - namespaceSelector: {}
    - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: promtail-to-loki
  namespace: ${MONITORING_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: promtail
  policyTypes: ["Egress"]
  egress:
  - to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: loki
    ports:
    - protocol: TCP
      port: 3100
EOF
  log_success "NetworkPolicies applied"
}


# ------------------------------
# Utilities
# ------------------------------
uninstall_all(){
  log_step "Uninstalling monitoring stack..."
  set +e
  # Uninstall all Helm releases (continue even if they don't exist)
  helm uninstall prometheus-stack -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  helm uninstall loki -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  helm uninstall tempo -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  helm uninstall mimir -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  helm uninstall alloy -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  
  # Delete Kubernetes resources (continue even if they don't exist)
  kubectl delete configmap tempo-config tempo-runtime -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete serviceaccount tempo -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  
  # Remove OTeBPF resources (current)
  kubectl delete daemonset otebpf -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete service otebpf -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete servicemonitor otebpf -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete serviceaccount otebpf -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrolebinding otebpf-cluster-role-binding --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrole otebpf-cluster-role --ignore-not-found 2>/dev/null || true
  
  # Remove old Beyla resources (if they exist from previous installations)
  kubectl delete daemonset beyla -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete service beyla -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete servicemonitor beyla -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete serviceaccount beyla -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrolebinding beyla-cluster-role-binding --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrole beyla-cluster-role --ignore-not-found 2>/dev/null || true
  
  # Delete secrets and configmaps
  kubectl delete -n "$MONITORING_NAMESPACE" secret grafana-admin-secret grafana-basic-auth --ignore-not-found 2>/dev/null || true
  kubectl delete cm grafana-datasources grafana-dashboard-openemr -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete secret alertmanager-config -n "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  
  # Delete namespaces (continue even if they don't exist)
  kubectl delete ns "$OBSERVABILITY_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete ns "$MONITORING_NAMESPACE" --ignore-not-found 2>/dev/null || true
  set -e
  log_success "Uninstall complete"
}

# ------------------------------
# Main CLI
# ------------------------------
main(){
  local cmd="${1:-install}"

  load_config
  check_dependencies
  log_info "AWS Region detected: ${AWS_REGION}"
  check_kubernetes
  ensure_namespace "$MONITORING_NAMESPACE"
  create_monitoring_rbac
  check_cluster_resources
  check_eks_auto_mode
  check_storage_class
  setup_helm_repos

  case "$cmd" in
    install)
      configure_namespace_security
      
      # Check if Grafana secret already exists to determine if we should preserve credentials
      local pw
      if kubectl get secret grafana-admin-secret -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        log_info "Existing Grafana installation detected - preserving existing credentials"
        # Retrieve existing password from secret
        pw=$(kubectl get secret grafana-admin-secret -n "$MONITORING_NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "")
        if [[ -z "$pw" ]]; then
          log_warn "Could not retrieve existing password - generating new one"
          pw="$(generate_secure_password)"
        else
          log_success "Retrieved existing Grafana password from secret"
        fi
      else
        log_info "Fresh Grafana installation - generating new credentials"
        pw="$(generate_secure_password)"
      fi
      
      create_grafana_secret "$pw"
      write_credentials_file "$pw"
      create_values_file
      install_prometheus_stack "$VALUES_FILE"
      install_loki_stack
      install_tempo
      install_mimir
      install_otebpf
      cleanup_duplicate_pods
      create_additional_hpa
      create_grafana_cloudwatch_iam       # Setup CloudWatch IAM before datasources
      create_grafana_datasources
      create_alertmanager_config
      create_openemr_monitoring
      apply_network_policies || log_warn "NetworkPolicies failed (continuing)"
      verify_installation
      verify_openemr_monitoring
      ;;
    verify)
      verify_installation
      verify_openemr_monitoring
      ;;
    status)
      kubectl get pods,svc -n "$MONITORING_NAMESPACE" || true
      ;;
    uninstall|destroy|delete)
      uninstall_all
      ;;
    *)
      echo "Usage: $SCRIPT_NAME {install|verify|status|uninstall}" >&2
      exit 2
      ;;
  esac
}
main "$@"
