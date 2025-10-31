#!/bin/bash

# =============================================================================
# GitHub OIDC Provider Destruction Script
# =============================================================================
#
# Purpose:
#   Destroys the GitHub OIDC provider and IAM roles created by the deploy script.
#
# NOTE: This project prefers GitHub OIDC over static AWS secrets.
# These scripts help you provision the OIDC provider and roles.
#
# Key Features:
#   - Validates prerequisites (Terraform, AWS CLI, credentials)
#   - Confirms destruction with user interaction (unless --force flag used)
#   - Destroys OIDC provider and IAM roles via Terraform
#
# Prerequisites:
#   - Terraform 1.13.4+ installed and in PATH
#   - AWS CLI 2.15+ installed and configured
#   - AWS credentials with permissions to delete OIDC providers and IAM roles
#   - Proper IAM permissions (see oidc_provider/README.md)
#
# Usage:
#   ./destroy.sh [--force]
#
# Options:
#   --force    Skip confirmation prompts (useful for automation)
#
# Environment Variables:
#   AWS_REGION - AWS region (defaults to us-west-2)
#
# WARNING: This will permanently delete the OIDC provider and IAM roles.
#          Ensure no active GitHub Actions workflows are using the role.
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
readonly SCRIPT_DIR        # Directory containing this destroy.sh script
readonly OIDC_PROVIDER_DIR # Directory containing oidc_provider Terraform files
readonly PROJECT_ROOT      # Root directory of the OpenEMR project

# AWS region configuration with auto-detection
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-west-2")}

# Force mode flag (skip confirmations)
FORCE_MODE=false

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

# Confirm destruction
confirm_destruction() {
    if [ "$FORCE_MODE" = true ]; then
        log_warning "Force mode enabled - skipping confirmation prompts"
        return 0
    fi

    echo ""
    log_warning "⚠️  WARNING: This will permanently delete:"
    log_warning "   - GitHub OIDC identity provider"
    log_warning "   - IAM role for GitHub Actions"
    log_warning "   - All attached policies"
    echo ""
    log_warning "⚠️  Ensure no active GitHub Actions workflows are using the OIDC role!"
    echo ""

    read -p "Are you sure you want to proceed? (type 'yes' to confirm): " confirmation

    if [ "$confirmation" != "yes" ]; then
        log_info "Destruction cancelled by user"
        exit 0
    fi

    log_info "Confirmation received - proceeding with destruction"
}

# =============================================================================
# PARSE COMMAND LINE ARGUMENTS
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_MODE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Destroy the GitHub OIDC provider and IAM roles."
            echo ""
            echo "Options:"
            echo "  --force    Skip confirmation prompts"
            echo "  --help     Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# MAIN EXECUTION
# =============================================================================

log_header "GitHub OIDC Provider Destruction"

log_info "Configuration:"
log_info "  Script location: $SCRIPT_DIR"
log_info "  OIDC provider directory: $OIDC_PROVIDER_DIR"
log_info "  Project root: $PROJECT_ROOT"
log_info "  AWS Region: $AWS_REGION"

# Check prerequisites
check_dependencies

# Confirm destruction
confirm_destruction

# Navigate to OIDC provider directory
cd "$OIDC_PROVIDER_DIR"

# Check if Terraform is initialized
if [ ! -d ".terraform" ]; then
    log_error "Terraform not initialized. Run deploy.sh first."
    exit 1
fi

# Plan destruction
log_step "Planning destruction..."
terraform plan -destroy -out=tfplan-destroy
log_success "Destruction plan created"

# Apply destruction
log_step "Destroying OIDC provider and IAM roles..."
log_warning "This will permanently delete all resources..."

terraform apply tfplan-destroy

log_success "OIDC provider and IAM roles destroyed successfully"

# Cleanup
rm -f tfplan-destroy

echo ""
log_header "Destruction Complete"
echo ""
log_info "📋 Next Steps:"
log_info "   - Remove AWS_OIDC_ROLE_ARN from GitHub repository secrets"
log_info "   - Update GitHub workflows to use static credentials (if needed)"
log_info "   - See docs/GITHUB_AWS_CREDENTIALS.md for migration guidance"
echo ""

log_success "Destruction completed successfully!"

