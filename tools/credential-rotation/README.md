# OpenEMR Credential Rotation Tool (EKS)

Dual-slot credential rotation for OpenEMR on EKS + EFS.

> **Full operational guide:** See [docs/credential-rotation.md](../../docs/credential-rotation.md) for architecture diagrams, the operational runbook, failure scenarios, and infrastructure setup (Terraform, IAM, RBAC).

## Table of Contents

- [Runtime assumptions](#runtime-assumptions)
- [CLI](#cli)
- [Required environment variables](#required-environment-variables)
- [Rotation algorithm](#rotation-algorithm)
- [Rollback](#rollback)
- [Development](#development)

## Runtime assumptions

- Database configuration is read from `sites/default/sqlconf.php` on the shared EFS volume.
- The K8s Secret `openemr-db-credentials` is patched with new credentials after rotation.
- Runtime refresh uses a rolling restart of the `openemr` Deployment for zero-downtime config pickup.

## CLI

```bash
python -m credential_rotation.cli --log-json
```

Flags:
- `--dry-run` — Evaluate flow without mutating state
- `--log-json` — Emit structured JSON status output
- `--sync-db-users` — Sync RDS users to match slot secrets (no flip)
- `--fix-permissions` — Fix sqlconf.php permissions (chmod 644)

## Required environment variables

| Variable | Description |
|----------|-------------|
| `AWS_REGION` | AWS region |
| `RDS_SLOT_SECRET_ID` | ARN of the dual-slot RDS secret |
| `RDS_ADMIN_SECRET_ID` | ARN of the RDS admin secret |
| `OPENEMR_SITES_MOUNT_ROOT` | EFS mount path for OpenEMR sites |
| `K8S_NAMESPACE` | Kubernetes namespace (e.g., `openemr`) |
| `K8S_DEPLOYMENT_NAME` | Deployment name (e.g., `openemr`) |
| `K8S_SECRET_NAME` | K8s Secret name (e.g., `openemr-db-credentials`) |
| `OPENEMR_HEALTHCHECK_URL` | *(optional)* Health check URL |

## Rotation algorithm

1. Determine active slot (`A` or `B`)
2. Select standby slot
3. Validate admin credentials (auto-heals drift)
4. Sync DB users to match slot secrets
5. Update EFS `sqlconf.php` to standby credentials
6. Patch K8s Secret with standby credentials
7. Rolling restart the Deployment
8. Validate DB + app health
9. Flip `active_slot` in Secrets Manager
10. Rotate old slot credentials
11. Rotate admin password

## Rollback

- If flip validation fails: revert `sqlconf.php`, restore K8s Secret, restart again, re-validate, fail.
- If old-slot rotation fails: keep app on current active slot and fail.

## Development

```bash
pip install -r requirements.txt
pytest tests/
```
