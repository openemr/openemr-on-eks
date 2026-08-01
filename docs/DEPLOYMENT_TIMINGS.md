# OpenEMR on EKS Deployment Timings Guide

## 📊 Overview

This guide provides measured timing data for various operations in the OpenEMR on EKS deployment, based on actual end-to-end test runs. All timings are measured in AWS `us-west-2` region with standard configurations.

> **Note:** Timings can vary based on AWS region, time of day, AWS service
> load, and network conditions. The OpenEMR 8.2.0 figures are one complete
> baseline run; historical ranges are labeled separately.

<!-- BEGIN AUTOMATED E2E TIMINGS -->
## Latest Automated E2E Timing Report

- **Generated:** 2026-08-01 16:16:16 UTC
- **OpenEMR:** 8.2.0
- **AWS Region:** us-west-2
- **Scope:** full 10-step suite
- **Run ID:** 20260801-092706
- **Total elapsed:** 10149s (169m 9s)

| Phase | Status | Seconds | Duration |
|---|---:|---:|---:|
| Infrastructure Deployment | SUCCESS | 1432 | 23m 52s |
| OpenEMR Deployment | SUCCESS | 1050 | 17m 30s |
| Test Data Deployment | SUCCESS | 314 | 5m 14s |
| Backup Creation | SUCCESS | 40 | 0m 40s |
| Monitoring Stack Test | SUCCESS | 1095 | 18m 15s |
| Infrastructure Deletion | SUCCESS | 1290 | 21m 30s |
| Infrastructure Recreation | SUCCESS | 1575 | 26m 15s |
| Backup Restoration | SUCCESS | 2013 | 33m 33s |
| Restoration Verification | SUCCESS | 51 | 0m 51s |
| Final Cleanup | SUCCESS | 1283 | 21m 23s |

<!-- END AUTOMATED E2E TIMINGS -->

## 📋 Table of Contents

### **Deployment Operations**

- [Initial Deployment](#-initial-deployment)
  - [Full Infrastructure Deployment (Terraform)](#full-infrastructure-deployment-terraform)
  - [Application Deployment (Kubernetes)](#application-deployment-kubernetes)
  - [Combined Initial Deployment](#combined-initial-deployment)

### **Backup & Restore**

- [Backup Operations](#-backup-operations)
  - [Full Backup Creation](#full-backup-creation)
  - [Snapshot Listing/Verification](#snapshot-listingverification)
- [Restore Operations](#-restore-operations)
  - [Full Restore from Backup](#full-restore-from-backup)

### **Cleanup & Monitoring**

- [Cleanup Operations](#cleanup-operations)
  - [Infrastructure Deletion (Terraform Destroy)](#infrastructure-deletion-terraform-destroy)
  - [S3 Bucket Cleanup](#s3-bucket-cleanup)
  - [CloudWatch Log Group Cleanup](#cloudwatch-log-group-cleanup)
  - [RDS Snapshot Cleanup](#rds-snapshot-cleanup)
- [Monitoring Stack Operations](#-monitoring-stack-operations)
  - [Prometheus/Grafana/Loki Installation](#prometheusgrafanaloki-installation)
  - [Monitoring Stack Uninstallation](#monitoring-stack-uninstallation)

### **Testing & Analysis**

- [End-to-End Test Suite](#-end-to-end-test-suite)
  - [Complete Backup/Restore Test](#complete-backuprestore-test)
- [Quick Operations](#-quick-operations)
  - [Fast Operations (< 1 minute)](#fast-operations--1-minute)
  - [Medium Operations (1-5 minutes)](#medium-operations-1-5-minutes)
- [Performance Insights](#-performance-insights)
  - [Consistent Metrics (Low Variability)](#consistent-metrics-low-variability)
  - [Variable Metrics (High Variability)](#variable-metrics-high-variability)
  - [Factors Affecting Timing](#factors-affecting-timing)

### **Planning & Best Practices**

- [Planning Guidelines](#-planning-guidelines)
  - [For Production Deployments](#for-production-deployments)
  - [For Development/Testing](#for-developmenttesting)
  - [For Disaster Recovery Planning](#for-disaster-recovery-planning)
- [Timing Comparison Table](#-timing-comparison-table)
- [Optimization Opportunities](#-optimization-opportunities)
- [Best Practices](#-best-practices)
  - [For Accurate Timing Expectations](#for-accurate-timing-expectations)
  - [For Troubleshooting Slow Operations](#for-troubleshooting-slow-operations)

### **Reference**

- [Data Sources](#-data-sources)
- [Related Documentation](#-related-documentation)

---

## 🚀 Initial Deployment

### Full Infrastructure Deployment (Terraform)

**Current OpenEMR 8.2.0 full-run measurement:** 23 minutes 52 seconds
(1,432 seconds, August 1, 2026).

**Historical total time:** 24-25 minutes (OpenEMR 8.0.x, December 2025)

| Component | Duration | Notes |
|-----------|----------|-------|
| **EKS Cluster** | 15-20 min | Longest component; includes control plane setup |
| **Aurora RDS Cluster** | 10-12 min | Includes primary and replica instances |
| **VPC & NAT Gateways** | 3-5 min | Network infrastructure setup |
| **Other Resources** | 5-8 min | S3, EFS, ElastiCache, KMS, WAF, CloudWatch |

**Historical December 2025 measurements:**
- Test Run 1: 25.25 minutes (1,515 seconds)
- Test Run 2: 24.57 minutes (1,474 seconds)
- Average: ~25 minutes (consistent with previous measurements)

**Breakdown by Resource Type:**
- **Networking** (VPC, Subnets, Route Tables, NAT, IGW): 3-5 min
- **Compute** (EKS Cluster, Auto Mode): 15-20 min
- **Database** (Aurora Serverless v2): 10-12 min
- **Storage** (S3, EFS): 2-3 min
- **Caching** (ElastiCache Serverless): 2-3 min
- **Security** (KMS, WAF, Security Groups): 3-5 min
- **Monitoring** (CloudWatch Log Groups): 1-2 min

### Application Deployment (Kubernetes)

**Current OpenEMR 8.2.0 full-run measurement:** 17 minutes 30 seconds
(1,050 seconds, August 1, 2026). This is the complete E2E application
deployment phase, including deployment-script prerequisites and readiness
checks.

> **Historical benchmark:** The OpenEMR 8.1.x timings below were recorded in
> July 2026 and are retained for comparison.

**Total Time (OpenEMR 8.1.x):** 8-12 minutes typical for `k8s/deploy.sh` end-to-end

| Component | Duration (8.1.x) | Notes |
|-----------|------------------|-------|
| **EFS CSI / prerequisites** | 2-4 min | Addon rollouts, PVC binding |
| **OpenEMR pod ready** | 3-6 min | HTTP readiness; much faster than 8.0.x |
| **Load Balancer** | 2-3 min | AWS ALB provisioning (parallel with pod startup) |
| **DB verify + SSL setup** | 1-2 min | Included in deploy.sh |

**OpenEMR 8.1.x (July 2026):** Pod readiness typically **3-6 minutes**; plan **10 minutes** as a safe ceiling.

**December 2025 measurements (OpenEMR 8.0.x era — slower startup):**

**Total Time:** 22-23 minutes (full deploy.sh including slower swarm init)

| Component | Duration | Notes |
|-----------|----------|-------|
| **OpenEMR Pods** | 20-22 min | Container image pull + startup + health checks |
| **Load Balancer** | 2-3 min | AWS ALB provisioning |
| **Health Checks** | 1-2 min | Waiting for readiness probes |

**December 2025 Measurements:**
- Initial Deployment Run 1: 22.05 minutes (1,323 seconds)
- Initial Deployment Run 2: 23.32 minutes (1,399 seconds)
- Restore Deployment Run 1: 25.48 minutes (1,529 seconds)
- Restore Deployment Run 2: 21.98 minutes (1,319 seconds)
- Average: 22-23 minutes

**Variability Factors:**
- Image pull times (initial deployments typically faster due to cached images on subsequent runs)
- Pod scheduling and node availability in EKS Auto Mode
- Health check intervals and readiness probe configuration
- Database connectivity and initialization time

### Combined Initial Deployment

**Current OpenEMR 8.2.0 full-run measurement:** 41 minutes 22 seconds for
steps 1-2 (infrastructure plus OpenEMR). Including test-data setup, steps 1-3
took 46 minutes 36 seconds.

**Historical total time (OpenEMR 8.1.x):** 35-42 minutes
- Infrastructure (Terraform): 30-32 min
- Application (Kubernetes): 3-6 min typical, 8-12 min full deploy.sh
- Buffer for variations: 2-4 min

**Current resume deploy chunk:** 22 minutes 44 seconds for steps 2-3 only.

---

## 💾 Backup Operations

### Full Backup Creation

**Current OpenEMR 8.2.0 full-run measurement:** 40 seconds.

**Historical total time:** 30-35 seconds.

| Component | Duration | Notes |
|-----------|----------|-------|
| **RDS Snapshot** | ~20 sec | AWS-managed, very fast |
| **S3 Data Backup** | ~5 sec | Application data (sitemap, documents) |
| **K8s Config Backup** | ~4 sec | Manifests and configurations |
| **Metadata Generation** | ~3 sec | Backup manifest and reports |

**Performance Characteristics:**
- ✅ **Very consistent** - minimal variation across runs
- ✅ **Incremental snapshots** - after first backup, RDS uses incremental
- ✅ **Parallel execution** - all components run concurrently

### Snapshot Listing/Verification

**Time:** 1-2 seconds per snapshot query

---

## 🔄 Restore Operations

### Full Restore from Backup

**Current OpenEMR 8.2.0 full-run measurement:** 33 minutes 33 seconds
(2,013 seconds, August 1, 2026).

This full-suite E2E phase used the current
`preflight → bootstrap → rds → data → deploy → verify` flow and includes the
configured 180-second post-restore observation window. An earlier resumed
recovery-path sample measured 34 minutes 57 seconds.

**Historical Total Time:** 53-55 minutes (OpenEMR 8.0.x, December 2025)

These measurements predate the current
`preflight → bootstrap → rds → data → deploy → verify` default flow. Treat them
as historical planning evidence; the current OpenEMR 8.2.0 measurement is
reported above.

| Component | Duration | Notes |
|-----------|----------|-------|
| **Clean Deployment** | 3-5 min | Wipe EFS, clean database, restart CSI driver |
| **OpenEMR Deployment** | 22-26 min | Fresh deployment with initial setup |
| **RDS Cluster Destroy** | 11-13 min | Delete existing instances and cluster |
| **RDS Cluster Restore** | 11-13 min | Restore from snapshot, create instances |
| **Application Data Restore** | <1 min | Download from S3 and extract to EFS |
| **Crypto Key Cleanup** | 40 sec | Delete sixa/sixb, wait for regeneration |
| **Verification (with retry)** | 43 sec | Historical success time; current default permits 6 attempts |

**Performance Characteristics:**
- **December 2025 Test Run 1:** 55.35 minutes (3,321 seconds)
- **December 2025 Test Run 2:** 52.82 minutes (3,169 seconds)
- **Average:** ~54 minutes
- **Variation:** ±2.5% (very consistent)

**Current restore controls:**
- ✅ **Automatic crypto key cleanup** - Prevents encryption key mismatches
- ✅ **Verification with retry** - Up to 6 attempts with a 5-minute poll
  window per attempt
- ✅ **Configurable polling** - Adjustable timeout and interval via environment variables
- ✅ **IRSA for data restoration** - Secure AWS credentials for S3 access
- ✅ **Fail-fast deployment detection** - Detects missing deployments immediately

---

## 🔄 Infrastructure Recreation

### Full Infrastructure Recreation (After Deletion)

**Current OpenEMR 8.2.0 full-run measurement:** 26 minutes 15 seconds
(1,575 seconds, August 1, 2026).

The current step 7 plan uses `skip_rds_creation=true`, then performs its
60-second infrastructure wait and EFS CSI readiness check. Aurora is restored
separately in step 8. An earlier resumed recovery-path sample measured
25 minutes 35 seconds.

**Historical Total Time:** 45-49 minutes (December 2025)

**December 2025 Measurements:**
- Test Run 1: 49.27 minutes (2,956 seconds)
- Test Run 2: 45.18 minutes (2,711 seconds)
- Average: ~47 minutes

**Performance Characteristics:**
- **Very consistent:** ±4.3% variation across test runs
- **Process:** Complete infrastructure deployment via Terraform after prior deletion
- **Use Case:** Part of disaster recovery and restore testing scenarios
- **Note:** This timing represents full infrastructure recreation as part of the restore test cycle, which includes all AWS resources (EKS, RDS, VPC, S3, EFS, etc.)

---

## Cleanup Operations

### Infrastructure Deletion (Terraform Destroy)

**Current OpenEMR 8.2.0 infrastructure-deletion measurement:** 21 minutes
30 seconds (1,290 seconds, step 6).

The final-cleanup phase measured 21 minutes 23 seconds (1,283 seconds, step 10).
It includes the comprehensive destroy workflow plus manual snapshot handling
and emptying/deleting the versioned backup bucket, so it is broader than
Terraform destruction alone. An earlier resumed final-cleanup sample measured
24 minutes 53 seconds.

**Historical Terraform destruction time:** 13-16 minutes

| Component | Duration | Notes |
|-----------|----------|-------|
| **RDS Cluster Deletion** | 7-9 min | Includes both instances |
| **EKS Cluster Deletion** | 3-5 min | Control plane teardown |
| **NAT Gateway Deletion** | 1-2 min | Network resource cleanup |
| **Other Resources** | 2-4 min | S3, EFS, ElastiCache, KMS, WAF |

**With Robustness Features (v3.0.0):**
- Base deletion time: 13.5 min
- With 30s propagation waits + verification: 16.3 min
- **Additional time:** +2.8 min for enhanced reliability

### S3 Bucket Cleanup

**Time:** 2-5 seconds per bucket (if empty), 10-30 seconds if versioned

### CloudWatch Log Group Cleanup

**Time:** 5-10 seconds for all log groups

### RDS Snapshot Cleanup

**Time:** 1-2 seconds per snapshot (API call only, actual deletion is asynchronous)

---

## 🧪 End-to-End Test Suite

### Complete Backup/Restore Test

**Current OpenEMR 8.2.0 full-suite baseline:** 10,149 seconds (169 minutes
9 seconds, August 1, 2026).

| E2E phase | OpenEMR 8.2.0 | Historical OpenEMR 8.0.x |
|-----------|---------------|--------------------------|
| **1. Infrastructure** | 23m 52s | 24-25 min |
| **2. OpenEMR Deploy** | 17m 30s | 22-23 min |
| **3. Test Data** | 5m 14s | 74-75 sec |
| **4. Backup** | 40 sec | 34-35 sec |
| **5. Monitoring Test** | 18m 15s | 27-28 min |
| **6. Deletion** | 21m 30s | 16-17 min |
| **7. Recreation** | 26m 15s | 45-49 min |
| **8. Restore** | 33m 33s | 53-55 min |
| **9. Verification** | 51 sec | 43 sec |
| **10. Final Cleanup** | 21m 23s | 18-18.5 min |

**Historical December 2025 full-suite totals:**
- **Test Run 1 (Dec 10, 2025):** 13,025 seconds (217.1 minutes / 3.62 hours)
- **Test Run 2 (Dec 10, 2025):** 12,673 seconds (211.2 minutes / 3.52 hours)
- **Average:** 211-217 minutes (3.5-3.6 hours)
- **Range:** 211-217 minutes across December 2025 test runs

**Historical December 2025 note:** Monitoring stack installation took 27-28
minutes, infrastructure recreation took 45-49 minutes, and backup restoration
took 53-55 minutes under that version of the workflow.

---

## 📦 Monitoring Stack Operations

### Prometheus/Grafana/Loki Installation

**Current OpenEMR 8.2.0 install/verify/uninstall cycle:** 18 minutes
15 seconds (1,095 seconds, August 1, 2026).

**Historical December 2025 cycle:** 27-28 minutes.

| Component | Duration | Notes |
|-----------|----------|-------|
| **Setup & Validation** | ~30 sec | Configuration validation, dependency checks, cluster connectivity |
| **Prometheus Operator** | ~1.5-2 min | Metrics collection (includes Prometheus and Grafana) |
| **Loki** | ~1 min | Log aggregation with S3 storage configuration |
| **Tempo** | ~30 sec | Distributed tracing (S3-backed) |
| **Mimir** | ~45 sec | Long-term metrics storage (S3-backed) |
| **OTeBPF** | ~20 sec | eBPF auto-instrumentation |
| **Total** | **~5.5 min** | Complete monitoring stack installation |

**Install/Uninstall Test Timing (December 2025):**
- **Test Run 1:** 26.98 minutes (1,619 seconds) - full install/uninstall cycle
- **Test Run 2:** 27.92 minutes (1,675 seconds) - full install/uninstall cycle
- **Average:** ~27-28 minutes (includes complete installation and uninstallation)
- **Note:** The monitoring stack test in the end-to-end test suite includes installation of all components (Prometheus, Grafana, Loki, Tempo, Mimir, OTeBPF) followed by complete uninstallation, which accounts for the longer duration compared to standalone installation timing

**Measured Installation Times (November 2025):**
- **Total Stack Installation**: 258 seconds (4.30 minutes) - end-to-end from script start to completion
- **Prometheus Stack**: ~1 minute 43 seconds (from installation start to pods ready)
- **Loki**: ~59 seconds (from Helm install start to pods ready)
- **Setup Phase**: ~30 seconds (validation, dependency checks, Terraform output retrieval)

**Note on Loki Installation:**
- **S3 Storage Setup**: Loki installation includes Terraform output retrieval, IAM role annotation, ServiceAccount creation, and S3 bucket configuration
- **Actual Timing**: ~1 minute (faster than initial estimate due to optimized configuration)
- **Architecture Improvement**: Uses AWS S3 for production-grade storage (as [recommended by Grafana](https://grafana.com/docs/loki/latest/setup/install/helm/configure-storage/)) instead of filesystem storage
- **Benefits**: Better durability, scalability, lifecycle management, and cost-effectiveness for production workloads
- **Persistence**: Uses 10Gi EBS volume for temporary files (read-only filesystem fix) while S3 is used for primary storage

### Monitoring Stack Uninstallation

**Total Time:** 30-60 seconds
- Helm uninstall commands: 10-15 sec each
- Resource cleanup: 10-20 sec

---

## ⚡ Quick Operations

### Fast Operations (< 1 minute)

| Operation | Duration |
|-----------|----------|
| Terraform plan | 15-30 sec |
| kubectl apply (single manifest) | 3-10 sec |
| kubectl get pods/services | 1-2 sec |
| AWS CLI queries | 1-3 sec |
| S3 file upload (< 10 MB) | 2-5 sec |
| CloudWatch log query (recent) | 2-5 sec |

### Medium Operations (1-5 minutes)

| Operation | Duration |
|-----------|----------|
| Pod restart | 1-3 min |
| Credential rotation (end-to-end) | 3-8 min |
| Service endpoint update | 2-4 min |
| Security group rule update | 1-2 min |
| IAM role/policy creation | 1-2 min |
| EFS mount target creation | 2-3 min |

---

## 📈 Performance Insights

### Current Samples and Historical Variability

The OpenEMR 8.2.0 full run provides these current samples:

- **Infrastructure Deployment:** 23m 52s
- **Backup Creation:** 40s
- **Test Data Creation:** 5m 14s
- **Monitoring Stack Test:** 18m 15s
- **Restore:** 33m 33s

One full run does not establish a variability range. Historical measurements
that did establish ranges include:

- **Infrastructure Deployment (December 2025):** ±1% variation (24-25 min)
- **Backup Creation (December 2025):** approximately 30-35 sec
- **Restore Operations (OpenEMR 8.0.x, December 2025):** ±2.5% variation
  (52.8-55.4 min)
  - Average: ~54 min
  - Current 8.2.0 measurement: 33m 33s

### Variable Metrics (High Variability)

These operations can vary significantly:

- **OpenEMR Deployment (8.2.0):** One full-run sample measured 17m 30s
  - Recommendation: plan for 20-25 min until additional 8.2.x runs establish a range

- **OpenEMR Deployment (8.1.x):** ±50% variation (3-10 min)
  - Normal: 3-6 min to HTTP ready
  - Spike: ~10 min (pod startup issues)
  - Recommendation: Plan for 10-12 min; timeouts use 15-20 min ceilings

- **OpenEMR Deployment (8.0.x and earlier):** ±135% variation (7-19 min)
  - Normal: 7-11 min
  - Anomaly: 19 min (pod startup issues)
  - Recommendation: Plan for 15 min to be safe

### Factors Affecting Timing

**AWS Service-Related:**
- Region capacity and load
- Time of day (peak vs. off-peak)
- AWS backend performance variations
- Resource quota limits

**Network-Related:**
- Container image pull speeds
- Inter-AZ latency
- Internet gateway performance
- NAT gateway bandwidth

**Configuration-Related:**
- Instance sizes (larger = faster startup)
- Number of replicas
- Health check intervals
- Resource requests/limits

---

## 🎯 Planning Guidelines

### For Production Deployments

**Minimum Time Windows:**
- **Initial deployment:** 60 minutes (includes buffer)
- **Application update:** 20 minutes (includes rollback time)
- **Credential rotation:** 10 minutes (includes validation and rolling restart)
- **Backup operation:** 2 minutes (includes verification)
- **Restore operation:** At least 45 minutes (8.2.0 measured 33m 33s)
- **Infrastructure teardown:** 25 minutes (includes verification)

### For Development/Testing

**Current OpenEMR 8.2.0 time budgets (August 2026):**
- **Application deployment:** 20-25 min (measured 17m 30s)
- **Cold deploy chunk (steps 1-3):** 50-55 min (measured 46m 36s)
- **Complete E2E test:** 180 min (measured 169m 9s)
- **Daily E2E run:** 190 min (includes reporting and operational buffer)

**Historical OpenEMR 8.1.x budgets (July 2026):**
- **Quick iteration:** 8-12 min (app changes only; pod ready ~3-6 min)
- **Full infrastructure test:** 35-45 min (single cold deployment)
- **Complete E2E test:** 150-160 min (~2.5 hours)
- **Daily CI/CD run:** 160-170 min (includes retries and reporting)

**December 2025 baselines (OpenEMR 8.0.x era):**
- **Quick iteration:** 10-15 min (app changes only)
- **Full infrastructure test:** 45-60 min (single deployment)
- **Complete E2E test:** 220-230 min (includes buffer for failures)
- **Daily CI/CD run:** 240-250 min (includes retries and reporting)

### For Disaster Recovery Planning

**Current OpenEMR 8.2.0 RTO evidence (August 2026):**
- **Infrastructure recreation:** 26m 15s
- **Full restore process:** 33m 33s
- **Recreation plus restore:** 59m 48s
- **DNS propagation:** 5-60 min (not measured; varies by DNS provider)
- **Planning window from destroyed infrastructure:** 65-120 min including DNS
- **Planning window with infrastructure intact:** 40-95 min including DNS

**Historical December 2025 estimates:**
- **Infrastructure recreation:** 45-49 minutes (if infrastructure was destroyed)
- **Full restore process:** 53-55 minutes (includes all restore steps)
- **Total restore (including infrastructure recreation):** 98-104 minutes (if starting from scratch)
- **DNS propagation:** 5-60 minutes (not measured, varies by DNS provider)
- **Total RTO (worst case):** 103-164 minutes (~1.7-2.7 hours)
- **Total RTO (infrastructure intact):** 58-115 minutes (~1-2 hours)

**RPO (Recovery Point Objective):**
- Based on backup frequency (manual or scheduled)
- Typical backup: Every 6-24 hours
- Data loss window: 0-24 hours

---

## 📊 Timing Comparison Table

### By Operation Type

| Operation | Current 8.2.0 sample | Historical comparison | Notes |
|-----------|----------------------|-----------------------|-------|
| **Infrastructure Deploy** | 23m 52s | 24-25 min (8.0.x) | Full-run step 1 |
| **App Deploy** | 17m 30s | 3-10 min (8.1.x) | Full-run step 2 |
| **Test Data** | 5m 14s | 74-75 sec (8.0.x) | Full-run step 3 |
| **Backup** | 40 sec | 34-35 sec (8.0.x) | Full-run step 4 |
| **Monitoring Cycle** | 18m 15s | 27-28 min (8.0.x) | Install, verify, uninstall |
| **Infrastructure Delete** | 21m 30s | 16-17 min (8.0.x) | Full-run step 6 |
| **Infrastructure Recreation** | 26m 15s | 45-49 min (8.0.x) | RDS deferred |
| **Restore** | 33m 33s | 53-55 min (8.0.x) | Includes observation window |
| **Verification** | 51 sec | 43 sec (8.0.x) | Full-run step 9 |
| **Final Cleanup** | 21m 23s | 18-18.5 min (8.0.x) | Includes backup cleanup |
| **Full E2E Test** | 169m 9s | 211-217 min (8.0.x) | Complete 10-step suite |

---

## 🔧 Optimization Opportunities

### Areas for Potential Time Savings

**Not Recommended (Breaks Reliability):**
- ❌ Reducing health check wait times
- ❌ Skipping verification steps
- ❌ Disabling propagation waits
- ❌ Reducing retry attempts

**Potentially Safe:**
- ✅ Using larger instance types (faster startup)
- ✅ Pre-warming container images
- ✅ Parallel resource creation (where possible)
- ✅ Regional service selection (closer regions)

**Already Optimized:**
- ✅ Parallel Terraform resource creation
- ✅ Concurrent backup operations
- ✅ Incremental RDS snapshots
- ✅ Efficient S3 operations

---

## 📝 Data Sources

This timing data combines the current OpenEMR 8.2.0 full-suite baseline with
historical complete runs from October and December 2025.

**Latest full run:**
- **August 1, 2026:** OpenEMR 8.2.0, run `20260801-092706`
- **Duration:** 10,149 seconds (169m 9s)
- **Result:** All 10 phases passed, including final resource cleanup

**Historical December 2025 runs:**
- **Test Run 1:** December 10, 2025 - 13,025 seconds (3.62 hours)
- **Test Run 2:** December 10, 2025 - 12,673 seconds (3.52 hours)
- Both tests completed successfully with all phases verified

**Test Environment:**
- AWS Region: us-west-2
- EKS Version: 1.36
- Current OpenEMR Version: 8.2.0
- Historical OpenEMR Version: 8.0.0
- Aurora: Serverless v2 (0.5-16 ACU)
- ElastiCache: Serverless (Valkey 8.0)

**Configuration:**
- Standard production configuration
- 2 OpenEMR replicas
- Enhanced monitoring enabled (Prometheus, Grafana, Loki, Tempo, Mimir, OTeBPF)
- All security features enabled
- Backup retention: 7 days

**Measurement Approach:**
- Multiple complete test cycles executed
- Measured in production-like environment
- Real-world conditions (no artificial optimizations)
- Includes robustness features and retry logic
- Timing data captured via comprehensive logging with timestamps

---

## 🎓 Best Practices

### For Accurate Timing Expectations

1. **Always add 25-50% buffer** for production planning
2. **Test in your target region** - timings vary by location
3. **Measure during peak hours** to understand worst-case scenarios
4. **Account for retries** in automation scripts
5. **Monitor trends over time** to detect performance degradation

### For Troubleshooting Slow Operations

**If deployment takes > 20 minutes longer than expected:**
1. Check AWS Service Health Dashboard
2. Review CloudWatch logs for errors
3. Check pod events: `kubectl describe pod <pod-name>`
4. Verify image pull times
5. Check resource quotas and limits

**If restore takes > 50 minutes:**
1. Check RDS instance deletion timing (should be ~11-13 min)
2. Check RDS cluster restore timing (should be ~11-13 min)
3. Check EFS wipe job completion (should complete in <5 min)
4. Verify crypto key cleanup and pod restart (should be ~40 sec)
5. Review verification retry attempts (default maximum: 6 attempts with a
   5-minute poll window each)

---

## 📚 Related Documentation

- [Deployment Guide](DEPLOYMENT_GUIDE.md) - Step-by-step deployment instructions
- [Backup & Restore Guide](BACKUP_RESTORE_GUIDE.md) - Backup/restore procedures
- [Troubleshooting Guide](TROUBLESHOOTING.md) - Common issues and solutions

---
