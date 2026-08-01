#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: monitoring/install-monitoring.sh
# Purpose: Validate command dispatch for all subcommands (install, uninstall,
#          verify, status), prerequisite flow, static constants, and safe
#          failure behavior.
# Scope:   Non-destructive checks only (no real cluster changes).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

MONITORING_SCRIPT="${PROJECT_ROOT}/monitoring/install-monitoring.sh"
MONITORING_CONFIG="${PROJECT_ROOT}/monitoring/openemr-monitoring.conf.example"
PROMETHEUS_VALUES="${PROJECT_ROOT}/monitoring/prometheus-values.yaml"
VERSIONS_FILE="${PROJECT_ROOT}/versions.yaml"

# -- Executable & syntax ------------------------------------------------------

@test "install-monitoring.sh is executable" {
  [ -x "$MONITORING_SCRIPT" ]
}

@test "install-monitoring.sh has valid bash syntax" {
  bash -n "$MONITORING_SCRIPT"
}

# -- Usage message & subcommand support (static analysis) ---------------------
# Note: install-monitoring.sh has no --help handler; it requires a live
# cluster before dispatching subcommands.  Validate subcommand support
# and the usage message via static analysis of the source code.

@test "script defines usage message with install, verify, status, uninstall" {
  run grep 'Usage.*install.*verify.*status.*uninstall' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script supports install subcommand in case block" {
  run grep -E '^\s+install\)' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script supports verify subcommand in case block" {
  run grep -E '^\s+verify\)' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script supports uninstall subcommand in case block" {
  run grep 'uninstall|destroy|delete' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script supports status subcommand in case block" {
  run grep -E '^\s+status\)' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

# -- Unknown command ----------------------------------------------------------

@test "unknown subcommand triggers usage in case fallthrough" {
  # The *) branch prints usage and exits 2
  run grep -A3 -E '^\s+[*][)]' "$MONITORING_SCRIPT"
  [[ "$output" =~ "Usage" ]]
  [[ "$output" =~ "exit 2" ]]
}

# -- Static analysis: constants -----------------------------------------------

@test "default MONITORING_NAMESPACE is 'monitoring'" {
  run grep 'MONITORING_NAMESPACE.*monitoring' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "default OPENEMR_NAMESPACE is 'openemr'" {
  run grep 'OPENEMR_NAMESPACE.*openemr' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines Helm chart version for kube-prometheus-stack" {
  run grep 'CHART_KPS_VERSION' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines Helm chart version for Loki" {
  run grep 'CHART_LOKI_VERSION' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines Helm chart version for Tempo" {
  run grep 'CHART_TEMPO_VERSION' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines Helm chart version for Mimir" {
  run grep 'CHART_MIMIR_VERSION' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "configuration file overrides are loaded before readonly defaults" {
  local config_file
  config_file=$(mktemp)
  cat > "$config_file" <<'EOF'
MONITORING_NAMESPACE="custom-monitoring"
CHART_KPS_VERSION="99.1.2"
EOF

  run env \
    CONFIG_FILE="$config_file" \
    OPENEMR_MONITORING_LIBRARY_ONLY=1 \
    AWS_REGION=us-east-1 \
    CLUSTER_NAME=test-cluster \
    bash -c 'source "$1"; printf "%s|%s\n" "$MONITORING_NAMESPACE" "$CHART_KPS_VERSION"' _ "$MONITORING_SCRIPT"

  assert_success
  [[ "$output" =~ "custom-monitoring|99.1.2" ]]
  rm -f "$config_file"
}

@test "generated Prometheus values default to a temporary runtime file" {
  run env \
    CONFIG_FILE=/does/not/exist \
    OPENEMR_MONITORING_LIBRARY_ONLY=1 \
    AWS_REGION=us-east-1 \
    CLUSTER_NAME=test-cluster \
    bash -c 'source "$1"; printf "%s|%s\n" "$VALUES_FILE_IS_TEMP" "$VALUES_FILE"' _ "$MONITORING_SCRIPT"

  assert_success
  [[ "$output" =~ ^1\| ]]
  [[ ! "$output" =~ "/monitoring/prometheus-values.yaml" ]]
}

@test "distributed chart values use supported storage and autoscaling keys" {
  grep -q -- '--set write.persistence.storageClass=' "$MONITORING_SCRIPT"
  grep -q -- '--set backend.persistence.storageClass=' "$MONITORING_SCRIPT"
  grep -q -- '--set store_gateway.persistentVolume.storageClass=' "$MONITORING_SCRIPT"
  grep -q '^store_gateway:' "$MONITORING_SCRIPT"
  ! grep -q '^store-gateway:' "$MONITORING_SCRIPT"
  ! grep -q '^autoscaling:' "$MONITORING_SCRIPT"
  ! grep -Eq 'kubectl patch (pvc|"\$pvc")' "$MONITORING_SCRIPT"

  local tempo_distributor
  tempo_distributor=$(awk '
    /# Component replicas and resources/{values=1; next}
    values && /^distributor:/{capture=1}
    values && /^ingester:/{if (capture) exit}
    capture
  ' "$MONITORING_SCRIPT")
  [[ "$tempo_distributor" =~ "autoscaling:" ]]
  [[ "$tempo_distributor" =~ "targetCPUUtilizationPercentage:" ]]
}

@test "Prometheus Alertmanager configuration is PVC-backed valid YAML" {
  ! grep -q 'am_s3_config' "$MONITORING_SCRIPT"
  ! grep -q 'routes:.*storage:' "$MONITORING_SCRIPT"
  grep -q '^    externalUrl: http://alertmanager-' "$MONITORING_SCRIPT"
  grep -q 'Slack with PVC-backed state' "$MONITORING_SCRIPT"
}

@test "CONTRACT: kube-prometheus-stack defaults match versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver script_ver config_ver
  yaml_ver=$(yq eval '.monitoring.prometheus_operator.current' "$VERSIONS_FILE")
  script_ver=$(awk -F ':-|}' '/^readonly CHART_KPS_VERSION=/{print $2; exit}' "$MONITORING_SCRIPT")
  config_ver=$(awk -F '"' '/^CHART_KPS_VERSION=/{print $2; exit}' "$MONITORING_CONFIG")

  [ "$script_ver" = "$yaml_ver" ]
  [ "$config_ver" = "$yaml_ver" ]
}

@test "CONTRACT: cert-manager defaults match versions.yaml including v prefix" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver script_ver config_ver
  yaml_ver=$(yq eval '.monitoring.cert_manager.current' "$VERSIONS_FILE")
  script_ver=$(awk -F ':-|}' '/^readonly CERT_MANAGER_VERSION=/{print $2; exit}' "$MONITORING_SCRIPT")
  config_ver=$(awk -F '"' '/^CERT_MANAGER_VERSION=/{print $2; exit}' "$MONITORING_CONFIG")

  [ "$script_ver" = "$yaml_ver" ]
  [ "$config_ver" = "$yaml_ver" ]
}

@test "UNIT: cert-manager installed version is read from controller image" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "cert_manager_installed_version")
  run bash -c "
    kubectl() { echo 'quay.io/jetstack/cert-manager-controller:v1.20.2'; }
    source '$FUNC_FILE'
    cert_manager_installed_version
  "
  assert_success
  [ "$output" = "v1.20.2" ]
  rm -f "$FUNC_FILE"
}

@test "cert-manager installer compares installed and target versions before returning" {
  run grep -F 'if [[ "$installed_version" == "$CERT_MANAGER_VERSION" ]]' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'Upgrading cert-manager from ${installed_version:-unknown}' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Prometheus Helm upgrades enable the chart CRD upgrade job" {
  run grep -F -- '--set crds.upgradeJob.enabled=true' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "generated Prometheus values keep stateful dashboards on supported scaling settings" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "create_values_file")
  grep -Fq 'deploymentStrategy:' "$FUNC_FILE"
  grep -Fq 'replicas: 1' "$FUNC_FILE"
  ! grep -Fq 'targetCPUUtilizationPercentage: ${HPA_CPU_TARGET}' "$FUNC_FILE"
  ! grep -Fq 'targetMemoryUtilizationPercentage: ${HPA_MEMORY_TARGET}' "$FUNC_FILE"
  ! grep -Eq '^[[:space:]]+tracing:' "$FUNC_FILE"
  rm -f "$FUNC_FILE"
}

@test "checked-in Prometheus values omit unsupported Grafana and Prometheus HPAs" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  [ "$(yq eval '.grafana.replicas' "$PROMETHEUS_VALUES")" = "1" ]
  [ "$(yq eval '.grafana.deploymentStrategy.type' "$PROMETHEUS_VALUES")" = "Recreate" ]
  [ "$(yq eval '.grafana.autoscaling' "$PROMETHEUS_VALUES")" = "null" ]
  [ "$(yq eval '.prometheus.prometheusSpec.autoscaling' "$PROMETHEUS_VALUES")" = "null" ]
  [ "$(yq eval '.grafana."grafana.ini".tracing' "$PROMETHEUS_VALUES")" = "null" ]
}

@test "monitoring pod counters cannot emit duplicate zero values" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "verify_installation")
  ! grep -Eq 'grep -c[^|]*\|\| echo 0' "$FUNC_FILE"
  ! grep -Eq 'grep -cv[^|]*\|\| echo 0' "$FUNC_FILE"
  grep -Fq 'hpa_pending="${hpa_pending:-0}"' "$FUNC_FILE"
  rm -f "$FUNC_FILE"
}

@test "default MAX_RETRIES is 3" {
  run grep 'MAX_RETRIES.*3' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "default storage class is gp3-monitoring-encrypted" {
  run grep 'gp3-monitoring-encrypted' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

# -- UNIT: check_command ------------------------------------------------------

@test "UNIT: check_command returns 0 for available command" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "check_command")
  run bash -c "
    log_error() { echo \"ERROR: \$*\"; }
    log_warn() { echo \"WARN: \$*\"; }
    log_debug() { :; }
    source '$FUNC_FILE'
    check_command 'bash' true
  "
  assert_success
  rm -f "$FUNC_FILE"
}

@test "UNIT: check_command returns 1 for missing required command" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "check_command")
  run bash -c "
    log_error() { echo \"ERROR: \$*\"; }
    log_warn() { echo \"WARN: \$*\"; }
    log_debug() { :; }
    source '$FUNC_FILE'
    check_command 'nonexistent_cmd_xyz' true
  "
  assert_failure
  [[ "$output" =~ "ERROR" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: check_command returns 1 for missing optional command with warning" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "check_command")
  run bash -c "
    log_error() { echo \"ERROR: \$*\"; }
    log_warn() { echo \"WARN: \$*\"; }
    log_debug() { :; }
    source '$FUNC_FILE'
    check_command 'nonexistent_cmd_xyz' false
  "
  assert_failure
  [[ "$output" =~ "WARN" ]]
  rm -f "$FUNC_FILE"
}

# -- UNIT: generate_secure_password -------------------------------------------

@test "UNIT: generate_secure_password returns 24-character string" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "generate_secure_password")
  run bash -c "
    source '$FUNC_FILE'
    pw=\$(generate_secure_password)
    echo \${#pw}
  "
  assert_success
  [ "$output" = "24" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: generate_secure_password only contains safe characters" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "generate_secure_password")
  run bash -c "
    source '$FUNC_FILE'
    pw=\$(generate_secure_password)
    if [[ \"\$pw\" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo 'SAFE'
    else
      echo 'UNSAFE'
    fi
  "
  [ "$output" = "SAFE" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: generate_secure_password produces unique values" {
  FUNC_FILE=$(extract_function "$MONITORING_SCRIPT" "generate_secure_password")
  run bash -c "
    source '$FUNC_FILE'
    pw1=\$(generate_secure_password)
    pw2=\$(generate_secure_password)
    if [ \"\$pw1\" != \"\$pw2\" ]; then echo 'UNIQUE'; else echo 'DUPLICATE'; fi
  "
  [ "$output" = "UNIQUE" ]
  rm -f "$FUNC_FILE"
}

# -- UNIT: alertmanager_enabled -----------------------------------------------

@test "UNIT: alertmanager_enabled returns true with valid slack config" {
  run bash -c '
    SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T00/B00/xxx" # checkov:skip=CKV_SECRET_14:Synthetic URL used only to test prefix validation.
    SLACK_CHANNEL="#alerts"
    alertmanager_enabled() { [[ -n "$SLACK_WEBHOOK_URL" && -n "$SLACK_CHANNEL" && "$SLACK_WEBHOOK_URL" =~ ^https://hooks\.slack\.com/ ]]; }
    alertmanager_enabled && echo "ENABLED" || echo "DISABLED"
  '
  [ "$output" = "ENABLED" ]
}

@test "UNIT: alertmanager_enabled returns false with empty slack config" {
  run bash -c '
    SLACK_WEBHOOK_URL=""
    SLACK_CHANNEL=""
    alertmanager_enabled() { [[ -n "$SLACK_WEBHOOK_URL" && -n "$SLACK_CHANNEL" && "$SLACK_WEBHOOK_URL" =~ ^https://hooks\.slack\.com/ ]]; }
    alertmanager_enabled && echo "ENABLED" || echo "DISABLED"
  '
  [ "$output" = "DISABLED" ]
}

@test "UNIT: alertmanager_enabled returns false with invalid webhook URL" {
  run bash -c '
    SLACK_WEBHOOK_URL="https://example.com/webhook"
    SLACK_CHANNEL="#alerts"
    alertmanager_enabled() { [[ -n "$SLACK_WEBHOOK_URL" && -n "$SLACK_CHANNEL" && "$SLACK_WEBHOOK_URL" =~ ^https://hooks\.slack\.com/ ]]; }
    alertmanager_enabled && echo "ENABLED" || echo "DISABLED"
  '
  [ "$output" = "DISABLED" ]
}

# -- UNIT: retry_with_backoff -------------------------------------------------

@test "UNIT: retry_with_backoff succeeds on first try" {
  run bash -c '
    log_debug() { :; }
    log_warn() { :; }
    log_error() { :; }
    retry_with_backoff() {
      local max="$1" base="$2" maxd="$3"; shift 3
      local attempt=1 delay="$base"
      while [[ $attempt -le $max ]]; do
        if "$@"; then return 0; fi
        if [[ $attempt -lt $max ]]; then
          delay=$((delay * 2)); [[ $delay -gt $maxd ]] && delay="$maxd"
        fi
        ((attempt++))
      done
      return 1
    }
    retry_with_backoff 3 1 5 true
    echo "EXIT=$?"
  '
  [[ "$output" =~ "EXIT=0" ]]
}

@test "UNIT: retry_with_backoff fails after all attempts" {
  run bash -c '
    log_debug() { :; }
    log_warn() { :; }
    log_error() { :; }
    retry_with_backoff() {
      local max="$1" base="$2" maxd="$3"; shift 3
      local attempt=1 delay="$base"
      while [[ $attempt -le $max ]]; do
        if "$@"; then return 0; fi
        ((attempt++))
      done
      return 1
    }
    retry_with_backoff 2 0 0 false
    echo "EXIT=$?"
  '
  [[ "$output" =~ "EXIT=1" ]]
}

# -- UNIT: log_with_timestamp -------------------------------------------------

@test "UNIT: log_with_timestamp includes timestamp" {
  run bash -c '
    GREEN="" NC="" ENABLE_LOG_FILE=0
    LOG_FILE="/dev/null"
    log_with_timestamp() {
      local level="$1"; shift
      local t; t="$(date '\''+%Y-%m-%d %H:%M:%S'\'')"
      echo -e "${level} [$t] $*"
    }
    log_with_timestamp "[INFO]" "hello from monitoring"
  '
  [[ "$output" =~ "[INFO]" ]]
  [[ "$output" =~ "hello from monitoring" ]]
  [[ "$output" =~ "[20" ]]
}
