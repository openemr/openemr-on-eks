# Floci main-stack Terraform experiment

Attempt to `terraform apply` / `destroy` the production `terraform/` root against
[Floci](https://floci.io/).

## Quick start

```bash
docker compose -f tests/floci/compose.yaml up -d
./tests/floci/wait.sh
./tests/floci/terraform/run-main-stack.sh plan          # works
./tests/floci/terraform/run-main-stack.sh apply-destroy # does NOT fully succeed today
```

State is isolated under `terraform/.floci-state/` (gitignored).

## Result (2026-08-10, Floci 1.6.0)

| Stage | Result |
|---|---|
| `terraform plan` | OK (~205 resources with Floci workarounds) |
| `terraform apply` | **Fails** before completion |
| `terraform destroy` | **Fails** on refresh of partial state |

### Workarounds already in the root module (only when `aws_endpoint_url` is set)

- AWS provider endpoints + skip flags
- Inline Floci EKS security groups (avoids hanging `aws_security_group_rule`)
- EKS Auto Mode disabled (Floci lacks Auto Mode managed policies)

### Remaining blockers on full apply

- Missing AWS managed policies (`AWSBackupServiceRolePolicyForBackup/Restores`, …)
- CloudTrail `ListTags` unsupported
- EFS `CreateFileSystem` unknown operation
- ElastiCache `ListTagsForResource` unsupported
- EKS Access Entry / OIDC identity incomplete under Floci mock
- Various provider “Invalid function argument” / inconsistent plan errors

**Conclusion:** Floci is useful for SDK/CLI integration and small Terraform roots.
It is **not** ready to apply/destroy this project’s full EKS Auto Mode stack in CI
without a large set of `count = local.use_floci ? 0 : 1` skips (EFS, Backup,
CloudTrail, ElastiCache Serverless, IRSA/access entries, etc.).

## Cleanup after a failed run

```bash
rm -rf terraform/.floci-state
docker compose -f tests/floci/compose.yaml down -v
```
