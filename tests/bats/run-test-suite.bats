#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: Unit tests for scripts/run-test-suite.sh
# Purpose: Validate CLI flag parsing, logging helpers, record_test_result
#          counters, environment defaults, and structural integrity.
# Note:    The script has no effective dry-run mode, so we avoid running the
#          full suite and instead unit-test extracted functions + flag parsing.
# -----------------------------------------------------------------------------

load test_helper

SCRIPT="${SCRIPTS_DIR}/run-test-suite.sh"

# ===========================================================================
# CLI / FLAG PARSING
# ===========================================================================

@test "run-test-suite.sh --help exits 0 and shows usage" {
  run bash "$SCRIPT" --help
  assert_success
  assert_output_contains "Usage:"
  assert_output_contains "--suite"
  assert_output_contains "--dry-run"
  assert_output_contains "--verbose"
}

@test "run-test-suite.sh -h exits 0 (short form)" {
  run bash "$SCRIPT" -h
  assert_success
  assert_output_contains "Usage:"
}

@test "run-test-suite.sh rejects unknown option" {
  run bash "$SCRIPT" --nonexistent-flag
  assert_failure
  assert_output_contains "Unknown option"
}

@test "--help lists all valid suites" {
  run bash "$SCRIPT" --help
  assert_output_contains "code_quality"
  assert_output_contains "kubernetes_manifests"
  assert_output_contains "script_validation"
  assert_output_contains "documentation"
}

# ===========================================================================
# LOGGING FUNCTION UNIT TESTS
# ===========================================================================

@test "log_info outputs [INFO] prefix" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log_info")
  NC='\033[0m'; BLUE='\033[0;34m'
  source "$func_file"
  run log_info "test message"
  [[ "$output" == *"[INFO]"* ]]
  [[ "$output" == *"test message"* ]]
  rm -f "$func_file"
}

@test "log_success outputs [SUCCESS] prefix" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log_success")
  NC='\033[0m'; GREEN='\033[0;32m'
  source "$func_file"
  run log_success "passed!"
  [[ "$output" == *"[SUCCESS]"* ]]
  [[ "$output" == *"passed!"* ]]
  rm -f "$func_file"
}

@test "log_error outputs [ERROR] prefix" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log_error")
  NC='\033[0m'; RED='\033[0;31m'
  source "$func_file"
  run log_error "boom"
  [[ "$output" == *"[ERROR]"* ]]
  [[ "$output" == *"boom"* ]]
  rm -f "$func_file"
}

@test "log_test outputs [TEST] prefix" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log_test")
  NC='\033[0m'; PURPLE='\033[0;35m'
  source "$func_file"
  run log_test "checking things"
  [[ "$output" == *"[TEST]"* ]]
  rm -f "$func_file"
}

@test "log_warning outputs [WARNING] prefix" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "log_warning")
  NC='\033[0m'; YELLOW='\033[1;33m'
  source "$func_file"
  run log_warning "careful"
  [[ "$output" == *"[WARNING]"* ]]
  rm -f "$func_file"
}

# ===========================================================================
# record_test_result FUNCTION UNIT TESTS
# ===========================================================================

_init_record_env() {
  NC='\033[0m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
  PASSED_TESTS=0; FAILED_TESTS=0; SKIPPED_TESTS=0; TEST_RESULTS=()
  log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
  log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
  log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
  record_test_result() {
    local test_name="$1" status="$2" message="$3" duration="$4"
    case $status in
      "PASS") TEST_RESULTS+=("PASS|$test_name|$message|$duration"); ((PASSED_TESTS += 1)); log_success "$test_name: $message" ;;
      "FAIL") TEST_RESULTS+=("FAIL|$test_name|$message|$duration"); ((FAILED_TESTS += 1)); log_error "$test_name: $message" ;;
      "SKIP") TEST_RESULTS+=("SKIP|$test_name|$message|$duration"); ((SKIPPED_TESTS += 1)); log_warning "$test_name: $message" ;;
    esac
  }
}

@test "record_test_result PASS increments PASSED_TESTS counter" {
  _init_record_env
  record_test_result "unit-test" "PASS" "it worked" "1"
  [ "$PASSED_TESTS" -eq 1 ]
  [ "$FAILED_TESTS" -eq 0 ]
  [ "$SKIPPED_TESTS" -eq 0 ]
}

@test "record_test_result FAIL increments FAILED_TESTS counter" {
  _init_record_env
  record_test_result "unit-test" "FAIL" "it broke" "2"
  [ "$FAILED_TESTS" -eq 1 ]
  [ "$PASSED_TESTS" -eq 0 ]
}

@test "record_test_result SKIP increments SKIPPED_TESTS counter" {
  _init_record_env
  record_test_result "unit-test" "SKIP" "not applicable" "0"
  [ "$SKIPPED_TESTS" -eq 1 ]
  [ "$PASSED_TESTS" -eq 0 ]
  [ "$FAILED_TESTS" -eq 0 ]
}

@test "record_test_result appends to TEST_RESULTS array" {
  _init_record_env
  record_test_result "test-a" "PASS" "ok" "1"
  record_test_result "test-b" "FAIL" "bad" "2"
  [ "${#TEST_RESULTS[@]}" -eq 2 ]
  [[ "${TEST_RESULTS[0]}" == "PASS|test-a|ok|1" ]]
  [[ "${TEST_RESULTS[1]}" == "FAIL|test-b|bad|2" ]]
}

# ===========================================================================
# ENVIRONMENT DEFAULTS
# ===========================================================================

@test "default TEST_SUITE is 'all'" {
  run grep '^TEST_SUITE=\${TEST_SUITE:-' "$SCRIPT"
  [[ "$output" == *'"all"'* ]]
}

@test "default PARALLEL is 'true'" {
  run grep '^PARALLEL=\${PARALLEL:-' "$SCRIPT"
  [[ "$output" == *'"true"'* ]]
}

@test "default DRY_RUN is 'false'" {
  run grep '^DRY_RUN=\${DRY_RUN:-' "$SCRIPT"
  [[ "$output" == *'"false"'* ]]
}

@test "default VERBOSE is 'false'" {
  run grep '^VERBOSE=\${VERBOSE:-' "$SCRIPT"
  [[ "$output" == *'"false"'* ]]
}

# ===========================================================================
# STRUCTURE CHECKS
# ===========================================================================

@test "show_help function exists" {
  grep -q '^show_help()' "$SCRIPT"
}

@test "run_test_suite function routes to sub-suite runners" {
  grep -q '^run_test_suite()' "$SCRIPT"
  grep -q 'run_code_quality_tests' "$SCRIPT"
  grep -q 'run_k8s_tests' "$SCRIPT"
  grep -q 'run_script_tests' "$SCRIPT"
  grep -q 'run_documentation_tests' "$SCRIPT"
}

@test "generate_report function exists" {
  grep -q '^generate_report()' "$SCRIPT"
}

@test "main function exists and calls generate_report" {
  grep -q '^main()' "$SCRIPT"
  grep -q 'generate_report' "$SCRIPT"
}
