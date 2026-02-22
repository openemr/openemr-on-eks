# Credential Rotation (RDS) — OpenEMR on EKS

Zero-downtime credential rotation for the Aurora MySQL database backing OpenEMR on EKS.

## Table of Contents

- [Architecture overview](#architecture-overview)
- [Runtime contract](#runtime-contract)
- [Secrets model](#secrets-model)
- [Rotation flow](#rotation-flow)
- [Rollback behavior](#rollback-behavior)
- [Idempotency and safety](#idempotency-and-safety)
- [IAM permissions](#iam-permissions)
- [Kubernetes RBAC](#kubernetes-rbac)
- [Manual run](#manual-run)
- [Automated scheduling](#automated-scheduling)
- [Container image build](#container-image-build)
- [Failure scenarios](#failure-scenarios)
- [Operational runbook](#operational-runbook)
- [Troubleshooting](#troubleshooting)

## Architecture overview

```
┌─────────────────────────────────────────────────────────────┐
│                       Secrets Manager                       │
│  ┌──────────────────────┐  ┌──────────────────────┐         │
│  │   RDS Slot Secret    │  │   RDS Admin Secret   │         │
│  │  active_slot: "A"    │  │  username: "openemr" │         │
│  │  A: {openemr_a, ...} │  │  password: "..."     │         │
│  │  B: {openemr_b, ...} │  │  host: "..."         │         │
│  └──────────────────────┘  └──────────────────────┘         │
└───────────┬─────────────────────────┬───────────────────────┘
            │                         │
            ▼                         ▼
┌─────────────────────────────────────────────────────────────┐
│             Credential Rotation Job (K8s)                   │
│                                                             │
│  1. Read active/standby slots                               │
│  2. Sync DB users (openemr_a, openemr_b)                    │
│  3. Update sqlconf.php on EFS                               │
│  4. Patch K8s Secret (openemr-db-credentials)               │
│  5. Rolling restart Deployment                              │
│  6. Validate DB + health                                    │
│  7. Flip active_slot pointer                                │
│  8. Rotate old slot + admin password                        │
└──────┬──────────────┬──────────────┬────────────────────────┘
       │              │              │
       ▼              ▼              ▼
┌────────────┐ ┌─────────────┐ ┌──────────────────┐
│  EFS       │ │ K8s Secret  │ │  Aurora MySQL    │
│ sqlconf.php│ │ db-creds    │ │  openemr_a / _b  │
└────────────┘ └─────────────┘ └──────────────────┘
       │              │
       ▼              ▼
┌─────────────────────────────────────────────────────────────┐
│             OpenEMR Pods (Rolling Restart)                  │
│  - Read sqlconf.php from EFS at startup                     │
│  - Env vars from K8s Secret as fallback                     │
│  - Readiness probes gate traffic before serving             │
└─────────────────────────────────────────────────────────────┘
```

### Dual-credential strategy

Two dedicated MySQL users (`openemr_a` and `openemr_b`) are maintained in the Aurora cluster. At any point, one is **active** (used by the application) and the other is **standby** (ready for the next rotation). The rotation process:

1. Flips the application to the standby user
2. Validates the new connection works
3. Rotates the password of the now-unused old user
4. The old user becomes the new standby for the next cycle

This ensures the application always has a working set of credentials and can roll back instantly if validation fails.

## Runtime contract

- **Application config file**: `/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php` on shared EFS
- **Shared storage**: EFS mounted as PVC `openemr-sites-pvc`
- **K8s Secret**: `openemr-db-credentials` in namespace `openemr` (env vars for pods)
- **Refresh strategy**: Rolling restart of the `openemr` Deployment + K8s Secret patch

## Secrets model

### RDS slot secret

Terraform output: `rds_slot_secret_arn`

```json
{
  "active_slot": "A",
  "A": {"username": "openemr_a", "password": "...", "host": "...", "port": "3306", "dbname": "openemr"},
  "B": {"username": "openemr_b", "password": "...", "host": "...", "port": "3306", "dbname": "openemr"}
}
```

### RDS admin secret

Terraform output: `rds_admin_secret_arn`

```json
{
  "username": "openemr",
  "password": "...",
  "host": "...",
  "port": "3306",
  "dbname": "openemr"
}
```

## Rotation flow

1. **Read** active slot from Secrets Manager (`A` or `B`)
2. **Select** standby slot (the other one)
3. **Validate** admin credentials (auto-heals drift from prior failed rotation)
4. **Sync DB users**: ensure `openemr_a` and `openemr_b` in RDS match slot secret passwords
5. **Update** `sqlconf.php` on EFS to standby credentials (atomic write)
6. **Patch** K8s Secret `openemr-db-credentials` with standby credentials
7. **Rolling restart** the `openemr` Deployment
8. **Wait** for rollout to complete (readiness probes confirm health)
9. **Validate** DB connection with standby credentials + OpenEMR health probe
10. **Persist** updated `active_slot` in Secrets Manager
11. **Rotate** old-slot password: generate new password, ALTER USER, validate, update secret
12. **Rotate** admin password: ALTER USER, validate, update admin secret

## Rollback behavior

- **If flip validation fails** (step 9):
  - Restore original `sqlconf.php` content
  - Restore K8s Secret to original (active slot) credentials
  - Rolling restart the Deployment again
  - Validate recovery
  - Exit with non-zero status
- **If old-slot rotation fails** (step 11):
  - Keep application on current active slot (it's working)
  - Exit with non-zero status
  - Next run will retry the old-slot rotation

## Idempotency and safety

| Scenario | Behavior |
|----------|----------|
| **First run (neither slot matches sqlconf)** | Bootstrap: creates `openemr_a` and `openemr_b` users with fresh passwords, initialises both slots |
| **sqlconf points at standby, secrets say active** | Auto-reconcile: flips `active_slot` in secrets to match reality, rotates old slot |
| **App and secret both indicate slot B active** | Continues directly to old-slot rotation (skips flip) |
| **Admin credential drift** | Auto-heals by probing slot passwords if admin secret is stale |
| **Rerun after partial failure** | Detects current state and resumes from appropriate phase |

## IAM permissions

The rotation Job's ServiceAccount assumes an IAM role (IRSA) with:

- `secretsmanager:GetSecretValue`
- `secretsmanager:DescribeSecret`
- `secretsmanager:PutSecretValue`
- `secretsmanager:UpdateSecretVersionStage`
- `kms:Decrypt`, `kms:GenerateDataKey*`, `kms:DescribeKey`

Scoped to the two rotation secrets and the RDS KMS key only.

## Kubernetes RBAC

The `credential-rotation-sa` ServiceAccount has a namespaced Role:

| Resource | Names | Verbs |
|----------|-------|-------|
| `secrets` | `openemr-db-credentials` | `get`, `update`, `patch` |
| `deployments` | `openemr` | `get`, `patch` |
| `deployments/status` | `openemr` | `get` |

## Manual run

```bash
# Full rotation
./scripts/run-credential-rotation.sh

# Dry run (evaluate without mutating)
./scripts/run-credential-rotation.sh --dry-run

# Sync DB users only (recovery mode)
./scripts/run-credential-rotation.sh --sync-db-users

# Verify prerequisites without running rotation
./scripts/verify-credential-rotation.sh
```

## Automated scheduling

### Option 1 — Kubernetes CronJob (default)

A CronJob manifest is provided at `k8s/credential-rotation-cronjob.yaml`. It runs monthly at 03:00 UTC. To enable:

```bash
kubectl patch cronjob credential-rotation -n openemr -p '{"spec":{"suspend":false}}'
```

### Option 2 — EventBridge Scheduler

Use EventBridge Scheduler to trigger a `kubectl` command via Lambda or CodeBuild. Follows the same pattern as the ECS approach.

## Container image build

```bash
cd tools/credential-rotation

# Build multi-arch image (works on both amd64 and arm64 EKS nodes)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2
ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/openemr-credential-rotation"

aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker buildx build --platform linux/amd64,linux/arm64 \
  -t "$ECR_REPO:latest" --push .
```

## Failure scenarios

| Scenario | Impact | Resolution |
|----------|--------|------------|
| Job fails mid-rotation (after sqlconf flip, before validation) | Rollback triggers automatically | Check Job logs, fix issue, re-run |
| EFS not mounted | Job fails immediately | Verify PVC status, EFS mount targets, security groups |
| Secrets Manager unreachable | Job fails immediately | Check IAM role, IRSA annotation, network policies |
| Admin password drift | Auto-healed | Next run probes slot passwords as fallback |
| K8s Secret update fails | Rollback triggers | Check RBAC permissions for ServiceAccount |
| Rollout timeout (>30 min) | Rotation fails with rollback | Check pod startup, resource limits, node availability |
| Old-slot rotation fails | App continues on current slot | Safe state; next run retries |
| Both slots corrupted | Manual intervention required | See runbook below |

## Operational runbook

### Pre-rotation checklist

1. Verify cluster is healthy: `kubectl get nodes`
2. Verify OpenEMR pods are running: `kubectl get pods -n openemr`
3. Verify EFS mount: `kubectl get pvc -n openemr`
4. Run verification: `./scripts/verify-credential-rotation.sh`

### Emergency: manual credential reset

If both slot credentials are corrupted and the application is down:

1. **Reset RDS master password** via AWS Console (RDS → Cluster → Modify → Master password)
2. **Update admin secret**:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id <RDS_ADMIN_SECRET_ARN> \
     --secret-string '{"username":"openemr","password":"<NEW_PASSWORD>","host":"<ENDPOINT>","port":"3306","dbname":"openemr"}'
   ```
3. **Run rotation with --sync-db-users** to recreate application users:
   ```bash
   ./scripts/run-credential-rotation.sh --sync-db-users
   ```
4. **Run full rotation** to establish proper dual-slot state:
   ```bash
   ./scripts/run-credential-rotation.sh
   ```

### Viewing rotation logs

```bash
# Current/recent Job
kubectl logs job/credential-rotation -n openemr

# Historical (if TTL hasn't expired)
kubectl logs job/credential-rotation-<timestamp> -n openemr
```

## Troubleshooting

- **Permission denied on sqlconf.php**: Run `./scripts/run-credential-rotation.sh --fix-permissions`. The rotation tool sets file ownership to `apache` (UID 1000) and mode `0o644` during writes.
- **Access denied for admin user**: The rotation auto-heals admin credential drift on startup. If auto-heal fails, reset the RDS master password manually (see runbook above).
- **Job cannot mount EFS**: Verify the `openemr-sites-pvc` is bound and EFS mount targets are in the correct subnets with security group access.
- **App not picking up new credentials**: Verify the rolling restart was triggered (check `credential-rotation/restartedAt` annotation on pods) and rollout completed.
- **DB validation fails**: Verify slot user exists and has privileges on the `openemr` database. Run `--sync-db-users` to fix.
- **K8s Secret update fails**: Verify RBAC — the `credential-rotation-sa` needs `patch` on `secrets/openemr-db-credentials`.

## Related documentation

- [Credential Rotation Tool README](../tools/credential-rotation/README.md) -- CLI flags, environment variables, rotation algorithm
- [Deployment Guide](DEPLOYMENT_GUIDE.md) -- Post-deployment credential rotation setup
- [Troubleshooting Guide](TROUBLESHOOTING.md) -- Database connection issues after rotation
- [Backup & Restore Guide](BACKUP_RESTORE_GUIDE.md) -- Re-syncing credentials after a restore
- [Terraform README](../terraform/README.md) -- `credential-rotation.tf` infrastructure
- [Kubernetes README](../k8s/README.md) -- Rotation Job/CronJob manifests and RBAC
- [Scripts README](../scripts/README.md) -- `run-credential-rotation.sh` and `verify-credential-rotation.sh`
