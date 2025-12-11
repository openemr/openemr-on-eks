#!/bin/bash

# =============================================================================
# OpenEMR on EKS Quick Deployment Script with Monitoring
# =============================================================================
#
# Purpose:
#   Quick deployment script that:
#   1. Stands up OpenEMR on EKS terraform infrastructure
#   2. Deploys OpenEMR on EKS
#   3. Installs comprehensive monitoring stack (Prometheus, Grafana, Loki, Tempo, Mimir, OTeBPF, AlertManager)
#   4. Prints out login addresses and credentials
#
# Usage:
#   ./scripts/quick-deploy.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME     EKS cluster name (default: auto-detect)
#   --aws-region REGION     AWS region (default: us-west-2)
#   --skip-terraform        Skip Terraform deployment (use existing infrastructure)
#   --skip-openemr          Skip OpenEMR deployment (use existing deployment)
#   --skip-monitoring       Skip monitoring installation (use existing monitoring)
#   --help                  Show this help message
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - Terraform >= 1.14.0
#   - kubectl >= 1.34.0
#   - helm >= 3.0.0
#   - jq
#
# =============================================================================

set -euo pipefail

# Disable AWS CLI pager to prevent interactive editors from opening
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly SCRIPT_DIR
readonly PROJECT_ROOT

# Configuration defaults
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-west-2")}
CLUSTER_NAME=""
SKIP_TERRAFORM=false
SKIP_OPENEMR=false
SKIP_MONITORING=false
NAMESPACE="openemr"
MONITORING_NAMESPACE="monitoring"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
}

log_error() {
    echo -e "${RED}❌ $*${NC}" >&2
}

log_step() {
    echo -e "${CYAN}🔄 $*${NC}"
}

log_header() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing_tools=()
    
    for tool in terraform kubectl aws jq helm; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Verify AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi
    
    log_success "All prerequisites met"
}

get_cluster_name() {
    if [ -z "$CLUSTER_NAME" ]; then
        log_info "Auto-detecting cluster name from Terraform..."
        cd "$PROJECT_ROOT/terraform" || exit 1
        TERRAFORM_CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null | grep -v "Warning:" | grep -E "^[a-zA-Z0-9-]+$" | head -1 || true)
        cd - >/dev/null || exit 1
        
        if [ -n "$TERRAFORM_CLUSTER_NAME" ]; then
            CLUSTER_NAME="$TERRAFORM_CLUSTER_NAME"
        else
            CLUSTER_NAME="openemr-eks"
        fi
    fi
    log_info "Using cluster name: $CLUSTER_NAME"
}

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

deploy_terraform() {
    if [ "$SKIP_TERRAFORM" = true ]; then
        log_warning "Skipping Terraform deployment (using existing infrastructure)"
        return 0
    fi
    
    log_header "Step 1: Deploying Terraform Infrastructure"
    
    cd "$PROJECT_ROOT/terraform" || exit 1
    
    log_step "Initializing Terraform..."
    terraform init -upgrade -no-color
    
    log_step "Planning Terraform deployment..."
    terraform plan -out=tfplan -no-color
    
    log_step "Applying Terraform configuration..."
    log_info "This may take 30-45 minutes..."
    terraform apply tfplan -no-color
    
    log_success "Terraform infrastructure deployed successfully"
    cd - >/dev/null || exit 1
}

deploy_openemr() {
    if [ "$SKIP_OPENEMR" = true ]; then
        log_warning "Skipping OpenEMR deployment (using existing deployment)"
        return 0
    fi
    
    log_header "Step 2: Deploying OpenEMR on EKS"
    
    cd "$PROJECT_ROOT/k8s" || exit 1
    
    log_step "Running OpenEMR deployment script..."
    log_info "This may take 7-11 minutes for OpenEMR to initialize..."
    ./deploy.sh --cluster-name "$CLUSTER_NAME" --aws-region "$AWS_REGION" --namespace "$NAMESPACE"
    
    log_success "OpenEMR deployed successfully"
    cd - >/dev/null || exit 1
}

install_monitoring() {
    if [ "$SKIP_MONITORING" = true ]; then
        log_warning "Skipping monitoring installation (using existing monitoring)"
        return 0
    fi
    
    log_header "Step 3: Installing Monitoring Stack"
    
    # Ensure kubectl is configured
    log_step "Configuring kubectl..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
    
    cd "$PROJECT_ROOT/monitoring" || exit 1
    
    log_step "Installing monitoring stack..."
    log_info "This includes:"
    log_info "  - Prometheus (metrics collection and alerting)"
    log_info "  - Grafana (dashboards and visualization)"
    log_info "  - Loki (log aggregation, S3-backed)"
    log_info "  - Tempo (distributed tracing, S3-backed, distributed mode)"
    log_info "  - Mimir (long-term metrics storage, S3-backed)"
    log_info "  - OTeBPF (eBPF auto-instrumentation for traces)"
    log_info "  - AlertManager (alert routing and notifications)"
    log_info "This may take 5-10 minutes..."
    
    # Build monitoring install command
    MONITORING_CMD="./install-monitoring.sh install"
    
    
    $MONITORING_CMD
    
    log_success "Monitoring stack installed successfully"
    cd - >/dev/null || exit 1
}

print_credentials() {
    log_header "Step 4: Deployment Information"
    
    # Get LoadBalancer URL for OpenEMR
    LB_URL=$(kubectl get svc openemr-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    # Get OpenEMR credentials
    ADMIN_USER="admin"
    ADMIN_PASSWORD=""
    
    # Try to get from credentials file first
    if [ -f "$PROJECT_ROOT/k8s/openemr-credentials.txt" ]; then
        ADMIN_PASSWORD=$(grep "Admin Password:" "$PROJECT_ROOT/k8s/openemr-credentials.txt" | awk '{print $3}' || echo "")
    fi
    
    # Fallback to secret if file doesn't exist
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(kubectl get secret openemr-app-credentials -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    # Get Grafana credentials
    GRAFANA_PASSWORD=""
    if [ -f "$PROJECT_ROOT/monitoring/credentials/grafana-credentials.txt" ]; then
        GRAFANA_PASSWORD=$(grep "Password:" "$PROJECT_ROOT/monitoring/credentials/grafana-credentials.txt" | awk '{print $2}' || echo "")
    fi
    
    # Fallback to secret if file doesn't exist
    if [ -z "$GRAFANA_PASSWORD" ]; then
        GRAFANA_PASSWORD=$(kubectl get secret grafana-admin-secret -n "$MONITORING_NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    # Get Grafana service info
    GRAFANA_PORT_FORWARD=""
    GRAFANA_SVC=$(kubectl get svc -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$GRAFANA_SVC" ]; then
        GRAFANA_PORT_FORWARD="kubectl -n $MONITORING_NAMESPACE port-forward svc/$GRAFANA_SVC 3000:80"
    fi
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🎉 OpenEMR Deployment Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}OpenEMR Access Information:${NC}"
    echo ""
    
    if [ -n "$LB_URL" ]; then
        echo -e "  ${BLUE}Login URL:${NC}     https://$LB_URL"
    else
        echo -e "  ${YELLOW}Login URL:${NC}     LoadBalancer URL not yet available"
        echo -e "  ${YELLOW}              Run: kubectl get svc openemr-service -n $NAMESPACE${NC}"
    fi
    
    echo ""
    echo -e "  ${BLUE}Username:${NC}       $ADMIN_USER"
    
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo -e "  ${BLUE}Password:${NC}       $ADMIN_PASSWORD"
    else
        echo -e "  ${YELLOW}Password:${NC}       Unable to retrieve password"
        echo -e "  ${YELLOW}              Check: kubectl get secret openemr-app-credentials -n $NAMESPACE${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}Monitoring Stack Access Information:${NC}"
    echo ""
    
    echo -e "  ${BLUE}Grafana Access:${NC} Use port-forward:"
    if [ -n "$GRAFANA_PORT_FORWARD" ]; then
        echo -e "  ${BLUE}              ${NC} $GRAFANA_PORT_FORWARD"
        echo -e "  ${BLUE}              ${NC} Then visit: http://localhost:3000"
    else
        echo -e "  ${YELLOW}              ${NC} kubectl port-forward -n $MONITORING_NAMESPACE svc/prometheus-stack-grafana 3000:80"
    fi
    
    echo ""
    echo -e "  ${BLUE}Grafana Username:${NC} admin"
    
    if [ -n "$GRAFANA_PASSWORD" ]; then
        echo -e "  ${BLUE}Grafana Password:${NC} $GRAFANA_PASSWORD"
    else
        echo -e "  ${YELLOW}Grafana Password:${NC} Unable to retrieve password"
        echo -e "  ${YELLOW}              ${NC} Check: kubectl get secret grafana-admin-secret -n $MONITORING_NAMESPACE"
    fi
    
    echo ""
    echo -e "${CYAN}Monitoring Components:${NC}"
    echo ""
    echo -e "  ${BLUE}Prometheus:${NC}      Metrics collection and alerting"
    echo -e "  ${BLUE}Grafana:${NC}         Dashboards and visualization"
    echo -e "  ${BLUE}Loki:${NC}            Log aggregation (S3-backed)"
    echo -e "  ${BLUE}Tempo:${NC}           Distributed tracing (S3-backed, distributed mode)"
    echo -e "  ${BLUE}Mimir:${NC}           Long-term metrics storage (S3-backed)"
    echo -e "  ${BLUE}OTeBPF:${NC}          eBPF auto-instrumentation for traces"
    echo -e "  ${BLUE}AlertManager:${NC}    Alert routing and notifications"
    echo ""
    echo -e "${CYAN}Deployment Summary:${NC}"
    echo ""
    echo -e "  ${BLUE}Cluster Name:${NC}    $CLUSTER_NAME"
    echo -e "  ${BLUE}AWS Region:${NC}      $AWS_REGION"
    echo -e "  ${BLUE}OpenEMR Namespace:${NC} $NAMESPACE"
    echo -e "  ${BLUE}Monitoring Namespace:${NC} $MONITORING_NAMESPACE"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo ""
    echo "  1. Access OpenEMR at the URL above"
    echo "  2. Access Grafana using the method above"
    echo "  3. Explore pre-configured dashboards in Grafana"
    echo "  4. Check Prometheus targets and metrics in Grafana"
    echo "  5. Review logs in Loki (datasource configured in Grafana)"
    echo "  6. View traces in Tempo (datasource configured in Grafana)"
    echo "  7. Explore auto-instrumented traces from OTeBPF (filter by service: openemr)"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_help() {
    cat <<EOF
OpenEMR on EKS Quick Deployment Script

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    Quick deployment script that:
    1. Stands up OpenEMR on EKS terraform infrastructure
    2. Deploys OpenEMR on EKS
    3. Installs comprehensive monitoring stack (Prometheus, Grafana, Loki, Tempo, Mimir, OTeBPF, AlertManager)
    4. Prints out login addresses and credentials

OPTIONS:
    --cluster-name NAME     EKS cluster name (default: auto-detect from Terraform)
    --aws-region REGION     AWS region (default: us-west-2)
    --skip-terraform        Skip Terraform deployment (use existing infrastructure)
    --skip-openemr          Skip OpenEMR deployment (use existing deployment)
    --skip-monitoring       Skip monitoring installation (use existing monitoring)
    --help                  Show this help message

ENVIRONMENT VARIABLES:
    AWS_REGION              AWS region
    CLUSTER_NAME            EKS cluster name

EXAMPLES:
    # Full deployment with monitoring
    $0

    # Use existing infrastructure
    $0 --skip-terraform --skip-openemr

    # Access Grafana via port-forwarding
    kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80

PREREQUISITES:
    - AWS CLI configured with appropriate permissions
    - Terraform >= 1.14.0
    - kubectl >= 1.34.0
    - helm >= 3.0.0
    - jq

EOF
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --aws-region)
                AWS_REGION="$2"
                shift 2
                ;;
            --skip-terraform)
                SKIP_TERRAFORM=true
                shift
                ;;
            --skip-openemr)
                SKIP_OPENEMR=true
                shift
                ;;
            --skip-monitoring)
                SKIP_MONITORING=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    log_header "OpenEMR on EKS Deployment with Monitoring"
    
    log_info "Configuration:"
    log_info "  Project root: $PROJECT_ROOT"
    log_info "  AWS Region: $AWS_REGION"
    log_info "  Skip Terraform: $SKIP_TERRAFORM"
    log_info "  Skip OpenEMR: $SKIP_OPENEMR"
    log_info "  Skip Monitoring: $SKIP_MONITORING"
    
    # Check prerequisites
    check_prerequisites
    
    # Get cluster name
    get_cluster_name
    
    # Deploy infrastructure
    deploy_terraform
    
    # Deploy OpenEMR
    deploy_openemr
    
    # Install monitoring
    install_monitoring
    
    # Print credentials
    print_credentials
    
    log_success "Deployment completed successfully!"
}

# Run main function
main "$@"

