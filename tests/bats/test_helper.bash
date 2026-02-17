# =============================================================================
# BATS shared test helper
# Provides PROJECT_ROOT, SCRIPTS_DIR, script invocation helpers, function
# extraction utilities for unit-testing individual functions, temp fixture
# management, and assertions.
# =============================================================================

BATS_TEST_DIRNAME="${BATS_TEST_DIRNAME:-$(dirname "$BATS_TEST_FILENAME")}"
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
export SCRIPTS_DIR="${PROJECT_ROOT}/scripts"

# ---------------------------------------------------------------------------
# Script runners
# ---------------------------------------------------------------------------

# Run a script from scripts/ directory.
run_script() {
  local script="$1"; shift
  run bash "${SCRIPTS_DIR}/${script}" "$@"
}

# Run a script from an arbitrary directory relative to PROJECT_ROOT.
run_script_from() {
  local rel_dir="$1"; local script="$2"; shift 2
  run bash "${PROJECT_ROOT}/${rel_dir}/${script}" "$@"
}

# Run a script from scripts/ and capture only stdout (stderr suppressed).
run_script_stdout() {
  local script="$1"; shift
  run bash "${SCRIPTS_DIR}/${script}" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Function extraction — the core mechanism for unit-testing individual
# functions from production scripts.
#
# How it works:
#   1. extract_function reads a bash script and pulls out just the named
#      function body (from "funcname() {" through its closing "}").
#   2. The extracted function is written to a temp file that can be sourced
#      in a clean environment, free from the script's top-level set -e,
#      global side-effects, and main-execution code.
#   3. Tests source the temp file and call the function directly.
#
# Usage in a test:
#   setup() {
#     FUNC_FILE=$(extract_function "${SCRIPTS_DIR}/myscript.sh" "my_func")
#   }
#   teardown() { rm -f "$FUNC_FILE"; }
#
#   @test "my_func returns expected value" {
#     source "$FUNC_FILE"
#     run my_func "arg1"
#     [ "$output" = "expected" ]
#   }
# ---------------------------------------------------------------------------
extract_function() {
  local script="$1"
  local func_name="$2"
  local tmp
  tmp=$(mktemp "${BATS_TEST_TMPDIR:-/tmp}/bats_func_XXXXXX.bash")

  # Use awk to extract the function body.  Handles both "func() {" and
  # "func () {" styles.  Counts brace depth to find the matching close.
  awk -v fn="$func_name" '
    BEGIN { found=0; depth=0 }
    # Match function declaration
    $0 ~ "^" fn "[[:space:]]*\\(\\)" || $0 ~ "^function[[:space:]]+" fn {
      found=1
    }
    found {
      print
      # Count braces on this line
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        if (chars[i] == "{") depth++
        if (chars[i] == "}") depth--
      }
      if (depth == 0 && found) { found=0 }
    }
  ' "$script" > "$tmp"

  echo "$tmp"
}

# ---------------------------------------------------------------------------
# Temp fixture helpers — create disposable files/dirs for tests that need
# to control the filesystem (e.g., providing a custom versions.yaml).
# ---------------------------------------------------------------------------

# Create a temp directory that is automatically cleaned up by BATS.
# Returns the path.
make_temp_dir() {
  mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/bats_fixture_XXXXXX"
}

# Create a temp file with given content.  Returns the path.
# Usage: local f=$(make_temp_file "some content here")
make_temp_file() {
  local content="$1"
  local tmp
  tmp=$(mktemp "${BATS_TEST_TMPDIR:-/tmp}/bats_file_XXXXXX")
  printf '%s' "$content" > "$tmp"
  echo "$tmp"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_success() {
  if [ "$status" -ne 0 ]; then
    echo "Expected exit 0, got: $status"
    echo "Output: $output"
    return 1
  fi
}

assert_failure() {
  if [ "$status" -eq 0 ]; then
    echo "Expected non-zero exit, got: 0"
    echo "Output: $output"
    return 1
  fi
}

assert_output_contains() {
  local expected="$1"
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected output to contain: $expected"
    echo "Actual output: $output"
    return 1
  fi
}

assert_output_regex() {
  local pattern="$1"
  if ! [[ "$output" =~ $pattern ]]; then
    echo "Output did not match pattern: $pattern"
    echo "Output: $output"
    return 1
  fi
}
