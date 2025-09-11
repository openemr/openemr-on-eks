#!/bin/bash
# Enhanced OpenEMR monitoring setup with security, reliability, performance, and ingress/auth options
# Jaeger/cert-manager fixes + optional cert-manager TLS for Grafana
set -euo pipefail
set -o errtrace

# ------------------------------
# Configuration Management
# ------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
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
readonly CHART_KPS_VERSION="${CHART_KPS_VERSION:-75.18.1}"
readonly CHART_LOKI_VERSION="${CHART_LOKI_VERSION:-6.35.1}"
readonly CHART_JAEGER_VERSION="${CHART_JAEGER_VERSION:-3.4.1}"

# Timeouts / retries
readonly TIMEOUT_HELM="${TIMEOUT_HELM:-45m}"
readonly TIMEOUT_KUBECTL="${TIMEOUT_KUBECTL:-600s}"
readonly MAX_RETRIES="${MAX_RETRIES:-3}"
readonly BASE_DELAY="${BASE_DELAY:-30}"
readonly MAX_DELAY="${MAX_DELAY:-300}"

# Ingress / Auth toggles (only nginx supported)
readonly ENABLE_INGRESS="${ENABLE_INGRESS:-0}"
readonly INGRESS_TYPE="${INGRESS_TYPE:-nginx}"     # must be 'nginx'
readonly GRAFANA_HOSTNAME="${GRAFANA_HOSTNAME:-}"  # e.g. grafana.example.com
TLS_SECRET_NAME="${TLS_SECRET_NAME:-}"             # may be set later if self-signed

# Basic auth (nginx only)
readonly ENABLE_BASIC_AUTH="${ENABLE_BASIC_AUTH:-0}"
readonly BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
readonly BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"

# Alertmanager Slack (optional)
readonly SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
readonly SLACK_CHANNEL="${SLACK_CHANNEL:-}"

# ---- cert-manager (pinned) & optional Grafana TLS via cert-manager
readonly CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.18.2}"
readonly USE_CERT_MANAGER_TLS="${USE_CERT_MANAGER_TLS:-0}"
readonly CERT_MANAGER_ISSUER_NAME="${CERT_MANAGER_ISSUER_NAME:-}"
readonly CERT_MANAGER_ISSUER_KIND="${CERT_MANAGER_ISSUER_KIND:-ClusterIssuer}"   # or Issuer
readonly CERT_MANAGER_ISSUER_GROUP="${CERT_MANAGER_ISSUER_GROUP:-cert-manager.io}"

# Colors
readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'; readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'; readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ------------------------------
# Enhanced Logging
# ------------------------------
log_with_timestamp() { local level="$1"; shift; local t; t="$(date '+%Y-%m-%d %H:%M:%S')"; echo -e "${level} [$t] $*"; [[ "${ENABLE_LOG_FILE:-1}" == "1" ]] && echo -e "${level} [$t] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_info()    { log_with_timestamp "${GREEN}[INFO]${NC}" "$@"; }
log_warn()    { log_with_timestamp "${YELLOW}[WARN]${NC}" "$@" >&2; }
log_error()   { log_with_timestamp "${RED}[ERROR]${NC}" "$@" >&2; }
log_debug()   { [[ "${DEBUG:-0}" == "1" ]] && log_with_timestamp "${BLUE}[DEBUG]${NC}" "$@" || true; }
log_success() { log_with_timestamp "${GREEN}[SUCCESS]${NC}" "$@"; }
log_step()    { log_with_timestamp "${CYAN}[STEP]${NC}" "$@"; }

log_audit() { local a="$1" r="$2" res="$3"; local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo "[$ts] AUDIT: action=$a resource=$r result=$res user=$(whoami) script=$SCRIPT_NAME" >> "${LOG_FILE%.log}-audit.log" 2>/dev/null || true; log_info "Audit: $a $r -> $res"; }

# ------------------------------
# Error Handling
# ------------------------------
capture_debug_info() {
  local f="${SCRIPT_DIR}/debug-$(date +%Y%m%d_%H%M%S).log"
  {
    echo "=== Debug Information ==="
    echo "Timestamp: $(date)"
    echo "Kubernetes cluster info:"; kubectl cluster-info 2>/dev/null || echo "Failed to get cluster info"
    echo ""; echo "Monitoring namespace resources:"; kubectl get all -n "$MONITORING_NAMESPACE" 2>/dev/null || echo "No resources found"
    echo ""; echo "Recent events:"; kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -20 2>/dev/null || echo "Failed to get events"
    echo ""; echo "Helm releases:"; helm list --all-namespaces 2>/dev/null || echo "Failed to list helm releases"
  } > "$f"; log_info "Debug information captured: $f"
}
cleanup_on_error(){ log_info "Performing error cleanup..."; [[ -f "${VALUES_FILE}.bak" ]] && mv "${VALUES_FILE}.bak" "${VALUES_FILE}" 2>/dev/null || true; find "$CREDENTIALS_DIR" -name "*.tmp" -type f -delete 2>/dev/null || true; }
cleanup(){ log_debug "Performing normal cleanup..."; rm -f "${VALUES_FILE}.bak" 2>/dev/null || true; find "$CREDENTIALS_DIR" -name "*.tmp" -type f -delete 2>/dev/null || true; }
handle_error(){ local c="$1" l="$2" cmd="$3"; log_error "Command failed with exit code $c at line $l: $cmd"; log_error "Function stack: ${FUNCNAME[*]}"; log_audit "ERROR" "script_execution" "FAILED"; capture_debug_info; cleanup_on_error; exit "$c"; }
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ------------------------------
# Config & Input Validation
# ------------------------------
load_config(){ if [[ -f "$CONFIG_FILE" ]]; then log_info "Loading configuration from: $CONFIG_FILE"; source "$CONFIG_FILE"; else log_debug "No configuration file found at: $CONFIG_FILE"; fi; mkdir -p "$CREDENTIALS_DIR" "$BACKUP_DIR"; chmod 700 "$CREDENTIALS_DIR"; validate_inputs; }
validate_inputs(){
  log_step "Validating configuration inputs..."
  local namespaces=("$MONITORING_NAMESPACE" "$OPENEMR_NAMESPACE" "$OBSERVABILITY_NAMESPACE")
  for ns in "${namespaces[@]}"; do [[ "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { log_error "Invalid namespace name: $ns"; return 1; }; done
  [[ "$STORAGE_CLASS_RWO" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { log_error "Invalid storage class: $STORAGE_CLASS_RWO"; return 1; }
  [[ "$BASE_DELAY" =~ ^[0-9]+$ && "$MAX_DELAY" =~ ^[0-9]+$ ]] || { log_error "Invalid delay values: BASE_DELAY=$BASE_DELAY, MAX_DELAY=$MAX_DELAY"; return 1; }

  if [[ "$ENABLE_INGRESS" == "1" ]]; then
    [[ -n "$GRAFANA_HOSTNAME" ]] || { log_error "ENABLE_INGRESS=1 requires GRAFANA_HOSTNAME"; return 1; }
    [[ "$INGRESS_TYPE" == "nginx" ]] || { log_error "Only NGINX ingress is supported (ALB removed). Set INGRESS_TYPE=nginx."; return 1; }
  fi

  if [[ "$USE_CERT_MANAGER_TLS" == "1" && -z "$CERT_MANAGER_ISSUER_NAME" ]]; then
    log_error "USE_CERT_MANAGER_TLS=1 requires CERT_MANAGER_ISSUER_NAME (and optionally CERT_MANAGER_ISSUER_KIND/GROUP)."; return 1
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
ensure_namespace(){ local ns="$1"; if ! kubectl get namespace "$ns" >/dev/null 2>&1; then log_info "Creating namespace: $ns"; kubectl create namespace "$ns"; log_audit "CREATE" "namespace:$ns" "SUCCESS"; else log_debug "Namespace $ns exists"; fi; }

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
    while read -r pod_name _; do if [[ -n "$pod_name" ]]; then log_info "Deleting pending Grafana pod: $pod_name"; kubectl delete pod "$pod_name" -n "$MONITORING_NAMESPACE" --ignore-not-found; ((cleaned++)); fi; done
  fi
  kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Failed --no-headers 2>/dev/null | \
  while read -r pod_name _ _ _ age _; do if [[ -n "$pod_name" && "$age" =~ ^[0-9]+[mh]$ ]]; then log_info "Deleting failed pod: $pod_name (age: $age)"; kubectl delete pod "$pod_name" -n "$MONITORING_NAMESPACE" --ignore-not-found; ((cleaned++)); fi; done
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
retry_with_backoff(){ local max="$1" base="$2" maxd="$3"; shift 3; local attempt=1 delay="$base"; while [[ $attempt -le $max ]]; do log_debug "Attempt $attempt/$max: $*"; if "$@"; then return 0; fi; if [[ $attempt -lt $max ]]; then log_warn "Attempt $attempt failed, retrying in ${delay}s..."; sleep "$delay"; delay=$((delay * 2)); [[ $delay -gt $maxd ]] && delay="$maxd"; fi; ((attempt++)); done; log_error "Command failed after $max attempts: $*"; return 1; }

# ------------------------------
# Helm Repo Setup
# ------------------------------
setup_helm_repos(){
  log_step "Setting up Helm repositories..."
  local repos=("prometheus-community|https://prometheus-community.github.io/helm-charts" "grafana|https://grafana.github.io/helm-charts" "jaegertracing|https://jaegertracing.github.io/helm-charts")
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
    local backup_file="${f}.backup.$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up existing password file to: $backup_file"
    cp "$f" "$backup_file"
    chmod 600 "$backup_file"
  fi

  umask 077
  echo "$p" > "$f"
  chmod 600 "$f"
  echo "$f"
}
create_grafana_secret(){ local p="$1"; log_info "Creating Grafana admin secret..."; kubectl create secret generic grafana-admin-secret --from-literal=admin-user="admin" --from-literal=admin-password="$p" --namespace="$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -; log_audit "CREATE" "secret:grafana-admin-secret" "SUCCESS"; }
write_credentials_file(){
  local p="$1" f="$CREDENTIALS_DIR/monitoring-credentials.txt"

  # Backup existing file if it exists
  if [[ -f "$f" ]]; then
    local backup_file="${f}.backup.$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up existing credentials file to: $backup_file"
    cp "$f" "$backup_file"
    chmod 600 "$backup_file"
  fi

  umask 077
  cat > "$f" <<EOF
# OpenEMR Monitoring Credentials
# Generated: $(date)

Grafana Admin User: admin
Grafana Admin Password: $p

# Port-forward access:
# Grafana:   kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-grafana 3000:80
# Prometheus: kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090
# AlertManager: kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-kube-prom-alertmanager 9093:9093
# Loki:       kubectl -n $MONITORING_NAMESPACE port-forward svc/loki 3100:3100
# Jaeger:     kubectl -n $MONITORING_NAMESPACE port-forward svc/jaeger-query 16686:16686

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
  if command -v python3 >/dev/null 2>&1; then python3 - "$vf" 2>/dev/null <<'PY' || { echo "YAML invalid"; exit 1; }
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
PY
  elif command -v yq >/dev/null 2>&1; then yq eval '.' "$vf" >/dev/null || { log_error "Invalid YAML syntax"; return 1; }
  fi
  grep -q "existingSecret:" "$vf" || { log_error "Grafana not configured to use existingSecret"; return 1; }
  log_success "Values file validation passed"
}

create_values_file(){
  log_step "Creating Helm values file..."
  [[ -f "$VALUES_FILE" ]] && cp "$VALUES_FILE" "${VALUES_FILE}.bak" || true
  resolve_access_modes
  local sc_prom="$STORAGE_CLASS_RWO" am_prom="$ACCESS_MODE_RWO"
  local sc_am="$STORAGE_CLASS_RWO"   am_am="$ACCESS_MODE_RWO"

  local AM_BLOCK=""
  if alertmanager_enabled; then
    AM_BLOCK=$(cat <<EOF_AM
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${sc_am}
          accessModes: ["${am_am}"]
          resources: { requests: { storage: 20Gi } }
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
    securityContext:
      runAsUser: 1000
      runAsGroup: 3000
      fsGroup: 2000
    configSecret: alertmanager-config
EOF_AM
)
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
    size: 20Gi
    accessModes: ["${am_prom}"]

  securityContext:
    runAsUser: 472
    runAsGroup: 472
    fsGroup: 472

  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 1000m, memory: 1Gi }

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
          resources: { requests: { storage: 100Gi } }

    resources:
      requests: { cpu: 500m, memory: 2Gi }
      limits:   { cpu: 2000m, memory: 4Gi }

    replicas: 1
    retention: 30d
    retentionSize: 90GB

    securityContext:
      runAsUser: 1000
      runAsGroup: 3000
      fsGroup: 2000

    additionalScrapeConfigs: []
    remoteWrite: []
    evaluationInterval: 30s
    scrapeInterval: 30s

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

# ------------------------------
# AlertManager Config (optional)
# ------------------------------
create_alertmanager_config(){
  if ! alertmanager_enabled; then log_info "Skipping Alertmanager config (SLACK_WEBHOOK_URL/SLACK_CHANNEL not set or invalid)."; return 0; fi
  log_step "Creating AlertManager configuration for Slack channel ${SLACK_CHANNEL}..."
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
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 24h
      receiver: 'slack-default'
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
  log_success "AlertManager configuration created (Slack)"; log_audit "CREATE" "alertmanager_config" "SUCCESS"
}

# ------------------------------
# Installs
# ------------------------------
install_prometheus_stack(){
  local vf="$1"
  log_step "Installing kube-prometheus-stack (version ${CHART_KPS_VERSION})..."
  log_info "⏱️  Expected duration: ~3 minutes"
  helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace "$MONITORING_NAMESPACE" --create-namespace \
    --version "$CHART_KPS_VERSION" \
    --timeout "$TIMEOUT_HELM" --atomic --wait --wait-for-jobs \
    --values "$vf" 2>&1 | tee "${SCRIPT_DIR}/helm-install-kps.log"
  if ! helm status prometheus-stack -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then log_error "Prometheus Stack Helm installation failed. Check ${SCRIPT_DIR}/helm-install-kps.log"; log_audit "INSTALL" "prometheus-stack" "FAILED"; return 1; fi
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n "$MONITORING_NAMESPACE" --timeout="$TIMEOUT_KUBECTL" || true
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n "$MONITORING_NAMESPACE" --timeout="$TIMEOUT_KUBECTL" || true
  log_success "Prometheus Stack installed"; log_audit "INSTALL" "prometheus-stack" "SUCCESS"
}
install_loki_stack(){
  log_step "Installing Loki (version ${CHART_LOKI_VERSION})..."
  log_info "⏱️  Expected duration: ~3 minutes"
  local sc_loki="$STORAGE_CLASS_RWO" am_loki="$ACCESS_MODE_RWO"
  if [[ -n "$STORAGE_CLASS_RWX" ]] && kubectl get storageclass "$STORAGE_CLASS_RWX" >/dev/null 2>&1; then sc_loki="$STORAGE_CLASS_RWX"; am_loki="$ACCESS_MODE_RWX"; log_info "Using RWX storage for Loki: $sc_loki"; fi
  helm upgrade --install loki grafana/loki \
    --namespace "$MONITORING_NAMESPACE" \
    --version "$CHART_LOKI_VERSION" \
    --timeout "35m" --atomic --wait --wait-for-jobs \
    --set deploymentMode=SingleBinary \
    --set loki.auth_enabled=false \
    --set loki.storage.type=filesystem \
    --set loki.storage.filesystem.chunks_directory=/var/loki/chunks \
    --set loki.storage.filesystem.rules_directory=/var/loki/rules \
    --set loki.schemaConfig.configs[0].from=2024-01-01 \
    --set loki.schemaConfig.configs[0].object_store=filesystem \
    --set loki.schemaConfig.configs[0].store=tsdb \
    --set loki.schemaConfig.configs[0].schema=v13 \
    --set loki.schemaConfig.configs[0].index.prefix=loki_index_ \
    --set loki.schemaConfig.configs[0].index.period=24h \
    --set singleBinary.persistence.enabled=true \
    --set singleBinary.persistence.storageClass="$sc_loki" \
    --set singleBinary.persistence.accessModes="{$am_loki}" \
    --set singleBinary.persistence.size=100Gi \
    --set singleBinary.resources.requests.cpu=200m \
    --set singleBinary.resources.requests.memory=512Mi \
    --set singleBinary.resources.limits.cpu=1000m \
    --set singleBinary.resources.limits.memory=1Gi \
    --set singleBinary.autoscaling.enabled=true \
    --set singleBinary.autoscaling.minReplicas=1 \
    --set singleBinary.autoscaling.maxReplicas=3 \
    --set singleBinary.autoscaling.targetCPUUtilizationPercentage=70 \
    --set singleBinary.autoscaling.targetMemoryUtilizationPercentage=80 \
    --set loki.limits_config.retention_period=720h \
    --set loki.compactor.retention_enabled=false \
    --set write.replicas=0 --set read.replicas=0 --set backend.replicas=0 \
    2>&1 | tee "${SCRIPT_DIR}/helm-install-loki.log"
  if ! helm status loki -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then log_error "Loki Helm installation failed. Check ${SCRIPT_DIR}/helm-install-loki.log"; log_audit "INSTALL" "loki" "FAILED"; return 1; fi
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=single-binary -n "$MONITORING_NAMESPACE" --timeout="$TIMEOUT_KUBECTL" || true
  log_success "Loki installed and ready"; log_audit "INSTALL" "loki" "SUCCESS"
}

create_additional_hpa(){
  log_step "Creating additional HPA resources (optional)..."
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
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Resource
    resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
  - type: Resource
    resource: { name: memory, target: { type: Utilization, averageUtilization: 80 } }
EOF
    log_info "✅ AlertManager HPA created"
  fi
  log_success "Additional HPA resources done"; log_audit "CREATE" "hpa_resources" "SUCCESS"
}

# ------------------------------
# Jaeger install (with cert-manager)
# ------------------------------
install_jaeger(){
  log_step "Installing Jaeger for distributed tracing..."
  ensure_namespace "$OBSERVABILITY_NAMESPACE"

  # ✅ cert-manager is required for the operator's webhook certs
  install_cert_manager

  log_info "Installing Jaeger Operator (v1.65.0; unmodified)..."
  local url="https://github.com/jaegertracing/jaeger-operator/releases/download/v1.65.0/jaeger-operator.yaml"
  if ! curl --fail --connect-timeout 10 --max-time 60 -L "$url" | kubectl apply -f -; then
    log_warn "Failed to apply Jaeger Operator manifest"; return 1
  fi

  # Detect operator namespace (varies by manifest)
  local JAEGER_OPERATOR_NS
  JAEGER_OPERATOR_NS="$(kubectl get deploy -A -o jsonpath='{range .items[?(@.metadata.name=="jaeger-operator")]}{.metadata.namespace}{"\n"}{end}' | head -n1)"
  if [[ -z "$JAEGER_OPERATOR_NS" ]]; then
    log_warn "Could not detect jaeger-operator namespace automatically; defaulting to ${OBSERVABILITY_NAMESPACE}"
    JAEGER_OPERATOR_NS="$OBSERVABILITY_NAMESPACE"
  fi
  log_info "jaeger-operator detected in namespace: ${JAEGER_OPERATOR_NS}"

  log_info "Waiting for Jaeger Operator deployment..."
  if ! kubectl wait --for=condition=available --timeout="$TIMEOUT_KUBECTL" deployment/jaeger-operator -n "$JAEGER_OPERATOR_NS"; then
    log_warn "Jaeger Operator not ready"; return 1
  fi

  # Give reconciler time to issue webhook certs via cert-manager (best-effort)
  log_info "Checking for webhook cert Secret..."
  kubectl -n "$JAEGER_OPERATOR_NS" get secret -l app.kubernetes.io/name=jaeger-operator -o name >/dev/null 2>&1 || true

  log_info "Creating Jaeger all-in-one instance..."
  kubectl apply -f - <<EOF
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata:
  name: jaeger
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/name: jaeger
    app.kubernetes.io/component: tracing
spec:
  strategy: allInOne
  storage:
    type: memory
    options:
      memory:
        max-traces: 100000
  allInOne:
    image: jaegertracing/all-in-one:1.72.0
    options:
      log-level: info
      memory.max-traces: 100000
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { cpu: 1000m, memory: 1Gi }
  ingress:
    enabled: false
  ui:
    options:
      dependencies: { menuEnabled: true }
      archiveEnabled: true
EOF

  log_info "Waiting for Jaeger deployment to be ready..."
  kubectl wait --for=condition=available --timeout="$TIMEOUT_KUBECTL" deployment/jaeger -n "$MONITORING_NAMESPACE" || true

  # Optional HPA
  kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: jaeger-hpa
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/name: jaeger
    app.kubernetes.io/component: tracing
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: jaeger
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Resource
    resource: { name: cpu,    target: { type: Utilization, averageUtilization: 70 } }
  - type: Resource
    resource: { name: memory, target: { type: Utilization, averageUtilization: 80 } }
EOF

  log_success "Jaeger installed with cert-manager-backed webhooks"; log_audit "INSTALL" "jaeger" "SUCCESS"
}

# ------------------------------
# Verification
# ------------------------------
verify_installation(){
  log_step "Verifying monitoring stack installation..."
  local checks=("prometheus:prometheus-stack-kube-prom-prometheus:9090" "grafana:prometheus-stack-grafana:80" "alertmanager:prometheus-stack-kube-prom-alertmanager:9093" "loki:loki:3100" "jaeger:jaeger-query:16686")
  local failed=0
  for c in "${checks[@]}"; do IFS=':' read -r name svc port <<<"$c"; log_info "Checking $name service..."
    if kubectl get service "$svc" -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
      local eps; eps="$(kubectl get endpoints "$svc" -n "$MONITORING_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
      if [[ -n "$eps" ]]; then log_success "✅ $name service has endpoints"; else log_warn "⚠️ $name service exists but has no endpoints"; ((failed++)); fi
    else
      if [[ "$name" == "jaeger" ]]; then log_info "ℹ️ $name service not found (optional component)"; else log_warn "❌ $name service not found"; ((failed++)); fi
    fi
  done
  log_info "Pod status in ${MONITORING_NAMESPACE} ..."; local pending running failed_p
  pending="$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo 0)"
  running="$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo 0)"
  failed_p="$(kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l || echo 0)"
  log_info "Pods: $running running, $pending pending, $failed_p failed"
  if [[ "$failed_p" -gt 0 ]]; then kubectl get pods -n "$MONITORING_NAMESPACE" --field-selector=status.phase=Failed || true; ((failed++)); fi
  if [[ $failed -eq 0 ]]; then log_success "🎉 All monitoring components verified successfully!"; log_audit "VERIFY" "monitoring_stack" "SUCCESS"; print_access_help; return 0
  else log_warn "⚠️ Installation verified with $failed issues"; log_audit "VERIFY" "monitoring_stack" "PARTIAL"; print_troubleshooting_help; return 1; fi
}
verify_openemr_monitoring(){
  log_step "Verifying OpenEMR-specific monitoring configuration..."
  kubectl get servicemonitor openemr-metrics -n "$OPENEMR_NAMESPACE" >/dev/null 2>&1 && log_success "✅ OpenEMR ServiceMonitor configured" || log_warn "⚠️ OpenEMR ServiceMonitor not found"
  kubectl get prometheusrule openemr-alerts -n "$OPENEMR_NAMESPACE" >/dev/null 2>&1 && log_success "✅ OpenEMR alerting rules configured" || log_warn "⚠️ OpenEMR alerting rules not found"
  kubectl get configmap grafana-datasources -n "$MONITORING_NAMESPACE" >/dev/null 2>&1 && log_success "✅ Grafana datasources configured" || log_warn "⚠️ Grafana datasources not configured"
  kubectl get configmap grafana-dashboard-openemr -n "$MONITORING_NAMESPACE" >/dev/null 2>&1 && log_success "✅ OpenEMR dashboard configured" || log_warn "⚠️ OpenEMR dashboard not configured. To configure create configmap called 'grafana-dashboard-openemr' that specifies the custom dashboard configuration you would like."
}

print_access_help(){
  log_info ""; log_info "🚀 Monitoring Stack Access Information:"; log_info ""
  local f="$CREDENTIALS_DIR/monitoring-credentials.txt"
  if [[ -f "$f" ]]; then local pw; pw="$(grep "Grafana Admin Password:" "$f" | awk '{print $4}' || echo "check-credentials-file")"; log_info "📋 Grafana Credentials:"; log_info "   Username: admin"; log_info "   Password: $pw"; log_info ""; fi
  log_info "🔗 Port-forward Commands:"; log_info "   Grafana:    kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-grafana 3000:80"
  log_info "   Prometheus: kubectl -n $MONITORING_NAMESPACE port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090"
  log_info "   Loki:       kubectl -n $MONITORING_NAMESPACE port-forward svc/loki 3100:3100"
  log_info ""; log_info "🌐 Access URLs (after port-forwarding):"; log_info "   Grafana:    http://localhost:3000"; log_info "   Prometheus: http://localhost:9090"; log_info "   Loki:       http://localhost:3100"; log_info ""
  log_info "📊 Next Steps:"; log_info "   1. Port-forward to Grafana and login"; log_info "   2. Dashboards → Browse"; log_info "   3. Kubernetes / Compute Resources / Namespace (Pods)"; log_info "   4. Filter namespace 'openemr'"; log_info ""
}
print_troubleshooting_help(){
  log_info ""; log_info "🔧 Troubleshooting Steps:"; log_info ""
  log_info "1. Check pods: kubectl get pods -n $MONITORING_NAMESPACE"
  log_info "2. Events:     kubectl get events -n $MONITORING_NAMESPACE --sort-by='.lastTimestamp' | tail -10"
  log_info "3. Grafana logs: kubectl logs deployment/prometheus-stack-grafana -n $MONITORING_NAMESPACE"
  log_info "4. Re-run with DEBUG=1"; log_info "5. Tail logs: tail -f $LOG_FILE"; log_info ""
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
      - name: Jaeger
        orgId: 1
    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-stack-kube-prom-prometheus:9090
        isDefault: true
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
        url: http://loki:3100
        jsonData:
          maxLines: 5000
        editable: true
      - name: Jaeger
        uid: jaeger
        type: jaeger
        access: proxy
        url: http://jaeger-query:16686
        jsonData: {}
        editable: true
EOF
  log_success "Grafana datasources created"; log_audit "CREATE" "grafana_datasources" "SUCCESS"
}

# ------------------------------
# OpenEMR Monitoring Objects
# ------------------------------
create_openemr_monitoring(){
  log_step "Creating comprehensive OpenEMR monitoring configuration..."
  wait_for_prom_operator_crds
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
      interval: 30s
      scrapeTimeout: 10s
      honorLabels: true
  namespaceSelector:
    matchNames: [ ${OPENEMR_NAMESPACE} ]
EOF

  kubectl apply -f - <<EOF
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
      interval: 30s
      rules:
        - alert: OpenEMRHighCPU
          expr: rate(container_cpu_usage_seconds_total{namespace="openemr",pod=~"openemr-.*",container!="",container!="POD"}[5m]) > 0.8
          for: 5m
          labels: { severity: warning, component: openemr, category: infrastructure }
          annotations:
            summary: "OpenEMR pod {{ \$labels.pod }} has high CPU usage"
            description: "CPU usage > 80% for 5m."
        - alert: OpenEMRHighMemory
          expr: |
            (container_memory_usage_bytes{namespace="openemr",pod=~"openemr-.*",container!="",container!="POD"}
            / ignoring (container) group_left
              max(container_spec_memory_limit_bytes{namespace="openemr",pod=~"openemr-.*",container!="",container!="POD"}) by (pod)) > 0.9
          for: 5m
          labels: { severity: warning, component: openemr, category: infrastructure }
          annotations:
            summary: "OpenEMR pod {{ \$labels.pod }} has high memory usage"
            description: "Memory usage > 90% for 5m."
        - alert: OpenEMRPodDown
          expr: up{namespace="openemr"} == 0
          for: 1m
          labels: { severity: critical, component: openemr, category: availability }
          annotations:
            summary: "OpenEMR target {{ \$labels.instance }} down"
            description: "Target has been down >1m."
    - name: openemr.performance
      interval: 30s
      rules:
        - alert: OpenEMRHighResponseTime
          expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace="openemr"}[5m])) by (le)) > 2
          for: 5m
          labels: { severity: warning, component: openemr, category: performance }
          annotations:
            summary: "P95 response > 2s"
            description: "P95 latency high for 5m."
        - alert: OpenEMRHighErrorRate
          expr: |
            sum(rate(http_requests_total{namespace="openemr",status=~"5.."}[5m])) / sum(rate(http_requests_total{namespace="openemr"}[5m])) > 0.05
          for: 5m
          labels: { severity: warning, component: openemr, category: performance }
          annotations:
            summary: "HTTP 5xx > 5%"
            description: "Error rate high for 5m."
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
# Ingress & Basic Auth (Grafana) + TLS (cert-manager or self-signed)
# ------------------------------
maybe_create_basic_auth_secret(){
  [[ "$ENABLE_BASIC_AUTH" == "1" && "$INGRESS_TYPE" == "nginx" ]] || return 0
  if ! command -v htpasswd >/dev/null 2>&1; then log_warn "htpasswd not installed; cannot create basic-auth secret. Skipping basic auth."; return 0; fi
  local user="$BASIC_AUTH_USER" pass="$BASIC_AUTH_PASSWORD"
  if [[ -z "$pass" ]]; then pass="$(generate_secure_password)"; log_info "Generated BASIC_AUTH_PASSWORD for user '$user'"; fi
  local tmp; tmp="$(mktemp)"; htpasswd -nbBC 10 "$user" "$pass" > "$tmp"
  kubectl create secret generic grafana-basic-auth --from-file=auth="$tmp" -n "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$tmp"; log_success "grafana-basic-auth secret created (user: $user)"; log_info "Store basic auth password securely; it will not be shown again."
}

ensure_self_signed_tls_secret(){
  [[ "$ENABLE_INGRESS" == "1" ]] || return 0
  if [[ -z "$TLS_SECRET_NAME" ]]; then
    [[ -n "$GRAFANA_HOSTNAME" ]] || { log_error "GRAFANA_HOSTNAME required for self-signed TLS"; return 1; }
    TLS_SECRET_NAME="grafana-tls-selfsigned"
    log_step "Creating self-signed TLS secret '$TLS_SECRET_NAME' for host $GRAFANA_HOSTNAME ..."
    local td; td="$(mktemp -d)"
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "${td}/tls.key" -out "${td}/tls.crt" \
      -subj "/CN=${GRAFANA_HOSTNAME}" -addext "subjectAltName=DNS:${GRAFANA_HOSTNAME}" >/dev/null 2>&1
    kubectl create secret tls "$TLS_SECRET_NAME" --namespace "$MONITORING_NAMESPACE" --key "${td}/tls.key" --cert "${td}/tls.crt" --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "$td"; log_success "Self-signed TLS secret created: $TLS_SECRET_NAME"
  fi
}

create_grafana_ingress(){
  [[ "$ENABLE_INGRESS" == "1" ]] || { log_info "Ingress disabled (ENABLE_INGRESS=0)"; return 0; }
  ensure_namespace "$MONITORING_NAMESPACE"
  maybe_create_basic_auth_secret

  # If using cert-manager for TLS, annotate and let it create the secret
  if [[ "$USE_CERT_MANAGER_TLS" == "1" ]]; then
    install_cert_manager
    [[ -n "$TLS_SECRET_NAME" ]] || TLS_SECRET_NAME="grafana-tls"
    log_step "Creating NGINX Ingress for Grafana (cert-manager TLS) at host: $GRAFANA_HOSTNAME"
    local issuer_annotations=""
    if [[ "$CERT_MANAGER_ISSUER_KIND" == "ClusterIssuer" ]]; then
      issuer_annotations="cert-manager.io/cluster-issuer: ${CERT_MANAGER_ISSUER_NAME}"
    else
      issuer_annotations="cert-manager.io/issuer: ${CERT_MANAGER_ISSUER_NAME}
    cert-manager.io/issuer-kind: ${CERT_MANAGER_ISSUER_KIND}
    cert-manager.io/issuer-group: ${CERT_MANAGER_ISSUER_GROUP}"
    fi
    # Build annotations dynamically
    local basic_auth_annotations=""
    if [[ "$ENABLE_BASIC_AUTH" == "1" ]] && [[ -n "$(kubectl get secret grafana-basic-auth -n "$MONITORING_NAMESPACE" --ignore-not-found)" ]]; then
      basic_auth_annotations="    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: grafana-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: \"Authentication Required\""
    fi

    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: ${MONITORING_NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: nginx
    ${issuer_annotations}
${basic_auth_annotations}
spec:
  tls:
  - hosts:
    - ${GRAFANA_HOSTNAME}
    secretName: ${TLS_SECRET_NAME}
  rules:
  - host: ${GRAFANA_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus-stack-grafana
            port:
              number: 80
EOF
    log_success "NGINX Ingress created (cert-manager will provision TLS)"
  else
    ensure_self_signed_tls_secret
    log_step "Creating NGINX Ingress for Grafana (self-signed TLS) at host: $GRAFANA_HOSTNAME"
    # Build annotations dynamically
    local basic_auth_annotations=""
    if [[ "$ENABLE_BASIC_AUTH" == "1" ]] && [[ -n "$(kubectl get secret grafana-basic-auth -n "$MONITORING_NAMESPACE" --ignore-not-found)" ]]; then
      basic_auth_annotations="    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: grafana-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: \"Authentication Required\""
    fi

    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: ${MONITORING_NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: nginx
${basic_auth_annotations}
spec:
  tls:
  - hosts:
    - ${GRAFANA_HOSTNAME}
    secretName: ${TLS_SECRET_NAME}
  rules:
  - host: ${GRAFANA_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus-stack-grafana
            port:
              number: 80
EOF
    log_success "NGINX Ingress created (self-signed TLS)"
  fi
}

# ------------------------------
# Utilities
# ------------------------------
print_access_help(){ log_info "Access the UIs with port-forward (if not using Ingress):"; echo "  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/prometheus-stack-grafana 3000:80        # http://localhost:3000"; echo "  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090"; echo "  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/prometheus-stack-kube-prom-alertmanager 9093:9093"; echo "  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/loki 3100:3100"; echo "  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/jaeger-query 16686:16686"; }
uninstall_all(){
  log_step "Uninstalling monitoring stack..."
  set +e
  kubectl delete ingress grafana -n "$MONITORING_NAMESPACE" --ignore-not-found
  helm uninstall prometheus-stack -n "$MONITORING_NAMESPACE"
  helm uninstall loki -n "$MONITORING_NAMESPACE"
  kubectl delete jaeger jaeger -n "$MONITORING_NAMESPACE" --ignore-not-found
  kubectl delete -n "$MONITORING_NAMESPACE" secret grafana-admin-secret grafana-basic-auth --ignore-not-found
  kubectl delete cm grafana-datasources grafana-dashboard-openemr -n "$MONITORING_NAMESPACE" --ignore-not-found
  kubectl delete secret alertmanager-config -n "$MONITORING_NAMESPACE" --ignore-not-found
  kubectl delete ns "$OBSERVABILITY_NAMESPACE" --ignore-not-found
  kubectl delete ns "$MONITORING_NAMESPACE" --ignore-not-found
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
      local pw; pw="$(generate_secure_password)"
      create_grafana_secret "$pw"
      write_credentials_file "$pw"
      create_values_file
      install_prometheus_stack "$VALUES_FILE"
      install_loki_stack
      install_jaeger                      # <-- cert-manager auto-installed & pinned here
      cleanup_duplicate_pods
      create_additional_hpa
      create_grafana_datasources
      create_alertmanager_config
      create_openemr_monitoring
      apply_network_policies || log_warn "NetworkPolicies failed (continuing)"
      create_grafana_ingress
      verify_installation
      verify_openemr_monitoring
      ;;
    verify)
      verify_installation
      verify_openemr_monitoring
      ;;
    status)
      kubectl get pods,svc,ingress -n "$MONITORING_NAMESPACE" || true
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
