#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: Floci AWS emulator smoke tests
# Purpose: Validate STS, S3, KMS, and Secrets Manager against a live Floci
#          endpoint (CI service or local compose).
# Scope:   Requires AWS_ENDPOINT_URL; skips cleanly when Floci is unavailable.
# -----------------------------------------------------------------------------

load test_helper
load floci_helper

setup() {
  require_floci
  TEST_PREFIX="floci-smoke-${BATS_SUITE_TEST_NUMBER:-$$}-${RANDOM}"
}

@test "Floci: STS get-caller-identity returns an account id" {
  run floci_aws sts get-caller-identity --query Account --output text
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "Floci: S3 create bucket, put, get, and list objects" {
  local bucket="floci-smoke-${RANDOM}$(date +%s)"
  run floci_aws s3 mb "s3://${bucket}"
  [ "$status" -eq 0 ]

  local tmp
  tmp="$(mktemp)"
  echo "hello-floci" > "$tmp"
  run floci_aws s3 cp "$tmp" "s3://${bucket}/smoke/${TEST_PREFIX}.txt"
  [ "$status" -eq 0 ]

  run floci_aws s3 ls "s3://${bucket}/smoke/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_PREFIX}.txt"* ]]

  run floci_aws s3 cp "s3://${bucket}/smoke/${TEST_PREFIX}.txt" -
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-floci"* ]]

  floci_aws s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
  floci_aws s3 rb "s3://${bucket}" >/dev/null 2>&1 || true
  rm -f "$tmp"
}

@test "Floci: KMS create-key, encrypt, and decrypt round-trip" {
  run floci_aws kms create-key --description "floci-smoke-${TEST_PREFIX}" --query KeyMetadata.KeyId --output text
  [ "$status" -eq 0 ]
  local key_id="$output"
  [ -n "$key_id" ]

  run floci_aws kms encrypt --key-id "$key_id" --plaintext "c21va2U=" --query CiphertextBlob --output text
  [ "$status" -eq 0 ]
  local cipher="$output"
  [ -n "$cipher" ]

  run floci_aws kms decrypt --ciphertext-blob "$cipher" --query Plaintext --output text
  [ "$status" -eq 0 ]
  [ "$output" = "c21va2U=" ]
}

@test "Floci: Secrets Manager create and get secret value" {
  local name="floci/smoke/${TEST_PREFIX}"
  run floci_aws secretsmanager create-secret --name "$name" --secret-string '{"active_slot":"A"}'
  [ "$status" -eq 0 ]

  run floci_aws secretsmanager get-secret-value --secret-id "$name" --query SecretString --output text
  [ "$status" -eq 0 ]
  [[ "$output" == *'"active_slot":"A"'* ]] || [[ "$output" == *'"active_slot": "A"'* ]]
}

@test "Floci: CloudWatch Logs create group and put events" {
  local group="/openemr/floci/${TEST_PREFIX}"
  local stream="smoke-stream"
  run floci_aws logs create-log-group --log-group-name "$group"
  [ "$status" -eq 0 ]

  run floci_aws logs create-log-stream --log-group-name "$group" --log-stream-name "$stream"
  [ "$status" -eq 0 ]

  local ts
  ts="$(date +%s000)"
  run floci_aws logs put-log-events \
    --log-group-name "$group" \
    --log-stream-name "$stream" \
    --log-events "timestamp=${ts},message=floci-smoke-ok"
  [ "$status" -eq 0 ]
}

@test "Floci: IAM create-role and get-role" {
  local role="floci-smoke-role-${TEST_PREFIX}"
  local trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  run floci_aws iam create-role --role-name "$role" --assume-role-policy-document "$trust"
  [ "$status" -eq 0 ]

  run floci_aws iam get-role --role-name "$role" --query Role.RoleName --output text
  [ "$status" -eq 0 ]
  [ "$output" = "$role" ]
}

@test "Floci: SSM put-parameter and get-parameter" {
  local name="/openemr/floci/${TEST_PREFIX}/endpoint"
  run floci_aws ssm put-parameter --name "$name" --type String --value "http://localhost:4566" --overwrite
  [ "$status" -eq 0 ]

  run floci_aws ssm get-parameter --name "$name" --query Parameter.Value --output text
  [ "$status" -eq 0 ]
  [ "$output" = "http://localhost:4566" ]
}

@test "Floci: RDS create-db-cluster and describe-db-clusters" {
  local cluster_id="floci-smoke-rds-${RANDOM}"
  run floci_aws rds create-db-cluster \
    --db-cluster-identifier "$cluster_id" \
    --engine aurora-mysql \
    --master-username openemr \
    --master-user-password 'SeedPassword123!' \
    --database-name openemr
  [ "$status" -eq 0 ]
  [[ "$output" == *"$cluster_id"* ]]

  run floci_aws rds describe-db-clusters --db-cluster-identifier "$cluster_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$cluster_id"* ]]
}
