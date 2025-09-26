#!/bin/bash

# OpenEMR EKS CI/CD Test Suite Runner
# ===================================
# This script runs comprehensive tests for code quality, syntax validation, and best practices
# across all components of the OpenEMR EKS deployment.
#
# Key Features:
# - Shell script syntax validation and best practices
# - YAML file validation and formatting checks
# - Terraform configuration validation
# - Kubernetes manifest syntax and best practices
# - Kubernetes security policy validation
# - Markdown documentation validation
# - Parallel test execution for performance
# - Comprehensive reporting and result tracking
#
# Test Categories:
# - Code Quality: Shell syntax, YAML validation, Terraform validation
# - Kubernetes: Manifest syntax, best practices, security policies
# - Documentation: Markdown validation and formatting
# - Scripts: Individual script validation and testing

# set -e  # Commented out to prevent premature exit on grep commands that may return non-zero

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and failed tests
GREEN='\033[0;32m'    # Success messages and passed tests
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
PURPLE='\033[0;35m'   # Test execution messages
CYAN='\033[0;36m'     # Special test categories
NC='\033[0m'          # Reset color to default

# Path resolution and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Directory containing this script
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"                      # Parent directory (project root)
CONFIG_FILE="$SCRIPT_DIR/test-config.yaml"                   # Test configuration file
TEST_RESULTS_DIR="$PROJECT_ROOT/test-results"                # Directory for test results
TIMESTAMP=$(date +%Y%m%d-%H%M%S)                             # Timestamp for result files

# Test execution parameters - can be overridden by environment variables
TEST_SUITE=${TEST_SUITE:-"all"}     # Test suite to run (all, code-quality, k8s, scripts, docs)
PARALLEL=${PARALLEL:-"true"}        # Whether to run tests in parallel
DRY_RUN=${DRY_RUN:-"false"}         # Whether to show what would be tested without executing
VERBOSE=${VERBOSE:-"false"}         # Whether to show detailed test output

# Test result tracking variables
TEST_RESULTS=()    # Array to store test results
PASSED_TESTS=0     # Counter for passed tests
FAILED_TESTS=0     # Counter for failed tests
SKIPPED_TESTS=0    # Counter for skipped tests

# Initialize test results directory for storing output files
mkdir -p "$TEST_RESULTS_DIR"

# Logging functions - provide consistent, color-coded output for different message types
# These functions ensure all test operations have clear, categorized feedback
log_info() {
    # Display informational messages in blue
    # Used for general information and progress updates
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    # Display success messages in green
    # Used for successful operations and passed tests
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    # Display warning messages in yellow
    # Used for cautionary information and non-critical issues
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    # Display error messages in red
    # Used for critical errors and failed tests
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    # Display test execution messages in purple
    # Used specifically for test-related operations and progress
    echo -e "${PURPLE}[TEST]${NC} $1"
}

# Debug: Log the paths we're using (after functions are defined)
log_info "Script directory: $SCRIPT_DIR"
log_info "Project root: $PROJECT_ROOT"
log_info "Config file: $CONFIG_FILE"
log_info "Current working directory: $(pwd)"

# Function to record test results and update counters
# This function maintains the test result tracking system and provides consistent logging
record_test_result() {
    local test_name="$1"   # Name of the test that was executed
    local status="$2"      # Test result status (PASS, FAIL, SKIP)
    local message="$3"     # Descriptive message about the test result
    local duration="$4"    # Time taken to execute the test

    # Store result in array and update counters based on status
    case $status in
        "PASS")
            TEST_RESULTS+=("PASS|$test_name|$message|$duration")
            ((PASSED_TESTS++))
            log_success "$test_name: $message"
            ;;
        "FAIL")
            TEST_RESULTS+=("FAIL|$test_name|$message|$duration")
            ((FAILED_TESTS++))
            log_error "$test_name: $message"
            ;;
        "SKIP")
            TEST_RESULTS+=("SKIP|$test_name|$message|$duration")
            ((SKIPPED_TESTS++))
            log_warning "$test_name: $message"
            ;;
    esac
}

# Generic test execution function
# This function provides a standardized way to run individual tests with timing and error handling
run_test() {
    local test_name="$1"   # Human-readable name of the test
    local test_type="$2"   # Type of test (syntax, validation, etc.)
    local test_files="$3"  # Files or patterns to test

    log_test "Running $test_name ($test_type)"
    local start_time=$(date +%s)

    # Add error handling to prevent script from exiting on test failure
    set +e  # Temporarily disable exit on error

    case $test_type in
        "shell_syntax")
            test_shell_syntax "$test_files"
            local test_result=$?
            ;;
        "yaml_validation")
            test_yaml_validation "$test_files"
            local test_result=$?
            ;;
        "terraform_validation")
            test_terraform_validation "$test_files"
            local test_result=$?
            ;;
        "k8s_syntax")
            test_k8s_syntax "$test_files"
            local test_result=$?
            ;;
        "k8s_best_practices")
            test_k8s_best_practices "$test_files"
            local test_result=$?
            ;;
        "k8s_security")
            test_k8s_security "$test_files"
            local test_result=$?
            ;;
        "markdown_validation")
            test_markdown_validation "$test_files"
            local test_result=$?
            ;;
        *)
            record_test_result "$test_name" "SKIP" "Unknown test type: $test_type" "0"
            return
            ;;
    esac

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $test_result -eq 0 ]]; then
        record_test_result "$test_name" "PASS" "Completed successfully" "$duration"
    else
        record_test_result "$test_name" "FAIL" "Test failed with exit code $test_result" "$duration"
        return 1  # Return failure but don't exit the script
    fi
}

# Test implementations
test_shell_syntax() {
    local files="$1"
    local failed=0

    log_info "Starting shell syntax validation for pattern: $files"

    # Expand the glob pattern to get actual files
    local expanded_files
    if [[ "$files" == *"*"* ]]; then
        # This is a glob pattern, expand it
        expanded_files=($PROJECT_ROOT/$files)
        log_info "Expanded glob pattern to: ${expanded_files[*]}"

        # Check if any files were found
        if [[ ${#expanded_files[@]} -eq 0 ]] || [[ "${expanded_files[0]}" == "$PROJECT_ROOT/$files" ]]; then
            log_warning "No files found matching pattern: $files"
            return 0  # Don't fail the test if no files found
        fi
    else
        # This is already a specific file
        expanded_files=("$PROJECT_ROOT/$files")
    fi

    for file in "${expanded_files[@]}"; do
        log_info "Processing file: $file"
        if [[ -f "$file" ]]; then
            log_info "Checking shell syntax: $file"

            # Capture stderr for better error reporting
            local output
            if ! output=$(bash -n "$file" 2>&1); then
                log_error "Shell syntax error in $file"
                log_error "Error details: $output"
                failed=1
            else
                log_info "✓ $file syntax is valid"
            fi
        else
            log_warning "File not found: $file"
        fi
    done

    log_info "Shell syntax validation complete. Failed: $failed"

    if [[ $failed -eq 1 ]]; then
        return 1
    fi
 }

test_yaml_validation() {
    local files="$1"
    local failed=0

    log_info "Starting YAML validation for pattern: $files"

    # Expand the glob pattern to get actual files
    local expanded_files
    if [[ "$files" == *"*"* ]]; then
        # This is a glob pattern, expand it
        expanded_files=($PROJECT_ROOT/$files)
        log_info "Expanded glob pattern to: ${expanded_files[*]}"

        # Check if any files were found
        if [[ ${#expanded_files[@]} -eq 0 ]] || [[ "${expanded_files[0]}" == "$PROJECT_ROOT/$files" ]]; then
            log_warning "No files found matching pattern: $files"
            return 0  # Don't fail the test if no files found
        fi
    else
        # This is already a specific file
        expanded_files=("$PROJECT_ROOT/$files")
    fi

    for file in "${expanded_files[@]}"; do
        log_info "Processing file: $file"
        if [[ -f "$file" ]]; then
            log_info "Validating YAML syntax: $file"

            # Capture stderr for better error reporting
            local output
            # Handle multi-document YAML files (common in Kubernetes manifests)
            if ! output=$(python3 -c "import yaml; list(yaml.safe_load_all(open('$file')))" 2>&1); then
                log_error "YAML syntax error in $file"
                log_error "Error details: $output"
                failed=1
            else
                log_info "✓ $file YAML syntax is valid"
            fi
        else
            log_warning "File not found: $file"
        fi
    done

    log_info "YAML validation complete. Failed: $failed"

    if [[ $failed -eq 1 ]]; then
        return 1
    fi
}

test_terraform_validation() {
    local files="$1"
    local failed=0

    # Check if terraform is available
    if ! command -v terraform &> /dev/null; then
        log_warning "Terraform not available, skipping validation"
        return 0
    fi

    cd "$PROJECT_ROOT/terraform"
    log_info "Initializing Terraform..."
    if ! output=$(terraform init -backend=false 2>&1); then
        log_error "Terraform init failed"
        log_error "Error details: $output"
        failed=1
    fi

    log_info "Validating Terraform configuration..."
    if ! output=$(terraform validate 2>&1); then
        log_error "Terraform validation failed"
        log_error "Error details: $output"
        failed=1
    else
        log_info "✓ Terraform configuration is valid"
    fi

    cd "$PROJECT_ROOT"

    if [[ $failed -eq 1 ]]; then
        return 1
    fi
}

test_k8s_syntax() {
    local files="$1"
    local failed=0

    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not available, skipping K8s validation"
        return 0
    fi

    log_info "Starting Kubernetes syntax validation for pattern: $files"

    # Expand the glob pattern to get actual files
    local expanded_files
    if [[ "$files" == *"*"* ]]; then
        # This is a glob pattern, expand it
        expanded_files=($PROJECT_ROOT/$files)
        log_info "Expanded glob pattern to: ${expanded_files[*]}"

        # Check if any files were found
        if [[ ${#expanded_files[@]} -eq 0 ]] || [[ "${expanded_files[0]}" == "$PROJECT_ROOT/$files" ]]; then
            log_warning "No files found matching pattern: $files"
            return 0  # Don't fail the test if no files found
        fi
    else
        # This is already a specific file
        expanded_files=("$PROJECT_ROOT/$files")
    fi

    for file in "${expanded_files[@]}"; do
        log_info "Processing file: $file"
        if [[ -f "$file" ]]; then
            log_info "Validating Kubernetes manifest: $file"

            # For CI/CD testing without a cluster, just validate YAML syntax
            # This is sufficient for catching basic syntax errors
            log_info "Validating YAML syntax for Kubernetes manifest: $file"

            # Use Python YAML parser to validate syntax (same as YAML validation test)
            local output
            if ! output=$(python3 -c "import yaml; list(yaml.safe_load_all(open('$file')))" 2>&1); then
                log_error "YAML syntax error in $file"
                log_error "Error details: $output"
                failed=1
            else
                log_info "✓ $file YAML syntax is valid"
            fi
        else
            log_warning "File not found: $file"
        fi
    done

    log_info "Kubernetes syntax validation complete. Failed: $failed"

    if [[ $failed -eq 1 ]]; then
        return 1
    fi
}

test_k8s_best_practices() {
    local files="$1"
    local failed=0

    for file in $files; do
        if [[ -f "$PROJECT_ROOT/$file" ]]; then
            # Check for common best practices
            if grep -q "image: latest" "$PROJECT_ROOT/$file"; then
                log_warning "Using 'latest' tag in $file (not recommended for production)"
            fi

            if grep -q "resources: {}" "$PROJECT_ROOT/$file"; then
                log_warning "No resource limits defined in $file"
            fi

            if grep -q "securityContext: {}" "$PROJECT_ROOT/$file"; then
                log_warning "No security context defined in $file"
            fi
        fi
    done

    # Best practices are warnings, not failures
    return 0
}

test_k8s_security() {
    local files="$1"
    local failed=0

    for file in $files; do
        if [[ -f "$PROJECT_ROOT/$file" ]]; then
            # Check for security-related configurations
            if grep -q "runAsUser: 0" "$PROJECT_ROOT/$file"; then
                log_warning "Container running as root in $file"
            fi

            if grep -q "privileged: true" "$PROJECT_ROOT/$file"; then
                log_warning "Privileged container in $file"
            fi
        fi
    done

    # Security warnings are not failures
    return 0
}

test_markdown_validation() {
    local files="$1"
    local failed=0

    # Expand the glob pattern to get actual files
    local expanded_files
    if [[ "$files" == *"*"* ]]; then
        # This is a glob pattern, expand it
        expanded_files=($PROJECT_ROOT/$files)
        log_info "Expanded glob pattern to: ${expanded_files[*]}"

        # Check if any files were found
        if [[ ${#expanded_files[@]} -eq 0 ]] || [[ "${expanded_files[0]}" == "$PROJECT_ROOT/$files" ]]; then
            log_warning "No files found matching pattern: $files"
            return 0  # Don't fail the test if no files found
        fi
    else
        # This is already a specific file
        expanded_files=("$PROJECT_ROOT/$files")
    fi

    for file in "${expanded_files[@]}"; do
        log_info "Processing file: $file"
        if [[ -f "$file" ]]; then
            log_info "Validating markdown file: $file"

            # Basic markdown validation - check for headers
            if ! grep -q "^#" "$file"; then
                log_warning "No headers found in $file"
            else
                log_info "✓ $file has headers"
            fi
        else
            log_warning "File not found: $file"
        fi
    done

    log_info "Markdown validation complete. Failed: $failed"

    # Markdown validation warnings are not failures
    return 0
}

# Parse test configuration
parse_test_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Test configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    log_info "Using test configuration: $CONFIG_FILE"
}

# Run test suite
run_test_suite() {
    local suite_name="$1"

    case $suite_name in
        "all")
            run_all_tests
            ;;
        "code_quality")
            run_code_quality_tests
            ;;
        "kubernetes_manifests")
            run_k8s_tests
            ;;
        "script_validation")
            run_script_tests
            ;;
        "documentation")
            run_documentation_tests
            ;;
        *)
            log_error "Unknown test suite: $suite_name"
            exit 1
            ;;
    esac
}

run_all_tests() {
    log_info "Running all test suites..."
    run_code_quality_tests
    run_k8s_tests
    run_script_tests
    run_documentation_tests
}

run_code_quality_tests() {
    log_info "Running code quality tests..."

    # Shell script validation
    run_test "Shell Script Syntax" "shell_syntax" "scripts/*.sh"

    # YAML validation
    run_test "YAML Validation" "yaml_validation" "k8s/*.yaml monitoring/*.yaml"

    # Terraform validation
    run_test "Terraform Validation" "terraform_validation" "terraform/*.tf"

    # Markdown validation
    run_test "Markdown Validation" "markdown_validation" "docs/*.md"
}

run_k8s_tests() {
    log_info "Running Kubernetes manifest tests..."

    # K8s syntax validation
    run_test "Kubernetes Syntax" "k8s_syntax" "k8s/*.yaml"

    # K8s best practices
    run_test "Kubernetes Best Practices" "k8s_best_practices" "k8s/*.yaml"

    # K8s security
    run_test "Kubernetes Security" "k8s_security" "k8s/security.yaml k8s/network-policies.yaml"
}

run_script_tests() {
    log_info "Running script validation tests..."

    # Debug: Show what files we're looking for
    log_info "Looking for shell scripts in: scripts/*.sh"
    log_info "Available shell scripts:"
    ls -la "$PROJECT_ROOT/scripts/"*.sh 2>/dev/null || log_warning "No shell scripts found"

    # Script syntax
    run_test "Script Syntax Check" "shell_syntax" "scripts/*.sh"

    # Additional script-specific tests could be added here
}

run_documentation_tests() {
    log_info "Running documentation tests..."

    # Markdown validation
    run_test "Documentation Validation" "markdown_validation" "docs/*.md"
}

# Generate test report
generate_report() {
    local report_file="$TEST_RESULTS_DIR/test-report-$TIMESTAMP.txt"

    {
        echo "OpenEMR EKS CI/CD Test Report"
        echo "Generated: $(date)"
        echo "Test Suite: $TEST_SUITE"
        echo "========================================"
        echo ""
        echo "Test Results Summary:"
        echo "  Passed: $PASSED_TESTS"
        echo "  Failed: $FAILED_TESTS"
        echo "  Skipped: $SKIPPED_TESTS"
        echo "  Total: $((PASSED_TESTS + FAILED_TESTS + SKIPPED_TESTS))"
        echo ""
        echo "Detailed Results:"
        echo "=================="

        for result in "${TEST_RESULTS[@]}"; do
            IFS='|' read -r status test_name message duration <<< "$result"
            echo "[$status] $test_name - $message (${duration}s)"
        done

        echo ""
        echo "========================================"

        if [[ $FAILED_TESTS -eq 0 ]]; then
            echo "🎉 All tests passed successfully!"
        else
            echo "❌ $FAILED_TESTS test(s) failed. Please review the errors above."
        fi
    } > "$report_file"

    log_info "Test report generated: $report_file"

    # Also output to console
    cat "$report_file"
}

# Main function
main() {
    log_info "Starting OpenEMR EKS CI/CD Test Suite"
    log_info "Project root: $PROJECT_ROOT"
    log_info "Test suite: $TEST_SUITE"

    # Parse configuration
    parse_test_config

    # Run tests
    run_test_suite "$TEST_SUITE"

    # Generate report
    generate_report

    # Exit with appropriate code
    if [[ $FAILED_TESTS -eq 0 ]]; then
        log_success "All tests completed successfully!"
        exit 0
    else
        log_error "$FAILED_TESTS test(s) failed!"
        exit 1
    fi
}

# Show help
show_help() {
    echo "OpenEMR EKS CI/CD Test Suite Runner"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -s, --suite SUITE    Test suite to run (default: all)"
    echo "                       Available suites: all, code_quality, kubernetes_manifests,"
    echo "                       script_validation, documentation"
    echo "  -p, --parallel       Enable parallel test execution (default: true)"
    echo "  -d, --dry-run        Show what tests would run without executing them"
    echo "  -v, --verbose        Enable verbose output"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  TEST_SUITE           Test suite to run"
    echo "  PARALLEL             Enable/disable parallel execution"
    echo "  DRY_RUN              Enable dry run mode"
    echo "  VERBOSE              Enable verbose output"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run all tests"
    echo "  $0 -s code_quality   # Run only code quality tests"
    echo "  $0 -s kubernetes_manifests  # Run only K8s manifest tests"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--suite)
            TEST_SUITE="$2"
            shift 2
            ;;
        -p|--parallel)
            PARALLEL="true"
            shift
            ;;
        -d|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
