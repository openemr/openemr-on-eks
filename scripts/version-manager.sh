#!/bin/bash

# OpenEMR EKS Version Management System
# ====================================
# This script provides comprehensive automated version checking and management
# for all components in the OpenEMR EKS deployment. It tracks versions across
# the entire codebase, generates detailed reports, and provides update recommendations.
#
# Key Features:
# - Automated version checking across the entire codebase
# - Comprehensive version tracking in versions.yaml
# - Detailed reporting with categorized file locations
# - Support for multiple component types (containers, actions, modules, etc.)
# - Automated report generation with update recommendations
# - Integration with CI/CD pipelines for automated updates
# - Comprehensive logging and audit trail
#
# Component Types Supported:
# - Docker containers (OpenEMR, monitoring stack, etc.)
# - GitHub Actions (workflows and reusable actions)
# - Terraform modules and providers
# - Helm charts and Kubernetes manifests
# - Python packages and dependencies
# - Node.js packages and dependencies
#
# Usage:
#   ./version-manager.sh check-all          # Check all components
#   ./version-manager.sh check <component>  # Check specific component
#   ./version-manager.sh report             # Generate version report
#   ./version-manager.sh update <component> # Update specific component

set -euo pipefail

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical issues
GREEN='\033[0;32m'    # Success messages and positive feedback
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
PURPLE='\033[0;35m'   # Version management messages
CYAN='\033[0;36m'     # Special categories and highlights
NC='\033[0m'          # Reset color to default

# Configuration variables - paths and file locations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Directory containing this script
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"                      # Parent directory (project root)
VERSIONS_FILE="$PROJECT_ROOT/versions.yaml"                  # File containing version tracking data
LOG_FILE="$PROJECT_ROOT/version-updates.log"                 # Log file for version update activities
TEMP_DIR="/tmp/openemr-version-check-$$"                     # Temporary directory for processing

# Create temporary directory for processing and set cleanup trap
mkdir -p "$TEMP_DIR"
trap "rm -rf '$TEMP_DIR'" EXIT  # Ensure cleanup on script exit

# Logging function - provides consistent, timestamped logging
# This function ensures all version management activities are logged with timestamps
# and appropriate log levels for audit trails and debugging
log() {
    local level="$1"    # Log level (INFO, WARN, ERROR, DEBUG)
    shift               # Remove first argument (level) from arguments
    local message="$*"  # Remaining arguments form the log message
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')  # Current timestamp for log entries
    
    # Output to both console (stderr) and log file with timestamp and level
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE" >&2
}

# Function to search for version strings in the codebase
# This function performs comprehensive searches for version references across the entire codebase
# It categorizes results by file type and provides detailed reporting for version updates
search_version_in_codebase() {
    local component="$1"       # Component name (e.g., "openemr/openemr", "actions/checkout")
    local current_version="$2" # Current version being tracked
    local latest_version="$3"  # Latest available version
    
    log "INFO" "Searching for version '$current_version' in codebase for component: $component"
    
    # Create a temporary file for search results
    # Sanitize component name for filename (replace slashes with underscores)
    local sanitized_component=$(echo "$component" | sed 's/[\/\\]/_/g')
    local search_results="$TEMP_DIR/${sanitized_component}_version_search.txt"
    
    # Define exclusion patterns for the search
    # Exclude build artifacts, temporary files, and version reports to focus on source code
    local exclude_patterns=(
        "--exclude-dir=.git"           # Git repository metadata
        "--exclude-dir=node_modules"   # Node.js dependencies
        "--exclude-dir=.terraform"     # Terraform state and cache
        "--exclude-dir=venv"           # Python virtual environment
        "--exclude-dir=__pycache__"    # Python bytecode cache
        "--exclude-dir=.pytest_cache"  # Pytest cache
        "--exclude-dir=dist"           # Distribution files
        "--exclude-dir=build"          # Build artifacts
        "--exclude=*.log"              # Log files
        "--exclude=version-update-report-*.md"  # Previous version reports
        "--exclude=*.pyc"              # Python compiled files
        "--exclude=*.pyo"              # Python optimized files
        "--exclude=*.so"               # Shared object files
        "--exclude=*.o"                # Object files
        "--exclude=*.a"                # Archive files
        "--exclude=*.tmp"              # Temporary files
        "--exclude=*.temp"             # Temporary files
    )
    
    # Escape special characters in the version string for grep regex
    # This prevents grep from interpreting version numbers as regex patterns
    local escaped_version=$(printf '%s\n' "$current_version" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Determine search pattern based on component type
    local search_pattern="$escaped_version"
    if [[ "$component" == *"actions/"* ]] || [[ "$component" == *"azure/"* ]] || [[ "$component" == *"hashicorp/"* ]]; then
        # For GitHub Actions, search for the full action name with the version
        # Format: component@version (e.g., actions/checkout@v3)
        local escaped_component=$(printf '%s\n' "$component" | sed 's/[[\.*^$()+?{|]/\\&/g')
        search_pattern="${escaped_component}@${escaped_version}"
    fi
    
    if grep -rn "${exclude_patterns[@]}" "$search_pattern" "$PROJECT_ROOT" > "$search_results" 2>/dev/null; then
        local match_count=$(wc -l < "$search_results")
        log "INFO" "Found $match_count occurrence(s) of version '$current_version' in codebase"
        
        # Add search results to the report
        echo "" >> "$update_report"
        echo "### 📍 Version Locations for $component" >> "$update_report"
        echo "" >> "$update_report"
        echo "**Current Version:** \`$current_version\`" >> "$update_report"
        echo "**Latest Version:** \`$latest_version\`" >> "$update_report"
        echo "" >> "$update_report"
        echo "**Files containing current version:**" >> "$update_report"
        echo "" >> "$update_report"
        
        # Categorize files by type for better organization in the report
        # This helps users understand where versions are referenced across different file types
        local config_files=()    # Configuration files (YAML, JSON, INI, etc.)
        local doc_files=()       # Documentation files (Markdown, text)
        local script_files=()    # Script files (Shell, Python, JavaScript, TypeScript)
        local terraform_files=() # Terraform configuration files
        local other_files=()     # Other file types not covered above
        
        # Process and categorize the search results
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                # Extract file path and line content from grep output
                # Format: filepath:line_number:content
                local file_path=$(echo "$line" | cut -d: -f1 | sed "s|^$PROJECT_ROOT/||")
                local line_content=$(echo "$line" | cut -d: -f2-)
                
                # Skip if it's the versions.yaml file itself (we know that's where it's tracked)
                if [[ "$file_path" == "versions.yaml" ]]; then
                    continue
                fi
                
                # Categorize files based on extension and type
                if [[ "$file_path" == *.yaml ]] || [[ "$file_path" == *.yml ]] || [[ "$file_path" == *.json ]] || [[ "$file_path" == *.cfg ]] || [[ "$file_path" == *.conf ]] || [[ "$file_path" == *.ini ]] || [[ "$file_path" == *.toml ]] || [[ "$file_path" == *.hcl ]] || [[ "$file_path" == *.env* ]]; then
                    # Configuration files - contain version specifications
                    config_files+=("$file_path:$line_content")
                elif [[ "$file_path" == *.md ]] || [[ "$file_path" == *.txt ]]; then
                    # Documentation files - may contain version references
                    doc_files+=("$file_path:$line_content")
                elif [[ "$file_path" == *.sh ]] || [[ "$file_path" == *.py ]] || [[ "$file_path" == *.js ]] || [[ "$file_path" == *.ts ]]; then
                    # Script files - may contain version checks or references
                    script_files+=("$file_path:$line_content")
                elif [[ "$file_path" == *.tf ]]; then
                    # Terraform files - contain provider and module versions
                    terraform_files+=("$file_path:$line_content")
                else
                    # Other file types - catch-all category
                    other_files+=("$file_path:$line_content")
                fi
            fi
        done < "$search_results"
        
        # Display categorized results in the report
        # Each category is displayed only if it contains files
        if [ ${#config_files[@]} -gt 0 ]; then
            echo "#### 🔧 Configuration Files" >> "$update_report"
            echo '```' >> "$update_report"
            printf '%s\n' "${config_files[@]}" >> "$update_report"
            echo '```' >> "$update_report"
            echo "" >> "$update_report"
        fi
        
        if [ ${#doc_files[@]} -gt 0 ]; then
            echo "#### 📚 Documentation Files" >> "$update_report"
            echo '```' >> "$update_report"
            printf '%s\n' "${doc_files[@]}" >> "$update_report"
            echo '```' >> "$update_report"
            echo "" >> "$update_report"
        fi
        
        if [ ${#script_files[@]} -gt 0 ]; then
            echo "#### 🐚 Script Files" >> "$update_report"
            echo '```' >> "$update_report"
            printf '%s\n' "${script_files[@]}" >> "$update_report"
            echo '```' >> "$update_report"
            echo "" >> "$update_report"
        fi
        
        if [ ${#terraform_files[@]} -gt 0 ]; then
            echo "#### 🏗️ Terraform Files" >> "$update_report"
            echo '```' >> "$update_report"
            printf '%s\n' "${terraform_files[@]}" >> "$update_report"
            echo '```' >> "$update_report"
            echo "" >> "$update_report"
        fi
        
        if [ ${#other_files[@]} -gt 0 ]; then
            echo "#### 📄 Other Files" >> "$update_report"
            echo '```' >> "$update_report"
            printf '%s\n' "${other_files[@]}" >> "$update_report"
            echo '```' >> "$update_report"
            echo "" >> "$update_report"
        fi
        
        # Add explanatory note about the search results
        echo "Note: Search results show all files containing $current_version that need updating." >> "$update_report"
        echo "" >> "$update_report"
    else
        # Handle case where no version occurrences are found in the codebase
        log "WARN" "No occurrences of version '$current_version' found in codebase for component: $component"
        echo "" >> "$update_report"
        echo "### 📍 Version Locations for $component" >> "$update_report"
        echo "" >> "$update_report"
        echo "**Current Version:** \`$current_version\`" >> "$update_report"
        echo "**Latest Version:** \`$latest_version\`" >> "$update_report"
        echo "" >> "$update_report"
        echo "**Note:** No occurrences of the current version found in the codebase. This may indicate the version is only tracked in \`versions.yaml\` or uses a different format." >> "$update_report"
        echo "" >> "$update_report"
    fi
    
    # Clean up temporary files
    # Remove the search results file to prevent accumulation of temporary files
    rm -f "$search_results"
}

# Function to normalize version strings for consistent comparison
# This function handles different version formats (v5 vs v5.0.0) and ensures
# consistent comparison by standardizing the format
normalize_version() {
    local version="$1"  # Version string to normalize
    
    # Remove 'v' prefix and normalize version format
    # This handles versions like "v5.0.0" -> "5.0.0"
    local normalized=$(echo "$version" | sed 's/^v//')
    
    # If it's just a major version (e.g., "5"), treat it as "5.0.0"
    # This ensures consistent comparison between "5" and "5.0.0"
    if [[ "$normalized" =~ ^[0-9]+$ ]]; then
        normalized="${normalized}.0.0"
    fi
    
    echo "$normalized"
}

# Function to compare two version strings for equality
# This function normalizes both versions and compares them, returning 0 if equal, 1 if different
compare_versions() {
    local version1="$1"  # First version to compare
    local version2="$2"  # Second version to compare
    
    # Normalize both versions to ensure consistent comparison
    local norm1=$(normalize_version "$version1")
    local norm2=$(normalize_version "$version2")
    
    # Compare normalized versions
    if [ "$norm1" = "$norm2" ]; then
        return 0  # Versions are equal
    else
        return 1  # Versions are different
    fi
}

# Error handling function
# This function provides consistent error handling and logging throughout the script
error_exit() {
    log "ERROR" "$1"  # Log the error message
    exit 1            # Exit with error code 1
}

# Function to check for required dependencies
# This function validates that all required tools are available before proceeding
check_dependencies() {
    # List of required command-line tools
    local deps=("yq" "curl" "jq" "kubectl" "terraform")
    local missing=()  # Array to track missing dependencies

    # Check each dependency
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    # Exit if any dependencies are missing
    if [ ${#missing[@]} -gt 0 ]; then
        error_exit "Missing dependencies: ${missing[*]}. Please install them first."
    fi
}

# Function to parse YAML configuration file
# This function reads the versions.yaml file and extracts component information
parse_config() {
    # Validate that the versions file exists
    if [ ! -f "$VERSIONS_FILE" ]; then
        error_exit "Version configuration file not found: $VERSIONS_FILE"
    fi

    # Extract configuration using yq
    # Application versions
    OPENEMR_CURRENT=$(yq eval '.applications.openemr.current' "$VERSIONS_FILE")
    OPENEMR_REGISTRY=$(yq eval '.applications.openemr.registry' "$VERSIONS_FILE")

    # Infrastructure versions
    K8S_CURRENT=$(yq eval '.infrastructure.eks.current' "$VERSIONS_FILE")

    # Logging and monitoring versions
    FLUENT_BIT_CURRENT=$(yq eval '.applications.fluent_bit.current' "$VERSIONS_FILE")
    FLUENT_BIT_REGISTRY=$(yq eval '.applications.fluent_bit.registry' "$VERSIONS_FILE")

    # Database versions
    AURORA_CURRENT=$(yq eval '.databases.aurora_mysql.current' "$VERSIONS_FILE")

    # Monitoring stack versions
    PROMETHEUS_CURRENT=$(yq eval '.monitoring.prometheus_operator.current' "$VERSIONS_FILE")
    LOKI_CURRENT=$(yq eval '.monitoring.loki.current' "$VERSIONS_FILE")
    JAEGER_CURRENT=$(yq eval '.monitoring.jaeger.current' "$VERSIONS_FILE")
}

# Function to get the latest Docker image version from Docker Hub
# This function queries Docker Hub's API to retrieve the latest available version
get_latest_docker_version() {
    local registry="$1"      # Docker registry name (e.g., "openemr/openemr")
    local use_stable="$2"    # Set to "true" for OpenEMR (second-to-latest), "false" for others (latest)

    log "INFO" "Checking latest version for $registry..."

    # Construct Docker Hub API URL for the registry
    local url="https://registry.hub.docker.com/v2/repositories/${registry}/tags?page_size=100"
    local response=$(curl -s "$url")

    # Check if curl command succeeded
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to fetch tags from Docker Hub for $registry"
        return 1
    fi

    # Parse and filter versions, excluding architecture-specific tags
    # Only include semantic version numbers (e.g., "7.0.3", not "7.0.3-amd64")
    local versions=$(echo "$response" | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -r)

    # Handle case where no clean semantic versions are found
    if [ -z "$versions" ]; then
        # If no clean versions found, try to extract base versions from architecture-specific tags
        # This handles cases where tags include architecture suffixes (e.g., "7.0.3-amd64")
        local arch_versions=$(echo "$response" | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$' | sed 's/-[a-zA-Z0-9]*$//' | sort -V -r | uniq)
        versions="$arch_versions"
    fi

    # Return appropriate version based on component type
    if [ "$use_stable" = "true" ]; then
        # For OpenEMR, return the second-to-latest version (stable production)
        # This is because the latest version may be a development/pre-release version
        echo "$versions" | sed -n '2p'
    else
        # For all other dependencies, return the latest version
        echo "$versions" | head -n 1
    fi
}

# Function to get the latest Helm chart version from repository index
# This function queries Helm chart repositories to retrieve the latest available version
get_latest_helm_version() {
    local chart="$1"  # Helm chart name (e.g., "kube-prometheus-stack")
    local repo_url="" # Repository URL for the chart
    
    # Determine the correct Helm repository URL based on chart name
    case "$chart" in
        "kube-prometheus-stack")
            repo_url="https://prometheus-community.github.io/helm-charts/index.yaml"
            ;;
        "loki-stack")
            repo_url="https://grafana.github.io/helm-charts/index.yaml"
            ;;
        "loki")
            repo_url="https://grafana.github.io/helm-charts/index.yaml"
            ;;
        "jaeger")
            repo_url="https://jaegertracing.github.io/helm-charts/index.yaml"
            ;;
        "cert-manager")
            repo_url="https://charts.jetstack.io/index.yaml"
            ;;
        *)
            log "ERROR" "Unknown Helm chart: $chart"
            echo "❌ Error"
            return 1
            ;;
    esac

    log "INFO" "Checking latest version for Helm chart: $chart..."

    # Get the repository index and extract the latest version
    # The repository index is a YAML file containing chart metadata
    local index_content=$(curl -s "$repo_url")
    
    # Check if curl command succeeded and content was retrieved
    if [ $? -ne 0 ] || [ -z "$index_content" ]; then
        log "ERROR" "Failed to fetch repository index for $chart"
        echo "❌ Error"
        return 1
    fi
    
    # Extract version from repository index (get the first version entry, not dependencies)
    # The repository index contains chart entries with version information
    local version=$(echo "$index_content" | grep -A 100 "^  $chart:" | grep -E "^    version:" | head -1 | awk '{print $2}')
    
    # Validate that version was successfully extracted
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        log "ERROR" "Failed to parse version for $chart"
        echo "❌ Error"
        return 1
    fi
    
    log "INFO" "Latest version for $chart: $version"
    echo "$version"
}

# Function to get the latest Kubernetes version supported by AWS EKS
# This function queries AWS EKS API to retrieve the latest supported Kubernetes version
get_latest_k8s_version() {
    log "INFO" "Checking latest Kubernetes version supported by AWS EKS..."
    
    # Try to get supported versions from AWS CLI if available
    if command -v aws >/dev/null 2>&1; then
        # Get all supported versions and find the latest one
        # Using EBS CSI driver as a proxy to get EKS supported versions
        local aws_versions=$(aws eks describe-addon-versions --addon-name aws-ebs-csi-driver --query 'addons[0].addonVersions[].compatibilities[].clusterVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -1)
        if [ -n "$aws_versions" ] && [ "$aws_versions" != "None" ]; then
            log "INFO" "Found EKS supported version via AWS CLI: $aws_versions"
            echo "$aws_versions"
            return 0
        fi
    fi
    
    # No fallback available - AWS CLI is required for EKS version checking
    log "ERROR" "Could not determine latest EKS version via AWS CLI"
    echo "❌ Unable to determine"
    return 1
}

# Function to get all supported EKS versions
# This function retrieves the complete list of Kubernetes versions supported by AWS EKS
get_eks_supported_versions() {
    log "INFO" "Getting all supported EKS versions..."
    
    # Try to get from AWS CLI if available
    if command -v aws >/dev/null 2>&1; then
        # Get all supported versions using EBS CSI driver as a proxy
        local aws_versions=$(aws eks describe-addon-versions --addon-name aws-ebs-csi-driver --query 'addons[0].addonVersions[].compatibilities[].clusterVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | uniq)
        if [ -n "$aws_versions" ] && [ "$aws_versions" != "None" ]; then
            # Filter out versions older than 1.28 (EKS minimum supported)
            # This ensures we only return versions that are currently supported by EKS
            local filtered_versions=$(echo "$aws_versions" | awk -F. '$1 == 1 && $2 >= 28 {print $0}' | sort -V)
            if [ -n "$filtered_versions" ]; then
                log "INFO" "Found EKS supported versions via AWS CLI (filtered): $filtered_versions"
                echo "$filtered_versions"
                return 0
            fi
        fi
    fi
    
    # No fallback available - AWS CLI is required for EKS version checking
    log "ERROR" "Could not determine EKS supported versions via AWS CLI"
    echo "❌ Unable to determine"
    return 1
}


# Function to get the latest EKS add-on version
# This function retrieves the latest version of a specific EKS add-on
get_latest_eks_addon_version() {
    local addon_name="$1"      # Name of the EKS add-on (e.g., "aws-ebs-csi-driver")
    local cluster_version="$2" # Kubernetes cluster version for compatibility check
    
    # Check if AWS CLI is available and configured
    if ! command -v aws >/dev/null 2>&1; then
        log "WARN" "AWS CLI not available, cannot check EKS add-on versions"
        echo "❌ AWS CLI not available"
        return 1
    fi
    
    # Check if AWS credentials are configured
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log "WARN" "AWS credentials not configured, cannot check EKS add-on versions"
        echo "❌ AWS credentials not configured"
        return 1
    fi
    
    log "INFO" "Checking latest version for EKS add-on: $addon_name (cluster version: $cluster_version)"
    
    # First try to get the latest version for the specific cluster version
    # This ensures compatibility with the current cluster version
    local latest_version=$(aws eks describe-addon-versions \
        --addon-name "$addon_name" \
        --kubernetes-version "$cluster_version" \
        --query 'addons[0].addonVersions[0].addonVersion' \
        --output text 2>/dev/null)
    
    # If that fails, try to get the latest version without specifying cluster version
    # This provides a fallback when cluster version filtering doesn't work
    if [ $? -ne 0 ] || [ -z "$latest_version" ] || [ "$latest_version" = "None" ]; then
        log "INFO" "Trying to get latest version for $addon_name without cluster version filter"
        latest_version=$(aws eks describe-addon-versions \
            --addon-name "$addon_name" \
            --query 'addons[0].addonVersions[0].addonVersion' \
            --output text 2>/dev/null)
    fi
    
    # If still no luck, try to get any available version
    # This is the final fallback to get any version of the add-on
    if [ $? -ne 0 ] || [ -z "$latest_version" ] || [ "$latest_version" = "None" ]; then
        log "INFO" "Trying to get any available version for $addon_name"
        latest_version=$(aws eks describe-addon-versions \
            --addon-name "$addon_name" \
            --query 'addons[0].addonVersions[-1].addonVersion' \
            --output text 2>/dev/null)
    fi
    
    # Validate that we successfully retrieved a version
    if [ $? -ne 0 ] || [ -z "$latest_version" ] || [ "$latest_version" = "None" ]; then
        log "WARN" "Failed to fetch EKS add-on version for $addon_name"
        echo "❌ Error"
        return 1
    fi
    
    log "INFO" "Latest version for EKS add-on $addon_name: $latest_version"
    echo "$latest_version"
}

# Function to get the latest Aurora MySQL version
# This function retrieves the latest available Aurora MySQL version from AWS
get_latest_aurora_version() {
    log "INFO" "Checking latest Aurora MySQL version..."

    # Try to get the latest version from AWS documentation first
    # Get the latest Aurora MySQL version 3.x.x and construct the full version
    # This method scrapes the AWS documentation for version information
    local latest_version=$(curl -s "https://docs.aws.amazon.com/AmazonRDS/latest/AuroraMySQLReleaseNotes/AuroraMySQL.Updates.30Updates.html" 2>/dev/null | \
        grep -oE "version [0-9]+\.[0-9]+\.[0-9]+" | \
        awk '{print $2}' | \
        uniq | \
        sort -t. -k1,1n -k2,2n -k3,3n | \
        tail -1)
    
    # If we got a version, construct the full Aurora MySQL version
    # Aurora MySQL versions follow the format: 8.0.mysql_aurora.3.x.x
    if [ -n "$latest_version" ]; then
        latest_version="8.0.mysql_aurora.${latest_version}"
        log "INFO" "Latest Aurora MySQL version from documentation: $latest_version"
        echo "$latest_version"
        return 0
    fi

    # If documentation parsing failed, try AWS CLI if available
    # This provides a fallback method using AWS API
    if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
        log "INFO" "Trying AWS CLI to get Aurora MySQL versions..."
        local aws_versions=$(aws rds describe-db-engine-versions \
            --engine aurora-mysql \
            --query 'DBEngineVersions[?contains(EngineVersion, `8.0.mysql_aurora.3`)].EngineVersion' \
            --output text 2>/dev/null | sort -V | tail -1)
        
        if [ -n "$aws_versions" ] && [ "$aws_versions" != "None" ]; then
            log "INFO" "Latest Aurora MySQL version from AWS CLI: $aws_versions"
            echo "$aws_versions"
            return 0
        fi
    fi

    # If all methods failed, return error
    log "WARN" "Could not determine latest Aurora MySQL version"
    echo "❌ Unable to determine"
    return 1
}


# Function to get the latest Terraform module version
# This function retrieves the latest version of a Terraform module from the registry
get_latest_terraform_module_version() {
    local module_source="$1"  # Module source (e.g., "terraform-aws-modules/vpc/aws")

    log "INFO" "Checking latest version for Terraform module: $module_source..."

    # Use Terraform registry API instead of GitHub
    # The Terraform registry provides a standardized API for module information
    local url="https://registry.terraform.io/v1/modules/${module_source}"

    # Fetch module information from the Terraform registry
    local response=$(curl -s "$url" 2>/dev/null || echo "")

    # Check if the API call was successful
    if [ -z "$response" ]; then
        log "WARN" "Could not fetch module information from Terraform registry"
        echo "❌ Error"
        return
    fi

    # Extract latest version from the versions array
    # The registry returns a JSON response with version information
    local version=$(echo "$response" | jq -r '.versions[-1]' 2>/dev/null)
    
    # Validate that we successfully extracted a version
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        log "WARN" "Could not determine latest version for $module_source"
        echo "❌ Unable to determine"
        return 1
    fi
    
    log "INFO" "Latest version for $module_source: $version"
    echo "$version"
}

# Function to get the latest GitHub Action version
# This function retrieves the latest version of a GitHub Action from the repository
get_latest_github_action_version() {
    local action_name="$1"  # GitHub Action name (e.g., "actions/checkout")

    log "INFO" "Checking latest version for GitHub Action: $action_name..."

    # For GitHub Actions, we'll check the marketplace or repository
    # GitHub Actions are typically versioned using Git tags
    local url="https://api.github.com/repos/${action_name}/releases/latest"

    # Fetch the latest release information from GitHub API
    local response=$(curl -s "$url" 2>/dev/null || echo "")

    # Check if the API call was successful
    if [ -z "$response" ]; then
        echo "❌ Error"
        return
    fi

    # Extract tag name (version) from the release information
    # GitHub releases use tag names for versioning
    echo "$response" | jq -r '.tag_name' 2>/dev/null || echo "❌ Error"
}

# Function to get the latest GitHub runner version
# This function retrieves the latest version of GitHub Actions runner images
get_latest_github_runner_version() {
    log "INFO" "Checking latest GitHub runner versions..."

    # Use GitHub API to get available runner releases
    # GitHub Actions runner images are released as part of the actions/runner-images repository
    local releases_url="https://api.github.com/repos/actions/runner-images/releases"
    
    log "INFO" "Fetching runner releases from GitHub API..."
    # Fetch runner releases from GitHub API
    local response=$(curl -s "$releases_url" 2>/dev/null || echo "")
    
    # Check if the API call was successful
    if [ -z "$response" ]; then
        log "WARN" "Failed to fetch runner releases from GitHub API"
        echo "❌ Unable to determine"
        return 1
    fi
    
    # Parse the API response to find Ubuntu runner releases
    # Look for tags that start with "ubuntu" followed by version numbers
    local ubuntu_releases=$(echo "$response" | jq -r '.[] | select(.tag_name | startswith("ubuntu")) | .tag_name' 2>/dev/null || echo "")
    
    # Validate that Ubuntu releases were found
    if [ -z "$ubuntu_releases" ]; then
        log "WARN" "No Ubuntu runner releases found in API response"
        echo "❌ Unable to determine"
        return 1
    fi
    
    # Find the latest Ubuntu version by parsing the tag names
    # Tags are typically in format like "ubuntu24/20250915.37" or "ubuntu22/20250915.36"
    local latest_ubuntu=""
    local latest_version=""
    
    # Process each Ubuntu release tag to find the latest version
    while IFS= read -r tag; do
        # Extract version from tag like "ubuntu24/20250915.37" -> "24"
        if [[ "$tag" =~ ubuntu([0-9]+)/ ]]; then
            local version="${BASH_REMATCH[1]}"
            # Convert to our format (ubuntu-XX.XX)
            # Handle both 2-digit (24 -> 24.04) and 4-digit (2404 -> 24.04) versions
            if [ ${#version} -eq 2 ]; then
                local formatted_version="ubuntu-${version}.04"
            elif [ ${#version} -eq 4 ]; then
                local formatted_version="ubuntu-${version:0:2}.${version:2:2}"
            else
                continue
            fi
            
            # Compare versions (simple string comparison works for this format)
            if [ -z "$latest_version" ] || [[ "$version" > "$latest_version" ]]; then
                latest_version="$version"
                latest_ubuntu="$formatted_version"
            fi
        fi
    done <<< "$ubuntu_releases"
    
    # Return the latest Ubuntu version found
    if [ -n "$latest_ubuntu" ]; then
        log "INFO" "Latest Ubuntu runner found: $latest_ubuntu"
        echo "$latest_ubuntu"
    else
        log "WARN" "Could not parse Ubuntu runner versions from API response"
        echo "❌ Unable to determine"
    fi
}

# Function to get the latest pre-commit hook version
# This function retrieves the latest version of a pre-commit hook from the repository
get_latest_pre_commit_hook_version() {
    local hook_name="$1"  # Pre-commit hook name (e.g., "pre-commit/pre-commit")

    log "INFO" "Checking latest version for pre-commit hook: $hook_name..."

    # Map hook names to their repositories
    # This mapping allows the function to work with common pre-commit hook names
    case "$hook_name" in
        "pre_commit_hooks")
            local repo="pre-commit/pre-commit-hooks"
            ;;
        "black")
            local repo="psf/black"
            ;;
        "isort")
            local repo="pycqa/isort"
            ;;
        "flake8")
            local repo="pycqa/flake8"
            ;;
        "bandit")
            local repo="pycqa/bandit"
            ;;
        "terraform_hooks")
            local repo="antonbabenko/pre-commit-terraform"
            ;;
        "shellcheck")
            local repo="koalaman/shellcheck-precommit"
            ;;
        "markdownlint")
            local repo="igorshubovych/markdownlint-cli"
            ;;
        "yamllint")
            local repo="adrienverge/yamllint"
            ;;
        "commitizen")
            local repo="commitizen-tools/commitizen"
            ;;
        *)
            log "ERROR" "Unknown pre-commit hook: $hook_name"
            echo "❌ Error"
            return 1
            ;;
    esac

    # Try releases first, then tags if releases don't exist
    # Some repositories use releases, others use tags for versioning
    local url="https://api.github.com/repos/${repo}/releases/latest"
    local response=$(curl -s "$url" 2>/dev/null || echo "")
    local latest_version=""

    # Check if releases exist, otherwise fall back to tags
    if [ -z "$response" ] || echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        # No releases, try tags
        log "INFO" "No releases found for $hook_name, trying tags..."
        local tags_url="https://api.github.com/repos/${repo}/tags"
        local tags_response=$(curl -s "$tags_url" 2>/dev/null || echo "")
        
        if [ -n "$tags_response" ] && [ "$tags_response" != "[]" ]; then
            latest_version=$(echo "$tags_response" | jq -r '.[0].name' 2>/dev/null || echo "")
        fi
    else
        # Use releases
        latest_version=$(echo "$response" | jq -r '.tag_name' 2>/dev/null || echo "")
    fi

    # Validate that we successfully retrieved a version
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        log "WARN" "Could not determine latest version for pre-commit hook: $hook_name"
        echo "❌ Unable to determine"
        return 1
    fi

    log "INFO" "Latest version for $hook_name: $latest_version"
    echo "$latest_version"
}

# Function to get the latest semver package version
# This function retrieves the latest version of a package that follows semantic versioning
get_latest_semver_version() {
    local package_name="$1"  # Package name (e.g., "semver")

    log "INFO" "Checking latest version for semver package: $package_name..."

    # Handle different package types with their specific version sources
    case "$package_name" in
        "python_version")
            # For Python, we'll check the official Python tags (no releases)
            # Python uses Git tags for versioning, not GitHub releases
            local url="https://api.github.com/repos/python/cpython/tags"
            local response=$(curl -s "$url" 2>/dev/null || echo "")
            if [ -z "$response" ] || [ "$response" = "[]" ]; then
                echo "❌ Error"
                return 1
            fi
            # Get the latest stable version (not RC/beta) - get full version, not just major.minor
            local latest_version=$(echo "$response" | jq -r '.[] | select(.name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | .name' 2>/dev/null | head -1 | sed 's/^v//' || echo "")
            ;;
        "terraform_version")
            # For Terraform, check HashiCorp releases
            # Terraform uses GitHub releases for versioning
            local url="https://api.github.com/repos/hashicorp/terraform/releases/latest"
            local response=$(curl -s "$url" 2>/dev/null || echo "")
            if [ -z "$response" ]; then
                echo "❌ Error"
                return 1
            fi
            local latest_version=$(echo "$response" | jq -r '.tag_name' 2>/dev/null | sed 's/^v//' || echo "")
            ;;
        "kubectl_version")
            # For kubectl, check Kubernetes releases
            # kubectl is part of the Kubernetes project and uses GitHub releases
            local url="https://api.github.com/repos/kubernetes/kubernetes/releases/latest"
            local response=$(curl -s "$url" 2>/dev/null || echo "")
            if [ -z "$response" ]; then
                echo "❌ Error"
                return 1
            fi
            local latest_version=$(echo "$response" | jq -r '.tag_name' 2>/dev/null || echo "")
            ;;
        "semver")
            # For semver Python package, check PyPI
            # Python packages are typically published to PyPI
            local url="https://pypi.org/pypi/semver/json"
            local response=$(curl -s "$url" 2>/dev/null || echo "")
            if [ -z "$response" ]; then
                echo "❌ Error"
                return 1
            fi
            local latest_version=$(echo "$response" | jq -r '.info.version' 2>/dev/null || echo "")
            ;;
        *)
            log "ERROR" "Unknown semver package: $package_name"
            echo "❌ Error"
            return 1
            ;;
    esac

    # Validate that we successfully retrieved a version
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        log "WARN" "Could not determine latest version for semver package: $package_name"
        echo "❌ Unable to determine"
        return 1
    fi

    log "INFO" "Latest version for $package_name: $latest_version"
    echo "$latest_version"
}

# Function to check for updates across all components
# This function orchestrates the version checking process for all components
check_updates() {
    local components="${1:-all}"  # Components to check (default: all)
    local create_issue="${2:-false}"
    local month="${3:-}"
    
    log "INFO" "Starting version awareness check for components: $components..."
    if [ "$create_issue" = "true" ]; then
        log "INFO" "GitHub issue creation enabled"
    fi
    if [ -n "$month" ]; then
        log "INFO" "Report month: $month"
    fi

    local updates_found=0
    local update_report="$TEMP_DIR/update-report.md"

    cat > "$update_report" << EOF
# OpenEMR EKS Version Awareness Report
Generated: $(date)

## Summary
EOF

    # Check applications if requested
    if [ "$components" = "all" ] || [ "$components" = "applications" ]; then
        # Check OpenEMR version
        log "INFO" "Checking OpenEMR version..."
        local openemr_latest=$(get_latest_docker_version "$OPENEMR_REGISTRY" "true")
        if [ "$openemr_latest" != "$OPENEMR_CURRENT" ]; then
            log "INFO" "OpenEMR update available: $OPENEMR_CURRENT -> $openemr_latest"
            echo "- **OpenEMR**: $OPENEMR_CURRENT → $openemr_latest" >> "$update_report"
            search_version_in_codebase "OpenEMR" "$OPENEMR_CURRENT" "$openemr_latest"
            updates_found=1
        else
            log "INFO" "OpenEMR is up to date: $OPENEMR_CURRENT"
        fi

        # Check Fluent Bit version
        log "INFO" "Checking Fluent Bit version..."
        local fluent_bit_latest=$(get_latest_docker_version "$FLUENT_BIT_REGISTRY" "false")
        if [ "$fluent_bit_latest" != "$FLUENT_BIT_CURRENT" ]; then
            log "INFO" "Fluent Bit update available: $FLUENT_BIT_CURRENT -> $fluent_bit_latest"
            echo "- **Fluent Bit**: $FLUENT_BIT_CURRENT → $fluent_bit_latest" >> "$update_report"
            search_version_in_codebase "Fluent Bit" "$FLUENT_BIT_CURRENT" "$fluent_bit_latest"
            updates_found=1
        else
            log "INFO" "Fluent Bit is up to date: $FLUENT_BIT_CURRENT"
        fi
    fi

    # Check infrastructure if requested
    if [ "$components" = "all" ] || [ "$components" = "infrastructure" ]; then
        # Check Kubernetes version
        log "INFO" "Checking Kubernetes version..."
        local k8s_latest=$(get_latest_k8s_version)
        if [ "$k8s_latest" != "❌ Unable to determine" ] && [ "$k8s_latest" != "$K8S_CURRENT" ]; then
            log "INFO" "Kubernetes update available: $K8S_CURRENT -> $k8s_latest"
            echo "- **Kubernetes**: $K8S_CURRENT → $k8s_latest" >> "$update_report"
            search_version_in_codebase "Kubernetes" "$K8S_CURRENT" "$k8s_latest"
            updates_found=1
        elif [ "$k8s_latest" = "❌ Unable to determine" ]; then
            log "WARN" "Could not check Kubernetes version - AWS CLI not available or not configured"
        else
            log "INFO" "Kubernetes is up to date: $K8S_CURRENT"
        fi

        # Check EKS version
        log "INFO" "Checking EKS version..."
        local eks_current=$(yq eval '.infrastructure.eks.current' "$VERSIONS_FILE")
        local eks_latest=$(get_latest_k8s_version)  # EKS uses same versioning as Kubernetes
        
        if [ "$eks_latest" != "❌ Unable to determine" ] && [ "$eks_latest" != "$eks_current" ]; then
            log "INFO" "EKS update available: $eks_current -> $eks_latest"
            echo "- **EKS**: $eks_current → $eks_latest" >> "$update_report"
            search_version_in_codebase "EKS" "$eks_current" "$eks_latest"
            updates_found=1
        elif [ "$eks_latest" = "❌ Unable to determine" ]; then
            log "WARN" "Could not check EKS version - AWS CLI not available or not configured"
        else
            log "INFO" "EKS is up to date: $eks_current"
        fi
    fi

    # Check Terraform modules if requested
    if [ "$components" = "all" ] || [ "$components" = "terraform_modules" ]; then
        log "INFO" "Checking Terraform modules..."

        # Check EKS module
        local eks_module_current=$(yq eval '.terraform_modules.aws_eks.current' "$VERSIONS_FILE")
        local eks_module_source=$(yq eval '.terraform_modules.aws_eks.source' "$VERSIONS_FILE")
        local eks_module_latest=$(get_latest_terraform_module_version "$eks_module_source")

        if [ "$eks_module_latest" != "❌ Error" ] && [ "$eks_module_latest" != "❌ Unable to determine" ] && [ "$eks_module_latest" != "$eks_module_current" ]; then
            log "INFO" "EKS module update available: $eks_module_current -> $eks_module_latest"
            echo "- **EKS Module**: $eks_module_current → $eks_module_latest" >> "$update_report"
            search_version_in_codebase "EKS Module" "$eks_module_current" "$eks_module_latest"
            updates_found=1
        elif [ "$eks_module_latest" = "❌ Unable to determine" ]; then
            log "WARN" "Could not determine latest version for EKS module (GitHub API issue)"
        fi

        # Check VPC module
        local vpc_module_current=$(yq eval '.terraform_modules.aws_vpc.current' "$VERSIONS_FILE")
        local vpc_module_source=$(yq eval '.terraform_modules.aws_vpc.source' "$VERSIONS_FILE")
        local vpc_module_latest=$(get_latest_terraform_module_version "$vpc_module_source")

        if [ "$vpc_module_latest" != "❌ Error" ] && [ "$vpc_module_latest" != "❌ Unable to determine" ] && [ "$vpc_module_latest" != "$vpc_module_current" ]; then
            log "INFO" "VPC module update available: $vpc_module_current -> $vpc_module_latest"
            echo "- **VPC Module**: $vpc_module_current → $vpc_module_latest" >> "$update_report"
            search_version_in_codebase "VPC Module" "$vpc_module_current" "$vpc_module_latest"
            updates_found=1
        elif [ "$vpc_module_latest" = "❌ Unable to determine" ]; then
            log "WARN" "Could not determine latest version for VPC module (GitHub API issue)"
        fi

        # Check aws_pod_identity module
        local pod_identity_module_current=$(yq eval '.terraform_modules.aws_pod_identity.current' "$VERSIONS_FILE")
        local pod_identity_module_source=$(yq eval '.terraform_modules.aws_pod_identity.source' "$VERSIONS_FILE")
        local pod_identity_module_latest=$(get_latest_terraform_module_version "$pod_identity_module_source")

        if [ "$pod_identity_module_latest" != "❌ Error" ] && [ "$pod_identity_module_latest" != "❌ Unable to determine" ] && [ "$pod_identity_module_latest" != "$pod_identity_module_current" ]; then
            log "INFO" "AWS Pod Identity module update available: $pod_identity_module_current -> $pod_identity_module_latest"
            echo "- **AWS Pod Identity Module**: $pod_identity_module_current → $pod_identity_module_latest" >> "$update_report"
            search_version_in_codebase "AWS Pod Identity Module" "$pod_identity_module_current" "$pod_identity_module_latest"
            updates_found=1
        elif [ "$pod_identity_module_latest" = "❌ Unable to determine" ]; then
            log "WARN" "Could not determine latest version for AWS Pod Identity module (GitHub API issue)"
        fi
    fi

    # Check GitHub workflow dependencies if requested
    if [ "$components" = "all" ] || [ "$components" = "github_workflows" ]; then
        log "INFO" "Checking GitHub workflow dependencies..."

        # Check actions/checkout
        local checkout_current=$(yq eval '.github_workflows.actions_checkout.current' "$VERSIONS_FILE")
        local checkout_latest=$(get_latest_github_action_version "actions/checkout")

        if [ "$checkout_latest" != "❌ Error" ] && ! compare_versions "$checkout_current" "$checkout_latest"; then
            log "INFO" "actions/checkout update available: $checkout_current -> $checkout_latest"
            echo "- **actions/checkout**: $checkout_current → $checkout_latest" >> "$update_report"
            search_version_in_codebase "actions/checkout" "$checkout_current" "$checkout_latest"
            updates_found=1
        fi

        # Check actions/setup-python
        local python_action_current=$(yq eval '.github_workflows.actions_setup_python.current' "$VERSIONS_FILE")
        local python_action_latest=$(get_latest_github_action_version "actions/setup-python")

        if [ "$python_action_latest" != "❌ Error" ] && ! compare_versions "$python_action_current" "$python_action_latest"; then
            log "INFO" "actions/setup-python update available: $python_action_current -> $python_action_latest"
            echo "- **actions/setup-python**: $python_action_current → $python_action_latest" >> "$update_report"
            search_version_in_codebase "actions/setup-python" "$python_action_current" "$python_action_latest"
            updates_found=1
        fi

        # Check hashicorp/setup-terraform
        local terraform_action_current=$(yq eval '.github_workflows.actions_setup_terraform.current' "$VERSIONS_FILE")
        local terraform_action_latest=$(get_latest_github_action_version "hashicorp/setup-terraform")

        if [ "$terraform_action_latest" != "❌ Error" ] && ! compare_versions "$terraform_action_current" "$terraform_action_latest"; then
            log "INFO" "hashicorp/setup-terraform update available: $terraform_action_current -> $terraform_action_latest"
            echo "- **hashicorp/setup-terraform**: $terraform_action_current → $terraform_action_latest" >> "$update_report"
            search_version_in_codebase "hashicorp/setup-terraform" "$terraform_action_current" "$terraform_action_latest"
            updates_found=1
        fi

        # Check azure/setup-kubectl
        local kubectl_action_current=$(yq eval '.github_workflows.actions_setup_kubectl.current' "$VERSIONS_FILE")
        local kubectl_action_latest=$(get_latest_github_action_version "azure/setup-kubectl")

        if [ "$kubectl_action_latest" != "❌ Error" ] && ! compare_versions "$kubectl_action_current" "$kubectl_action_latest"; then
            log "INFO" "azure/setup-kubectl update available: $kubectl_action_current -> $kubectl_action_latest"
            echo "- **azure/setup-kubectl**: $kubectl_action_current → $kubectl_action_latest" >> "$update_report"
            search_version_in_codebase "azure/setup-kubectl" "$kubectl_action_current" "$kubectl_action_latest"
            updates_found=1
        fi

        # Check GitHub runner
        local runner_current=$(yq eval '.github_workflows.github_runner.current' "$VERSIONS_FILE")
        local runner_latest=$(get_latest_github_runner_version)

        if [ "$runner_latest" != "❌ Unable to determine" ] && [ "$runner_latest" != "$runner_current" ]; then
            log "INFO" "GitHub runner update available: $runner_current -> $runner_latest"
            echo "- **GitHub Runner**: $runner_current → $runner_latest" >> "$update_report"
            search_version_in_codebase "GitHub Runner" "$runner_current" "$runner_latest"
            updates_found=1
        fi
    fi

    # Check pre-commit hooks if requested
    if [ "$components" = "all" ] || [ "$components" = "pre_commit_hooks" ]; then
        log "INFO" "Checking pre-commit hooks versions..."

        # Check pre-commit-hooks
        local pre_commit_current=$(yq eval '.pre_commit_hooks.pre_commit_hooks.current' "$VERSIONS_FILE")
        local pre_commit_latest=$(get_latest_pre_commit_hook_version "pre_commit_hooks")

        if [ "$pre_commit_latest" != "❌ Error" ] && [ "$pre_commit_latest" != "$pre_commit_current" ]; then
            log "INFO" "pre-commit-hooks update available: $pre_commit_current -> $pre_commit_latest"
            echo "- **pre-commit-hooks**: $pre_commit_current → $pre_commit_latest" >> "$update_report"
            search_version_in_codebase "pre-commit-hooks" "$pre_commit_current" "$pre_commit_latest"
            updates_found=1
        fi

        # Check black
        local black_current=$(yq eval '.pre_commit_hooks.black.current' "$VERSIONS_FILE")
        local black_latest=$(get_latest_pre_commit_hook_version "black")

        if [ "$black_latest" != "❌ Error" ] && [ "$black_latest" != "$black_current" ]; then
            log "INFO" "black update available: $black_current -> $black_latest"
            echo "- **black**: $black_current → $black_latest" >> "$update_report"
            search_version_in_codebase "black" "$black_current" "$black_latest"
            updates_found=1
        fi

        # Check isort
        local isort_current=$(yq eval '.pre_commit_hooks.isort.current' "$VERSIONS_FILE")
        local isort_latest=$(get_latest_pre_commit_hook_version "isort")

        if [ "$isort_latest" != "❌ Error" ] && [ "$isort_latest" != "$isort_current" ]; then
            log "INFO" "isort update available: $isort_current -> $isort_latest"
            echo "- **isort**: $isort_current → $isort_latest" >> "$update_report"
            updates_found=1
        fi

        # Check flake8
        local flake8_current=$(yq eval '.pre_commit_hooks.flake8.current' "$VERSIONS_FILE")
        local flake8_latest=$(get_latest_pre_commit_hook_version "flake8")

        if [ "$flake8_latest" != "❌ Error" ] && [ "$flake8_latest" != "$flake8_current" ]; then
            log "INFO" "flake8 update available: $flake8_current -> $flake8_latest"
            echo "- **flake8**: $flake8_current → $flake8_latest" >> "$update_report"
            updates_found=1
        fi

        # Check bandit
        local bandit_current=$(yq eval '.pre_commit_hooks.bandit.current' "$VERSIONS_FILE")
        local bandit_latest=$(get_latest_pre_commit_hook_version "bandit")

        if [ "$bandit_latest" != "❌ Error" ] && [ "$bandit_latest" != "$bandit_current" ]; then
            log "INFO" "bandit update available: $bandit_current -> $bandit_latest"
            echo "- **bandit**: $bandit_current → $bandit_latest" >> "$update_report"
            updates_found=1
        fi

        # Check terraform hooks
        local terraform_hooks_current=$(yq eval '.pre_commit_hooks.terraform_hooks.current' "$VERSIONS_FILE")
        local terraform_hooks_latest=$(get_latest_pre_commit_hook_version "terraform_hooks")

        if [ "$terraform_hooks_latest" != "❌ Error" ] && [ "$terraform_hooks_latest" != "$terraform_hooks_current" ]; then
            log "INFO" "terraform hooks update available: $terraform_hooks_current -> $terraform_hooks_latest"
            echo "- **terraform hooks**: $terraform_hooks_current → $terraform_hooks_latest" >> "$update_report"
            updates_found=1
        fi

        # Check shellcheck
        local shellcheck_current=$(yq eval '.pre_commit_hooks.shellcheck.current' "$VERSIONS_FILE")
        local shellcheck_latest=$(get_latest_pre_commit_hook_version "shellcheck")

        if [ "$shellcheck_latest" != "❌ Error" ] && [ "$shellcheck_latest" != "$shellcheck_current" ]; then
            log "INFO" "shellcheck update available: $shellcheck_current -> $shellcheck_latest"
            echo "- **shellcheck**: $shellcheck_current → $shellcheck_latest" >> "$update_report"
            updates_found=1
        fi

        # Check markdownlint
        local markdownlint_current=$(yq eval '.pre_commit_hooks.markdownlint.current' "$VERSIONS_FILE")
        local markdownlint_latest=$(get_latest_pre_commit_hook_version "markdownlint")

        if [ "$markdownlint_latest" != "❌ Error" ] && [ "$markdownlint_latest" != "$markdownlint_current" ]; then
            log "INFO" "markdownlint update available: $markdownlint_current -> $markdownlint_latest"
            echo "- **markdownlint**: $markdownlint_current → $markdownlint_latest" >> "$update_report"
            updates_found=1
        fi

        # Check yamllint
        local yamllint_current=$(yq eval '.pre_commit_hooks.yamllint.current' "$VERSIONS_FILE")
        local yamllint_latest=$(get_latest_pre_commit_hook_version "yamllint")

        if [ "$yamllint_latest" != "❌ Error" ] && [ "$yamllint_latest" != "$yamllint_current" ]; then
            log "INFO" "yamllint update available: $yamllint_current -> $yamllint_latest"
            echo "- **yamllint**: $yamllint_current → $yamllint_latest" >> "$update_report"
            updates_found=1
        fi

        # Check commitizen
        local commitizen_current=$(yq eval '.pre_commit_hooks.commitizen.current' "$VERSIONS_FILE")
        local commitizen_latest=$(get_latest_pre_commit_hook_version "commitizen")

        if [ "$commitizen_latest" != "❌ Error" ] && [ "$commitizen_latest" != "$commitizen_current" ]; then
            log "INFO" "commitizen update available: $commitizen_current -> $commitizen_latest"
            echo "- **commitizen**: $commitizen_current → $commitizen_latest" >> "$update_report"
            search_version_in_codebase "commitizen" "$commitizen_current" "$commitizen_latest"
            updates_found=1
        fi
    fi

    # Check semver packages if requested
    if [ "$components" = "all" ] || [ "$components" = "semver_packages" ]; then
        log "INFO" "Checking semver package versions..."

        # Check Python version
        local python_current=$(yq eval '.semver_packages.python_version.current' "$VERSIONS_FILE")
        local python_latest=$(get_latest_semver_version "python_version")

        if [ "$python_latest" != "❌ Error" ] && [ "$python_latest" != "$python_current" ]; then
            log "INFO" "Python version update available: $python_current -> $python_latest"
            echo "- **Python**: $python_current → $python_latest" >> "$update_report"
            updates_found=1
        fi

        # Check Terraform version
        local terraform_current=$(yq eval '.semver_packages.terraform_version.current' "$VERSIONS_FILE")
        local terraform_latest=$(get_latest_semver_version "terraform_version")

        if [ "$terraform_latest" != "❌ Error" ] && [ "$terraform_latest" != "$terraform_current" ]; then
            log "INFO" "Terraform version update available: $terraform_current -> $terraform_latest"
            echo "- **Terraform**: $terraform_current → $terraform_latest" >> "$update_report"
            search_version_in_codebase "Terraform" "$terraform_current" "$terraform_latest"
            updates_found=1
        fi

        # Check kubectl version
        local kubectl_current=$(yq eval '.semver_packages.kubectl_version.current' "$VERSIONS_FILE")
        local kubectl_latest=$(get_latest_semver_version "kubectl_version")

        if [ "$kubectl_latest" != "❌ Error" ] && [ "$kubectl_latest" != "$kubectl_current" ]; then
            log "INFO" "kubectl version update available: $kubectl_current -> $kubectl_latest"
            echo "- **kubectl**: $kubectl_current → $kubectl_latest" >> "$update_report"
            search_version_in_codebase "kubectl" "$kubectl_current" "$kubectl_latest"
            updates_found=1
        fi

        # Check semver package version
        local semver_current=$(yq eval '.semver_packages.semver.current' "$VERSIONS_FILE")
        local semver_latest=$(get_latest_semver_version "semver")

        if [ "$semver_latest" != "❌ Error" ] && [ "$semver_latest" != "$semver_current" ]; then
            log "INFO" "semver package update available: $semver_current -> $semver_latest"
            echo "- **semver**: $semver_current → $semver_latest" >> "$update_report"
            updates_found=1
        fi
    fi

    # Check monitoring stack versions if requested
    if [ "$components" = "all" ] || [ "$components" = "monitoring" ]; then
        log "INFO" "Checking monitoring stack versions..."

        # Prometheus Operator
        local prometheus_latest=$(get_latest_helm_version "kube-prometheus-stack")
        if [ "$prometheus_latest" != "$PROMETHEUS_CURRENT" ]; then
            log "INFO" "Prometheus Operator update available: $PROMETHEUS_CURRENT -> $prometheus_latest"
            echo "- **Prometheus Operator**: $PROMETHEUS_CURRENT → $prometheus_latest" >> "$update_report"
            search_version_in_codebase "Prometheus Operator" "$PROMETHEUS_CURRENT" "$prometheus_latest"
            updates_found=1
        fi

        # Loki
        local loki_latest=$(get_latest_helm_version "loki" "grafana")
        if [ "$loki_latest" != "$LOKI_CURRENT" ]; then
            log "INFO" "Loki update available: $LOKI_CURRENT -> $loki_latest"
            echo "- **Loki**: $LOKI_CURRENT → $loki_latest" >> "$update_report"
            search_version_in_codebase "Loki" "$LOKI_CURRENT" "$loki_latest"
            updates_found=1
        fi

        # Jaeger
        local jaeger_latest=$(get_latest_helm_version "jaeger")
        if [ "$jaeger_latest" != "$JAEGER_CURRENT" ]; then
            log "INFO" "Jaeger update available: $JAEGER_CURRENT -> $jaeger_latest"
            echo "- **Jaeger**: $JAEGER_CURRENT → $jaeger_latest" >> "$update_report"
            search_version_in_codebase "Jaeger" "$JAEGER_CURRENT" "$jaeger_latest"
            updates_found=1
        fi

        # cert-manager
        local cert_manager_current=$(yq eval '.monitoring.cert_manager.current' "$VERSIONS_FILE")
        local cert_manager_latest=$(get_latest_helm_version "cert-manager" "jetstack")
        if [ "$cert_manager_latest" != "$cert_manager_current" ]; then
            log "INFO" "cert-manager update available: $cert_manager_current -> $cert_manager_latest"
            echo "- **cert-manager**: $cert_manager_current → $cert_manager_latest" >> "$update_report"
            search_version_in_codebase "cert-manager" "$cert_manager_current" "$cert_manager_latest"
            updates_found=1
        fi
    fi

    # Check EKS add-ons versions if requested
    if [ "$components" = "all" ] || [ "$components" = "eks_addons" ]; then
        log "INFO" "Checking EKS add-ons versions..."
        
        # Get current EKS cluster version
        local eks_version=$(yq eval '.infrastructure.eks.current' "$VERSIONS_FILE")
        
        # Check EFS CSI Driver
        local efs_csi_current=$(yq eval '.eks_addons.efs_csi_driver.current' "$VERSIONS_FILE")
        local efs_csi_latest=$(get_latest_eks_addon_version "aws-efs-csi-driver" "$eks_version")
        
        if [ "$efs_csi_latest" != "❌ Error" ] && [ "$efs_csi_latest" != "$efs_csi_current" ]; then
            log "INFO" "EFS CSI Driver update available: $efs_csi_current -> $efs_csi_latest"
            echo "- **EFS CSI Driver**: $efs_csi_current → $efs_csi_latest" >> "$update_report"
            search_version_in_codebase "EFS CSI Driver" "$efs_csi_current" "$efs_csi_latest"
            updates_found=1
        fi
        
        # Check Metrics Server
        local metrics_server_current=$(yq eval '.eks_addons.metrics_server.current' "$VERSIONS_FILE")
        local metrics_server_latest=$(get_latest_eks_addon_version "metrics-server" "$eks_version")
        
        if [ "$metrics_server_latest" != "❌ Error" ] && [ "$metrics_server_latest" != "$metrics_server_current" ]; then
            log "INFO" "Metrics Server update available: $metrics_server_current -> $metrics_server_latest"
            echo "- **Metrics Server**: $metrics_server_current → $metrics_server_latest" >> "$update_report"
            search_version_in_codebase "Metrics Server" "$metrics_server_current" "$metrics_server_latest"
            updates_found=1
        fi
    fi


    if [ $updates_found -eq 0 ]; then
        log "INFO" "All components are up to date!"
        echo "No updates available." >> "$update_report"
    else
        log "INFO" "Found $updates_found component(s) with available updates"
    fi

    # Display report
    echo ""
    cat "$update_report"

    # Save report
    local report_file="$PROJECT_ROOT/version-update-report-$(date +%Y%m%d-%H%M%S).md"
    cp "$update_report" "$report_file"
    log "INFO" "Update report saved to: $report_file"

    # Return success (0) regardless of whether updates were found
    # This prevents GitHub Actions from failing when no updates are available
    return 0
}







# Show help
show_help() {
    cat << EOF
OpenEMR EKS Version Manager

Usage: $0 [COMMAND] [OPTIONS]

Commands:
  check [--components TYPE]  Check for available updates (awareness only)
  status                   Show current version status
  help                     Show this help message

Options:
  --components TYPE       Check specific component types (all, applications, infrastructure, terraform_modules, github_workflows, pre_commit_hooks, semver_packages, monitoring, eks_addons)
  --create-issue          Create GitHub issue for updates (used by CI/CD)
  --month <month>         Specify month for report title (used by CI/CD)
  --log-level LEVEL       Set log level (DEBUG, INFO, WARN, ERROR)

Component Types:
  applications            OpenEMR, Fluent Bit
  infrastructure          Kubernetes, Terraform, AWS Provider
  terraform_modules       EKS, VPC, RDS modules
  github_workflows        GitHub Actions dependencies
  pre_commit_hooks        Pre-commit hook versions
  semver_packages         Python, Terraform, kubectl versions
  monitoring              Prometheus, Loki, Jaeger
  eks_addons             EFS CSI Driver, Metrics Server

Examples:
  $0 check                                    # Check all components
  $0 check --components applications          # Check only applications
  $0 check --components terraform_modules     # Check only Terraform modules
  $0 check --components eks_addons           # Check only EKS add-ons
  $0 check --create-issue --month "January 2025"  # Create GitHub issue
  $0 status                                   # Show current status

Note: Some version checks require AWS CLI credentials to be configured.
      The system will gracefully handle missing credentials and report what
      cannot be checked due to lack of AWS access.

EOF
}

# Show current status
show_status() {
    log "INFO" "Current version status:"
    echo ""
    echo -e "${BLUE}Applications:${NC}"
    echo -e "  OpenEMR: ${GREEN}$OPENEMR_CURRENT${NC}"
    echo -e "  Fluent Bit: ${GREEN}$FLUENT_BIT_CURRENT${NC}"
    echo ""
    echo -e "${BLUE}Infrastructure:${NC}"
    echo -e "  Kubernetes: ${GREEN}$K8S_CURRENT${NC}"
    echo -e "  Aurora MySQL: ${GREEN}$AURORA_CURRENT${NC}"
    echo ""
    echo -e "${BLUE}Monitoring:${NC}"
    echo -e "  Prometheus Operator: ${GREEN}$PROMETHEUS_CURRENT${NC}"
    echo -e "  Loki: ${GREEN}$LOKI_CURRENT${NC}"
    echo -e "  Jaeger: ${GREEN}$JAEGER_CURRENT${NC}"
    echo ""
}

# Main function - entry point for the script
# This function handles command-line argument parsing and dispatches to appropriate functions
main() {
    # Set default values for command-line options
    local command="${1:-check}"     # Default command is 'check'
    local components="all"          # Default to checking all components
    local create_issue="false"      # Don't create GitHub issues by default
    local month=""                  # No month filtering by default

    # Parse command-line arguments
    shift || true  # Remove the command from arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --components)
                components="$2"
                shift 2
                ;;
            --create-issue)
                create_issue="true"
                shift
                ;;
            --month)
                month="$2"
                shift 2
                ;;
            --log-level)
                # Log level - would set logging level (placeholder for future enhancement)
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done

    # Initialize script dependencies and configuration
    check_dependencies  # Validate required tools are available
    parse_config       # Load version configuration from YAML file

    # Execute the specified command
    case "$command" in
        "check")
            # Check for version updates across specified components
            check_updates "$components" "$create_issue" "$month"
            ;;
        "status")
            # Display current version status
            show_status
            ;;
        "help"|"--help")
            # Show usage information
            show_help
            ;;
        *)
            error_exit "Unknown command: $command. Use 'help' or '--help' for usage information."
            ;;
    esac
}

# Run main function with all arguments
main "$@"
