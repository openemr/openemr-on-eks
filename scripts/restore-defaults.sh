#!/bin/bash

# =============================================================================
# OpenEMR Deployment Files Default State Restoration Script
# =============================================================================
#
# Purpose:
#   Restores all deployment files to their default Git HEAD state, removing
#   deployment artifacts, backup files, and generated credentials. Designed
#   to clean up the repository for fresh deployments or git operations.
#
# Key Features:
#   - Restores Kubernetes YAML files to default template state
#   - Removes backup files (.bak) created during deployment
#   - Cleans up generated credentials and temporary files
#   - Provides safety confirmations and backup options
#   - Preserves user configuration files (terraform.tfvars)
#
# Prerequisites:
#   - Git repository with clean working tree (for safety)
#
# Usage:
#   ./restore-defaults.sh [OPTIONS]
#
# Options:
#   --force    Skip confirmation prompts
#   --help     Show this help message
#
# Notes:
#   ⚠️  WARNING: This script will ERASE any structural changes to YAML files.
#   Only use for cleaning up deployment artifacts, NOT during active development.
#   Always commit your changes before running this script.
#
# Examples:
#   ./restore-defaults.sh
#   ./restore-defaults.sh --force
#
# =============================================================================

set -e

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical warnings
GREEN='\033[0;32m'    # Success messages and positive feedback
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
NC='\033[0m'          # Reset color to default

# Path resolution for script portability
# These variables ensure the script works regardless of the current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Directory containing this script
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"                      # Parent directory (project root)

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Restore OpenEMR deployment files to their default state"
    echo ""
    echo "Options:"
    echo "  --force         Skip confirmation prompts"
    echo "  --backup        Create backup before restoration"
    echo "  --help          Show this help message"
    echo ""
    echo "What this script does:"
    echo "  • Removes all .bak files created by deployment scripts"
    echo "  • Restores deployment.yaml to default template state"
    echo "  • Restores service.yaml to default template state"
    echo "  • Restores hpa.yaml to default template state"
    echo "  • Restores storage.yaml to default template state"
    echo "  • Restores ingress.yaml to default template state"
    echo "  • Restores logging.yaml to default template state"
    echo "  • Restores ssl-renewal.yaml to default template state"
    echo "  • Removes generated credentials files"
    echo "  • Cleans up temporary deployment files"
    echo ""
    echo "⚠️  IMPORTANT WARNING FOR DEVELOPERS:"
    echo "  • This script will ERASE any structural changes to YAML files"
    echo "  • If you're modifying file structure/content (not just values),"
    echo "  • your changes will be LOST and restored to git HEAD state"
    echo "  • Only use this script for cleaning up deployment artifacts"
    echo "  • NOT for cleaning up during active development work"
    echo ""
    echo "Files preserved:"
    echo "  • terraform.tfvars (your configuration)"
    echo "  • All infrastructure state"
    echo "  • All documentation"
    echo "  • All scripts"
    echo ""
    echo "Use this script to:"
    echo "  • Clean up after deployments for git tracking"
    echo "  • Reset files before making configuration changes"
    echo "  • Prepare for fresh deployments"
    exit 0
}

# Function to create backup before restoration
# This function creates a timestamped backup of the k8s directory for safety
create_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/restore_backup_$timestamp"

    echo -e "${YELLOW}Creating backup in $backup_dir...${NC}"
    mkdir -p "$backup_dir"

    # Create a complete backup of the k8s directory
    cp -r "$PROJECT_ROOT/k8s" "$backup_dir/"

    echo -e "${GREEN}✅ Backup created successfully${NC}"
}

# Function to restore deployment.yaml to default Git HEAD state
# This function uses git checkout to restore the file to its original state
restore_deployment_yaml() {
    echo -e "${YELLOW}Restoring deployment.yaml to default state...${NC}"

    # Attempt to restore from git HEAD state
    cd "$PROJECT_ROOT"
    if git checkout HEAD -- k8s/deployment.yaml 2>/dev/null; then
        echo -e "${GREEN}✅ deployment.yaml restored from git${NC}"
        return
    else
        echo -e "${YELLOW}⚠️  Could not restore deployment.yaml from git${NC}"
        return
    fi
}

# Function to restore service.yaml to default state
restore_service_yaml() {
    echo -e "${YELLOW}Restoring service.yaml to default state...${NC}"

    # Try to restore from git
    cd "$PROJECT_ROOT"
    if git checkout HEAD -- k8s/service.yaml 2>/dev/null; then
        echo -e "${GREEN}✅ service.yaml restored from git${NC}"
        return
    else
        echo -e "${YELLOW}⚠️  Could not restore service.yaml from git${NC}"
        return
    fi
}

# Function to restore other YAML files to default state
restore_other_yaml_files() {
    echo -e "${YELLOW}Restoring other YAML files to default state...${NC}"

    cd "$PROJECT_ROOT"

    # List of files to restore from git
    local files_to_restore=(
        "k8s/hpa.yaml"
        "k8s/storage.yaml"
        "k8s/ingress.yaml"
        "k8s/logging.yaml"
        "k8s/configmap.yaml"
        "k8s/security.yaml"
        "k8s/ssl-renewal.yaml"
    )

    for file in "${files_to_restore[@]}"; do
        if [ -f "$file" ]; then
            if git checkout HEAD -- "$file" 2>/dev/null; then
                echo -e "${GREEN}✅ $(basename "$file") restored from git${NC}"
            else
                echo -e "${YELLOW}⚠️  Could not restore $(basename "$file") from git${NC}"
            fi
        fi
    done
}

# Function to clean up backup files created during deployment
# This function removes all .bak files that were created as safety backups
cleanup_backup_files() {
    echo -e "${YELLOW}Cleaning up .bak files...${NC}"

    # Remove backup files from k8s and terraform directories
    find "$PROJECT_ROOT/k8s" -name "*.bak" -delete 2>/dev/null || true
    find "$PROJECT_ROOT/terraform" -name "*.bak" -delete 2>/dev/null || true

    echo -e "${GREEN}✅ Backup files cleaned up${NC}"
}

# Function to clean up generated files and credentials
# This function removes files that were generated during deployment processes
cleanup_generated_files() {
    echo -e "${YELLOW}Cleaning up generated files...${NC}"

    # Remove credential files with various naming patterns
    rm -f "$PROJECT_ROOT/k8s/openemr-credentials.txt"
    rm -f "$PROJECT_ROOT/k8s/openemr-credentials-"*.txt

    # Remove log files generated during deployment
    rm -f "$PROJECT_ROOT/terraform/openemr-all-logs.txt"

    # Remove any temporary files that may have been created
    find "$PROJECT_ROOT/k8s" -name "*.tmp" -delete 2>/dev/null || true
    find "$PROJECT_ROOT/terraform" -name "*.tmp" -delete 2>/dev/null || true

    echo -e "${GREEN}✅ Generated files cleaned up${NC}"
}

# Main restoration function
restore_defaults() {
    echo -e "${BLUE}🔄 OpenEMR Deployment Files Default State Restoration${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo ""

    restore_deployment_yaml
    restore_service_yaml
    restore_other_yaml_files
    cleanup_backup_files
    cleanup_generated_files

    echo ""
    echo -e "${GREEN}🎉 All deployment files restored to default state!${NC}"
    echo ""
    echo -e "${BLUE}📋 What was restored:${NC}"
    echo -e "${BLUE}• deployment.yaml - Reset to template with placeholders${NC}"
    echo -e "${BLUE}• service.yaml - Reset to template with placeholders${NC}"
    echo -e "${BLUE}• Other YAML files - Reset placeholders${NC}"
    echo -e "${BLUE}• Removed all .bak files${NC}"
    echo -e "${BLUE}• Removed generated credentials files${NC}"
    echo ""
    echo -e "${BLUE}📋 Files preserved:${NC}"
    echo -e "${BLUE}• terraform.tfvars (your configuration)${NC}"
    echo -e "${BLUE}• All infrastructure state${NC}"
    echo -e "${BLUE}• All documentation and scripts${NC}"
    echo ""
    echo -e "${BLUE}💡 Next steps:${NC}"
    echo -e "${BLUE}• Files are now ready for clean git tracking${NC}"
    echo -e "${BLUE}• Run './deploy.sh' to deploy with current configuration${NC}"
    echo -e "${BLUE}• Commit changes to git for clean version control${NC}"
}

# Parse command line arguments
FORCE=false
BACKUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --backup)
            BACKUP=true
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo -e "${YELLOW}Use --help for usage information${NC}"
            exit 1
            ;;
    esac
done

# Confirmation prompt unless --force is used
if [ "$FORCE" = false ]; then
    echo -e "${RED}⚠️  DEVELOPER WARNING:${NC}"
    echo -e "${RED}This will restore all deployment files to their git HEAD state.${NC}"
    echo -e "${RED}Any structural changes you've made to YAML files will be LOST.${NC}"
    echo ""
    echo -e "${YELLOW}This script will:${NC}"
    echo -e "${YELLOW}• Restore deployment files to their default template state${NC}"
    echo -e "${YELLOW}• Remove generated files and .bak files${NC}"
    echo -e "${YELLOW}• Preserve your terraform.tfvars and infrastructure${NC}"
    echo ""
    echo -e "${BLUE}Safe to use when:${NC}"
    echo -e "${BLUE}• Cleaning up after deployments${NC}"
    echo -e "${BLUE}• Preparing for git commits${NC}"
    echo -e "${BLUE}• You only changed configuration values${NC}"
    echo ""
    echo -e "${RED}DO NOT use when:${NC}"
    echo -e "${RED}• You're actively developing/modifying YAML file structure${NC}"
    echo -e "${RED}• You've made custom changes to deployment templates${NC}"
    echo -e "${RED}• You're working on new features in the YAML files${NC}"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        exit 0
    fi
fi

# Create backup if requested
if [ "$BACKUP" = true ]; then
    create_backup
fi

# Run the restoration
restore_defaults
