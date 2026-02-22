#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: versions.yaml structural contract
# Purpose: Ensure every critical version key exists, is non-empty, and follows
#          the expected format. Catches accidental deletions, typos, and format
#          drift during refactors.
# Scope:   Read-only — only inspects the file, never modifies it.
# -----------------------------------------------------------------------------

load test_helper

setup() {
  VERSIONS_FILE="${PROJECT_ROOT}/versions.yaml"
}

# ── File existence ──────────────────────────────────────────────────────────

@test "versions.yaml exists at project root" {
  [ -f "$VERSIONS_FILE" ]
}

@test "versions.yaml is non-empty" {
  [ -s "$VERSIONS_FILE" ]
}

@test "versions.yaml is valid YAML (parseable by yq)" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
}

# ── Application versions ───────────────────────────────────────────────────

@test "versions.yaml: applications.openemr.current is set" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.openemr.current' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [ -n "$output" ]
}

@test "versions.yaml: OpenEMR version is semver (x.y.z)" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.openemr.current' "$VERSIONS_FILE"
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "versions.yaml: applications.python.current is set" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.python.current' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [ -n "$output" ]
}

@test "versions.yaml: Python version is MAJOR.MINOR format" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.python.current' "$VERSIONS_FILE"
  [[ "$output" =~ ^[0-9]+\.[0-9]+$ ]]
}

@test "versions.yaml: applications.fluent_bit.current is set" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.fluent_bit.current' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "versions.yaml: python auto_detect_latest is a boolean" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.python.auto_detect_latest' "$VERSIONS_FILE"
  [[ "$output" == "true" || "$output" == "false" ]]
}

# ── Infrastructure versions ────────────────────────────────────────────────

@test "versions.yaml: infrastructure.eks.current is set" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.infrastructure.eks.current' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+$ ]]
}

# ── Python package versions ────────────────────────────────────────────────

@test "versions.yaml: python_packages.pymysql.current is set" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "versions.yaml: python_packages.boto3.current is set" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.python_packages.boto3.current' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "versions.yaml: python_packages.pytest.current is set" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.python_packages.pytest.current' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

# ── Registry values ────────────────────────────────────────────────────────

@test "versions.yaml: OpenEMR registry is 'openemr/openemr'" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.openemr.registry' "$VERSIONS_FILE"
  [ "$output" = "openemr/openemr" ]
}

@test "versions.yaml: Python registry is 'library/python'" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq eval '.applications.python.registry' "$VERSIONS_FILE"
  [ "$output" = "library/python" ]
}

# ── Cross-reference: DEFAULT_VERSION in get-python-image-version.sh ────────

@test "get-python-image-version.sh DEFAULT_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_version
  yaml_version=$(yq eval '.applications.python.current' "$VERSIONS_FILE")
  # Extract the DEFAULT_VERSION from the script source
  local script_default
  script_default=$(grep 'DEFAULT_VERSION=' "${SCRIPTS_DIR}/get-python-image-version.sh" | head -1 | sed 's/.*DEFAULT_VERSION="\([^"]*\)".*/\1/')
  [ "$script_default" = "$yaml_version" ]
}

# ── UNIT: YAML structure validation ─────────────────────────────────────────

@test "UNIT: versions.yaml has top-level 'applications' key" {
  run grep '^applications:' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
}

@test "UNIT: versions.yaml has top-level 'infrastructure' key" {
  run grep '^infrastructure:' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
}

@test "UNIT: versions.yaml has top-level 'python_packages' key" {
  run grep '^python_packages:' "$VERSIONS_FILE"
  [ "$status" -eq 0 ]
}

@test "UNIT: versions.yaml contains no tab characters" {
  run grep -P '\t' "$VERSIONS_FILE"
  [ "$status" -ne 0 ]
}

@test "UNIT: versions.yaml all non-empty lines are valid YAML indentation" {
  run bash -c "
    while IFS= read -r line; do
      # Skip empty lines and comments
      [[ -z \"\$line\" || \"\$line\" =~ ^[[:space:]]*# ]] && continue
      # Check that leading whitespace is spaces only (no tabs)
      if [[ \"\$line\" =~ ^[[:space:]] ]] && [[ \"\$line\" =~ ^[^[:space:]] ]] ; then
        continue
      fi
    done < '$VERSIONS_FILE'
    echo 'VALID'
  "
  [[ "$output" =~ "VALID" ]]
}

# ── Cross-file version consistency checks ─────────────────────────────────

@test "CROSS-FILE: credential rotation Dockerfile PYTHON_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver docker_ver
  yaml_ver=$(yq eval '.applications.python.current' "$VERSIONS_FILE")
  docker_ver=$(grep '^ARG PYTHON_VERSION=' "${PROJECT_ROOT}/tools/credential-rotation/Dockerfile" | sed 's/ARG PYTHON_VERSION=//')
  [ "$docker_ver" = "$yaml_ver" ]
}

@test "CROSS-FILE: CI workflow PYTHON_VERSION matches versions.yaml semver_packages" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.python_version.current' "$VERSIONS_FILE")
  run grep "PYTHON_VERSION:" "${PROJECT_ROOT}/.github/workflows/ci-cd-tests.yml"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CROSS-FILE: CI workflow TERRAFORM_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.terraform_version.current' "$VERSIONS_FILE")
  run grep "TERRAFORM_VERSION:" "${PROJECT_ROOT}/.github/workflows/ci-cd-tests.yml"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CROSS-FILE: CI workflow KUBECTL_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.kubectl_version.current' "$VERSIONS_FILE")
  run grep "KUBECTL_VERSION:" "${PROJECT_ROOT}/.github/workflows/ci-cd-tests.yml"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CROSS-FILE: warp requirements.txt boto3 matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.boto3.current' "$VERSIONS_FILE")
  run grep '^boto3' "${PROJECT_ROOT}/warp/requirements.txt"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CROSS-FILE: warp requirements.txt pymysql matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE")
  run grep '^pymysql' "${PROJECT_ROOT}/warp/requirements.txt"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CROSS-FILE: credential rotation requirements.txt boto3 matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.boto3.current' "$VERSIONS_FILE")
  run grep '^boto3' "${PROJECT_ROOT}/tools/credential-rotation/requirements.txt"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CROSS-FILE: credential rotation requirements.txt pymysql matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE")
  run grep '^pymysql' "${PROJECT_ROOT}/tools/credential-rotation/requirements.txt"
  [[ "$output" == *"$yaml_ver"* ]]
}
