#!/bin/bash

# =============================================================================
# GitHub OIDC Provider Deployment Script
# =============================================================================
#
# Purpose:
#   Deploys the GitHub OIDC provider and IAM roles for GitHub Actions
#   authentication using OpenID Connect (OIDC).
#
# NOTE: This project prefers GitHub OIDC over static AWS secrets.
# These scripts help you provision the OIDC provider and roles.
#
# Key Features:
#   - Validates prerequisites (Terraform, AWS CLI, credentials)
#   - Initializes Terraform in the oidc_provider directory
#   - Applies Terraform configuration to create OIDC provider and roles
#   - Outputs role ARN for use in GitHub repository secrets
#
# Prerequisites:
#   - Terraform 1.13.4+ installed and in PATH
#   - AWS CLI 2.15+ installed and configured
#   - AWS credentials with permissions to create OIDC providers and IAM roles
#   - Proper IAM permissions (see oidc_provider/README.md)
#
# Usage:
#   ./deploy.sh
#
# =============================================================================

# Strict error handling: exit on any command failure, undefined variables, or pipe failures
set -euo pipefail

# =============================================================================
# OUTPUT FORMATTING CONFIGURATION
# =============================================================================
# Color codes for consistent, readable output across different terminal types.
# Using ANSI escape sequences that work across most modern terminals.
# The NC (No Color) constant is used to reset formatting after colored text.

readonly RED='\033[0;31m'      # Error messages and critical failures
readonly GREEN='\033[0;32m'    # Success messages and completed operations
readonly YELLOW='\033[1;33m'   # Warning messages and important notices
readonly BLUE='\033[0;34m'     # Information messages and status updates
readonly CYAN='\033[0;36m'     # Step headers and section dividers
readonly NC='\033[0m'          # Reset to default color (No Color)

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================
# All configuration values are centralized here for easy maintenance and updates.

# Script metadata - automatically determined paths for reliable file operations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OIDC_PROVIDER_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$OIDC_PROVIDER_DIR")"
readonly SCRIPT_DIR        # Directory containing this deploy.sh script
readonly OIDC_PROVIDER_DIR # Directory containing oidc_provider Terraform files
readonly PROJECT_ROOT      # Root directory of the OpenEMR project

# AWS region configuration with auto-detection
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-west-2")}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
# Centralized logging functions that provide consistent, color-coded output
# throughout the script.

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
# VALIDATION FUNCTIONS
# =============================================================================

# Check for required dependencies
check_dependencies() {
    log_step "Checking prerequisites..."

    local errors=0

    # Check Terraform
    if ! command -v terraform >/dev/null 2>&1; then
        log_error "Terraform is required but not installed."
        log_error "Install Terraform 1.13.4 (see main README for instructions)"
        ((errors++))
    else
        local terraform_version
        terraform_version=$(terraform --version -json 2>/dev/null | grep -o '"terraform_version": "[^"]*"' | sed 's/.*"terraform_version": "\([^"]*\)".*/\1/' || echo "")
        if [ -z "$terraform_version" ]; then
            terraform_version=$(terraform --version | head -1 | sed -n 's/.*v\([0-9.]*\).*/\1/p' || echo "")
        fi
        log_info "Terraform version: $terraform_version"
        
        # Check if version is 1.13.4 or higher
        if [ -n "$terraform_version" ]; then
            log_success "Terraform found: $terraform_version"
        else
            log_warning "Could not determine Terraform version"
        fi
    fi

    # Check AWS CLI
    if ! command -v aws >/dev/null 2>&1; then
        log_error "AWS CLI is required but not installed."
        log_error "Install AWS CLI 2.15+ (see main README for instructions)"
        ((errors++))
    else
        local aws_version
        aws_version=$(aws --version 2>&1 | sed -n 's/.*aws-cli\/\([0-9.]*\).*/\1/p' || echo "")
        log_success "AWS CLI found: $aws_version"
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid."
        log_error "Run: aws configure"
        ((errors++))
    else
        local account_id
        account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
        log_success "AWS credentials valid (Account: $account_id)"
    fi

    if [ $errors -gt 0 ]; then
        log_error "Prerequisites check failed with $errors error(s)"
        exit 1
    fi

    log_success "All prerequisites validated"
}

# Validate Terraform configuration
validate_terraform() {
    log_step "Validating Terraform configuration..."

    cd "$OIDC_PROVIDER_DIR"

    if ! terraform validate >/dev/null 2>&1; then
        log_error "Terraform configuration validation failed"
        terraform validate
        exit 1
    fi

    log_success "Terraform configuration is valid"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

log_header "GitHub OIDC Provider Deployment"

log_info "Configuration:"
log_info "  Script location: $SCRIPT_DIR"
log_info "  OIDC provider directory: $OIDC_PROVIDER_DIR"
log_info "  Project root: $PROJECT_ROOT"
log_info "  AWS Region: $AWS_REGION"

# Check prerequisites
check_dependencies

# Navigate to OIDC provider directory
cd "$OIDC_PROVIDER_DIR"

# Initialize Terraform
log_step "Initializing Terraform..."
if [ ! -d ".terraform" ]; then
    terraform init
else
    log_info "Terraform already initialized, upgrading modules..."
    terraform init -upgrade
fi
log_success "Terraform initialized"

# Validate configuration
validate_terraform

# Plan deployment
log_step "Planning deployment..."
terraform plan -out=tfplan
log_success "Deployment plan created"

# Apply deployment
log_step "Applying Terraform configuration..."
log_info "This will create:"
log_info "  - GitHub OIDC identity provider"
log_info "  - IAM role for GitHub Actions"
log_info "  - IAM policy attachment"

terraform apply tfplan

log_success "OIDC provider and IAM role created successfully"

# Display outputs
echo ""
log_header "Deployment Summary"
echo ""

log_info "Outputs:"
TERRAFORM_OUTPUT=$(terraform output -json 2>/dev/null || echo "{}")

if command -v jq >/dev/null 2>&1; then
    ROLE_ARN=$(echo "$TERRAFORM_OUTPUT" | jq -r '.github_actions_role_arn.value // empty')
    OIDC_ARN=$(echo "$TERRAFORM_OUTPUT" | jq -r '.oidc_provider_arn.value // empty')
    
    if [ -n "$ROLE_ARN" ]; then
        echo -e "${GREEN}✅ GitHub Actions Role ARN:${NC}"
        echo "   $ROLE_ARN"
        echo ""
        log_info "📋 Next Steps:"
        log_info "   1. Add this ARN to your GitHub repository secrets:"
        echo -e "      ${CYAN}Name:${NC} AWS_OIDC_ROLE_ARN"
        echo -e "      ${CYAN}Value:${NC} $ROLE_ARN"
        echo ""
        log_info "   2. Update your GitHub workflows to use OIDC (see docs/GITHUB_AWS_CREDENTIALS.md)"
        echo ""
    fi
    
    if [ -n "$OIDC_ARN" ]; then
        echo -e "${GREEN}✅ OIDC Provider ARN:${NC}"
        echo "   $OIDC_ARN"
        echo ""
    fi
else
    # Fallback if jq is not available
    log_info "Run 'terraform output' to see role ARN and provider ARN"
    terraform output
fi

# Cleanup
rm -f tfplan

log_success "Deployment completed successfully!"

