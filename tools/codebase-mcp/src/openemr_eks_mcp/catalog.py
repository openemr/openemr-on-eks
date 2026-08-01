"""Small curated knowledge and operational command catalogs."""

from __future__ import annotations

from openemr_eks_mcp.models import (
    OperationalCommand,
    RiskProfile,
    SourceReference,
    Topic,
)

SOURCE_PRECEDENCE = (
    {
        "rank": 1,
        "source": "Executable source and configuration",
        "guidance": (
            "Terraform, Kubernetes manifests, scripts, workflows, and package source define implemented behavior."
        ),
    },
    {
        "rank": 2,
        "source": "versions.yaml",
        "guidance": "The version inventory is authoritative for centrally managed versions.",
    },
    {
        "rank": 3,
        "source": "Focused guides",
        "guidance": "Topic-specific docs explain intent, prerequisites, and operating procedures.",
    },
    {
        "rank": 4,
        "source": "README overviews",
        "guidance": "Overview documents provide orientation but may lag executable sources.",
    },
)


def source(path: str, role: str, precedence: int) -> SourceReference:
    return SourceReference(path=path, role=role, precedence=precedence)


TOPICS: tuple[Topic, ...] = (
    Topic(
        slug="deployment",
        title="Deployment",
        summary=(
            "Provision the AWS infrastructure, deploy OpenEMR workloads, then validate the "
            "result. Project scripts are cloud-affecting and can create ongoing cost."
        ),
        key_points=(
            "Terraform defines VPC, EKS Auto Mode, Aurora, Valkey, EFS, IAM, KMS, WAF, and backup.",
            "k8s/deploy.sh applies the application layer after infrastructure outputs are ready.",
            "scripts/quick-deploy.sh orchestrates infrastructure, OpenEMR, and monitoring.",
            "Review active AWS and Kubernetes contexts before any project deployment command.",
        ),
        sources=(
            source("terraform/main.tf", "Terraform/provider entry point", 1),
            source("terraform/eks.tf", "EKS Auto Mode configuration", 1),
            source("k8s/deploy.sh", "Application deployment implementation", 1),
            source("scripts/quick-deploy.sh", "End-to-end deployment orchestration", 1),
            source("docs/DEPLOYMENT_GUIDE.md", "Deployment runbook", 3),
        ),
        related_topics=("architecture", "security", "monitoring", "openemr-initialization"),
        aliases=("deploy", "installation", "provisioning"),
    ),
    Topic(
        slug="architecture",
        title="Architecture and EKS Auto Mode",
        summary=(
            "OpenEMR runs on EKS Auto Mode in a VPC with managed compute, Aurora MySQL, "
            "Valkey, encrypted EFS, ingress protection, and layered observability."
        ),
        key_points=(
            "EKS Auto Mode manages core compute, networking, and block-storage capabilities.",
            "OpenEMR pods use Aurora for relational data, Valkey for cache, and EFS for shared sites data.",
            "Ingress, WAF, network policies, security groups, IAM, and KMS form defense in depth.",
            "Terraform is the resource-level architectural authority; diagrams and README are summaries.",
        ),
        sources=(
            source("terraform/eks.tf", "Cluster and Auto Mode implementation", 1),
            source("terraform/vpc.tf", "Network topology", 1),
            source("terraform/rds.tf", "Aurora data layer", 1),
            source("terraform/efs.tf", "Shared storage layer", 1),
            source("k8s/deployment.yaml", "OpenEMR workload topology", 1),
            source("README.md", "Conceptual architecture overview", 4),
        ),
        related_topics=("deployment", "security", "monitoring", "backup-restore-dr"),
        aliases=("eks", "auto-mode", "eks-auto-mode", "infrastructure"),
    ),
    Topic(
        slug="security",
        title="Security Model",
        summary=(
            "The project combines encryption, least-privilege identities, network controls, "
            "audit logging, secret management, and zero-tolerance security scanning."
        ),
        key_points=(
            "KMS-backed encryption protects EKS, EFS, Aurora, cache, S3, logs, and backups.",
            "IAM roles and pod identities avoid embedding cloud credentials in workloads.",
            "Kubernetes security contexts, RBAC, and network policies constrain runtime access.",
            "Repository documentation is not a substitute for organizational HIPAA controls or an AWS BAA.",
        ),
        sources=(
            source("terraform/kms.tf", "Encryption keys and policy", 1),
            source("terraform/iam.tf", "IAM and workload identity", 1),
            source("terraform/waf.tf", "Web application protection", 1),
            source("terraform/cloudtrail.tf", "API audit trail", 1),
            source("k8s/security.yaml", "Pod and namespace security controls", 1),
            source("k8s/network-policies.yaml", "Workload network segmentation", 1),
            source("docs/SECURITY_SCANNING.md", "Security scanning policy", 3),
        ),
        related_topics=("credentials-rotation", "architecture", "ci-cd", "backup-restore-dr"),
        aliases=("compliance", "hipaa", "encryption", "iam"),
    ),
    Topic(
        slug="monitoring",
        title="Monitoring, Logging, and Observability",
        summary=(
            "CloudWatch logging is part of the core deployment; an optional monitoring stack "
            "adds Prometheus, Grafana, Loki, Tempo, Mimir, AlertManager, and OTeBPF."
        ),
        key_points=(
            "Fluent Bit forwards OpenEMR logs and CloudWatch provides the core logging path.",
            "The optional stack covers metrics, logs, traces, dashboards, and alert routing.",
            "Loki, Tempo, Mimir, and AlertManager use Terraform-provisioned S3 and workload identity.",
            "Installing the optional stack mutates the cluster and can increase AWS cost.",
        ),
        sources=(
            source("monitoring/install-monitoring.sh", "Monitoring installation implementation", 1),
            source("monitoring/prometheus-values.yaml", "Helm values and component configuration", 1),
            source("k8s/logging.yaml", "Application log forwarding", 1),
            source("terraform/cloudwatch.tf", "CloudWatch logging resources", 1),
            source("monitoring/README.md", "Monitoring architecture and runbook", 3),
            source("docs/LOGGING_GUIDE.md", "Logging operations", 3),
        ),
        related_topics=("architecture", "deployment", "troubleshooting", "versions"),
        aliases=("observability", "logging", "metrics", "grafana"),
    ),
    Topic(
        slug="backup-restore-dr",
        title="Backup, Restore, and Disaster Recovery",
        summary=(
            "Scheduled AWS Backup resources and on-demand scripts protect Aurora, EFS, "
            "Kubernetes configuration, and application data with phased restore support."
        ),
        key_points=(
            "terraform/backup.tf defines scheduled encrypted backup infrastructure and retention.",
            "scripts/backup.sh creates application-aware, optionally cross-region backups.",
            "scripts/restore.sh delegates to the phased Python orchestrator by default.",
            "Restore and end-to-end DR exercises are destructive, cloud-affecting, and context-sensitive.",
        ),
        sources=(
            source("terraform/backup.tf", "Scheduled backup infrastructure", 1),
            source("scripts/backup.sh", "On-demand backup implementation", 1),
            source("scripts/restore.sh", "Restore entry point", 1),
            source("scripts/openemr_dr/cli.py", "Phased DR command interface", 1),
            source("docs/BACKUP_RESTORE_GUIDE.md", "Backup and restore runbook", 3),
            source("docs/DISASTER_RECOVERY_PYTHON.md", "Python DR architecture", 3),
        ),
        related_topics=("cleanup", "testing", "security", "troubleshooting"),
        aliases=("backup", "restore", "dr", "disaster-recovery"),
    ),
    Topic(
        slug="credentials-rotation",
        title="Credentials and Rotation",
        summary=(
            "Aurora credentials use a dual-slot A/B model coordinated through Secrets Manager, "
            "a Kubernetes job, EFS configuration, and rolling workload restarts."
        ),
        key_points=(
            "The application alternates between openemr_a and openemr_b database users.",
            "Rotation validates the standby credential before changing the active slot.",
            "Scoped IAM and namespaced RBAC limit the rotation job to required resources.",
            "Verification and dry-run modes still require a correctly selected live environment.",
        ),
        sources=(
            source("terraform/credential-rotation.tf", "Secrets and IAM infrastructure", 1),
            source("k8s/credential-rotation-job.yaml", "Rotation workload", 1),
            source("k8s/credential-rotation-rbac.yaml", "Rotation RBAC", 1),
            source("tools/credential-rotation/README.md", "Tool contract and flags", 1),
            source("scripts/run-credential-rotation.sh", "Operational wrapper", 1),
            source("docs/CREDENTIAL_ROTATION_GUIDE.md", "Architecture and runbook", 3),
        ),
        related_topics=("security", "troubleshooting", "backup-restore-dr"),
        aliases=("credentials", "credential-rotation", "secrets", "rotation"),
    ),
    Topic(
        slug="versions",
        title="Version Inventory and Maintenance",
        summary=(
            "versions.yaml is the central inventory for application, infrastructure, workflow, "
            "tooling, package, and monitoring versions; consumer files implement those pins."
        ),
        key_points=(
            "Use the dynamic version tool for current values rather than copying them into prose.",
            "Consumer paths are contextual and bounded; versions.yaml remains authoritative.",
            "Monthly checks can use registries, documentation, and optional AWS lookups.",
            "Version-check scripts may require network or active cloud credentials even when read-only.",
        ),
        sources=(
            source("versions.yaml", "Authoritative central inventory", 2),
            source("scripts/version-manager.sh", "Version checking implementation", 1),
            source(".github/workflows/monthly-version-check.yml", "Scheduled version workflow", 1),
            source("docs/VERSION_MANAGEMENT.md", "Version maintenance guide", 3),
        ),
        related_topics=("ci-cd", "testing", "deployment"),
        aliases=("version", "dependencies", "upgrades"),
    ),
    Topic(
        slug="ci-cd",
        title="CI/CD and Release Workflows",
        summary=(
            "GitHub Actions validate contracts, Python and Go packages, infrastructure syntax, "
            "security posture, versions, and manually initiated releases."
        ),
        key_points=(
            "Workflow YAML is authoritative for triggers, permissions, jobs, and tool versions.",
            "Contract tests and local unit tests are designed to avoid requiring AWS credentials.",
            "Security scanning is separated into a comprehensive workflow with multiple scanners.",
            "Manual release workflows can mutate repository and release state; inspect inputs first.",
        ),
        sources=(
            source(".github/workflows/ci-cd-tests.yml", "Primary CI jobs", 1),
            source(
                ".github/workflows/ci-contract-tests.yml",
                "Contract and infrastructure validation",
                1,
            ),
            source(".github/workflows/security-comprehensive.yml", "Security scanning jobs", 1),
            source(".github/workflows/manual-releases.yml", "Manual release behavior", 1),
            source(".github/workflows/README.md", "Workflow overview", 3),
        ),
        related_topics=("testing", "security", "versions"),
        aliases=("ci", "cd", "github-actions", "pipelines", "release"),
    ),
    Topic(
        slug="testing",
        title="Testing",
        summary=(
            "The repository combines network-free unit and contract tests with optional "
            "cloud-affecting end-to-end deployment, backup, restore, and data-import exercises."
        ),
        key_points=(
            "Distinguish local validation from end-to-end scripts before running a command.",
            "BATS contract tests exercise shell behavior without a live cluster where possible.",
            "Python packages maintain isolated unit suites and coverage thresholds.",
            "The backup/restore E2E suite can create, mutate, and delete AWS resources and local manifests.",
        ),
        sources=(
            source("tests/bats/contract-tests.bats", "Shell and repository contracts", 1),
            source("scripts/run-test-suite.sh", "Repository test orchestration", 1),
            source("scripts/test-end-to-end-backup-restore.sh", "Cloud E2E implementation", 1),
            source("docs/TESTING_GUIDE.md", "Testing guide and safety warnings", 3),
            source("docs/END_TO_END_TESTING_REQUIREMENTS.md", "E2E prerequisites", 3),
        ),
        related_topics=("ci-cd", "backup-restore-dr", "troubleshooting"),
        aliases=("tests", "quality", "validation"),
    ),
    Topic(
        slug="troubleshooting",
        title="Troubleshooting",
        summary=(
            "Troubleshooting starts with project validation scripts and focused guides, then "
            "narrows to cluster access, storage, workload, database, and observability layers."
        ),
        key_points=(
            "Validation commands need live AWS and Kubernetes context even when they are read-only.",
            "Use storage and cluster-access checks before destructive cleanup.",
            "Do not treat cleanup or restore as diagnostics; both can cause data loss.",
            "Correlate executable checks with the topic-specific guide for the failing subsystem.",
        ),
        sources=(
            source("scripts/validate-deployment.sh", "Comprehensive live validation", 1),
            source("scripts/validate-efs-csi.sh", "Storage validation", 1),
            source("scripts/cluster-security-manager.sh", "Cluster access diagnostics", 1),
            source("docs/TROUBLESHOOTING.md", "Issue-oriented runbook", 3),
            source("docs/DEPLOYMENT_TIMINGS.md", "Expected operation timing", 3),
        ),
        related_topics=("monitoring", "deployment", "cleanup", "credentials-rotation"),
        aliases=("diagnostics", "debugging", "problems", "errors"),
    ),
    Topic(
        slug="cleanup",
        title="Cleanup and Destruction",
        summary=(
            "Application cleanup, manifest reset, and full infrastructure destruction are "
            "different operations with materially different data-loss and cloud impact."
        ),
        key_points=(
            "clean-deployment.sh removes application resources and can delete database and EFS data.",
            "destroy.sh targets the complete AWS deployment and is irreversible.",
            "restore-defaults.sh changes local manifests and should not be confused with cluster cleanup.",
            "Back up data, verify account/region/cluster context, and read prompts before cleanup.",
        ),
        sources=(
            source("scripts/clean-deployment.sh", "Application cleanup implementation", 1),
            source("scripts/destroy.sh", "Full infrastructure destruction", 1),
            source("scripts/restore-defaults.sh", "Local manifest reset behavior", 1),
            source("scripts/README.md", "Operational distinctions and warnings", 3),
            source("docs/TROUBLESHOOTING.md", "Cleanup cautions", 3),
        ),
        related_topics=("backup-restore-dr", "deployment", "troubleshooting"),
        aliases=("destroy", "delete", "teardown", "reset"),
    ),
    Topic(
        slug="openemr-initialization",
        title="OpenEMR Initialization and Training Data",
        summary=(
            "The deployment manifest configures OpenEMR startup and readiness, while the training "
            "workflow deploys infrastructure and imports synthetic OMOP data through Warp."
        ),
        key_points=(
            "k8s/deployment.yaml is authoritative for containers, probes, mounts, and initialization.",
            "k8s/deploy.sh prepares and applies the application manifests.",
            "The training setup is not a local data generator; it deploys cloud resources and accesses S3.",
            "Synthetic training data must never be confused with production PHI.",
        ),
        sources=(
            source("k8s/deployment.yaml", "OpenEMR pod initialization and runtime", 1),
            source("k8s/deploy.sh", "Application setup and manifest application", 1),
            source("scripts/deploy-training-openemr-setup.sh", "Training environment orchestration", 1),
            source("warp/README.md", "Synthetic data import behavior", 3),
            source("docs/DEPLOYMENT_GUIDE.md", "Initialization and post-deployment guidance", 3),
        ),
        related_topics=("deployment", "testing", "architecture"),
        aliases=("initialization", "init", "training", "synthetic-data", "openemr"),
    ),
)


def risk(
    level: str,
    *,
    read_only: bool,
    destructive: bool = False,
    cloud_affecting: bool = False,
    costly: bool = False,
    requires_active_context: bool = False,
    requires_network: bool = False,
) -> RiskProfile:
    return RiskProfile(
        level=level,
        read_only=read_only,
        destructive=destructive,
        cloud_affecting=cloud_affecting,
        costly=costly,
        requires_active_context=requires_active_context,
        requires_network=requires_network,
    )


COMMANDS: tuple[OperationalCommand, ...] = (
    OperationalCommand(
        task="Validate the local knowledge server repository",
        command="uvx --from ./tools/codebase-mcp openemr-eks-mcp --repo-root . --check",
        description="Checks repository discovery, policy, and version parsing; starts no MCP transport.",
        aliases=("knowledge check", "mcp check", "validate mcp"),
        prerequisites=("uv", "local repository checkout"),
        source_paths=("docs/KNOWLEDGE_MCP.md", "tools/codebase-mcp/pyproject.toml"),
        risk=risk("local-safe", read_only=True),
    ),
    OperationalCommand(
        task="Deploy the complete OpenEMR stack",
        command="./scripts/quick-deploy.sh",
        description="Provisions infrastructure, deploys OpenEMR, and installs monitoring.",
        aliases=("quick deploy", "deploy everything", "provision stack"),
        prerequisites=("AWS credentials", "reviewed Terraform variables", "AWS service quotas"),
        source_paths=("scripts/quick-deploy.sh", "docs/DEPLOYMENT_GUIDE.md"),
        risk=risk(
            "high-impact",
            read_only=False,
            cloud_affecting=True,
            costly=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Deploy or update the OpenEMR application layer",
        command="./k8s/deploy.sh",
        description="Resolves infrastructure context and applies Kubernetes application resources.",
        aliases=("deploy application", "apply manifests", "openemr deploy"),
        prerequisites=("deployed infrastructure", "AWS credentials", "correct cluster context"),
        source_paths=("k8s/deploy.sh", "k8s/README.md"),
        risk=risk(
            "mutating",
            read_only=False,
            cloud_affecting=True,
            costly=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Install the optional monitoring stack",
        command="./monitoring/install-monitoring.sh",
        description="Installs observability workloads and configures cloud-backed storage integrations.",
        aliases=("install monitoring", "install grafana", "observability setup"),
        prerequisites=(
            "deployed cluster",
            "Terraform monitoring outputs",
            "correct cluster context",
        ),
        source_paths=("monitoring/install-monitoring.sh", "monitoring/README.md"),
        risk=risk(
            "mutating",
            read_only=False,
            cloud_affecting=True,
            costly=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Validate a running deployment",
        command="./scripts/validate-deployment.sh",
        description="Performs live infrastructure, cluster, workload, storage, and policy checks.",
        aliases=("deployment health", "health check", "validate cluster"),
        prerequisites=("AWS credentials", "correct cluster context", "deployed infrastructure"),
        source_paths=("scripts/validate-deployment.sh", "docs/TROUBLESHOOTING.md"),
        risk=risk(
            "read-only-cloud",
            read_only=True,
            cloud_affecting=False,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Validate EFS CSI storage",
        command="./scripts/validate-efs-csi.sh",
        description="Checks the live EFS CSI add-on, storage classes, volumes, and connectivity.",
        aliases=("efs check", "storage validation", "pending pod storage"),
        prerequisites=("AWS credentials", "correct cluster context"),
        source_paths=("scripts/validate-efs-csi.sh", "docs/TROUBLESHOOTING.md"),
        risk=risk(
            "read-only-cloud",
            read_only=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Create an on-demand backup",
        command="./scripts/backup.sh",
        description="Creates and stores application-aware database, configuration, and data backups.",
        aliases=("backup deployment", "create backup", "disaster recovery backup"),
        prerequisites=("AWS credentials", "correct cluster context", "backup storage budget"),
        source_paths=("scripts/backup.sh", "docs/BACKUP_RESTORE_GUIDE.md"),
        risk=risk(
            "mutating",
            read_only=False,
            cloud_affecting=True,
            costly=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Restore a deployment from backup",
        command="./scripts/restore.sh <backup-bucket> <snapshot-id> --region <aws-region>",
        description="Runs phased recovery and replaces deployment data from a selected backup.",
        aliases=("restore backup", "disaster recovery", "recover deployment"),
        prerequisites=(
            "verified backup identifiers",
            "AWS credentials",
            "approved recovery window",
        ),
        source_paths=("scripts/restore.sh", "docs/BACKUP_RESTORE_GUIDE.md"),
        risk=risk(
            "destructive",
            read_only=False,
            destructive=True,
            cloud_affecting=True,
            costly=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Verify credential rotation prerequisites",
        command="./scripts/verify-credential-rotation.sh",
        description="Reads live Secrets Manager, Kubernetes, EFS, and Terraform-derived state.",
        aliases=("verify rotation", "credential preflight", "rotation readiness"),
        prerequisites=("AWS credentials", "correct cluster context", "deployed rotation resources"),
        source_paths=("scripts/verify-credential-rotation.sh", "docs/CREDENTIAL_ROTATION_GUIDE.md"),
        risk=risk(
            "read-only-cloud",
            read_only=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Rotate Aurora application credentials",
        command="./scripts/run-credential-rotation.sh",
        description="Runs the A/B credential flip, workload restart, validation, and old-slot rotation.",
        aliases=("rotate credentials", "rotate database password", "credential rotation"),
        prerequisites=(
            "successful rotation preflight",
            "AWS credentials",
            "correct cluster context",
        ),
        source_paths=("scripts/run-credential-rotation.sh", "docs/CREDENTIAL_ROTATION_GUIDE.md"),
        risk=risk(
            "high-impact",
            read_only=False,
            cloud_affecting=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Check centrally managed component versions",
        command="./scripts/version-manager.sh status",
        description=(
            "Reports locally recorded versions and writes the version-manager log and temporary working files; "
            "update checks additionally use network and optional AWS APIs."
        ),
        aliases=("version status", "component versions", "dependency inventory"),
        prerequisites=("local repository checkout",),
        source_paths=("scripts/version-manager.sh", "docs/VERSION_MANAGEMENT.md"),
        risk=risk("local-writing", read_only=False),
    ),
    OperationalCommand(
        task="Check for available component version updates",
        command="./scripts/version-manager.sh check",
        description="Queries upstream sources and may use AWS APIs for definitive managed-service versions.",
        aliases=("check version updates", "available upgrades", "latest component versions"),
        prerequisites=("network access", "optional AWS credentials for managed-service lookups"),
        source_paths=("scripts/version-manager.sh", "docs/VERSION_MANAGEMENT.md"),
        risk=risk(
            "read-only-network",
            read_only=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Run repository-local validation suites",
        command="./scripts/run-test-suite.sh --dry-run",
        description="Shows planned suites without invoking live validation; remove --dry-run only after review.",
        aliases=("test dry run", "list tests", "local tests"),
        prerequisites=("test toolchain",),
        source_paths=("scripts/run-test-suite.sh", "docs/TESTING_GUIDE.md"),
        risk=risk("local-safe", read_only=True),
    ),
    OperationalCommand(
        task="Run the end-to-end backup and restore exercise",
        command="./scripts/test-end-to-end-backup-restore.sh --cluster-name <development-cluster>",
        description="Creates, mutates, and deletes AWS resources while exercising deployment and DR.",
        aliases=("e2e backup restore", "full e2e", "disaster recovery test"),
        prerequisites=(
            "development-only AWS account",
            "saved local manifest changes",
            "cost approval",
        ),
        source_paths=(
            "scripts/test-end-to-end-backup-restore.sh",
            "docs/END_TO_END_TESTING_REQUIREMENTS.md",
        ),
        risk=risk(
            "destructive",
            read_only=False,
            destructive=True,
            cloud_affecting=True,
            costly=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Remove the deployed application layer",
        command="./scripts/clean-deployment.sh",
        description="Deletes application resources and can remove Aurora and EFS data.",
        aliases=("clean deployment", "remove application", "reset deployment"),
        prerequisites=("verified backup", "explicit data-loss approval", "correct cluster context"),
        source_paths=("scripts/clean-deployment.sh", "scripts/README.md"),
        risk=risk(
            "destructive",
            read_only=False,
            destructive=True,
            cloud_affecting=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Destroy all provisioned infrastructure",
        command="./scripts/destroy.sh",
        description="Irreversibly removes the project AWS infrastructure and associated data resources.",
        aliases=("destroy infrastructure", "delete everything", "full teardown"),
        prerequisites=(
            "verified account and region",
            "verified backup",
            "explicit destruction approval",
        ),
        source_paths=("scripts/destroy.sh", "scripts/README.md"),
        risk=risk(
            "destructive",
            read_only=False,
            destructive=True,
            cloud_affecting=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
    OperationalCommand(
        task="Deploy a training environment with synthetic patients",
        command=("./scripts/deploy-training-openemr-setup.sh --use-default-dataset --max-records <count>"),
        description="Deploys cloud infrastructure and imports synthetic OMOP data through Warp.",
        aliases=("training setup", "synthetic patients", "initialize openemr"),
        prerequisites=("development AWS account", "AWS credentials", "reviewed record count"),
        source_paths=("scripts/deploy-training-openemr-setup.sh", "warp/README.md"),
        risk=risk(
            "high-impact",
            read_only=False,
            cloud_affecting=True,
            costly=True,
            requires_active_context=True,
            requires_network=True,
        ),
    ),
)
