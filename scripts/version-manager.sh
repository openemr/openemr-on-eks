#!/bin/bash

# =============================================================================
# OpenEMR EKS Version Management System
# =============================================================================
#
# Purpose:
#   Provides comprehensive automated version checking and management for all
#   components in the OpenEMR EKS deployment. Tracks versions across the
#   entire codebase, generates reports, and provides update recommendations.
#
# Key Features:
#   - Automated version checking across the entire codebase
#   - Comprehensive version tracking in versions.yaml
#   - Detailed reporting with categorized file locations
#   - Support for multiple component types (containers, actions, modules, etc.)
#   - Automated report generation with update recommendations
#   - Integration with CI/CD pipelines for automated updates
#   - Comprehensive logging and audit trail
#
# Prerequisites:
#   - Internet connectivity for version checking
#   - jq (for JSON parsing)
#   - yq (for YAML parsing)
#   - Access to Docker Hub, GitHub, Terraform Registry APIs
#
# Usage:
#   ./version-manager.sh [COMMAND] [OPTIONS]
#
# Commands:
#   check [--components TYPE]  Check for available updates (awareness only)
#   status                     Show current version status
#   help                       Show this help message
#
# Environment Variables:
#   None - Script uses fixed paths relative to project root
#
# Component Types Supported:
#   - Docker containers (OpenEMR, monitoring stack, etc.)
#   - GitHub Actions (workflows and reusable actions)
#   - Terraform modules and providers
#   - Helm charts and Kubernetes manifests
#   - Python packages and dependencies
#   - Node.js packages and dependencies
#
# Examples:
#   ./version-manager.sh check                                        # Check all components
#   ./version-manager.sh check --components applications              # Check only applications
#   ./version-manager.sh check --components terraform_modules         # Check only Terraform modules
#   ./version-manager.sh check --components eks_addons                # Check only EKS add-ons
#   ./version-manager.sh check --create-issue --month "January 2025"  # Create GitHub issue
#   ./version-manager.sh status                                       # Show current status
#
# =============================================================================

set -euo pipefail

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'    # Error messages and critical issues
GREEN='\033[0;32m'  # Success messages and positive feedback
YELLOW='\033[1;33m' # Warning messages and cautionary information
BLUE='\033[0;34m'   # Info messages and general information
PURPLE='\033[0;35m' # Version management messages
CYAN='\033[0;36m'   # Special categories and highlights
NC='\033[0m'        # Reset color to default

# Configuration variables - paths and file locations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Directory containing this script
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"                    # Parent directory (project root)
VERSIONS_FILE="$PROJECT_ROOT/versions.yaml"                # File containing version tracking data
LOG_FILE="$PROJECT_ROOT/version-updates.log"               # Log file for version update activities
TEMP_DIR="/tmp/openemr-version-check-$$"                   # Temporary directory for processing

# Create temporary directory for processing and set cleanup trap
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT  # Ensure cleanup on script exit

# Logging function - provides consistent, timestamped logging
# This function ensures all version management activities are logged with timestamps
# and appropriate log levels for audit trails and debugging
log() {
    local level="$1"                             # Log level (INFO, WARN, ERROR, DEBUG)
    shift                                        # Remove first argument (level) from arguments
    local message="$*"                           # Remaining arguments form the log message
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S') # Current timestamp for log entries
    
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
        "--exclude-dir=.git"                   # Git repository metadata
        "--exclude-dir=node_modules"           # Node.js dependencies
        "--exclude-dir=.terraform"             # Terraform state and cache
        "--exclude-dir=venv"                   # Python virtual environment
        "--exclude-dir=__pycache__"            # Python bytecode cache
        "--exclude-dir=.pytest_cache"          # Pytest cache
        "--exclude-dir=dist"                   # Distribution files
        "--exclude-dir=build"                  # Build artifacts
        "--exclude=*.log"                      # Log files
        "--exclude=version-update-report-*.md" # Previous version reports
        "--exclude=*.pyc"                      # Python compiled files
        "--exclude=*.pyo"                      # Python optimized files
        "--exclude=*.so"                       # Shared object files
        "--exclude=*.o"                        # Object files
        "--exclude=*.a"                        # Archive files
        "--exclude=*.tmp"                      # Temporary files
        "--exclude=*.temp"                     # Temporary files
    )
    
    # Escape special characters in the version string for grep regex
    # This prevents grep from interpreting version numbers as regex patterns
    # shellcheck disable=SC2016
    local escaped_version=$(printf '%s\n' "$current_version" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Determine search pattern based on component type
    local search_pattern="$escaped_version"
    if [[ "$component" == actions/* ]] ||
        [[ "$component" == azure/* ]] ||
        [[ "$component" == hashicorp/setup-* ]] ||
        [[ "$component" == aquasecurity/trivy-action ]] ||
        [[ "$component" == aws-actions/* ]] ||
        [[ "$component" == github/codeql-action ]] ||
        [[ "$component" == dorny/* ]] ||
        [[ "$component" == Checkmarx/kics-github-action ]] ||
        [[ "$component" == ncipollo/* ]] ||
        [[ "$component" == terraform-linters/* ]]; then
        # Actions use immutable SHAs with a reviewed release tag in a comment.
        # shellcheck disable=SC2016
        local escaped_component=$(printf '%s\n' "$component" | sed 's/[[\.*^$()+?{|]/\\&/g')
        search_pattern="${escaped_component}.*@.*# ${escaped_version}"
    fi
    
    if grep -rn "${exclude_patterns[@]}" "$search_pattern" "$PROJECT_ROOT" > "$search_results" 2>/dev/null; then
        local match_count=$(wc -l < "$search_results")
        log "INFO" "Found $match_count occurrence(s) of version '$current_version' in codebase"
        
        # Add search results to the report
        {
            echo ""
            echo "### 📍 Version Locations for $component"
            echo ""
            echo "**Current Version:** \`$current_version\`"
            echo "**Latest Version:** \`$latest_version\`"
            echo ""
            echo "**Files containing current version:**"
            echo ""
        } >> "$update_report"
        
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
            {
                echo "#### 🔧 Configuration Files"
                echo '```'
                printf '%s\n' "${config_files[@]}"
                echo '```'
                echo ""
            } >> "$update_report"
        fi
        
        if [ ${#doc_files[@]} -gt 0 ]; then
            {
                echo "#### 📚 Documentation Files"
                echo '```'
                printf '%s\n' "${doc_files[@]}"
                echo '```'
                echo ""
            } >> "$update_report"
        fi
        
        if [ ${#script_files[@]} -gt 0 ]; then
            {
                echo "#### 🐚 Script Files"
                echo '```'
                printf '%s\n' "${script_files[@]}"
                echo '```'
                echo ""
            } >> "$update_report"
        fi
        
        if [ ${#terraform_files[@]} -gt 0 ]; then
            {
                echo "#### 🏗️ Terraform Files"
                echo '```'
                printf '%s\n' "${terraform_files[@]}"
                echo '```'
                echo ""
            } >> "$update_report"
        fi
        
        if [ ${#other_files[@]} -gt 0 ]; then
            {
                echo "#### 📄 Other Files"
                echo '```'
                printf '%s\n' "${other_files[@]}"
                echo '```'
                echo ""
            } >> "$update_report"
        fi
        
        # Add explanatory note about the search results
        echo "Note: Search results show all files containing $current_version that need updating." >> "$update_report"
        echo "" >> "$update_report"
    else
        # Handle case where no version occurrences are found in the codebase
        log "WARN" "No occurrences of version '$current_version' found in codebase for component: $component"
        {
            echo ""
            echo "### 📍 Version Locations for $component"
            echo ""
            echo "**Current Version:** \`$current_version\`"
            echo "**Latest Version:** \`$latest_version\`"
            echo ""
            echo "**Note:** No occurrences of the current version found in the codebase. This may indicate the version is only tracked in \`versions.yaml\` or uses a different format."
            echo ""
        } >> "$update_report"
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
    local normalized="${version#v}"
    
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
    local version1="$1" # First version to compare
    local version2="$2" # Second version to compare
    
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
    log "ERROR" "$1" # Log the error message
    exit 1           # Exit with error code 1
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
    
    # Python Docker image version (for Warp)
    PYTHON_CURRENT=$(yq eval '.applications.python.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
    PYTHON_REGISTRY=$(yq eval '.applications.python.registry' "$VERSIONS_FILE" 2>/dev/null || echo "library/python")

    # Floci local AWS emulator image (CI integration / e2e-lite)
    FLOCI_CURRENT=$(yq eval '.applications.floci.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
    FLOCI_REGISTRY=$(yq eval '.applications.floci.registry' "$VERSIONS_FILE" 2>/dev/null || echo "floci/floci")

    # Database versions
    AURORA_CURRENT=$(yq eval '.databases.aurora_mysql.current' "$VERSIONS_FILE")

    # Monitoring stack versions
    PROMETHEUS_CURRENT=$(yq eval '.monitoring.prometheus_operator.current' "$VERSIONS_FILE")
    LOKI_CURRENT=$(yq eval '.monitoring.loki.current' "$VERSIONS_FILE")
    TEMPO_CURRENT=$(yq eval '.monitoring.tempo.current' "$VERSIONS_FILE")
    MIMIR_CURRENT=$(yq eval '.monitoring.mimir.current' "$VERSIONS_FILE")
    OTEBPF_CURRENT=$(yq eval '.monitoring.otebpf.current' "$VERSIONS_FILE")
}

# Function to get the latest Docker image version from Docker Hub
# This function queries Docker Hub's API to retrieve the latest available version
# Extract the newest stable Docker Hub tag from a JSON tags payload.
# Accepts plain and v-prefixed semver (e.g. 1.6.0, v0.10.0). Architecture
# suffixes are stripped as a fallback when only arch-qualified tags exist.
_extract_latest_docker_semver_tag() {
    local response="$1"
    local versions

    versions=$(echo "$response" | jq -r '.results[]?.name // empty' 2>/dev/null \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V -r) || versions=""

    if [ -z "$versions" ]; then
        versions=$(echo "$response" \
            | jq -r '.results[]?.name // empty' 2>/dev/null \
            | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+-(amd64|arm64|aarch64|x86_64)$' \
            | sed -E 's/-(amd64|arm64|aarch64|x86_64)$//' \
            | sort -V -r \
            | uniq) || versions=""
    fi

    echo "$versions" | head -n 1
}

get_latest_docker_version() {
    local registry="$1" # Docker registry name (e.g., "fluent/fluent-bit")

    log "INFO" "Checking latest version for $registry..."

    local page=1
    local max_pages=5
    local next_url="https://registry.hub.docker.com/v2/repositories/${registry}/tags?page_size=100"
    local versions=""
    local response=""

    # Paginate: some repos (e.g. otel/ebpf-instrument) bury release tags under
    # many commit/nightly tags on earlier pages.
    while [ -n "$next_url" ] && [ "$page" -le "$max_pages" ]; do
        if ! response=$(curl -sS "$next_url"); then
            log "ERROR" "Failed to fetch tags from Docker Hub for $registry"
            return 1
        fi

        if ! echo "$response" | jq empty 2>/dev/null; then
            log "ERROR" "Invalid JSON response from Docker Hub for $registry. API may be rate-limited or changed."
            log "DEBUG" "Response preview: $(echo "$response" | head -c 200)..."
            return 1
        fi

        versions=$(_extract_latest_docker_semver_tag "$response")
        if [ -n "$versions" ]; then
            echo "$versions"
            return 0
        fi

        next_url=$(echo "$response" | jq -r '.next // empty' 2>/dev/null || echo "")
        page=$((page + 1))
    done

    # Targeted search when release tags never appear in the first pages.
    for name_filter in v 0 1 2 3 4 5 6 7 8 9; do
        local filter_url="https://registry.hub.docker.com/v2/repositories/${registry}/tags?page_size=100&name=${name_filter}"
        if ! response=$(curl -sS "$filter_url"); then
            continue
        fi
        if ! echo "$response" | jq empty 2>/dev/null; then
            continue
        fi
        versions=$(_extract_latest_docker_semver_tag "$response")
        if [ -n "$versions" ]; then
            echo "$versions"
            return 0
        fi
    done

    log "ERROR" "No stable semantic-version tags found for $registry"
    return 1
}

# Return the latest official non-draft, non-prerelease OpenEMR release.
# Docker Hub can contain clean semantic tags before an upstream release is
# declared production-ready, so it is not authoritative for this decision.
get_latest_openemr_release_version() {
    local url="https://api.github.com/repos/openemr/openemr/releases/latest"
    local response
    if ! response=$(curl -s "$url"); then
        log "ERROR" "Failed to fetch the latest OpenEMR release"
        return 1
    fi
    if ! echo "$response" | jq empty 2>/dev/null; then
        log "ERROR" "Invalid JSON response from the OpenEMR releases API"
        return 1
    fi

    local release_tag
    release_tag=$(echo "$response" | jq -r \
        'select(.draft == false and .prerelease == false) | .tag_name // empty' 2>/dev/null)
    release_tag=$(echo "$release_tag" | sed -E 's/^[vV]//' | tr '_' '.')
    if [[ ! "$release_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "No stable semantic OpenEMR release found"
        return 1
    fi
    echo "$release_tag"
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
        "tempo")
            repo_url="https://grafana.github.io/helm-charts/index.yaml"
            ;;
        "tempo-distributed")
            repo_url="https://grafana-community.github.io/helm-charts/index.yaml"
            ;;
        "mimir-distributed")
            repo_url="https://grafana.github.io/helm-charts/index.yaml"
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
    local index_content
    if ! index_content=$(curl -s "$repo_url") || [ -z "$index_content" ]; then
        log "ERROR" "Failed to fetch repository index for $chart"
        echo "❌ Error"
        return 1
    fi
    
    # Parse all chart entries, exclude prereleases (for example Mimir weekly
    # builds), and select the highest stable semantic version deterministically.
    local version
    version=$(printf '%s' "$index_content" \
        | yq eval -r ".entries[\"${chart}\"][].version" - 2>/dev/null \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -1) || version=""
    
    # Validate that version was successfully extracted
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        log "ERROR" "Failed to parse version for $chart"
        return 1
    fi

    # cert-manager is installed from its GitHub release manifest, whose tag
    # includes a leading "v", rather than from the Helm chart directly.
    if [ "$chart" = "cert-manager" ]; then
        version="v${version#v}"
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
    local latest_version
    if ! latest_version=$(aws eks describe-addon-versions \
        --addon-name "$addon_name" \
        --kubernetes-version "$cluster_version" \
        --query 'addons[0].addonVersions[0].addonVersion' \
        --output text 2>/dev/null) || [ -z "$latest_version" ] || [ "$latest_version" = "None" ]; then
        log "INFO" "Trying to get latest version for $addon_name without cluster version filter"
        if ! latest_version=$(aws eks describe-addon-versions \
            --addon-name "$addon_name" \
            --query 'addons[0].addonVersions[0].addonVersion' \
            --output text 2>/dev/null) || [ -z "$latest_version" ] || [ "$latest_version" = "None" ]; then
            log "INFO" "Trying to get any available version for $addon_name"
            if ! latest_version=$(aws eks describe-addon-versions \
                --addon-name "$addon_name" \
                --query 'addons[0].addonVersions[-1].addonVersion' \
                --output text 2>/dev/null) || [ -z "$latest_version" ] || [ "$latest_version" = "None" ]; then
                log "WARN" "Failed to fetch EKS add-on version for $addon_name"
                echo "❌ Error"
                return 1
            fi
        fi
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
        # shellcheck disable=SC2016
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
get_latest_terraform_provider_version() {
    local provider_source="$1"
    local url="https://registry.terraform.io/v1/providers/${provider_source}"
    local response
    local version

    log "INFO" "Checking latest version for Terraform provider: $provider_source..."
    if ! response=$(curl --fail --silent --show-error --location "$url" 2>/dev/null) ||
        ! echo "$response" | jq empty 2>/dev/null; then
        log "ERROR" "Could not fetch Terraform provider metadata for $provider_source"
        return 1
    fi

    version=$(echo "$response" | jq -r '.version // empty' 2>/dev/null)
    if [ -z "$version" ]; then
        log "ERROR" "Could not determine latest version for Terraform provider $provider_source"
        return 1
    fi

    echo "$version"
}

get_latest_terraform_module_version() {
    local module_source="$1"  # Module source (e.g., "terraform-aws-modules/vpc/aws")

    log "INFO" "Checking latest version for Terraform module: $module_source..."

    # Use Terraform registry API instead of GitHub
    # The Terraform registry provides a standardized API for module information
    local url="https://registry.terraform.io/v1/modules/${module_source}"

    # Fetch module information from the Terraform registry
    local response=$(curl -s "$url" 2>/dev/null || echo "")

    # Check if the API call was successful and response is valid JSON
    if [ -z "$response" ] || ! echo "$response" | jq empty 2>/dev/null; then
        log "WARN" "Could not fetch or parse module information from Terraform registry"
        echo "❌ Error"
        return 1
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
    local tags_url="https://api.github.com/repos/${action_name}/tags?per_page=100"
    local response
    local version

    log "INFO" "Checking latest version for GitHub Action: $action_name..."

    if ! response=$(curl --fail --silent --show-error --location "$tags_url" 2>/dev/null) ||
        ! echo "$response" | jq empty 2>/dev/null; then
        log "ERROR" "Failed to fetch or parse GitHub tags for $action_name"
        return 1
    fi

    version=$(echo "$response" | jq -r '.[].name' 2>/dev/null |
        grep -E '^v?[0-9]+(\.[0-9]+){0,2}$' |
        sort -V |
        tail -1 || true)
    if [ -z "$version" ]; then
        log "ERROR" "No stable semantic-version tags found for $action_name"
        return 1
    fi

    echo "$version"
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

# Function to get the latest Go package version from GitHub
# This function retrieves the latest version of a Go package from GitHub
get_latest_go_package_version() {
    local package_repo="$1"  # GitHub repository (e.g., "charmbracelet/bubbletea" or "github.com/charmbracelet/bubbletea")

    # Normalize repository path - remove github.com/ prefix if present
    local repo_path="$package_repo"
    if [[ "$package_repo" == github.com/* ]]; then
        repo_path="${package_repo#github.com/}"
    fi

    log "INFO" "Checking latest version for Go package: $repo_path..."

    # Use GitHub API to get latest release
    local url="https://api.github.com/repos/${repo_path}/releases/latest"

    # Fetch the latest release information from GitHub API
    local response=$(curl -s "$url" 2>/dev/null || echo "")

    # Check if the API call was successful and response is valid JSON
    if [ -z "$response" ] || ! echo "$response" | jq empty 2>/dev/null; then
        log "WARN" "Failed to fetch or parse GitHub API response for $repo_path, trying tags..."
        # Try tags as fallback
        local tags_url="https://api.github.com/repos/${repo_path}/tags"
        local tags_response=$(curl -s "$tags_url" 2>/dev/null || echo "")
        
        if [ -n "$tags_response" ] && [ "$tags_response" != "[]" ]; then
            # Get the first tag (latest)
            local latest_tag=$(echo "$tags_response" | jq -r '.[0].name' 2>/dev/null || echo "")
            if [ -n "$latest_tag" ] && [ "$latest_tag" != "null" ]; then
                log "INFO" "Latest version for $repo_path (from tags): $latest_tag"
                echo "$latest_tag"
                return 0
            fi
        fi
        echo "❌ Error"
        return 1
    fi

    # Check for GitHub API error messages
    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        log "WARN" "GitHub API error for $repo_path: $(echo "$response" | jq -r '.message'), trying tags..."
        # Try tags as fallback
        local tags_url="https://api.github.com/repos/${repo_path}/tags"
        local tags_response=$(curl -s "$tags_url" 2>/dev/null || echo "")
        
        if [ -n "$tags_response" ] && [ "$tags_response" != "[]" ]; then
            local latest_tag=$(echo "$tags_response" | jq -r '.[0].name' 2>/dev/null || echo "")
            if [ -n "$latest_tag" ] && [ "$latest_tag" != "null" ]; then
                log "INFO" "Latest version for $repo_path (from tags): $latest_tag"
                echo "$latest_tag"
                return 0
            fi
        fi
        echo "❌ Error"
        return 1
    fi

    # Extract tag name (version) from the release information
    local version=$(echo "$response" | jq -r '.tag_name' 2>/dev/null || echo "")
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        log "WARN" "Could not determine latest version for $repo_path"
        echo "❌ Unable to determine"
        return 1
    fi

    log "INFO" "Latest version for $repo_path: $version"
    echo "$version"
}

# Function to get the latest Go version
# This function retrieves the latest Go version from the official Go repository
get_latest_go_version() {
    log "INFO" "Checking latest Go version..."
    local response
    local version

    if ! response=$(curl --fail --silent --show-error --location \
        "https://go.dev/dl/?mode=json" 2>/dev/null) ||
        ! echo "$response" | jq empty 2>/dev/null; then
        log "ERROR" "Failed to fetch the official Go release feed"
        return 1
    fi

    version=$(echo "$response" |
        jq -r '[.[] | select(.stable == true) | .version][0] // empty' |
        sed 's/^go//')
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "Could not determine the latest stable Go patch release"
        return 1
    fi

    log "INFO" "Latest Go version: $version"
    echo "$version"
}

# Function to get the latest semver package version
# This function retrieves the latest version of a package that follows semantic versioning
get_latest_semver_version() {
    local package_name="$1"  # Package name (e.g., "semver")

    log "INFO" "Checking latest version for semver package: $package_name..."

    # Handle different package types with their specific version sources
    case "$package_name" in
        "python_version")
            # CPython publishes tags (not always a matching GitHub Release). Paginate
            # and sort so patch bumps like 3.14.7 are not missed when newer RC tags
            # appear first in the API response.
            local response
            response="$(curl -sS "https://api.github.com/repos/python/cpython/tags?per_page=100" 2>/dev/null || echo "")"
            if [ -z "$response" ] || [ "$response" = "[]" ]; then
                echo "❌ Error"
                return 1
            fi
            local latest_version
            latest_version="$(echo "$response" | jq -r '.[] | select(.name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | .name' 2>/dev/null \
                | sed 's/^v//' | sort -V | tail -1 || echo "")"
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

# Capture a lookup without allowing API failures to masquerade as "up to date".
# Bash's dynamic scoping lets this helper update check_updates()'s local counters.
run_version_lookup() {
    local result_variable="$1"
    local component_name="$2"
    local current_version="$3"
    shift 3

    local latest_version
    if latest_version=$("$@") && [ -n "$latest_version" ] &&
        [[ "$latest_version" != "❌"* ]]; then
        printf -v "$result_variable" '%s' "$latest_version"
        return 0
    fi

    printf -v "$result_variable" '%s' "$current_version"
    checks_failed=$((checks_failed + 1))
    log "ERROR" "Version lookup failed for $component_name"
    echo "- **${component_name}**: ❌ Version check incomplete" >> "$update_report"
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
    local checks_failed=0
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
        local openemr_latest
        run_version_lookup openemr_latest "OpenEMR" "$OPENEMR_CURRENT" \
            get_latest_openemr_release_version
        if [ -n "$openemr_latest" ] && [ "$openemr_latest" != "$OPENEMR_CURRENT" ]; then
            log "INFO" "OpenEMR update available: $OPENEMR_CURRENT -> $openemr_latest"
            echo "- **OpenEMR**: $OPENEMR_CURRENT → $openemr_latest" >> "$update_report"
            search_version_in_codebase "OpenEMR" "$OPENEMR_CURRENT" "$openemr_latest"
            updates_found=1
        else
            log "INFO" "OpenEMR is up to date: $OPENEMR_CURRENT"
        fi

        # Check Fluent Bit version
        log "INFO" "Checking Fluent Bit version..."
        local fluent_bit_latest
        run_version_lookup fluent_bit_latest "Fluent Bit" "$FLUENT_BIT_CURRENT" \
            get_latest_docker_version "$FLUENT_BIT_REGISTRY"
        if [ -n "$fluent_bit_latest" ] && [ "$fluent_bit_latest" != "$FLUENT_BIT_CURRENT" ]; then
            log "INFO" "Fluent Bit update available: $FLUENT_BIT_CURRENT -> $fluent_bit_latest"
            echo "- **Fluent Bit**: $FLUENT_BIT_CURRENT → $fluent_bit_latest" >> "$update_report"
            search_version_in_codebase "Fluent Bit" "$FLUENT_BIT_CURRENT" "$fluent_bit_latest"
            updates_found=1
        else
            log "INFO" "Fluent Bit is up to date: $FLUENT_BIT_CURRENT"
        fi

        # Check Python Docker image version
        PYTHON_CURRENT=$(yq eval '.applications.python.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        PYTHON_REGISTRY=$(yq eval '.applications.python.registry' "$VERSIONS_FILE" 2>/dev/null || echo "library/python")
        PYTHON_AUTO_DETECT=$(yq eval '.applications.python.auto_detect_latest' "$VERSIONS_FILE" 2>/dev/null || echo "false")
        
        if [ -n "$PYTHON_CURRENT" ] && [ "$PYTHON_AUTO_DETECT" = "true" ]; then
            log "INFO" "Checking Python Docker image version (auto-detect enabled)..."
            # Get latest Python 3.xx version from Docker Hub
            local python_tags_url="https://registry.hub.docker.com/v2/repositories/${PYTHON_REGISTRY}/tags?page_size=100&name=3."
            local python_response=$(curl -s "$python_tags_url" 2>/dev/null || echo "")
            
            if [ -n "$python_response" ] && echo "$python_response" | jq empty 2>/dev/null; then
                # Extract latest 3.xx version (excluding RC/beta)
                local python_latest=$(echo "$python_response" | jq -r '.results[].name' 2>/dev/null | \
                    grep -E "^3\.[0-9]+(-slim)?$" | \
                    sed 's/-slim$//' | \
                    sort -V -r | \
                    head -1 || echo "")
                
                if [ -z "$python_latest" ]; then
                    checks_failed=$((checks_failed + 1))
                    log "ERROR" "Could not determine the latest stable Python Docker image"
                    echo "- **Python Docker Image**: ❌ Version check incomplete" >> "$update_report"
                elif [ "$python_latest" != "$PYTHON_CURRENT" ]; then
                    log "INFO" "Python Docker image update available: $PYTHON_CURRENT -> $python_latest"
                    echo "- **Python Docker Image**: $PYTHON_CURRENT → $python_latest (latest 3.xx)" >> "$update_report"
                    search_version_in_codebase "Python Docker Image" "$PYTHON_CURRENT" "$python_latest"
                    updates_found=1
                else
                    log "INFO" "Python Docker image is up to date: $PYTHON_CURRENT"
                fi
            else
                checks_failed=$((checks_failed + 1))
                log "ERROR" "Could not fetch Python Docker image tags"
                echo "- **Python Docker Image**: ❌ Version check incomplete" >> "$update_report"
            fi
        fi

        # Check Floci Docker image version
        FLOCI_CURRENT=$(yq eval '.applications.floci.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        FLOCI_REGISTRY=$(yq eval '.applications.floci.registry' "$VERSIONS_FILE" 2>/dev/null || echo "floci/floci")
        if [ -n "$FLOCI_CURRENT" ]; then
            log "INFO" "Checking Floci version..."
            local floci_latest
            run_version_lookup floci_latest "Floci" "$FLOCI_CURRENT" \
                get_latest_docker_version "$FLOCI_REGISTRY"
            if [ -n "$floci_latest" ] && [ "$floci_latest" != "$FLOCI_CURRENT" ]; then
                log "INFO" "Floci update available: $FLOCI_CURRENT -> $floci_latest"
                echo "- **Floci**: $FLOCI_CURRENT → $floci_latest" >> "$update_report"
                search_version_in_codebase "Floci" "$FLOCI_CURRENT" "$floci_latest"
                updates_found=1
            else
                log "INFO" "Floci is up to date: $FLOCI_CURRENT"
            fi
        fi
    fi

    # Check infrastructure if requested
    if [ "$components" = "all" ] || [ "$components" = "infrastructure" ]; then
        # Check Kubernetes version
        log "INFO" "Checking Kubernetes version..."
        local k8s_latest
        run_version_lookup k8s_latest "Kubernetes" "$K8S_CURRENT" \
            get_latest_k8s_version
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
        local eks_latest
        run_version_lookup eks_latest "EKS" "$eks_current" get_latest_k8s_version
        
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

        # Check Aurora MySQL engine version.
        local aurora_current
        local aurora_latest
        aurora_current=$(yq eval '.databases.aurora_mysql.current' "$VERSIONS_FILE")
        run_version_lookup aurora_latest "Aurora MySQL" "$aurora_current" \
            get_latest_aurora_version
        if [ "$aurora_latest" != "$aurora_current" ]; then
            log "INFO" "Aurora MySQL update available: $aurora_current -> $aurora_latest"
            echo "- **Aurora MySQL**: $aurora_current → $aurora_latest" >> "$update_report"
            search_version_in_codebase "Aurora MySQL" "$aurora_current" "$aurora_latest"
            updates_found=1
        fi
    fi

    # Check Terraform modules if requested
    if [ "$components" = "all" ] || [ "$components" = "terraform_modules" ]; then
        log "INFO" "Checking Terraform modules..."

        # Check directly required Terraform providers.
        local provider_key
        while IFS= read -r provider_key; do
            local provider_current
            local provider_source
            local provider_latest
            provider_current=$(yq eval ".terraform_modules.${provider_key}.current" "$VERSIONS_FILE")
            provider_source=$(yq eval ".terraform_modules.${provider_key}.source" "$VERSIONS_FILE")
            run_version_lookup provider_latest "$provider_source provider" "$provider_current" \
                get_latest_terraform_provider_version "$provider_source"
            if [ "$provider_latest" != "$provider_current" ]; then
                log "INFO" "$provider_source provider update available: $provider_current -> $provider_latest"
                echo "- **${provider_source} provider**: $provider_current → $provider_latest" >> "$update_report"
                search_version_in_codebase "$provider_source provider" "$provider_current" "$provider_latest"
                updates_found=1
            fi
        done < <(
            yq eval -r \
                '.terraform_modules | to_entries | .[] | select(.value.kind == "provider") | .key' \
                "$VERSIONS_FILE"
        )

        # Check EKS module
        local eks_module_current=$(yq eval '.terraform_modules.aws_eks.current' "$VERSIONS_FILE")
        local eks_module_source=$(yq eval '.terraform_modules.aws_eks.source' "$VERSIONS_FILE")
        local eks_module_latest
        run_version_lookup eks_module_latest "EKS Terraform module" "$eks_module_current" \
            get_latest_terraform_module_version "$eks_module_source"

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
        local vpc_module_latest
        run_version_lookup vpc_module_latest "VPC Terraform module" "$vpc_module_current" \
            get_latest_terraform_module_version "$vpc_module_source"

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
        local pod_identity_module_latest
        run_version_lookup pod_identity_module_latest "EKS Pod Identity module" \
            "$pod_identity_module_current" \
            get_latest_terraform_module_version "$pod_identity_module_source"

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

        # Drive action checks from versions.yaml so every tracked action is covered.
        local action_key
        while IFS= read -r action_key; do
            local action_current
            local action_repo
            local action_latest
            action_current=$(yq eval ".github_workflows.${action_key}.current" "$VERSIONS_FILE")
            action_repo=$(yq eval ".github_workflows.${action_key}.repository" "$VERSIONS_FILE")
            run_version_lookup action_latest "$action_repo" "$action_current" \
                get_latest_github_action_version "$action_repo"

            if ! compare_versions "$action_current" "$action_latest"; then
                log "INFO" "$action_repo update available: $action_current -> $action_latest"
                echo "- **${action_repo}**: $action_current → $action_latest" >> "$update_report"
                search_version_in_codebase "$action_repo" "$action_current" "$action_latest"
                updates_found=1
            fi
        done < <(
            yq eval -r \
                '.github_workflows | to_entries | .[] | select(.value.repository != null) | .key' \
                "$VERSIONS_FILE"
        )

        # Check GitHub runner
        local runner_current=$(yq eval '.github_workflows.github_runner.current' "$VERSIONS_FILE")
        local runner_latest
        run_version_lookup runner_latest "GitHub runner" "$runner_current" \
            get_latest_github_runner_version

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
        local pre_commit_latest
        run_version_lookup pre_commit_latest "pre-commit-hooks" "$pre_commit_current" \
            get_latest_pre_commit_hook_version "pre_commit_hooks"

        if [ "$pre_commit_latest" != "❌ Error" ] && [ "$pre_commit_latest" != "$pre_commit_current" ]; then
            log "INFO" "pre-commit-hooks update available: $pre_commit_current -> $pre_commit_latest"
            echo "- **pre-commit-hooks**: $pre_commit_current → $pre_commit_latest" >> "$update_report"
            search_version_in_codebase "pre-commit-hooks" "$pre_commit_current" "$pre_commit_latest"
            updates_found=1
        fi

        # Check black
        local black_current=$(yq eval '.pre_commit_hooks.black.current' "$VERSIONS_FILE")
        local black_latest
        run_version_lookup black_latest "Black pre-commit hook" "$black_current" \
            get_latest_pre_commit_hook_version "black"

        if [ "$black_latest" != "❌ Error" ] && [ "$black_latest" != "$black_current" ]; then
            log "INFO" "black update available: $black_current -> $black_latest"
            echo "- **black**: $black_current → $black_latest" >> "$update_report"
            search_version_in_codebase "black" "$black_current" "$black_latest"
            updates_found=1
        fi

        # Check isort
        local isort_current=$(yq eval '.pre_commit_hooks.isort.current' "$VERSIONS_FILE")
        local isort_latest
        run_version_lookup isort_latest "isort pre-commit hook" "$isort_current" \
            get_latest_pre_commit_hook_version "isort"

        if [ "$isort_latest" != "❌ Error" ] && [ "$isort_latest" != "$isort_current" ]; then
            log "INFO" "isort update available: $isort_current -> $isort_latest"
            echo "- **isort**: $isort_current → $isort_latest" >> "$update_report"
            updates_found=1
        fi

        # Check flake8
        local flake8_current=$(yq eval '.pre_commit_hooks.flake8.current' "$VERSIONS_FILE")
        local flake8_latest
        run_version_lookup flake8_latest "Flake8 pre-commit hook" "$flake8_current" \
            get_latest_pre_commit_hook_version "flake8"

        if [ "$flake8_latest" != "❌ Error" ] && [ "$flake8_latest" != "$flake8_current" ]; then
            log "INFO" "flake8 update available: $flake8_current -> $flake8_latest"
            echo "- **flake8**: $flake8_current → $flake8_latest" >> "$update_report"
            updates_found=1
        fi

        # Check bandit
        local bandit_current=$(yq eval '.pre_commit_hooks.bandit.current' "$VERSIONS_FILE")
        local bandit_latest
        run_version_lookup bandit_latest "Bandit pre-commit hook" "$bandit_current" \
            get_latest_pre_commit_hook_version "bandit"

        if [ "$bandit_latest" != "❌ Error" ] && [ "$bandit_latest" != "$bandit_current" ]; then
            log "INFO" "bandit update available: $bandit_current -> $bandit_latest"
            echo "- **bandit**: $bandit_current → $bandit_latest" >> "$update_report"
            updates_found=1
        fi

        # Check terraform hooks
        local terraform_hooks_current=$(yq eval '.pre_commit_hooks.terraform_hooks.current' "$VERSIONS_FILE")
        local terraform_hooks_latest
        run_version_lookup terraform_hooks_latest "Terraform pre-commit hooks" \
            "$terraform_hooks_current" get_latest_pre_commit_hook_version "terraform_hooks"

        if [ "$terraform_hooks_latest" != "❌ Error" ] && [ "$terraform_hooks_latest" != "$terraform_hooks_current" ]; then
            log "INFO" "terraform hooks update available: $terraform_hooks_current -> $terraform_hooks_latest"
            echo "- **terraform hooks**: $terraform_hooks_current → $terraform_hooks_latest" >> "$update_report"
            updates_found=1
        fi

        # Check shellcheck
        local shellcheck_current=$(yq eval '.pre_commit_hooks.shellcheck.current' "$VERSIONS_FILE")
        local shellcheck_latest
        run_version_lookup shellcheck_latest "ShellCheck pre-commit hook" "$shellcheck_current" \
            get_latest_pre_commit_hook_version "shellcheck"

        if [ "$shellcheck_latest" != "❌ Error" ] && [ "$shellcheck_latest" != "$shellcheck_current" ]; then
            log "INFO" "shellcheck update available: $shellcheck_current -> $shellcheck_latest"
            echo "- **shellcheck**: $shellcheck_current → $shellcheck_latest" >> "$update_report"
            updates_found=1
        fi

        # Check markdownlint
        local markdownlint_current=$(yq eval '.pre_commit_hooks.markdownlint.current' "$VERSIONS_FILE")
        local markdownlint_latest
        run_version_lookup markdownlint_latest "markdownlint pre-commit hook" \
            "$markdownlint_current" get_latest_pre_commit_hook_version "markdownlint"

        if [ "$markdownlint_latest" != "❌ Error" ] && [ "$markdownlint_latest" != "$markdownlint_current" ]; then
            log "INFO" "markdownlint update available: $markdownlint_current -> $markdownlint_latest"
            echo "- **markdownlint**: $markdownlint_current → $markdownlint_latest" >> "$update_report"
            updates_found=1
        fi

        # Check yamllint
        local yamllint_current=$(yq eval '.pre_commit_hooks.yamllint.current' "$VERSIONS_FILE")
        local yamllint_latest
        run_version_lookup yamllint_latest "yamllint pre-commit hook" "$yamllint_current" \
            get_latest_pre_commit_hook_version "yamllint"

        if [ "$yamllint_latest" != "❌ Error" ] && [ "$yamllint_latest" != "$yamllint_current" ]; then
            log "INFO" "yamllint update available: $yamllint_current -> $yamllint_latest"
            echo "- **yamllint**: $yamllint_current → $yamllint_latest" >> "$update_report"
            updates_found=1
        fi

        # Check commitizen
        local commitizen_current=$(yq eval '.pre_commit_hooks.commitizen.current' "$VERSIONS_FILE")
        local commitizen_latest
        run_version_lookup commitizen_latest "Commitizen pre-commit hook" "$commitizen_current" \
            get_latest_pre_commit_hook_version "commitizen"

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
        local python_latest
        run_version_lookup python_latest "Python runtime" "$python_current" \
            get_latest_semver_version "python_version"

        if [ "$python_latest" != "❌ Error" ] && [ "$python_latest" != "$python_current" ]; then
            log "INFO" "Python version update available: $python_current -> $python_latest"
            echo "- **Python**: $python_current → $python_latest" >> "$update_report"
            search_version_in_codebase "Python" "$python_current" "$python_latest"
            updates_found=1
        fi

        # Check Terraform version
        local terraform_current=$(yq eval '.semver_packages.terraform_version.current' "$VERSIONS_FILE")
        local terraform_latest
        run_version_lookup terraform_latest "Terraform CLI" "$terraform_current" \
            get_latest_semver_version "terraform_version"

        if [ "$terraform_latest" != "❌ Error" ] && [ "$terraform_latest" != "$terraform_current" ]; then
            log "INFO" "Terraform version update available: $terraform_current -> $terraform_latest"
            echo "- **Terraform**: $terraform_current → $terraform_latest" >> "$update_report"
            search_version_in_codebase "Terraform" "$terraform_current" "$terraform_latest"
            updates_found=1
        fi

        # Check kubectl version
        local kubectl_current=$(yq eval '.semver_packages.kubectl_version.current' "$VERSIONS_FILE")
        local kubectl_latest
        run_version_lookup kubectl_latest "kubectl" "$kubectl_current" \
            get_latest_semver_version "kubectl_version"

        if [ "$kubectl_latest" != "❌ Error" ] && [ "$kubectl_latest" != "$kubectl_current" ]; then
            log "INFO" "kubectl version update available: $kubectl_current -> $kubectl_latest"
            echo "- **kubectl**: $kubectl_current → $kubectl_latest" >> "$update_report"
            search_version_in_codebase "kubectl" "$kubectl_current" "$kubectl_latest"
            updates_found=1
        fi

        # Check semver package version
        local semver_current=$(yq eval '.semver_packages.semver.current' "$VERSIONS_FILE")
        local semver_latest
        run_version_lookup semver_latest "Node semver package" "$semver_current" \
            get_latest_semver_version "semver"

        if [ "$semver_latest" != "❌ Error" ] && [ "$semver_latest" != "$semver_current" ]; then
            log "INFO" "semver package update available: $semver_current -> $semver_latest"
            echo "- **semver**: $semver_current → $semver_latest" >> "$update_report"
            updates_found=1
        fi
    fi

    # Check Go packages if requested
    if [ "$components" = "all" ] || [ "$components" = "go_packages" ]; then
        log "INFO" "Checking Go package versions..."

        # Check Go version
        local go_current=$(yq eval '.go_packages.go_version.current' "$VERSIONS_FILE")
        local go_latest
        run_version_lookup go_latest "Go toolchain" "$go_current" get_latest_go_version

        if [ "$go_latest" != "❌ Error" ] && [ "$go_latest" != "❌ Unable to determine" ] && [ "$go_latest" != "$go_current" ]; then
            log "INFO" "Go version update available: $go_current -> $go_latest"
            echo "- **Go**: $go_current → $go_latest" >> "$update_report"
            search_version_in_codebase "Go" "$go_current" "$go_latest"
            updates_found=1
        fi

        # Check bubbletea version
        local bubbletea_current=$(yq eval '.go_packages.bubbletea.current' "$VERSIONS_FILE")
        local bubbletea_repo=$(yq eval '.go_packages.bubbletea.repository' "$VERSIONS_FILE" 2>/dev/null || echo "charmbracelet/bubbletea")
        # Normalize repository path - remove github.com/ prefix if present
        if [[ "$bubbletea_repo" == github.com/* ]]; then
            bubbletea_repo="${bubbletea_repo#github.com/}"
        fi
        local bubbletea_latest
        run_version_lookup bubbletea_latest "Bubble Tea" "$bubbletea_current" \
            get_latest_go_package_version "$bubbletea_repo"

        if [ "$bubbletea_latest" != "❌ Error" ] && [ "$bubbletea_latest" != "❌ Unable to determine" ] && [ "$bubbletea_latest" != "$bubbletea_current" ]; then
            log "INFO" "bubbletea update available: $bubbletea_current -> $bubbletea_latest"
            echo "- **bubbletea**: $bubbletea_current → $bubbletea_latest" >> "$update_report"
            search_version_in_codebase "bubbletea" "$bubbletea_current" "$bubbletea_latest"
            updates_found=1
        fi

        # Check lipgloss version
        local lipgloss_current=$(yq eval '.go_packages.lipgloss.current' "$VERSIONS_FILE")
        local lipgloss_repo=$(yq eval '.go_packages.lipgloss.repository' "$VERSIONS_FILE" 2>/dev/null || echo "charmbracelet/lipgloss")
        # Normalize repository path - remove github.com/ prefix if present
        if [[ "$lipgloss_repo" == github.com/* ]]; then
            lipgloss_repo="${lipgloss_repo#github.com/}"
        fi
        local lipgloss_latest
        run_version_lookup lipgloss_latest "Lip Gloss" "$lipgloss_current" \
            get_latest_go_package_version "$lipgloss_repo"

        if [ "$lipgloss_latest" != "❌ Error" ] && [ "$lipgloss_latest" != "❌ Unable to determine" ] && [ "$lipgloss_latest" != "$lipgloss_current" ]; then
            log "INFO" "lipgloss update available: $lipgloss_current -> $lipgloss_latest"
            echo "- **lipgloss**: $lipgloss_current → $lipgloss_latest" >> "$update_report"
            search_version_in_codebase "lipgloss" "$lipgloss_current" "$lipgloss_latest"
            updates_found=1
        fi
    fi

    # Check monitoring stack versions if requested
    if [ "$components" = "all" ] || [ "$components" = "monitoring" ]; then
        log "INFO" "Checking monitoring stack versions..."

        # Prometheus Operator
        local prometheus_latest
        run_version_lookup prometheus_latest "Prometheus Operator" "$PROMETHEUS_CURRENT" \
            get_latest_helm_version "kube-prometheus-stack"
        if [ -n "$prometheus_latest" ] && [ "$prometheus_latest" != "$PROMETHEUS_CURRENT" ]; then
            log "INFO" "Prometheus Operator update available: $PROMETHEUS_CURRENT -> $prometheus_latest"
            echo "- **Prometheus Operator**: $PROMETHEUS_CURRENT → $prometheus_latest" >> "$update_report"
            search_version_in_codebase "Prometheus Operator" "$PROMETHEUS_CURRENT" "$prometheus_latest"
            updates_found=1
        fi

        # Loki's original chart repository is now the Grafana Enterprise Logs
        # maintenance track. OSS migration to grafana-community spans breaking
        # chart releases and must be reviewed as a dedicated change.
        local loki_update_policy
        loki_update_policy=$(yq eval '.monitoring.loki.update_policy // "automatic"' "$VERSIONS_FILE")
        if [ "$loki_update_policy" = "manual-migration" ]; then
            log "WARN" "Skipping automatic Loki comparison; OSS chart migration requires manual review"
        else
            local loki_latest
            run_version_lookup loki_latest "Loki" "$LOKI_CURRENT" \
                get_latest_helm_version "loki"
            if [ -n "$loki_latest" ] && [ "$loki_latest" != "$LOKI_CURRENT" ]; then
                log "INFO" "Loki update available: $LOKI_CURRENT -> $loki_latest"
                echo "- **Loki**: $LOKI_CURRENT → $loki_latest" >> "$update_report"
                search_version_in_codebase "Loki" "$LOKI_CURRENT" "$loki_latest"
                updates_found=1
            fi
        fi

        # Tempo chart 3.x replaces ingesters/compactors with a Kafka-backed
        # architecture, so it cannot be treated as a drop-in chart update.
        local tempo_update_policy
        tempo_update_policy=$(yq eval '.monitoring.tempo.update_policy // "automatic"' "$VERSIONS_FILE")
        if [ "$tempo_update_policy" = "manual-migration" ]; then
            log "WARN" "Skipping automatic Tempo comparison; chart 3.x requires an architecture migration"
        else
            local tempo_latest
            run_version_lookup tempo_latest "Tempo" "$TEMPO_CURRENT" \
                get_latest_helm_version "tempo-distributed"
            if [ -n "$tempo_latest" ] && [ "$tempo_latest" != "$TEMPO_CURRENT" ]; then
                log "INFO" "Tempo update available: $TEMPO_CURRENT -> $tempo_latest"
                echo "- **Tempo**: $TEMPO_CURRENT → $tempo_latest" >> "$update_report"
                search_version_in_codebase "Tempo" "$TEMPO_CURRENT" "$tempo_latest"
                updates_found=1
            fi
        fi

        # Mimir
        local mimir_latest
        run_version_lookup mimir_latest "Mimir" "$MIMIR_CURRENT" \
            get_latest_helm_version "mimir-distributed"
        if [ -n "$mimir_latest" ] && [ "$mimir_latest" != "$MIMIR_CURRENT" ]; then
            log "INFO" "Mimir update available: $MIMIR_CURRENT -> $mimir_latest"
            echo "- **Mimir**: $MIMIR_CURRENT → $mimir_latest" >> "$update_report"
            search_version_in_codebase "Mimir" "$MIMIR_CURRENT" "$mimir_latest"
            updates_found=1
        fi

        # OTeBPF (check Docker image version since it's not a Helm chart)
        local otebpf_repo
        otebpf_repo=$(yq eval '.monitoring.otebpf.repository' "$VERSIONS_FILE" 2>/dev/null || echo "ghcr.io/open-telemetry/opentelemetry-ebpf-instrumentation")
        local otebpf_latest
        run_version_lookup otebpf_latest "OTeBPF" "$OTEBPF_CURRENT" \
            get_latest_docker_version "$otebpf_repo"
        if [ -n "$otebpf_latest" ] && [ "$otebpf_latest" != "$OTEBPF_CURRENT" ]; then
            log "INFO" "OTeBPF update available: $OTEBPF_CURRENT -> $otebpf_latest"
            echo "- **OTeBPF**: $OTEBPF_CURRENT → $otebpf_latest" >> "$update_report"
            search_version_in_codebase "OTeBPF" "$OTEBPF_CURRENT" "$otebpf_latest"
            updates_found=1
        fi



        # cert-manager
        local cert_manager_current
        cert_manager_current=$(yq eval '.monitoring.cert_manager.current' "$VERSIONS_FILE")
        local cert_manager_latest
        run_version_lookup cert_manager_latest "cert-manager" "$cert_manager_current" \
            get_latest_helm_version "cert-manager"
        if [ -n "$cert_manager_latest" ] && [ "$cert_manager_latest" != "$cert_manager_current" ]; then
            log "INFO" "cert-manager update available: $cert_manager_current -> $cert_manager_latest"
            echo "- **cert-manager**: $cert_manager_current → $cert_manager_latest" >> "$update_report"
            search_version_in_codebase "cert-manager" "$cert_manager_current" "$cert_manager_latest"
            updates_found=1
        fi
    fi

    # Check security tools versions if requested
    if [ "$components" = "all" ] || [ "$components" = "security_tools" ]; then
        log "INFO" "Checking security tools versions..."

        # Check Trivy version
        local trivy_current=$(yq eval '.security_tools.trivy.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        if [ -n "$trivy_current" ]; then
            local trivy_latest
            run_version_lookup trivy_latest "Trivy" "$trivy_current" \
                get_latest_go_package_version "aquasecurity/trivy"
            trivy_latest="${trivy_latest#v}"  # Remove 'v' prefix for comparison
            if [ "$trivy_latest" != "❌ Error" ] && [ "$trivy_latest" != "❌ Unable to determine" ] && [ "$trivy_latest" != "$trivy_current" ]; then
                log "INFO" "Trivy update available: $trivy_current -> $trivy_latest"
                echo "- **Trivy**: $trivy_current → $trivy_latest" >> "$update_report"
                search_version_in_codebase "Trivy" "$trivy_current" "$trivy_latest"
                updates_found=1
            fi
        fi

        # Check Checkov version (PyPI)
        local checkov_current=$(yq eval '.security_tools.checkov.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        if [ -n "$checkov_current" ]; then
            local checkov_url="https://pypi.org/pypi/checkov/json"
            local checkov_response
            checkov_response=$(curl -s "$checkov_url" 2>/dev/null || echo "")
            if [ -n "$checkov_response" ] && echo "$checkov_response" | jq empty 2>/dev/null; then
                local checkov_latest
                checkov_latest=$(echo "$checkov_response" | jq -r '.info.version // empty' 2>/dev/null)
                if [ -n "$checkov_latest" ] && [ "$checkov_latest" != "null" ] && [ "$checkov_latest" != "$checkov_current" ]; then
                    log "INFO" "Checkov update available: $checkov_current -> $checkov_latest"
                    echo "- **Checkov**: $checkov_current → $checkov_latest" >> "$update_report"
                    search_version_in_codebase "Checkov" "$checkov_current" "$checkov_latest"
                    updates_found=1
                fi
                if [ -z "$checkov_latest" ]; then
                    checks_failed=$((checks_failed + 1))
                    log "ERROR" "Could not determine latest Checkov version"
                    echo "- **Checkov**: ❌ Version check incomplete" >> "$update_report"
                fi
            else
                checks_failed=$((checks_failed + 1))
                log "ERROR" "Could not fetch Checkov package metadata"
                echo "- **Checkov**: ❌ Version check incomplete" >> "$update_report"
            fi
        fi

        # Check KICS version
        local kics_current=$(yq eval '.security_tools.kics.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        if [ -n "$kics_current" ]; then
            local kics_latest
            run_version_lookup kics_latest "KICS" "$kics_current" \
                get_latest_go_package_version "Checkmarx/kics-github-action"
            if [ "$kics_latest" != "❌ Error" ] && [ "$kics_latest" != "❌ Unable to determine" ] && [ "$kics_latest" != "$kics_current" ]; then
                log "INFO" "KICS update available: $kics_current -> $kics_latest"
                echo "- **KICS**: $kics_current → $kics_latest" >> "$update_report"
                search_version_in_codebase "KICS" "$kics_current" "$kics_latest"
                updates_found=1
            fi
        fi

        # Check gosec version
        local gosec_current=$(yq eval '.security_tools.gosec.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        if [ -n "$gosec_current" ]; then
            local gosec_latest
            run_version_lookup gosec_latest "gosec" "$gosec_current" \
                get_latest_go_package_version "securego/gosec"
            if [ "$gosec_latest" != "❌ Error" ] && [ "$gosec_latest" != "❌ Unable to determine" ] && [ "$gosec_latest" != "$gosec_current" ]; then
                log "INFO" "gosec update available: $gosec_current -> $gosec_latest"
                echo "- **gosec**: $gosec_current → $gosec_latest" >> "$update_report"
                search_version_in_codebase "gosec" "$gosec_current" "$gosec_latest"
                updates_found=1
            fi
        fi
    fi

    # Check Python package versions if requested
    if [ "$components" = "all" ] || [ "$components" = "python_packages" ]; then
        log "INFO" "Checking Python package versions..."

        local pypi_packages=(
            "pymysql:PyMySQL"
            "boto3:boto3"
            "requests:requests"
            "kubernetes:kubernetes"
            "pytest:pytest"
            "pytest_cov:pytest-cov"
            "ruff:ruff"
            "flake8:flake8"
            "black:black"
            "mypy:mypy"
            "fastmcp:fastmcp"
            "pyyaml:PyYAML"
            "uv:uv"
        )
        for entry in "${pypi_packages[@]}"; do
            local yaml_key="${entry%%:*}"
            local pypi_name="${entry##*:}"
            local pkg_current
            pkg_current=$(yq eval ".python_packages.${yaml_key}.current" "$VERSIONS_FILE" 2>/dev/null || echo "")
            if [ -z "$pkg_current" ] || [ "$pkg_current" = "null" ]; then
                continue
            fi
            local pypi_url="https://pypi.org/pypi/${pypi_name}/json"
            local pypi_response
            pypi_response=$(curl -s "$pypi_url" 2>/dev/null || echo "")
            if [ -n "$pypi_response" ] && echo "$pypi_response" | jq empty 2>/dev/null; then
                local pkg_latest
                pkg_latest=$(echo "$pypi_response" | jq -r '.info.version // empty' 2>/dev/null)
                if [ -n "$pkg_latest" ] && [ "$pkg_latest" != "null" ] && [ "$pkg_latest" != "$pkg_current" ]; then
                    log "INFO" "${pypi_name} update available: $pkg_current -> $pkg_latest"
                    echo "- **${pypi_name}**: $pkg_current → $pkg_latest" >> "$update_report"
                    search_version_in_codebase "$pypi_name" "$pkg_current" "$pkg_latest"
                    updates_found=1
                fi
                if [ -z "$pkg_latest" ]; then
                    checks_failed=$((checks_failed + 1))
                    log "ERROR" "Could not determine latest ${pypi_name} version"
                    echo "- **${pypi_name}**: ❌ Version check incomplete" >> "$update_report"
                fi
            else
                checks_failed=$((checks_failed + 1))
                log "ERROR" "Could not fetch ${pypi_name} package metadata"
                echo "- **${pypi_name}**: ❌ Version check incomplete" >> "$update_report"
            fi
        done
    fi

    # Check EKS add-ons versions if requested
    if [ "$components" = "all" ] || [ "$components" = "eks_addons" ]; then
        log "INFO" "Checking EKS add-ons versions..."
        
        # Get current EKS cluster version
        local eks_version=$(yq eval '.infrastructure.eks.current' "$VERSIONS_FILE")
        
        # Check EFS CSI Driver
        local efs_csi_current=$(yq eval '.eks_addons.efs_csi_driver.current' "$VERSIONS_FILE")
        local efs_csi_latest
        run_version_lookup efs_csi_latest "EFS CSI Driver" "$efs_csi_current" \
            get_latest_eks_addon_version "aws-efs-csi-driver" "$eks_version"
        
        if [ "$efs_csi_latest" != "❌ Error" ] && [ "$efs_csi_latest" != "$efs_csi_current" ]; then
            log "INFO" "EFS CSI Driver update available: $efs_csi_current -> $efs_csi_latest"
            echo "- **EFS CSI Driver**: $efs_csi_current → $efs_csi_latest" >> "$update_report"
            search_version_in_codebase "EFS CSI Driver" "$efs_csi_current" "$efs_csi_latest"
            updates_found=1
        fi
        
        # Check Metrics Server
        local metrics_server_current=$(yq eval '.eks_addons.metrics_server.current' "$VERSIONS_FILE")
        local metrics_server_latest
        run_version_lookup metrics_server_latest "Metrics Server" "$metrics_server_current" \
            get_latest_eks_addon_version "metrics-server" "$eks_version"
        
        if [ "$metrics_server_latest" != "❌ Error" ] && [ "$metrics_server_latest" != "$metrics_server_current" ]; then
            log "INFO" "Metrics Server update available: $metrics_server_current -> $metrics_server_latest"
            echo "- **Metrics Server**: $metrics_server_current → $metrics_server_latest" >> "$update_report"
            search_version_in_codebase "Metrics Server" "$metrics_server_current" "$metrics_server_latest"
            updates_found=1
        fi
    fi


    if [ "$checks_failed" -gt 0 ]; then
        log "ERROR" "$checks_failed component version check(s) did not complete"
        {
            echo ""
            echo "⚠️ **Incomplete:** $checks_failed component check(s) failed."
            echo "Review the log before concluding that dependencies are current."
        } >> "$update_report"
    elif [ "$updates_found" -eq 0 ]; then
        log "INFO" "All components are up to date!"
        echo "No updates available." >> "$update_report"
    else
        log "INFO" "Found one or more components with available updates"
    fi

    # Display report
    echo ""
    cat "$update_report"

    # Save report
    local report_file="$PROJECT_ROOT/version-update-report-$(date +%Y%m%d-%H%M%S).md"
    cp "$update_report" "$report_file"
    log "INFO" "Update report saved to: $report_file"

    [ "$checks_failed" -eq 0 ]
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
  --components TYPE       Check specific component types (all, applications, infrastructure, terraform_modules, github_workflows, pre_commit_hooks, semver_packages, go_packages, python_packages, monitoring, eks_addons, security_tools)
  --create-issue          Create GitHub issue for updates (used by CI/CD)
  --month <month>         Specify month for report title (used by CI/CD)
  --log-level LEVEL       Set log level (DEBUG, INFO, WARN, ERROR)

Component Types:
  applications            OpenEMR, Fluent Bit, Python, Floci
  infrastructure          Kubernetes, Terraform, AWS Provider
  terraform_modules       EKS, VPC, RDS modules
  github_workflows        GitHub Actions dependencies
  pre_commit_hooks        Pre-commit hook versions
  semver_packages         Python, Terraform, kubectl versions
  go_packages             Go version, bubbletea, lipgloss
  python_packages         Python runtime, testing, and knowledge MCP packages
  monitoring              Prometheus, AlertManager, Grafana Loki, Grafana Tempo, Grafana Mimir, OTeBPF
  eks_addons              EFS CSI Driver, Metrics Server
  security_tools          Trivy, Checkov, KICS, gosec

Examples:
  $0 check                                       # Check all components
  $0 check --components applications             # Check only applications
  $0 check --components terraform_modules        # Check only Terraform modules
  $0 check --components go_packages              # Check only Go packages
  $0 check --components eks_addons               # Check only EKS add-ons
  $0 check --components security_tools           # Check only security tools
  $0 check --create-issue --month "January 2025" # Create GitHub issue
  $0 status                                      # Show current status

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
    [ -n "${PYTHON_CURRENT:-}" ] && echo -e "  Python: ${GREEN}$PYTHON_CURRENT${NC}"
    [ -n "${FLOCI_CURRENT:-}" ] && echo -e "  Floci: ${GREEN}$FLOCI_CURRENT${NC}"
    echo ""
    echo -e "${BLUE}Infrastructure:${NC}"
    echo -e "  Kubernetes: ${GREEN}$K8S_CURRENT${NC}"
    echo -e "  Aurora MySQL: ${GREEN}$AURORA_CURRENT${NC}"
    echo ""
    
    # Show Go packages if available
    if yq eval '.go_packages' "$VERSIONS_FILE" >/dev/null 2>&1; then
        local go_version=$(yq eval '.go_packages.go_version.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local bubbletea_version=$(yq eval '.go_packages.bubbletea.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local lipgloss_version=$(yq eval '.go_packages.lipgloss.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        
        if [ -n "$go_version" ] || [ -n "$bubbletea_version" ] || [ -n "$lipgloss_version" ]; then
            echo -e "${BLUE}Go Packages:${NC}"
            [ -n "$go_version" ] && echo -e "  Go: ${GREEN}$go_version${NC}"
            [ -n "$bubbletea_version" ] && echo -e "  bubbletea: ${GREEN}$bubbletea_version${NC}"
            [ -n "$lipgloss_version" ] && echo -e "  lipgloss: ${GREEN}$lipgloss_version${NC}"
            echo ""
        fi
    fi
    
    # Show Python packages if available
    if yq eval '.python_packages' "$VERSIONS_FILE" >/dev/null 2>&1; then
        local pymysql_version=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local boto3_version=$(yq eval '.python_packages.boto3.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local requests_version=$(yq eval '.python_packages.requests.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local kubernetes_version=$(yq eval '.python_packages.kubernetes.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local pytest_version=$(yq eval '.python_packages.pytest.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local ruff_version=$(yq eval '.python_packages.ruff.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local black_version=$(yq eval '.python_packages.black.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local mypy_version=$(yq eval '.python_packages.mypy.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local fastmcp_version=$(yq eval '.python_packages.fastmcp.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local pyyaml_version=$(yq eval '.python_packages.pyyaml.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local uv_version=$(yq eval '.python_packages.uv.current' "$VERSIONS_FILE" 2>/dev/null || echo "")

        echo -e "${BLUE}Python Packages:${NC}"
        [ -n "$pymysql_version" ] && echo -e "  PyMySQL: ${GREEN}$pymysql_version${NC}"
        [ -n "$boto3_version" ] && echo -e "  boto3: ${GREEN}$boto3_version${NC}"
        [ -n "$requests_version" ] && echo -e "  requests: ${GREEN}$requests_version${NC}"
        [ -n "$kubernetes_version" ] && echo -e "  kubernetes: ${GREEN}$kubernetes_version${NC}"
        [ -n "$pytest_version" ] && echo -e "  pytest: ${GREEN}$pytest_version${NC}"
        [ -n "$ruff_version" ] && echo -e "  Ruff: ${GREEN}$ruff_version${NC}"
        [ -n "$black_version" ] && echo -e "  black: ${GREEN}$black_version${NC}"
        [ -n "$mypy_version" ] && echo -e "  mypy: ${GREEN}$mypy_version${NC}"
        [ -n "$fastmcp_version" ] && echo -e "  FastMCP: ${GREEN}$fastmcp_version${NC}"
        [ -n "$pyyaml_version" ] && echo -e "  PyYAML: ${GREEN}$pyyaml_version${NC}"
        [ -n "$uv_version" ] && echo -e "  uv: ${GREEN}$uv_version${NC}"
        echo ""
    fi

    echo -e "${BLUE}Monitoring:${NC}"
    echo -e "  Prometheus Operator: ${GREEN}$PROMETHEUS_CURRENT${NC}"
    echo -e "  Loki: ${GREEN}$LOKI_CURRENT${NC}"
    echo -e "  Tempo: ${GREEN}$TEMPO_CURRENT${NC}"
    echo -e "  Mimir: ${GREEN}$MIMIR_CURRENT${NC}"
    echo -e "  OTeBPF: ${GREEN}$OTEBPF_CURRENT${NC}"
    echo ""

    # Show security tools if available
    if yq eval '.security_tools' "$VERSIONS_FILE" >/dev/null 2>&1; then
        local trivy_version=$(yq eval '.security_tools.trivy.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local checkov_version=$(yq eval '.security_tools.checkov.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local kics_version=$(yq eval '.security_tools.kics.current' "$VERSIONS_FILE" 2>/dev/null || echo "")
        local gosec_version=$(yq eval '.security_tools.gosec.current' "$VERSIONS_FILE" 2>/dev/null || echo "")

        if [ -n "$trivy_version" ] || [ -n "$checkov_version" ] || [ -n "$kics_version" ] || [ -n "$gosec_version" ]; then
            echo -e "${BLUE}Security Tools (Zero-Tolerance):${NC}"
            [ -n "$trivy_version" ] && echo -e "  Trivy: ${GREEN}$trivy_version${NC}"
            [ -n "$checkov_version" ] && echo -e "  Checkov: ${GREEN}$checkov_version${NC}"
            [ -n "$kics_version" ] && echo -e "  KICS: ${GREEN}$kics_version${NC}"
            [ -n "$gosec_version" ] && echo -e "  gosec: ${GREEN}$gosec_version${NC}"
            echo ""
        fi
    fi
}

# Main function - entry point for the script
# This function handles command-line argument parsing and dispatches to appropriate functions
main() {
    # Set default values for command-line options
    local command="${1:-check}" # Default command is 'check'
    local components="all"      # Default to checking all components
    local create_issue="false"  # Don't create GitHub issues by default
    local month=""              # No month filtering by default

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

    # Handle help and invalid commands before requiring dependencies
    case "$command" in
        check|status) ;;
        help|--help)
            show_help
            exit 0
            ;;
        *)
            error_exit "Unknown command: $command. Use 'help' or '--help' for usage information."
            ;;
    esac

    # Initialize script dependencies and configuration
    check_dependencies # Validate required tools are available
    parse_config       # Load version configuration from YAML file

    # Execute the specified command
    case "$command" in
        "check")
            check_updates "$components" "$create_issue" "$month"
            ;;
        "status")
            show_status
            ;;
    esac
}

# Run main function with all arguments
main "$@"
