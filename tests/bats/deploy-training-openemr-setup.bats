#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/deploy-training-openemr-setup.sh
# Purpose: Validate CLI help contract, every documented flag, default dataset
#          configuration, skip-mode flags, and error handling.
# Scope:   Invokes only --help and invalid-option paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/deploy-training-openemr-setup.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "deploy-training-openemr-setup.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "deploy-training-openemr-setup.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  assert_success
}

@test "--help shows usage information" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ (Usage|USAGE|Options|options) ]]
}

# ── Help documents every flag ───────────────────────────────────────────────

@test "--help documents --cluster-name" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ "cluster-name" ]]
}

@test "--help documents --aws-region" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ "aws-region" ]]
}

@test "--help documents --s3-bucket" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ "s3-bucket" ]]
}

@test "--help documents --max-records" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ "max-records" ]]
}

@test "--help documents --use-default-dataset" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ "use-default-dataset" ]]
}

@test "--help documents --skip-terraform" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ "skip-terraform" ]]
}

@test "--help documents --skip-openemr" {
  run_script "deploy-training-openemr-setup.sh" "--help"
  [[ "$output" =~ "skip-openemr" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "deploy-training-openemr-setup.sh" "--invalid"
  [ "$status" -ne 0 ]
}

@test "unknown option suggests help" {
  run_script "deploy-training-openemr-setup.sh" "--invalid"
  [[ "$output" =~ (help|Usage|usage) ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DEFAULT_S3_BUCKET is synpuf-omop" {
  run grep 'DEFAULT_S3_BUCKET="synpuf-omop"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DEFAULT_S3_PREFIX is cmsdesynpuf1k" {
  run grep 'DEFAULT_S3_PREFIX="cmsdesynpuf1k"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "MAX_RECORDS defaults to 1000" {
  run grep 'MAX_RECORDS.*1000' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "NAMESPACE is set to 'openemr'" {
  run grep 'NAMESPACE="openemr"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: show_help ─────────────────────────────────────────────────────────

@test "UNIT: show_help prints usage information" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  assert_success
  [[ "$output" =~ "USAGE" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents all CLI flags" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--cluster-name" ]]
  [[ "$output" =~ "--aws-region" ]]
  [[ "$output" =~ "--s3-bucket" ]]
  [[ "$output" =~ "--max-records" ]]
  [[ "$output" =~ "--use-default-dataset" ]]
  [[ "$output" =~ "--skip-terraform" ]]
  [[ "$output" =~ "--skip-openemr" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help lists prerequisites" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "PREREQUISITES" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help includes example with --use-default-dataset" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--use-default-dataset" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: log functions ─────────────────────────────────────────────────────

@test "UNIT: log_info outputs message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_info")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_info 'training info'
  "
  [[ "$output" =~ "training info" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: get_aws_region ────────────────────────────────────────────────────

@test "UNIT: get_aws_region falls back to us-west-2 default" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "us-west-2" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: build_data_source ─────────────────────────────────────────────────

@test "UNIT: build_data_source constructs correct S3 path without prefix" {
  run bash -c '
    log_info() { :; }
    S3_BUCKET="my-training-bucket"
    S3_PREFIX=""
    DATA_SOURCE=""
    build_data_source() {
      if [ -n "$S3_PREFIX" ]; then
        S3_PREFIX=$(echo "$S3_PREFIX" | sed "s|^/||;s|/$||")
        DATA_SOURCE="s3://$S3_BUCKET/$S3_PREFIX/"
      else
        DATA_SOURCE="s3://$S3_BUCKET/"
      fi
    }
    build_data_source
    echo "$DATA_SOURCE"
  '
  [ "$output" = "s3://my-training-bucket/" ]
}

@test "UNIT: build_data_source constructs correct S3 path with prefix" {
  run bash -c '
    log_info() { :; }
    S3_BUCKET="my-training-bucket"
    S3_PREFIX="data/training"
    DATA_SOURCE=""
    build_data_source() {
      if [ -n "$S3_PREFIX" ]; then
        S3_PREFIX=$(echo "$S3_PREFIX" | sed "s|^/||;s|/$||")
        DATA_SOURCE="s3://$S3_BUCKET/$S3_PREFIX/"
      else
        DATA_SOURCE="s3://$S3_BUCKET/"
      fi
    }
    build_data_source
    echo "$DATA_SOURCE"
  '
  [ "$output" = "s3://my-training-bucket/data/training/" ]
}

@test "UNIT: build_data_source strips leading slash from prefix" {
  run bash -c '
    log_info() { :; }
    S3_BUCKET="my-bucket"
    S3_PREFIX="/leading/slash/"
    DATA_SOURCE=""
    build_data_source() {
      if [ -n "$S3_PREFIX" ]; then
        S3_PREFIX=$(echo "$S3_PREFIX" | sed "s|^/||;s|/$||")
        DATA_SOURCE="s3://$S3_BUCKET/$S3_PREFIX/"
      else
        DATA_SOURCE="s3://$S3_BUCKET/"
      fi
    }
    build_data_source
    echo "$DATA_SOURCE"
  '
  [ "$output" = "s3://my-bucket/leading/slash/" ]
}

# ── UNIT: additional log functions ──────────────────────────────────────────

@test "UNIT: log_success outputs message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_success")
  run bash -c "
    GREEN='' NC=''
    source '$FUNC_FILE'
    log_success 'training deployed'
  "
  [[ "$output" =~ "training deployed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_error outputs message to stderr" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'training failed' 2>&1
  "
  [[ "$output" =~ "training failed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_step outputs decorated step message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_step")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_step 'Deploying Terraform'
  "
  [[ "$output" =~ "Deploying Terraform" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_header outputs header message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_header")
  run bash -c "
    CYAN='' NC=''
    source '$FUNC_FILE'
    log_header 'Training Setup'
  "
  [[ "$output" =~ "Training Setup" ]]
  rm -f "$FUNC_FILE"
}
