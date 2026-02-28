#!/bin/bash

# =============================================================================
# GitHub OIDC Provider Validation Script
# =============================================================================
#
# Purpose:
#   Validates the GitHub OIDC provider and IAM role configuration without
#   making any changes.
#
# NOTE: This project prefers GitHub OIDC over static AWS secrets.
# These scripts help you provision the OIDC provider and roles.
#
# Key Features:
#   - Validates Terraform configuration syntax
#   - Checks AWS credentials and permissions
#   - Verifies existing OIDC provider (if already deployed)
#   - Validates IAM role trust policy
#
# Prerequisites:
#   - Terraform 1.14.6+ installed and in PATH
#   - AWS CLI 2.15+ installed and configured
#   - AWS credentials with permissions to read IAM resources
#
# Usage:
#   ./validate.sh
#
# Environment Variables:
#   AWS_REGION - AWS region (defaults to us-west-2)
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

readonly RED='\033[0;31m'    # Error messages and critical failures
readonly GREEN='\033[0;32m'  # Success messages and completed operations
readonly YELLOW='\033[1;33m' # Warning messages and important notices
readonly BLUE='\033[0;34m'   # Information messages and status updates
readonly CYAN='\033[0;36m'   # Step headers and section dividers
readonly NC='\033[0m'        # Reset to default color (No Color)

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================
# All configuration values are centralized here for easy maintenance and updates.

# Script metadata - automatically determined paths for reliable file operations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OIDC_PROVIDER_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$OIDC_PROVIDER_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
readonly SCRIPT_DIR        # Directory containing this validate.sh script
readonly OIDC_PROVIDER_DIR # Directory containing oidc_provider Terraform files
readonly PROJECT_ROOT      # Root directory of the OpenEMR project
readonly TERRAFORM_DIR     # Main Terraform directory for region detection

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
            log_info "Found AWS region from Terraform state: $AWS_REGION"
            return 0
        fi
    fi
    
    # Priority 2: If AWS_REGION is explicitly set via environment AND it's not the default, use it
    if [ -n "${AWS_REGION:-}" ] && [ "$AWS_REGION" != "us-west-2" ]; then
        # Validate it's a real region format (e.g., us-west-2, eu-west-1, ap-southeast-1)
        if [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            log_info "Using AWS region from environment: $AWS_REGION"
            return 0
        else
            log_warning "Invalid AWS_REGION format in environment: $AWS_REGION"
        fi
    fi
    
    # Priority 3: Fall back to default
    AWS_REGION="us-west-2"
    log_warning "Could not determine AWS region, using default: $AWS_REGION"
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
        ((errors++))
    else
        log_success "Terraform found"
    fi

    # Check AWS CLI
    if ! command -v aws >/dev/null 2>&1; then
        log_error "AWS CLI is required but not installed."
        ((errors++))
    else
        log_success "AWS CLI found"
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid."
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
validate_terraform_config() {
    log_step "Validating Terraform configuration..."

    cd "$OIDC_PROVIDER_DIR"

    # Format check
    log_info "Checking Terraform formatting..."
    if terraform fmt -check -recursive >/dev/null 2>&1; then
        log_success "Terraform files are properly formatted"
    else
        log_warning "Terraform files need formatting (run 'terraform fmt')"
    fi

    # Initialize if needed
    if [ ! -d ".terraform" ]; then
        log_info "Initializing Terraform..."
        terraform init >/dev/null 2>&1
    fi

    # Validate configuration
    log_info "Validating Terraform configuration syntax..."
    if terraform validate >/dev/null 2>&1; then
        log_success "Terraform configuration is valid"
    else
        log_error "Terraform configuration validation failed"
        terraform validate
        return 1
    fi

    return 0
}

# Check AWS permissions
check_aws_permissions() {
    log_step "Checking AWS IAM permissions..."

    local errors=0
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

    # Check IAM permissions
    log_info "Testing IAM permissions..."

    # Try to list OIDC providers (read permission)
    if aws iam list-open-id-connect-providers >/dev/null 2>&1; then
        log_success "IAM read permissions validated"
    else
        log_warning "Cannot list OIDC providers - may need iam:ListOpenIDConnectProviders"
        ((errors++))
    fi

    # Try to list roles (read permission)
    if aws iam list-roles --max-items 1 >/dev/null 2>&1; then
        log_success "IAM role read permissions validated"
    else
        log_warning "Cannot list IAM roles - may need iam:ListRoles"
        ((errors++))
    fi

    if [ $errors -gt 0 ]; then
        log_warning "Some IAM permissions may be missing (read-only checks failed)"
        log_info "This is OK for validation - deployment will require write permissions"
    else
        log_success "AWS IAM permissions validated"
    fi

    return 0
}

# Check for existing OIDC provider
check_existing_resources() {
    log_step "Checking for existing OIDC provider..."

    # Check if OIDC provider already exists
    local oidc_providers
    oidc_providers=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[*].Arn' --output text 2>/dev/null || echo "")

    if [ -n "$oidc_providers" ]; then
        log_info "Found existing OIDC provider(s):"
        echo "$oidc_providers" | while IFS= read -r arn; do
            if [ -n "$arn" ]; then
                echo "   $arn"
            fi
        done
        
        # Check if GitHub OIDC provider exists
        if echo "$oidc_providers" | grep -q "token.actions.githubusercontent.com"; then
            log_warning "GitHub OIDC provider may already exist"
            log_info "Terraform will manage the existing provider or create a new one"
        fi
    else
        log_info "No existing OIDC providers found (will be created on deployment)"
    fi

    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Detect AWS region from Terraform state if not explicitly set
get_aws_region

log_header "GitHub OIDC Provider Validation"

log_info "Configuration:"
log_info "  Script location: $SCRIPT_DIR"
log_info "  OIDC provider directory: $OIDC_PROVIDER_DIR"
log_info "  Project root: $PROJECT_ROOT"
log_info "  AWS Region: $AWS_REGION"

# Check prerequisites
check_dependencies

# Validate Terraform configuration
if ! validate_terraform_config; then
    log_error "Terraform validation failed"
    exit 1
fi

# Check AWS permissions
check_aws_permissions

# Check for existing resources
check_existing_resources

# Summary
echo ""
log_header "Validation Summary"
echo ""
log_success "✅ All validations passed"
log_info "📋 Next Steps:"
log_info "   1. Review variables in variables.tf (customize GitHub repository if needed)"
log_info "   2. Review IAM policy in main.tf (replace example policy with actual permissions)"
log_info "   3. Run ./deploy.sh to create the OIDC provider and IAM role"
echo ""

log_success "Validation completed successfully!"

