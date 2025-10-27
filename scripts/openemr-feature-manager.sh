#!/bin/bash

# =============================================================================
# OpenEMR Feature Manager
# =============================================================================
#
# Purpose:
#   Manages OpenEMR API and Patient Portal features by modifying Terraform
#   configuration variables and applying infrastructure changes. Provides
#   centralized control to enable/disable features without manual editing.
#
# Key Features:
#   - Enable/disable OpenEMR REST API and FHIR endpoints
#   - Enable/disable OpenEMR Patient Portal functionality
#   - Update Terraform variables and apply infrastructure changes
#   - Redeploy OpenEMR with new feature configurations
#   - Display current feature status and configuration
#
# Prerequisites:
#   - Terraform installed and initialized
#   - kubectl configured for the target cluster
#   - AWS CLI configured with appropriate permissions
#
# Usage:
#   ./openemr-feature-manager.sh {enable-api|disable-api|enable-portal|disable-portal|status}
#
# Options:
#   enable-api       Enable OpenEMR REST API and FHIR endpoints
#   disable-api      Disable OpenEMR REST API and FHIR endpoints
#   enable-portal    Enable OpenEMR Patient Portal
#   disable-portal   Disable OpenEMR Patient Portal
#   status           Display current feature configuration
#
# Environment Variables:
#   NAMESPACE       Kubernetes namespace (default: openemr)
#   CLUSTER_NAME    EKS cluster name (default: openemr-eks)
#   AWS_REGION      AWS region (default: us-west-2)
#
# Workflow:
#   1. Updates Terraform variables in terraform.tfvars
#   2. Applies Terraform changes to update infrastructure outputs
#   3. Redeploys OpenEMR with new feature configuration
#   4. Validates feature status and provides feedback
#
# Examples:
#   ./openemr-feature-manager.sh status
#   ./openemr-feature-manager.sh enable-api
#   ./openemr-feature-manager.sh disable-portal
#
# =============================================================================

set -e

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical issues
GREEN='\033[0;32m'    # Success messages and positive feedback
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
NC='\033[0m'          # Reset color to default

# Configuration variables - can be overridden by environment variables
NAMESPACE=${NAMESPACE:-"openemr"}           # Kubernetes namespace for OpenEMR
CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"} # EKS cluster name
AWS_REGION=${AWS_REGION:-"us-west-2"}       # AWS region where resources are located

# Path resolution for script portability
# These variables ensure the script works regardless of the current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Directory containing this script
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"                      # Parent directory (project root)
TERRAFORM_DIR="$PROJECT_ROOT/terraform"                      # Terraform configuration directory
K8S_DIR="$PROJECT_ROOT/k8s"                                  # Kubernetes manifests directory

# Help function
show_help() {
    echo "Usage: $0 {enable|disable|status} {api|portal|all}"
    echo ""
    echo "Manage OpenEMR API and Patient Portal features via Terraform configuration"
    echo ""
    echo "Commands:"
    echo "  enable api      Enable OpenEMR REST API and FHIR endpoints"
    echo "  enable portal   Enable OpenEMR Patient Portal"
    echo "  enable all      Enable both API and Portal features"
    echo "  disable api     Disable OpenEMR REST API and FHIR endpoints"
    echo "  disable portal  Disable OpenEMR Patient Portal"
    echo "  disable all     Disable both API and Portal features"
    echo "  status api      Show API feature status"
    echo "  status portal   Show Portal feature status"
    echo "  status all      Show all feature status"
    echo ""
    echo "Examples:"
    echo "  $0 enable api       # Enable API endpoints"
    echo "  $0 disable portal   # Disable patient portal"
    echo "  $0 status all       # Show all feature status"
    echo ""
    echo "How it works:"
    echo "  • Updates Terraform variables in terraform.tfvars"
    echo "  • Applies Terraform changes to update outputs"
    echo "  • Redeploys OpenEMR with new environment variables"
    echo "  • Features are controlled via OPENEMR_SETTING_* environment variables"
    echo ""
    echo "Security Notes:"
    echo "  • Features are disabled by default to minimize attack surface"
    echo "  • Changes require infrastructure update and redeployment"
    echo "  • Network policies are updated accordingly"
    exit 0
}

# Function to validate Terraform configuration file exists
# This ensures the script can modify the necessary configuration files
check_terraform_config() {
    if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        echo -e "${RED}Error: terraform.tfvars not found in $TERRAFORM_DIR${NC}"
        echo -e "${YELLOW}Please ensure you have a terraform.tfvars file configured${NC}"
        exit 1
    fi
}

# Function to update Terraform variable values in terraform.tfvars
# This function safely updates or adds variables to the Terraform configuration file
update_terraform_var() {
    local var_name="$1"   # Name of the Terraform variable to update
    local var_value="$2"  # New value for the variable

    echo -e "${YELLOW}Updating $var_name to $var_value in terraform.tfvars...${NC}"

    cd "$TERRAFORM_DIR"

    # Check if the variable already exists in the configuration file
    if grep -q "^$var_name" terraform.tfvars; then
        # Update existing variable - create backup and modify in place
        # Uses sed with backup file (.bak) for safety
        sed -i.bak "s/^${var_name}[[:space:]]*=.*/${var_name} = ${var_value}/" terraform.tfvars
    else
        # Add new variable at the end of the file
        echo "" >> terraform.tfvars
        echo "$var_name = $var_value" >> terraform.tfvars
    fi

    echo -e "${GREEN}✅ Updated $var_name = $var_value${NC}"
}

# Function to retrieve current feature status from Terraform outputs
# This function queries Terraform to get the current configuration state
get_feature_status() {
    cd "$TERRAFORM_DIR"

    # Validate that Terraform outputs are available
    if ! terraform output -json openemr_app_config >/dev/null 2>&1; then
        echo -e "${RED}Error: Unable to get Terraform outputs. Run 'terraform apply' first.${NC}"
        exit 1
    fi

    # Extract feature configuration from Terraform JSON output
    local config=$(terraform output -json openemr_app_config)
    API_ENABLED=$(echo "$config" | jq -r '.api_enabled')               # Current API feature status
    PORTAL_ENABLED=$(echo "$config" | jq -r '.patient_portal_enabled') # Current Portal feature status
    OPENEMR_VERSION=$(echo "$config" | jq -r '.version')               # Current OpenEMR version
}

# Function to apply Terraform configuration changes
# This function updates the infrastructure to reflect the new feature configuration
apply_terraform_changes() {
    echo -e "${YELLOW}Applying Terraform changes...${NC}"
    cd "$TERRAFORM_DIR"

    # Apply changes to specific targets to minimize impact and reduce execution time
    # Targets: EKS module and RDS cluster (core infrastructure components)
    if terraform apply -target=module.eks -target=aws_rds_cluster.openemr -auto-approve >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Terraform changes applied successfully${NC}"
    else
        echo -e "${RED}Error: Failed to apply Terraform changes${NC}"
        exit 1
    fi
}

# Function to redeploy OpenEMR with updated configuration
# This function triggers a fresh deployment using the updated Terraform outputs
redeploy_openemr() {
    echo -e "${YELLOW}Redeploying OpenEMR with new configuration...${NC}"
    cd "$K8S_DIR"

    # Execute the deployment script to apply new configuration
    if ./deploy.sh >/dev/null 2>&1; then
        echo -e "${GREEN}✅ OpenEMR redeployed successfully${NC}"
    else
        echo -e "${RED}Error: Failed to redeploy OpenEMR${NC}"
        exit 1
    fi
}

# Function to show feature status
show_status() {
    local feature="$1"

    get_feature_status

    echo -e "${BLUE}📋 OpenEMR Feature Status${NC}"
    echo -e "${BLUE}=========================${NC}"
    echo -e "${BLUE}OpenEMR Version: ${GREEN}$OPENEMR_VERSION${NC}"
    echo ""

    case "$feature" in
        "api")
            if [ "$API_ENABLED" = "true" ]; then
                echo -e "${GREEN}✅ REST API and FHIR endpoints: ENABLED${NC}"
            else
                echo -e "${YELLOW}🔒 REST API and FHIR endpoints: DISABLED${NC}"
                echo -e "${BLUE}   💡 To enable: $0 enable api${NC}"
            fi
            ;;
        "portal")
            if [ "$PORTAL_ENABLED" = "true" ]; then
                echo -e "${GREEN}✅ Patient Portal: ENABLED${NC}"
                echo -e "${BLUE}   🌐 Portal Access: https://your-domain/portal${NC}"
            else
                echo -e "${YELLOW}🔒 Patient Portal: DISABLED${NC}"
                echo -e "${BLUE}   💡 To enable: $0 enable portal${NC}"
            fi
            ;;
        "all"|*)
            if [ "$API_ENABLED" = "true" ]; then
                echo -e "${GREEN}✅ REST API and FHIR endpoints: ENABLED${NC}"
            else
                echo -e "${YELLOW}🔒 REST API and FHIR endpoints: DISABLED${NC}"
            fi

            if [ "$PORTAL_ENABLED" = "true" ]; then
                echo -e "${GREEN}✅ Patient Portal: ENABLED${NC}"
            else
                echo -e "${YELLOW}🔒 Patient Portal: DISABLED${NC}"
            fi

            echo ""
            echo -e "${BLUE}💡 Management Commands:${NC}"
            echo -e "${BLUE}   • Enable API: $0 enable api${NC}"
            echo -e "${BLUE}   • Enable Portal: $0 enable portal${NC}"
            echo -e "${BLUE}   • Disable API: $0 disable api${NC}"
            echo -e "${BLUE}   • Disable Portal: $0 disable portal${NC}"
            ;;
    esac

    echo ""
    echo -e "${BLUE}🔒 Security: Features are disabled by default to minimize attack surface${NC}"
}

# Function to enable features
enable_feature() {
    local feature="$1"

    check_terraform_config

    case "$feature" in
        "api")
            echo -e "${GREEN}🔓 Enabling OpenEMR REST API and FHIR endpoints...${NC}"
            update_terraform_var "enable_openemr_api" "true"
            apply_terraform_changes
            redeploy_openemr
            echo -e "${GREEN}✅ API endpoints enabled successfully${NC}"
            ;;
        "portal")
            echo -e "${GREEN}🔓 Enabling OpenEMR Patient Portal...${NC}"
            update_terraform_var "enable_patient_portal" "true"
            apply_terraform_changes
            redeploy_openemr
            echo -e "${GREEN}✅ Patient Portal enabled successfully${NC}"
            ;;
        "all")
            echo -e "${GREEN}🔓 Enabling all OpenEMR features...${NC}"
            update_terraform_var "enable_openemr_api" "true"
            update_terraform_var "enable_patient_portal" "true"
            apply_terraform_changes
            redeploy_openemr
            echo -e "${GREEN}✅ All features enabled successfully${NC}"
            ;;
        *)
            echo -e "${RED}Error: Unknown feature '$feature'${NC}"
            echo -e "${YELLOW}Valid features: api, portal, all${NC}"
            exit 1
            ;;
    esac
}

# Function to disable features
disable_feature() {
    local feature="$1"

    check_terraform_config

    case "$feature" in
        "api")
            echo -e "${YELLOW}🔒 Disabling OpenEMR REST API and FHIR endpoints...${NC}"
            update_terraform_var "enable_openemr_api" "false"
            apply_terraform_changes
            redeploy_openemr
            echo -e "${GREEN}✅ API endpoints disabled successfully${NC}"
            ;;
        "portal")
            echo -e "${YELLOW}🔒 Disabling OpenEMR Patient Portal...${NC}"
            update_terraform_var "enable_patient_portal" "false"
            apply_terraform_changes
            redeploy_openemr
            echo -e "${GREEN}✅ Patient Portal disabled successfully${NC}"
            ;;
        "all")
            echo -e "${YELLOW}🔒 Disabling all OpenEMR features...${NC}"
            update_terraform_var "enable_openemr_api" "false"
            update_terraform_var "enable_patient_portal" "false"
            apply_terraform_changes
            redeploy_openemr
            echo -e "${GREEN}✅ All features disabled successfully${NC}"
            ;;
        *)
            echo -e "${RED}Error: Unknown feature '$feature'${NC}"
            echo -e "${YELLOW}Valid features: api, portal, all${NC}"
            exit 1
            ;;
    esac
}

# Main script logic
if [ $# -eq 0 ]; then
    show_help
fi

ACTION="$1"
FEATURE="$2"

case "$ACTION" in
    "enable")
        if [ -z "$FEATURE" ]; then
            echo -e "${RED}Error: Feature not specified${NC}"
            echo -e "${YELLOW}Usage: $0 enable {api|portal|all}${NC}"
            exit 1
        fi
        enable_feature "$FEATURE"
        ;;
    "disable")
        if [ -z "$FEATURE" ]; then
            echo -e "${RED}Error: Feature not specified${NC}"
            echo -e "${YELLOW}Usage: $0 disable {api|portal|all}${NC}"
            exit 1
        fi
        disable_feature "$FEATURE"
        ;;
    "status")
        show_status "$FEATURE"
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        echo -e "${RED}Error: Unknown action '$ACTION'${NC}"
        echo -e "${YELLOW}Valid actions: enable, disable, status, help${NC}"
        show_help
        ;;
esac
