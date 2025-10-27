# OpenEMR on EKS - Deployment Timings Guide

## 📊 Overview

This guide provides measured timing data for various operations in the OpenEMR on EKS deployment, based on actual end-to-end test runs. All timings are measured in AWS `us-west-2` region with standard configurations.

> **Note:** Timings can vary based on AWS region, time of day, AWS service load, and network conditions. The ranges provided represent typical behavior observed across multiple test runs.

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

- [Cleanup Operations](#%EF%B8%8F-cleanup-operations)
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

**Total Time:** 30-32 minutes

| Component | Duration | Notes |
|-----------|----------|-------|
| **EKS Cluster** | 15-20 min | Longest component; includes control plane setup |
| **Aurora RDS Cluster** | 10-12 min | Includes primary and replica instances |
| **VPC & NAT Gateways** | 3-5 min | Network infrastructure setup |
| **Other Resources** | 5-8 min | S3, EFS, ElastiCache, KMS, WAF, CloudWatch |

**Breakdown by Resource Type:**
- **Networking** (VPC, Subnets, Route Tables, NAT, IGW): 3-5 min
- **Compute** (EKS Cluster, Auto Mode): 15-20 min
- **Database** (Aurora Serverless v2): 10-12 min
- **Storage** (S3, EFS): 2-3 min
- **Caching** (ElastiCache Serverless): 2-3 min
- **Security** (KMS, WAF, Security Groups): 3-5 min
- **Monitoring** (CloudWatch Log Groups): 1-2 min

### Application Deployment (Kubernetes)

**Total Time:** 7-11 minutes (normal), can spike to 19 minutes

| Component | Duration | Notes |
|-----------|----------|-------|
| **OpenEMR Pods** | 5-8 min | Container image pull + startup |
| **Load Balancer** | 2-3 min | AWS ALB provisioning |
| **Health Checks** | 1-2 min | Waiting for readiness probes |

**Variability Factors:**
- **First deployment:** Slower (10-11 min) - full image pull
- **Subsequent deployments:** Faster (7-8 min) - cached images
- **Anomalous delays:** Can spike to 19 min (pod scheduling issues, image pull timeouts)

### Combined Initial Deployment

**Total Time:** 40-45 minutes
- Infrastructure (Terraform): 30-32 min
- Application (Kubernetes): 7-11 min
- Buffer for variations: 2-4 min

---

## 💾 Backup Operations

### Full Backup Creation

**Total Time:** 30-35 seconds (very consistent)

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

**Total Time:** 38-43 minutes (comprehensive restore)

| Component | Duration | Notes |
|-----------|----------|-------|
| **Clean Deployment** | 3-5 min | Wipe EFS, clean database, restart CSI driver |
| **OpenEMR Deployment** | 5-6 min | Fresh deployment with initial setup |
| **RDS Cluster Destroy** | 11-13 min | Delete existing instances and cluster |
| **RDS Cluster Restore** | 11-13 min | Restore from snapshot, create instances |
| **Application Data Restore** | <1 min | Download from S3 and extract to EFS |
| **Crypto Key Cleanup** | 40 sec | Delete sixa/sixb, wait for regeneration |
| **Verification (with retry)** | 10 sec | Poll for pod readiness (3 attempts max) |

**Performance Characteristics:**
- **Consistent timing:** 38-43 min across multiple runs (±6% variation)
- **Test Run 1:** 38 minutes 20 seconds
- **Test Run 2:** 42 minutes 38 seconds
- **Average:** ~40 minutes

**Process Enhancements (v3.0.0):**
- ✅ **Automatic crypto key cleanup** - Prevents encryption key mismatches
- ✅ **Verification with retry** - Up to 3 attempts with 5-minute timeout each
- ✅ **Configurable polling** - Adjustable timeout and interval via environment variables
- ✅ **IRSA for data restoration** - Secure AWS credentials for S3 access
- ✅ **Fail-fast deployment detection** - Detects missing deployments immediately

---

## 🗑️ Cleanup Operations

### Infrastructure Deletion (Terraform Destroy)

**Total Time:** 13-16 minutes

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

**Total Time:** 120-130 minutes (~2 hours)

| Phase | Duration | Steps |
|-------|----------|-------|
| **1. Initial Deploy** | 31-32 min | Infrastructure + application |
| **2. OpenEMR Deploy** | 7-11 min | Application deployment |
| **3. Test Data** | 7-8 sec | Create proof file |
| **4. Backup** | 30-35 sec | Full backup creation |
| **5. Monitoring Test** | 7-8 min | Install/uninstall monitoring stack |
| **6. Deletion** | 16-17 min | Destroy all infrastructure |
| **7. Recreation** | 40-42 min | Redeploy infrastructure |
| **8. Restore** | 38-43 min | Full restore (clean + deploy + restore data) |
| **9. Verification** | 10-15 sec | Verify restored data |
| **10. Final Cleanup** | 13-14 min | Clean up all resources |

**Total Measured Duration:** 
- Average: 160-165 minutes (with updated restore timing)
- Range: 155-170 minutes across multiple test runs

---

## 📦 Monitoring Stack Operations

### Prometheus/Grafana/Loki Installation

**Total Time:** 7-8 minutes

| Component | Duration | Notes |
|-----------|----------|-------|
| **cert-manager** | 1-2 min | Certificate management |
| **Prometheus Operator** | 3-4 min | Metrics collection |
| **Loki** | 2-3 min | Log aggregation |
| **Grafana** | 1-2 min | Dashboard deployment |

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
| Service endpoint update | 2-4 min |
| Security group rule update | 1-2 min |
| IAM role/policy creation | 1-2 min |
| EFS mount target creation | 2-3 min |

---

## 📈 Performance Insights

### Consistent Metrics (Low Variability)

These operations have very predictable timing:

- **Infrastructure Deployment:** ±1% variation (30-32 min)
- **Backup Creation:** ±15% variation (30-35 sec)
- **Test Data Creation:** ±10% variation (7-8 sec)
- **Monitoring Stack:** ±5% variation (7-8 min)
- **Restore Operations:** ±6% variation (38-43 min)
  - Fast: 38 min
  - Normal: 40-43 min
  - Very consistent due to comprehensive process
  - Recommendation: Plan for 45 min to be safe

### Variable Metrics (High Variability)

These operations can vary significantly:

- **OpenEMR Deployment:** ±135% variation (7-19 min)
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
- **Backup operation:** 2 minutes (includes verification)
- **Restore operation:** 45 minutes (full restore with verification)
- **Infrastructure teardown:** 25 minutes (includes verification)

### For Development/Testing

**Typical Time Budgets:**
- **Quick iteration:** 10-15 min (app changes only)
- **Full infrastructure test:** 45-60 min (single deployment)
- **Complete E2E test:** 130-150 min (includes buffer for failures)
- **Daily CI/CD run:** 180 min (includes retries and reporting)

### For Disaster Recovery Planning

**RTO (Recovery Time Objective) Estimates:**
- **Full restore process:** 40-43 minutes (includes all steps)
- **DNS propagation:** 5-60 minutes (not measured, varies by DNS provider)
- **Total RTO:** 45-105 minutes

**RPO (Recovery Point Objective):**
- Based on backup frequency (manual or scheduled)
- Typical backup: Every 6-24 hours
- Data loss window: 0-24 hours

---

## 📊 Timing Comparison Table

### By Operation Type

| Operation | Quick (Best Case) | Typical | Slow (Worst Case) | Notes |
|-----------|-------------------|---------|-------------------|-------|
| **Infrastructure Deploy** | 30 min | 31 min | 32 min | Very consistent |
| **App Deploy** | 7 min | 9 min | 19 min | High variability |
| **Backup** | 29 sec | 32 sec | 35 sec | Very consistent |
| **Restore** | 38 min | 40 min | 43 min | Very consistent (v3.0) |
| **Infrastructure Delete** | 13 min | 15 min | 17 min | With robustness features |
| **Full E2E Test** | 155 min | 162 min | 170 min | Includes all phases |

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

This timing data is based on multiple complete end-to-end test runs performed in October 2025.

**Test Environment:**
- AWS Region: us-west-2
- EKS Version: 1.34
- OpenEMR Version: 7.0.3
- Aurora: Serverless v2 (0.5-16 ACU)
- ElastiCache: Serverless (Valkey 8.0)

**Configuration:**
- Standard production configuration
- 2 OpenEMR replicas
- Enhanced monitoring enabled
- All security features enabled
- Backup retention: 7 days

**Measurement Approach:**
- Multiple complete test cycles executed
- Measured in production-like environment
- Real-world conditions (no artificial optimizations)
- Includes robustness features and retry logic

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
5. Review verification retry attempts (max 3 attempts of 5 min each)

---

## 📚 Related Documentation

- [Deployment Guide](DEPLOYMENT_GUIDE.md) - Step-by-step deployment instructions
- [Backup & Restore Guide](BACKUP_RESTORE_GUIDE.md) - Backup/restore procedures
- [Troubleshooting Guide](TROUBLESHOOTING.md) - Common issues and solutions

---