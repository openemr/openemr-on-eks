# Floci CI experiment — apply/destroy the main terraform/ root against a local emulator.
# Never use for real AWS. Invoked by tests/floci/terraform/run-main-stack.sh.

aws_region       = "us-east-1"
environment      = "floci"
cluster_name     = "openemr-eks-floci"
aws_endpoint_url = "http://localhost:4566"

# Faster waits; Floci mocks do not need real NAT/node settle time
vpc_ready_wait_duration     = "1s"
compute_ready_wait_duration = "1s"

# Prefer the lighter testing profile
rds_deletion_protection = false
backup_retention_days   = 1
aurora_min_capacity     = 0.5
aurora_max_capacity     = 2
enable_waf              = false
enable_public_access    = true
allowed_cidr_blocks     = ["0.0.0.0/0"]
