#!/bin/bash

# =============================================================================
# SSL Certificate Renewal Manager for OpenEMR EKS
# =============================================================================
#
# Purpose:
#   Manages the Kubernetes CronJob responsible for renewing SSL certificates
#   for OpenEMR on EKS. Provides commands to deploy, monitor, and manage the
#   SSL certificate renewal process with manual triggers and testing.
#
# Key Features:
#   - Deploy SSL certificate renewal CronJob
#   - Check SSL certificate and CronJob status
#   - Trigger immediate SSL certificate renewal
#   - View logs from renewal operations
#   - Run test jobs to validate renewal process
#   - Clean up old renewal jobs
#   - Display renewal schedule information
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - AWS credentials with ACM and Route53 permissions
#   - SSL certificate renewal CronJob YAML file (ssl-renewal.yaml)
#
# Usage:
#   ./ssl-renewal-manager.sh {deploy|status|run-now|logs|test|cleanup|schedule}
#
# Options:
#   deploy      Deploy SSL certificate renewal CronJob
#   status      Check SSL certificate and CronJob status
#   run-now     Trigger immediate SSL certificate renewal
#   logs        View logs from recent renewal operations
#   test        Run a test job to validate renewal process
#   cleanup     Clean up old renewal jobs
#   schedule    Display renewal schedule information
#
# Environment Variables:
#   NAMESPACE           Kubernetes namespace (default: openemr)
#   CRONJOB_NAME        CronJob name (default: ssl-cert-renewal)
#   TEST_JOB_NAME       Test job name (default: ssl-cert-renewal-test)
#
# Examples:
#   ./ssl-renewal-manager.sh deploy
#   ./ssl-renewal-manager.sh status
#   ./ssl-renewal-manager.sh run-now
#   ./ssl-renewal-manager.sh logs
#
# =============================================================================

set -e

# Script directories for Terraform state access
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Configuration variables - can be overridden via environment variables
NAMESPACE=${NAMESPACE:-"openemr"}                       # Kubernetes namespace for OpenEMR
CRONJOB_NAME=${CRONJOB_NAME:-"ssl-cert-renewal"}        # Name of the SSL renewal CronJob
TEST_JOB_NAME=${TEST_JOB_NAME:-"ssl-cert-renewal-test"} # Name for test jobs
AWS_REGION=${AWS_REGION:-"us-west-2"}                   # AWS region

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'    # Error messages and critical issues
GREEN='\033[0;32m'  # Success messages and positive feedback
YELLOW='\033[1;33m' # Warning messages and cautionary information
BLUE='\033[0;34m'   # Info messages and general information
NC='\033[0m'        # Reset color to default

# Get AWS region from environment or Terraform state
get_aws_region() {
    # Priority 1: Try to get region from Terraform state file (existing deployment takes precedence)
    if [ -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
        cd "$TERRAFORM_DIR"
        local terraform_region
        
        # Extract region directly from state file JSON
        terraform_region=$(grep -o '"region"[[:space:]]*:[[:space:]]*"[^"]*"' terraform.tfstate 2>/dev/null | \
            head -1 | \
            sed 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
        
        cd - >/dev/null
        
        # Validate region format
        if [ -n "$terraform_region" ] && [[ "$terraform_region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            AWS_REGION="$terraform_region"
            echo -e "${BLUE}ℹ️  Found AWS region from Terraform state: $AWS_REGION${NC}"
            return 0
        fi
    fi
    
    # Priority 2: If AWS_REGION is explicitly set via environment AND it's not the default, use it
    if [ -n "${AWS_REGION:-}" ] && [ "$AWS_REGION" != "us-west-2" ]; then
        # Validate it's a real region format (e.g., us-west-2, eu-west-1, ap-southeast-1)
        if [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            echo -e "${BLUE}ℹ️  Using AWS region from environment: $AWS_REGION${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  Invalid AWS_REGION format in environment: $AWS_REGION${NC}"
        fi
    fi
    
    # Priority 3: Fall back to default
    AWS_REGION="us-west-2"
    echo -e "${YELLOW}⚠️  Could not determine AWS region, using default: $AWS_REGION${NC}"
}

print_usage() {
    echo "Usage: $0 {deploy|status|run-now|logs|test|cleanup|schedule}"
    echo ""
    echo "Commands:"
    echo "  deploy     - Deploy the SSL renewal CronJob"
    echo "  status     - Check SSL certificate and CronJob status"
    echo "  run-now    - Trigger SSL renewal immediately"
    echo "  logs       - Show logs from recent SSL renewal jobs"
    echo "  test       - Run SSL certificate test job"
    echo "  cleanup    - Remove old SSL renewal jobs"
    echo "  schedule   - Show next scheduled renewal times"
    echo ""
    echo "Examples:"
    echo "  $0 deploy"
    echo "  $0 status"
    echo "  $0 run-now"
}

# Function to validate prerequisites before executing SSL renewal operations
# This function checks for required tools and AWS credentials
check_prerequisites() {
    # Validate kubectl availability
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl is not installed or not in PATH${NC}"
        exit 1
    fi

    # Validate AWS CLI availability
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}Error: AWS CLI is not installed or not in PATH${NC}"
        echo -e "${YELLOW}Install with: brew install awscli (macOS) or pip install awscli${NC}"
        exit 1
    fi

    # Validate AWS credentials and permissions
    echo -e "${BLUE}Checking AWS credentials...${NC}"
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}Error: AWS credentials not configured or invalid${NC}"
        echo -e "${YELLOW}Configure with: aws configure${NC}"
        echo -e "${YELLOW}Or set environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY${NC}"
        echo -e "${YELLOW}Or use IAM roles/instance profiles${NC}"
        exit 1
    fi

    # Get and display current AWS identity
    AWS_IDENTITY=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null || echo "Unknown")
    echo -e "${GREEN}AWS credentials valid - Identity: $AWS_IDENTITY${NC}"

    # Display current AWS region (already detected via get_aws_region)
    echo -e "${GREEN}AWS region: $AWS_REGION${NC}"

    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo -e "${RED}Error: Namespace '$NAMESPACE' does not exist${NC}"
        exit 1
    fi
}

deploy_ssl_renewal() {
    echo -e "${BLUE}Deploying SSL certificate renewal CronJob...${NC}"

    # Detect script location and set project root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ "$SCRIPT_DIR" == */scripts ]]; then
        PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    else
        PROJECT_ROOT="$SCRIPT_DIR"
    fi

    SSL_RENEWAL_FILE="$PROJECT_ROOT/k8s/ssl-renewal.yaml"

    if [ ! -f "$SSL_RENEWAL_FILE" ]; then
        echo -e "${RED}Error: k8s/ssl-renewal.yaml not found at $SSL_RENEWAL_FILE${NC}"
        echo -e "${YELLOW}Current directory: $(pwd)${NC}"
        echo -e "${YELLOW}Script directory: $SCRIPT_DIR${NC}"
        echo -e "${YELLOW}Project root: $PROJECT_ROOT${NC}"
        exit 1
    fi

    kubectl apply -f "$SSL_RENEWAL_FILE"
    echo -e "${GREEN}SSL renewal CronJob deployed successfully${NC}"

    # Show the schedule
    echo -e "${BLUE}CronJob schedule:${NC}"
    kubectl get cronjob "$CRONJOB_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.schedule}' && echo
}

check_status() {
    echo -e "${BLUE}=== SSL Certificate Status ===${NC}"

    # Check if SSL PVC exists and get certificate info
    if kubectl get pvc openemr-ssl-pvc -n "$NAMESPACE" &> /dev/null; then
        echo -e "${GREEN}SSL PVC exists${NC}"

        # Get certificate info by running a temporary pod
        echo -e "${BLUE}Checking certificate validity...${NC}"
        kubectl run ssl-check --rm -i --restart=Never --image=openemr/openemr:8.0.0 -n "$NAMESPACE" \
            --overrides='{"spec":{"containers":[{"name":"ssl-check","image":"openemr/openemr:8.0.0","command":["/bin/sh","-c","if [ -f /etc/ssl/certs/selfsigned.cert.pem ]; then echo \"Certificate found:\"; openssl x509 -in /etc/ssl/certs/selfsigned.cert.pem -noout -dates -subject; else echo \"No certificate found\"; fi"],"volumeMounts":[{"name":"ssl-vol","mountPath":"/etc/ssl"}]}],"volumes":[{"name":"ssl-vol","persistentVolumeClaim":{"claimName":"openemr-ssl-pvc"}}],"serviceAccountName":"openemr-sa"}}' \
            2>/dev/null || echo -e "${YELLOW}Could not check certificate (pod may still be starting)${NC}"
    else
        echo -e "${RED}SSL PVC does not exist${NC}"
    fi

    echo -e "\n${BLUE}=== CronJob Status ===${NC}"
    if kubectl get cronjob "$CRONJOB_NAME" -n "$NAMESPACE" &> /dev/null; then
        kubectl get cronjob "$CRONJOB_NAME" -n "$NAMESPACE"
        echo ""
        echo -e "${BLUE}Recent jobs:${NC}"
        kubectl get jobs -n "$NAMESPACE" -l app=ssl-cert-renewal --sort-by=.metadata.creationTimestamp | tail -5
    else
        echo -e "${YELLOW}SSL renewal CronJob not found${NC}"
    fi
}

run_renewal_now() {
    echo -e "${BLUE}Triggering SSL certificate renewal immediately...${NC}"

    # Create a manual job from the cronjob
    JOB_NAME="ssl-cert-renewal-manual-$(date +%Y%m%d-%H%M%S)"

    kubectl create job "$JOB_NAME" --from=cronjob/"$CRONJOB_NAME" -n "$NAMESPACE"
    echo -e "${GREEN}Manual renewal job '$JOB_NAME' created${NC}"

    echo -e "${BLUE}Waiting for job to complete...${NC}"
    kubectl wait --for=condition=complete --timeout=300s job/"$JOB_NAME" -n "$NAMESPACE" || {
        echo -e "${RED}Job did not complete within 5 minutes${NC}"
        echo -e "${YELLOW}Check logs with: $0 logs${NC}"
        return 1
    }

    echo -e "${GREEN}SSL certificate renewal completed successfully${NC}"

    # Show the logs
    echo -e "${BLUE}Job logs:${NC}"
    kubectl logs job/"$JOB_NAME" -n "$NAMESPACE"
}

show_logs() {
    echo -e "${BLUE}=== Recent SSL Renewal Job Logs ===${NC}"

    # Get the most recent ssl renewal job
    RECENT_JOB=$(kubectl get jobs -n "$NAMESPACE" -l app=ssl-cert-renewal --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

    if [ -n "$RECENT_JOB" ]; then
        echo -e "${BLUE}Logs from job: $RECENT_JOB${NC}"
        kubectl logs job/"$RECENT_JOB" -n "$NAMESPACE"
    else
        echo -e "${YELLOW}No SSL renewal jobs found${NC}"
    fi
}

run_test() {
    echo -e "${BLUE}Running SSL certificate test...${NC}"

    # Detect script location and set project root (same logic as deploy function)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ "$SCRIPT_DIR" == */scripts ]]; then
        PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    else
        PROJECT_ROOT="$SCRIPT_DIR"
    fi

    SSL_RENEWAL_FILE="$PROJECT_ROOT/k8s/ssl-renewal.yaml"

    if [ ! -f "$SSL_RENEWAL_FILE" ]; then
        echo -e "${RED}Error: k8s/ssl-renewal.yaml not found at $SSL_RENEWAL_FILE${NC}"
        echo -e "${YELLOW}Current directory: $(pwd)${NC}"
        echo -e "${YELLOW}Script directory: $SCRIPT_DIR${NC}"
        echo -e "${YELLOW}Project root: $PROJECT_ROOT${NC}"
        exit 1
    fi

    # Delete existing test job if it exists
    kubectl delete job "$TEST_JOB_NAME" -n "$NAMESPACE" 2>/dev/null || true

    # Apply the test job
    kubectl apply -f "$SSL_RENEWAL_FILE"

    echo -e "${BLUE}Waiting for test job to complete...${NC}"
    kubectl wait --for=condition=complete --timeout=60s job/"$TEST_JOB_NAME" -n "$NAMESPACE" || {
        echo -e "${RED}Test job did not complete within 1 minute${NC}"
        return 1
    }

    echo -e "${GREEN}Test completed successfully${NC}"
    echo -e "${BLUE}Test logs:${NC}"
    kubectl logs job/"$TEST_JOB_NAME" -n "$NAMESPACE"
}

cleanup_jobs() {
    echo -e "${BLUE}Cleaning up old SSL renewal jobs...${NC}"

    # Keep only the last 3 successful and 3 failed jobs (as configured in CronJob)
    # Delete jobs older than 7 days
    kubectl get jobs -n "$NAMESPACE" -l app=ssl-cert-renewal -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.creationTimestamp}{"\n"}{end}' | \
    while read job_name creation_time; do
        if [ -n "$job_name" ] && [ -n "$creation_time" ]; then
            # Convert creation time to epoch
            creation_epoch=$(date -d "$creation_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$creation_time" +%s 2>/dev/null || echo 0)
            current_epoch=$(date +%s)
            age_days=$(( (current_epoch - creation_epoch) / 86400 ))

            if [ "$age_days" -gt 7 ]; then
                echo "Deleting old job: $job_name (${age_days} days old)"
                kubectl delete job "$job_name" -n "$NAMESPACE"
            fi
        fi
    done

    echo -e "${GREEN}Cleanup completed${NC}"
}

show_schedule() {
    echo -e "${BLUE}=== SSL Certificate Renewal Schedule ===${NC}"

    if kubectl get cronjob "$CRONJOB_NAME" -n "$NAMESPACE" &> /dev/null; then
        SCHEDULE=$(kubectl get cronjob "$CRONJOB_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.schedule}')
        echo "Schedule: $SCHEDULE (every 2 days at 2 AM)"

        echo -e "\n${BLUE}Last scheduled run:${NC}"
        kubectl get cronjob "$CRONJOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastScheduleTime}' && echo

        echo -e "\n${BLUE}Next scheduled run:${NC}"
        # This is approximate - actual next run depends on the cron schedule
        echo "Next run will be within 2 days from the last run"

        echo -e "\n${BLUE}Active jobs:${NC}"
        ACTIVE_JOBS=$(kubectl get cronjob "$CRONJOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.active}')
        if [ -n "$ACTIVE_JOBS" ] && [ "$ACTIVE_JOBS" != "null" ]; then
            echo "Active renewal jobs: $ACTIVE_JOBS"
        else
            echo "No active renewal jobs"
        fi
    else
        echo -e "${RED}SSL renewal CronJob not found${NC}"
    fi
}

# Detect AWS region from Terraform state if not explicitly set
get_aws_region

# Main script logic
case "${1:-}" in
    deploy)
        check_prerequisites
        deploy_ssl_renewal
        ;;
    status)
        check_prerequisites
        check_status
        ;;
    run-now)
        check_prerequisites
        run_renewal_now
        ;;
    logs)
        check_prerequisites
        show_logs
        ;;
    test)
        check_prerequisites
        run_test
        ;;
    cleanup)
        check_prerequisites
        cleanup_jobs
        ;;
    schedule)
        check_prerequisites
        show_schedule
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
