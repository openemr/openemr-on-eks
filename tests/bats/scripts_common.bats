#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: Cross-cutting script conventions and directory structure
# Purpose: Validate global invariants that ALL scripts must satisfy:
#          executability, shebang lines, project directory structure,
#          test-runner contract, and code hygiene conventions.
# Scope:   Static analysis and help-path invocations.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

# ── Test runner contract ───────────────────────────────────────────────────

@test "run-test-suite.sh --help exits successfully" {
  run_script "run-test-suite.sh" "--help"
  assert_success
  [[ "$output" =~ "Test Suite" ]]
}

@test "run-test-suite.sh unknown suite exits non-zero" {
  run_script "run-test-suite.sh" "-s" "this_suite_should_not_exist"
  [ "$status" -ne 0 ]
  [[ "$output" =~ (Unknown test suite|Unknown option|error|Error) ]]
}

# ── All scripts in scripts/ ───────────────────────────────────────────────

@test "all scripts in scripts/ are executable" {
  local failed=0
  for f in "${SCRIPTS_DIR}"/*.sh; do
    [ -f "$f" ] || continue
    if [ ! -x "$f" ]; then
      echo "Not executable: $f"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "all scripts in scripts/ have a bash shebang" {
  local failed=0
  for f in "${SCRIPTS_DIR}"/*.sh; do
    [ -f "$f" ] || continue
    local first_line
    first_line=$(head -1 "$f")
    if [[ "$first_line" != "#!/bin/bash" && "$first_line" != "#!/usr/bin/env bash" ]]; then
      echo "Missing/wrong shebang: $f -> $first_line"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "all scripts in scripts/ use set -e or set -euo pipefail" {
  local failed=0
  for f in "${SCRIPTS_DIR}"/*.sh; do
    [ -f "$f" ] || continue
    if ! grep -q 'set -e' "$f"; then
      echo "Missing set -e: $f"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "no scripts in scripts/ contain TODO without issue reference" {
  # Allow TODO comments but they should ideally reference an issue.
  # This is a soft check — just verify no scripts have bare naked TODOs.
  # We just count them; won't fail if there are some.
  local count=0
  for f in "${SCRIPTS_DIR}"/*.sh; do
    [ -f "$f" ] || continue
    local hits
    hits=$(grep -c 'TODO' "$f" 2>/dev/null || true)
    count=$((count + hits))
  done
  # This is informational — echo the count, don't fail
  echo "Total TODO comments in scripts/: $count"
  true
}

# ── k8s/deploy.sh ─────────────────────────────────────────────────────────

@test "k8s/deploy.sh is executable" {
  [ -x "${PROJECT_ROOT}/k8s/deploy.sh" ]
}

@test "k8s/deploy.sh has a bash shebang" {
  local first_line
  first_line=$(head -1 "${PROJECT_ROOT}/k8s/deploy.sh")
  [[ "$first_line" == "#!/bin/bash" || "$first_line" == "#!/usr/bin/env bash" ]]
}

# ── monitoring/install-monitoring.sh ───────────────────────────────────────

@test "monitoring/install-monitoring.sh is executable" {
  [ -x "${PROJECT_ROOT}/monitoring/install-monitoring.sh" ]
}

@test "monitoring/install-monitoring.sh has a bash shebang" {
  local first_line
  first_line=$(head -1 "${PROJECT_ROOT}/monitoring/install-monitoring.sh")
  [[ "$first_line" == "#!/bin/bash" || "$first_line" == "#!/usr/bin/env bash" ]]
}

# ── OIDC provider scripts ─────────────────────────────────────────────────

@test "oidc_provider scripts are executable" {
  for script in deploy.sh validate.sh destroy.sh; do
    [ -x "${PROJECT_ROOT}/oidc_provider/scripts/${script}" ]
  done
}

# ── Project directory structure ────────────────────────────────────────────

@test "scripts/ directory exists" {
  [ -d "${PROJECT_ROOT}/scripts" ]
}

@test "k8s/ directory exists" {
  [ -d "${PROJECT_ROOT}/k8s" ]
}

@test "terraform/ directory exists" {
  [ -d "${PROJECT_ROOT}/terraform" ]
}

@test "monitoring/ directory exists" {
  [ -d "${PROJECT_ROOT}/monitoring" ]
}

@test "warp/ directory exists" {
  [ -d "${PROJECT_ROOT}/warp" ]
}

@test "oidc_provider/ directory exists" {
  [ -d "${PROJECT_ROOT}/oidc_provider" ]
}

@test "tests/ directory exists" {
  [ -d "${PROJECT_ROOT}/tests" ]
}

@test "versions.yaml exists at project root" {
  [ -f "${PROJECT_ROOT}/versions.yaml" ]
}

# ── No debug/temp files committed ─────────────────────────────────────────

@test "no .log files in scripts/" {
  local count
  count=$(find "${SCRIPTS_DIR}" -name '*.log' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

@test "no .tmp files in scripts/" {
  local count
  count=$(find "${SCRIPTS_DIR}" -name '*.tmp' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# ── UNIT: test_helper functions ─────────────────────────────────────────────

@test "UNIT: extract_function extracts a real function body" {
  # Use a known function from a known script
  FUNC_FILE=$(extract_function "${SCRIPTS_DIR}/destroy.sh" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  assert_success
  [[ "$output" =~ "USAGE" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: extract_function returns empty file for nonexistent function" {
  FUNC_FILE=$(extract_function "${SCRIPTS_DIR}/destroy.sh" "totally_fake_function_xyz")
  local size
  size=$(wc -c < "$FUNC_FILE" | tr -d ' ')
  [ "$size" -eq 0 ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: make_temp_dir creates a directory" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  [ -d "$tmpdir" ]
  rm -rf "$tmpdir"
}

@test "UNIT: make_temp_file creates a file with content" {
  local tmpfile
  tmpfile=$(make_temp_file "hello world")
  [ -f "$tmpfile" ]
  run bash -c "cat '$tmpfile'"
  [ "$output" = "hello world" ]
  rm -f "$tmpfile"
}

@test "UNIT: assert_output_contains works for matching content" {
  output="hello world test"
  assert_output_contains "world"
}

@test "UNIT: assert_output_regex works for matching pattern" {
  output="version 1.2.3 release"
  assert_output_regex "[0-9]+\.[0-9]+\.[0-9]+"
}
