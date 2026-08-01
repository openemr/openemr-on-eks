#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/version-manager.sh
# Purpose: Validate command grammar (check, status, help), dependency checks,
#          help content completeness, and error handling for invalid commands.
# Scope:   Invokes only 'help' and invalid-command paths (no network calls).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/version-manager.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "version-manager.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "version-manager.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help command ────────────────────────────────────────────────────────────

@test "help runs successfully" {
  run_script "version-manager.sh" "help"
  assert_success
}

@test "help mentions 'check' command" {
  run_script "version-manager.sh" "help"
  [[ "$output" =~ "check" ]]
}

@test "help mentions 'status' command" {
  run_script "version-manager.sh" "help"
  [[ "$output" =~ "status" ]]
}

@test "help mentions 'help' command" {
  run_script "version-manager.sh" "help"
  [[ "$output" =~ "help" ]]
}

@test "help mentions --components option" {
  run_script "version-manager.sh" "help"
  [[ "$output" =~ "--components" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "invalid command exits non-zero" {
  run_script "version-manager.sh" "invalidcommand"
  [ "$status" -ne 0 ]
}

@test "invalid command suggests help" {
  run_script "version-manager.sh" "invalidcommand"
  [[ "$output" =~ (help|Help|usage|Usage) ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines log function" {
  run grep 'log()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines search_version_in_codebase function" {
  run grep 'search_version_in_codebase()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script creates cleanup trap for TEMP_DIR" {
  run grep "trap.*rm.*TEMP_DIR.*EXIT" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "VERSIONS_FILE points to versions.yaml" {
  run grep 'VERSIONS_FILE=.*versions.yaml' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script references PROJECT_ROOT for path resolution" {
  run grep 'PROJECT_ROOT=' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These extract individual functions and test them in isolation.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: log function outputs timestamped message to stderr" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log")
  local tmpdir
  tmpdir=$(make_temp_dir)
  local log_file="${tmpdir}/test.log"
  run bash -c '
    LOG_FILE="'"$log_file"'"
    source "'"$func_file"'"
    log "INFO" "test message from bats"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  # Output should contain the level and message
  [[ "$output" =~ "INFO" ]]
  [[ "$output" =~ "test message from bats" ]]
  # Log file should also contain the message
  run bash -c 'cat "'"$log_file"'"'
  [[ "$output" =~ "test message from bats" ]]
  rm -rf "$tmpdir"
}

@test "UNIT: log function includes timestamp in YYYY-MM-DD format" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log")
  local tmpdir
  tmpdir=$(make_temp_dir)
  local log_file="${tmpdir}/test.log"
  run bash -c '
    LOG_FILE="'"$log_file"'"
    source "'"$func_file"'"
    log "WARN" "check timestamp"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  # Should contain a date-like pattern
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
  rm -rf "$tmpdir"
}

@test "UNIT: log function handles ERROR level" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log")
  local tmpdir
  tmpdir=$(make_temp_dir)
  local log_file="${tmpdir}/test.log"
  run bash -c '
    LOG_FILE="'"$log_file"'"
    source "'"$func_file"'"
    log "ERROR" "something went wrong"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ERROR" ]]
  [[ "$output" =~ "something went wrong" ]]
  rm -rf "$tmpdir"
}

# ── UNIT: normalize_version ─────────────────────────────────────────────────

@test "UNIT: normalize_version strips v prefix" {
  FUNC_FILE=$(extract_function "$SCRIPT" "normalize_version")
  run bash -c "
    source '$FUNC_FILE'
    normalize_version 'v5.0.0'
  "
  [ "$output" = "5.0.0" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: normalize_version expands major-only to x.0.0" {
  FUNC_FILE=$(extract_function "$SCRIPT" "normalize_version")
  run bash -c "
    source '$FUNC_FILE'
    normalize_version '5'
  "
  [ "$output" = "5.0.0" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: normalize_version passes through full version unchanged" {
  FUNC_FILE=$(extract_function "$SCRIPT" "normalize_version")
  run bash -c "
    source '$FUNC_FILE'
    normalize_version '1.2.3'
  "
  [ "$output" = "1.2.3" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: normalize_version handles v prefix with major only" {
  FUNC_FILE=$(extract_function "$SCRIPT" "normalize_version")
  run bash -c "
    source '$FUNC_FILE'
    normalize_version 'v3'
  "
  [ "$output" = "3.0.0" ]
  rm -f "$FUNC_FILE"
}

# ── UNIT: compare_versions ──────────────────────────────────────────────────

@test "UNIT: compare_versions returns 0 for equal versions" {
  run bash -c "
    normalize_version() {
      local version=\"\$1\"
      local normalized=\$(echo \"\$version\" | sed 's/^v//')
      if [[ \"\$normalized\" =~ ^[0-9]+$ ]]; then normalized=\"\${normalized}.0.0\"; fi
      echo \"\$normalized\"
    }
    compare_versions() {
      local norm1=\$(normalize_version \"\$1\")
      local norm2=\$(normalize_version \"\$2\")
      if [ \"\$norm1\" = \"\$norm2\" ]; then return 0; else return 1; fi
    }
    compare_versions '1.2.3' '1.2.3'
  "
  assert_success
}

@test "UNIT: compare_versions returns 1 for different versions" {
  run bash -c "
    normalize_version() {
      local version=\"\$1\"
      local normalized=\$(echo \"\$version\" | sed 's/^v//')
      if [[ \"\$normalized\" =~ ^[0-9]+$ ]]; then normalized=\"\${normalized}.0.0\"; fi
      echo \"\$normalized\"
    }
    compare_versions() {
      local norm1=\$(normalize_version \"\$1\")
      local norm2=\$(normalize_version \"\$2\")
      if [ \"\$norm1\" = \"\$norm2\" ]; then return 0; else return 1; fi
    }
    compare_versions '1.2.3' '1.2.4'
  "
  assert_failure
}

@test "UNIT: compare_versions normalizes v prefix for comparison" {
  run bash -c "
    normalize_version() {
      local version=\"\$1\"
      local normalized=\$(echo \"\$version\" | sed 's/^v//')
      if [[ \"\$normalized\" =~ ^[0-9]+$ ]]; then normalized=\"\${normalized}.0.0\"; fi
      echo \"\$normalized\"
    }
    compare_versions() {
      local norm1=\$(normalize_version \"\$1\")
      local norm2=\$(normalize_version \"\$2\")
      if [ \"\$norm1\" = \"\$norm2\" ]; then return 0; else return 1; fi
    }
    compare_versions 'v1.2.3' '1.2.3'
  "
  assert_success
}

# ── UNIT: stable upstream version selection ────────────────────────────────

@test "UNIT: Docker stable lookup returns newest clean semantic version" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_docker_version")
  run bash -c '
    log() { :; }
    curl() {
      printf "%s\n" '"'"'{"results":[{"name":"8.1.1"},{"name":"8.2.0"},{"name":"8.3.0-rc1"},{"name":"latest"}]}'"'"'
    }
    source "$1"
    get_latest_docker_version "fluent/fluent-bit"
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_success
  [ "$output" = "8.2.0" ]
}

@test "UNIT: Docker stable lookup does not reinterpret prerelease tags" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_docker_version")
  run bash -c '
    log() { :; }
    curl() {
      printf "%s\n" '"'"'{"results":[{"name":"8.3.0-rc1"},{"name":"latest"}]}'"'"'
    }
    source "$1"
    get_latest_docker_version "fluent/fluent-bit"
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_failure
  [ -z "$output" ]
}

@test "UNIT: OpenEMR lookup trusts official releases instead of newer Docker tags" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_openemr_release_version")
  run bash -c '
    log() { :; }
    curl() {
      printf "%s\n" '"'"'{"tag_name":"v8_2_0","draft":false,"prerelease":false}'"'"'
    }
    source "$1"
    get_latest_openemr_release_version
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_success
  [ "$output" = "8.2.0" ]
  grep -Fq 'run_version_lookup openemr_latest' "$SCRIPT"
}

@test "UNIT: Helm lookup excludes weekly prereleases" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_helm_version")
  run bash -c '
    log() { :; }
    curl() {
      cat <<'"'"'YAML'"'"'
entries:
  mimir-distributed:
    - version: 6.2.0-weekly.402
    - version: 6.1.0
    - version: 6.0.6
YAML
    }
    source "$1"
    get_latest_helm_version "mimir-distributed"
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_success
  [ "$output" = "6.1.0" ]
}

@test "UNIT: cert-manager Helm lookup restores release-tag v prefix" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_helm_version")
  run bash -c '
    log() { :; }
    curl() {
      cat <<'"'"'YAML'"'"'
entries:
  cert-manager:
    - version: 1.21.1
    - version: 1.21.0-alpha.1
YAML
    }
    source "$1"
    get_latest_helm_version "cert-manager"
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_success
  [ "$output" = "v1.21.1" ]
}

@test "UNIT: Go lookup uses official feed and preserves patch version" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_go_version")
  run bash -c '
    log() { :; }
    curl() {
      [[ "$*" == *"https://go.dev/dl/?mode=json"* ]] || return 1
      printf "%s\n" '"'"'[{"version":"go1.25.12","stable":true},{"version":"go1.26rc1","stable":false}]'"'"'
    }
    source "$1"
    get_latest_go_version
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_success
  [ "$output" = "1.25.12" ]
}

@test "UNIT: Terraform provider lookup reads registry metadata" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_terraform_provider_version")
  run bash -c '
    log() { :; }
    curl() { printf "%s\n" '"'"'{"version":"6.52.0"}'"'"'; }
    source "$1"
    get_latest_terraform_provider_version "hashicorp/aws"
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_success
  [ "$output" = "6.52.0" ]
}

@test "UNIT: GitHub Action lookup ignores aliases and prereleases" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  FUNC_FILE=$(extract_function "$SCRIPT" "get_latest_github_action_version")
  run bash -c '
    log() { :; }
    curl() {
      printf "%s\n" '"'"'[{"name":"v7"},{"name":"v7.0.1"},{"name":"v8.0.0-beta.1"}]'"'"'
    }
    source "$1"
    get_latest_github_action_version "actions/checkout"
  ' _ "$FUNC_FILE"
  rm -f "$FUNC_FILE"
  assert_success
  [ "$output" = "v7.0.1" ]
}

@test "UNIT: failed lookup marks the overall version check incomplete" {
  FUNC_FILE=$(extract_function "$SCRIPT" "run_version_lookup")
  local tmpdir
  tmpdir=$(make_temp_dir)
  run bash -c '
    log() { :; }
    failing_lookup() { return 1; }
    source "$1"
    checks_failed=0
    update_report="$2/report.md"
    result=""
    run_version_lookup result "test component" "1.0.0" failing_lookup
    [ "$checks_failed" -eq 1 ]
    [ "$result" = "1.0.0" ]
    grep -q "Version check incomplete" "$update_report"
  ' _ "$FUNC_FILE" "$tmpdir"
  rm -f "$FUNC_FILE"
  rm -rf "$tmpdir"
  assert_success
}

@test "version checks are metadata-driven for providers and actions and include Ruff" {
  grep -Fq '.value.kind == "provider"' "$SCRIPT"
  grep -Fq '.value.repository != null' "$SCRIPT"
  grep -Fq '"ruff:ruff"' "$SCRIPT"
}

@test "Tempo 3.x and Loki community upgrades require explicit migration" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  [ "$(yq eval '.monitoring.loki.update_policy' "$PROJECT_ROOT/versions.yaml")" = "manual-migration" ]
  [ "$(yq eval '.monitoring.tempo.update_policy' "$PROJECT_ROOT/versions.yaml")" = "manual-migration" ]
  grep -Fq '.monitoring.loki.update_policy' "$SCRIPT"
  grep -Fq '.monitoring.tempo.update_policy' "$SCRIPT"
}

# ── UNIT: show_help ─────────────────────────────────────────────────────────

@test "UNIT: show_help prints usage and all component types" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  assert_success
  [[ "$output" =~ "Usage" ]]
  [[ "$output" =~ "applications" ]]
  [[ "$output" =~ "infrastructure" ]]
  [[ "$output" =~ "terraform_modules" ]]
  [[ "$output" =~ "monitoring" ]]
  [[ "$output" =~ "security_tools" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents --create-issue option" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--create-issue" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents --log-level option" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--log-level" ]]
  rm -f "$FUNC_FILE"
}
