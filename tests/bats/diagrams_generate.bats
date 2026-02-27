#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: diagrams/generate.sh
# Purpose: Validate the Terravision diagram generation wrapper — executable
#          flag, bash syntax, preflight checks, path handling, and the
#          .dot.png rename logic.
# Scope:   Non-destructive static checks only (no AWS credentials or
#          terravision install required).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

GENERATE_SCRIPT="${PROJECT_ROOT}/diagrams/generate.sh"

# -- Executable & syntax ------------------------------------------------------

@test "generate.sh is executable" {
  [ -x "$GENERATE_SCRIPT" ]
}

@test "generate.sh has valid bash syntax" {
  bash -n "$GENERATE_SCRIPT"
}

@test "generate.sh uses strict mode (set -euo pipefail)" {
  run grep 'set -euo pipefail' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

# -- Preflight checks (static analysis) --------------------------------------

@test "script checks for terravision command" {
  run grep 'terravision' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks for dot (graphviz) command" {
  run grep 'dot' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks for terraform command" {
  run grep 'terraform' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks for AWS credentials via aws sts" {
  run grep 'aws sts get-caller-identity' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script validates terraform directory exists" {
  run grep -E '\[ !? -d.*TERRAFORM_DIR' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

# -- Path handling ------------------------------------------------------------

@test "script resolves SCRIPT_DIR from BASH_SOURCE" {
  run grep 'BASH_SOURCE' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "TERRAFORM_DIR points to project-root/terraform" {
  run grep 'TERRAFORM_DIR.*PROJECT_ROOT.*terraform' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "OUTPUT_FILE is set inside the diagrams directory" {
  run grep 'OUTPUT_FILE.*SCRIPT_DIR.*architecture' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

# -- Terravision invocation ---------------------------------------------------

@test "script calls terravision draw with --source and --outfile" {
  run grep 'terravision draw.*--source.*--outfile' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

# -- Output rename logic ------------------------------------------------------

@test "script handles the .dot.png rename to .png" {
  run grep '\.dot\.png' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script verifies the final .png exists before declaring success" {
  run grep -c '\.png' "$GENERATE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

# -- Committed output ---------------------------------------------------------

@test "architecture.png exists in diagrams/" {
  [ -f "${PROJECT_ROOT}/diagrams/architecture.png" ]
}
