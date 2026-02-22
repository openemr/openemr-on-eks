#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: Cross-file contract & consistency tests
# Purpose: Validate that versions, names, outputs, and references stay in sync
#          across Terraform, K8s manifests, shell scripts, Dockerfiles, and
#          versions.yaml.  Catches the kind of drift that only surfaces at
#          deploy time today.
# Scope:   Read-only — inspects files, never modifies anything.
# -----------------------------------------------------------------------------

load test_helper

setup() {
  VERSIONS_FILE="${PROJECT_ROOT}/versions.yaml"
  OUTPUTS_TF="${PROJECT_ROOT}/terraform/outputs.tf"
  CRED_ROT_TF="${PROJECT_ROOT}/terraform/credential-rotation.tf"
  CRED_ROT_DOCKERFILE="${PROJECT_ROOT}/tools/credential-rotation/Dockerfile"
  CRED_ROT_REQUIREMENTS="${PROJECT_ROOT}/tools/credential-rotation/requirements.txt"
  WARP_REQUIREMENTS="${PROJECT_ROOT}/warp/requirements.txt"
  CI_WORKFLOW="${PROJECT_ROOT}/.github/workflows/ci-cd-tests.yml"
  K8S_DIR="${PROJECT_ROOT}/k8s"
}

# ── Helper: extract Terraform output names from outputs.tf + credential-rotation.tf ──
_all_tf_output_names() {
  grep -h '^output "' "$OUTPUTS_TF" "$CRED_ROT_TF" 2>/dev/null \
    | sed 's/output "\([^"]*\)".*/\1/' | sort -u
}

# ===========================================================================
# VERSION CONSISTENCY
# ===========================================================================

@test "CONTRACT: credential rotation Dockerfile PYTHON_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.applications.python.current' "$VERSIONS_FILE")
  local docker_ver
  docker_ver=$(grep '^ARG PYTHON_VERSION=' "$CRED_ROT_DOCKERFILE" | sed 's/ARG PYTHON_VERSION=//')
  [ "$docker_ver" = "$yaml_ver" ]
}

@test "CONTRACT: credential rotation requirements.txt boto3 version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.boto3.current' "$VERSIONS_FILE")
  run grep '^boto3' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: credential rotation requirements.txt pymysql version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE")
  run grep '^pymysql' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: credential rotation requirements.txt kubernetes version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.kubernetes.current' "$VERSIONS_FILE")
  run grep '^kubernetes' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: credential rotation requirements.txt requests version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.requests.current' "$VERSIONS_FILE")
  run grep '^requests' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: warp requirements.txt pymysql version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE")
  run grep '^pymysql' "$WARP_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: CI workflow PYTHON_VERSION matches versions.yaml semver_packages" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.python_version.current' "$VERSIONS_FILE")
  run grep "PYTHON_VERSION:" "$CI_WORKFLOW"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: CI workflow TERRAFORM_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.terraform_version.current' "$VERSIONS_FILE")
  run grep "TERRAFORM_VERSION:" "$CI_WORKFLOW"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: CI workflow KUBECTL_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.kubectl_version.current' "$VERSIONS_FILE")
  run grep "KUBECTL_VERSION:" "$CI_WORKFLOW"
  [[ "$output" == *"$yaml_ver"* ]]
}

# ===========================================================================
# TERRAFORM-TO-SCRIPT CONTRACT
# ===========================================================================

@test "CONTRACT: run-credential-rotation.sh terraform outputs exist in .tf files" {
  local script="${SCRIPTS_DIR}/run-credential-rotation.sh"
  local outputs
  outputs=$(_all_tf_output_names)
  for name in rds_slot_secret_arn rds_admin_secret_arn credential_rotation_role_arn; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in run-credential-rotation.sh)"
      return 1
    }
  done
}

@test "CONTRACT: verify-credential-rotation.sh terraform outputs exist in .tf files" {
  local script="${SCRIPTS_DIR}/verify-credential-rotation.sh"
  local outputs
  outputs=$(_all_tf_output_names)
  for name in rds_slot_secret_arn rds_admin_secret_arn credential_rotation_role_arn; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in verify-credential-rotation.sh)"
      return 1
    }
  done
}

@test "CONTRACT: backup.sh terraform outputs exist in outputs.tf" {
  local outputs
  outputs=$(_all_tf_output_names)
  echo "$outputs" | grep -qx "aurora_cluster_id"
}

@test "CONTRACT: restore.sh critical terraform outputs exist in outputs.tf" {
  local outputs
  outputs=$(_all_tf_output_names)
  for name in cluster_name aurora_cluster_id aurora_endpoint aurora_password efs_id openemr_role_arn aurora_db_subnet_group_name aurora_engine_version; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in restore.sh)"
      return 1
    }
  done
}

@test "CONTRACT: destroy.sh terraform outputs exist in outputs.tf" {
  local outputs
  outputs=$(_all_tf_output_names)
  for name in cluster_name alb_logs_bucket_name loki_s3_bucket_name tempo_s3_bucket_name mimir_blocks_s3_bucket_name alertmanager_s3_bucket_name backup_vault_name; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in destroy.sh)"
      return 1
    }
  done
}

# ===========================================================================
# K8S MANIFEST CONSISTENCY
# ===========================================================================

@test "CONTRACT: all credential rotation manifests use same ServiceAccount name" {
  local sa_name="credential-rotation-sa"
  grep -q "name: $sa_name" "$K8S_DIR/credential-rotation-sa.yaml"
  grep -q "serviceAccountName: $sa_name" "$K8S_DIR/credential-rotation-job.yaml"
  grep -q "serviceAccountName: $sa_name" "$K8S_DIR/credential-rotation-cronjob.yaml"
  grep -q "name: $sa_name" "$K8S_DIR/credential-rotation-rbac.yaml"
}

@test "CONTRACT: all credential rotation manifests use namespace 'openemr'" {
  for f in credential-rotation-sa.yaml credential-rotation-rbac.yaml credential-rotation-job.yaml credential-rotation-cronjob.yaml; do
    grep -q "namespace: openemr" "$K8S_DIR/$f" || {
      echo "Missing namespace: openemr in $f"
      return 1
    }
  done
}

@test "CONTRACT: credential rotation Job and CronJob use same container image variable" {
  local job_image cronjob_image
  job_image=$(grep 'image:' "$K8S_DIR/credential-rotation-job.yaml" | head -1 | awk '{print $2}')
  cronjob_image=$(grep 'image:' "$K8S_DIR/credential-rotation-cronjob.yaml" | head -1 | awk '{print $2}')
  [ "$job_image" = "$cronjob_image" ]
}

@test "CONTRACT: credential rotation Job and CronJob use same env vars" {
  local job_envs cronjob_envs
  job_envs=$(grep '- name:' "$K8S_DIR/credential-rotation-job.yaml" | awk '{print $3}' | sort)
  cronjob_envs=$(grep '- name:' "$K8S_DIR/credential-rotation-cronjob.yaml" | awk '{print $3}' | sort)
  [ "$job_envs" = "$cronjob_envs" ]
}

@test "CONTRACT: RBAC targets openemr-db-credentials Secret (matches secrets.yaml)" {
  grep -q 'openemr-db-credentials' "$K8S_DIR/credential-rotation-rbac.yaml"
  grep -q 'name: openemr-db-credentials' "$K8S_DIR/secrets.yaml"
}

@test "CONTRACT: RBAC targets 'openemr' Deployment (matches deployment.yaml)" {
  grep -q 'resourceNames: \["openemr"\]' "$K8S_DIR/credential-rotation-rbac.yaml" || \
  grep -q '"openemr"' "$K8S_DIR/credential-rotation-rbac.yaml"
  grep -q 'name: openemr' "$K8S_DIR/deployment.yaml"
}

@test "CONTRACT: Job K8S_SECRET_NAME env matches secrets.yaml Secret name" {
  local job_secret_name
  job_secret_name=$(grep -A1 'K8S_SECRET_NAME' "$K8S_DIR/credential-rotation-job.yaml" | grep 'value:' | awk -F'"' '{print $2}')
  grep -q "name: $job_secret_name" "$K8S_DIR/secrets.yaml"
}

@test "CONTRACT: all credential rotation manifests have consistent labels" {
  for f in credential-rotation-sa.yaml credential-rotation-rbac.yaml credential-rotation-job.yaml credential-rotation-cronjob.yaml; do
    grep -q 'app: credential-rotation' "$K8S_DIR/$f" || {
      echo "Missing label app: credential-rotation in $f"
      return 1
    }
  done
}

@test "CONTRACT: Job references openemr-sites-pvc PVC (must exist in storage.yaml)" {
  grep -q 'claimName: openemr-sites-pvc' "$K8S_DIR/credential-rotation-job.yaml"
  grep -q 'openemr-sites-pvc' "$K8S_DIR/storage.yaml"
}

# ===========================================================================
# SCRIPT-TO-FILE REFERENCES
# ===========================================================================

@test "CONTRACT: run-credential-rotation.sh references existing K8s manifests" {
  local script="${SCRIPTS_DIR}/run-credential-rotation.sh"
  for manifest in credential-rotation-rbac.yaml credential-rotation-sa.yaml credential-rotation-job.yaml; do
    if grep -q "$manifest" "$script"; then
      [ -f "$K8S_DIR/$manifest" ] || {
        echo "Referenced manifest $manifest does not exist"
        return 1
      }
    fi
  done
}

@test "CONTRACT: every k8s/*.yaml file is valid YAML (parseable)" {
  for f in "$K8S_DIR"/*.yaml; do
    python3 -c "import yaml; yaml.safe_load_all(open('$f'))" 2>/dev/null || {
      echo "Invalid YAML: $f"
      return 1
    }
  done
}

@test "CONTRACT: k8s deployment.yaml and service.yaml share 'app: openemr' selector" {
  grep -q 'app: openemr' "$K8S_DIR/deployment.yaml"
  grep -q 'app: openemr' "$K8S_DIR/service.yaml"
}

@test "CONTRACT: HPA targets 'openemr' Deployment (matches deployment.yaml)" {
  grep -q 'name: openemr' "$K8S_DIR/hpa.yaml"
  grep -q 'name: openemr' "$K8S_DIR/deployment.yaml"
}

@test "CONTRACT: all k8s manifests in openemr namespace use it consistently" {
  for f in deployment.yaml service.yaml secrets.yaml hpa.yaml storage.yaml; do
    if grep -q 'namespace:' "$K8S_DIR/$f"; then
      grep 'namespace:' "$K8S_DIR/$f" | grep -q 'openemr' || {
        echo "$f has a non-openemr namespace"
        return 1
      }
    fi
  done
}

# ===========================================================================
# DOCKERFILE & TOOL CONSISTENCY
# ===========================================================================

@test "CONTRACT: credential rotation Dockerfile installs from requirements.txt" {
  grep -q 'requirements.txt' "$CRED_ROT_DOCKERFILE"
}

@test "CONTRACT: credential rotation Dockerfile uses -slim base image" {
  grep -q 'python:.*-slim' "$CRED_ROT_DOCKERFILE"
}
