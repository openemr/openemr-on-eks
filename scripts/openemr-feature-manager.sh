#!/bin/bash

# OpenEMR Feature Manager
# This script manages OpenEMR API and Patient Portal features via Terraform configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${NAMESPACE:-"openemr"}
CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}
AWS_REGION=${AWS_REGION:-"us-west-2"}

# Get the script's directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
K8S_DIR="$PROJECT_ROOT/k8s"

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

# Function to check if terraform.tfvars exists
check_terraform_config() {
    if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        echo -e "${RED}Error: terraform.tfvars not found in $TERRAFORM_DIR${NC}"
        echo -e "${YELLOW}Please ensure you have a terraform.tfvars file configured${NC}"
        exit 1
    fi
}

# Function to update terraform.tfvars
update_terraform_var() {
    local var_name="$1"
    local var_value="$2"

    echo -e "${YELLOW}Updating $var_name to $var_value in terraform.tfvars...${NC}"

    cd "$TERRAFORM_DIR"

    # Check if the variable exists in the file
    if grep -q "^$var_name" terraform.tfvars; then
        # Update existing variable - escape special characters in sed
        sed -i.bak "s/^${var_name}[[:space:]]*=.*/${var_name} = ${var_value}/" terraform.tfvars
    else
        # Add new variable at the end with proper newline
        echo "" >> terraform.tfvars
        echo "$var_name = $var_value" >> terraform.tfvars
    fi

    echo -e "${GREEN}✅ Updated $var_name = $var_value${NC}"
}

# Function to get current feature status from Terraform
get_feature_status() {
    cd "$TERRAFORM_DIR"

    if ! terraform output -json openemr_app_config >/dev/null 2>&1; then
        echo -e "${RED}Error: Unable to get Terraform outputs. Run 'terraform apply' first.${NC}"
        exit 1
    fi

    local config=$(terraform output -json openemr_app_config)
    API_ENABLED=$(echo "$config" | jq -r '.api_enabled')
    PORTAL_ENABLED=$(echo "$config" | jq -r '.patient_portal_enabled')
    OPENEMR_VERSION=$(echo "$config" | jq -r '.version')
}

# Function to apply terraform changes
apply_terraform_changes() {
    echo -e "${YELLOW}Applying Terraform changes...${NC}"
    cd "$TERRAFORM_DIR"

    # Only apply the outputs, not the entire infrastructure
    if terraform apply -target=module.eks -target=aws_rds_cluster.openemr -auto-approve >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Terraform changes applied successfully${NC}"
    else
        echo -e "${RED}Error: Failed to apply Terraform changes${NC}"
        exit 1
    fi
}

# Function to redeploy OpenEMR
redeploy_openemr() {
    echo -e "${YELLOW}Redeploying OpenEMR with new configuration...${NC}"
    cd "$K8S_DIR"

    # Run the deployment script
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
