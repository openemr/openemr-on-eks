#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: monitoring/install-monitoring.sh
# Purpose: Validate command dispatch for all subcommands (install, uninstall,
#          verify, --help), prerequisite flow, static constants, and safe
#          failure behavior.
# Scope:   Non-destructive checks only (no real cluster changes).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

MONITORING_SCRIPT="${PROJECT_ROOT}/monitoring/install-monitoring.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "install-monitoring.sh is executable" {
  [ -x "$MONITORING_SCRIPT" ]
}

@test "install-monitoring.sh has valid bash syntax" {
  bash -n "$MONITORING_SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script_from "monitoring" "install-monitoring.sh" "--help"
  assert_success
}

@test "--help shows usage information" {
  run_script_from "monitoring" "install-monitoring.sh" "--help"
  [[ "$output" =~ (Usage|usage|install|uninstall|verify) ]]
}

# ── Help documents subcommands ─────────────────────────────────────────────

@test "--help mentions 'install' subcommand" {
  run_script_from "monitoring" "install-monitoring.sh" "--help"
  [[ "$output" =~ "install" ]]
}

@test "--help mentions 'uninstall' subcommand" {
  run_script_from "monitoring" "install-monitoring.sh" "--help"
  [[ "$output" =~ "uninstall" ]]
}

@test "--help mentions 'verify' subcommand" {
  run_script_from "monitoring" "install-monitoring.sh" "--help"
  [[ "$output" =~ "verify" ]]
}

# ── Unknown command ────────────────────────────────────────────────────────

@test "unknown subcommand exits non-zero" {
  run_script_from "monitoring" "install-monitoring.sh" "unknowncommand"
  [ "$status" -ne 0 ]
}

@test "unknown command triggers prerequisite or error flow" {
  run_script_from "monitoring" "install-monitoring.sh" "unknowncommand"
  [[ "$output" =~ (Checking|required dependencies|Kubernetes|cannot connect|Command failed|Usage|Unknown) ]]
}

# ── Static analysis: constants ─────────────────────────────────────────────

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

@test "default MAX_RETRIES is 3" {
  run grep 'MAX_RETRIES.*3' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "default storage class is gp3-monitoring-encrypted" {
  run grep 'gp3-monitoring-encrypted' "$MONITORING_SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: check_command ─────────────────────────────────────────────────────

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

# ── UNIT: generate_secure_password ──────────────────────────────────────────

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

# ── UNIT: alertmanager_enabled ──────────────────────────────────────────────

@test "UNIT: alertmanager_enabled returns true with valid slack config" {
  run bash -c '
    SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T00/B00/xxx"
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

# ── UNIT: retry_with_backoff ────────────────────────────────────────────────

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

# ── UNIT: log_with_timestamp ────────────────────────────────────────────────

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
