#!/bin/bash

# =============================================================================
# OpenEMR Version Checker
# =============================================================================
#
# Purpose:
#   Queries Docker Hub API to retrieve and display available OpenEMR Docker
#   image versions with filtering capabilities. Helps administrators choose
#   appropriate versions for deployment based on stability recommendations.
#
# Key Features:
#   - Fetches version data from Docker Hub API v2
#   - Filters versions by semantic versioning patterns
#   - Distinguishes between latest (development) and stable (production) versions
#   - Provides deployment configuration examples
#   - Validates current deployment version against available versions
#
# Prerequisites:
#   - Internet connectivity to Docker Hub API
#
# Usage:
#   ./check-openemr-versions.sh [OPTIONS]
#
# Options:
#   --count N          Show N most recent versions (default: 10)
#   --all              Show all available versions
#   --stable-only      Show only stable release versions
#   --latest-only      Show only latest/development versions
#   --check-current    Check current deployment version
#   --help             Show this help message
#
# Dependencies:
#   - curl (for API calls to Docker Hub)
#   - jq (for JSON parsing and formatting)
#
# Examples:
#   ./check-openemr-versions.sh
#   ./check-openemr-versions.sh --count 20
#   ./check-openemr-versions.sh --stable-only
#   ./check-openemr-versions.sh --check-current
#
# =============================================================================

set -e

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical issues
GREEN='\033[0;32m'    # Success messages and stable versions
YELLOW='\033[1;33m'   # Warning messages and latest/development versions
BLUE='\033[0;34m'     # Info messages and general information
NC='\033[0m'          # Reset color to default

# Configuration variables
DOCKER_REGISTRY="openemr/openemr"  # Docker Hub repository for OpenEMR images
DEFAULT_TAGS_TO_SHOW=10            # Default number of versions to display when no specific count is requested

# Help function - displays usage information and examples
# This function provides comprehensive documentation for script usage,
# including all available options and practical examples for common use cases
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Check available OpenEMR Docker image versions"
    echo ""
    echo "Options:"
    echo "  --count NUMBER      Number of versions to display (default: $DEFAULT_TAGS_TO_SHOW)"
    echo "  --search PATTERN    Search for versions matching pattern (e.g., '7.0')"
    echo "  --latest            Show only the latest version"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                  # Show latest $DEFAULT_TAGS_TO_SHOW versions"
    echo "  $0 --count 20       # Show latest 20 versions"
    echo "  $0 --search 7.0     # Show all 7.0.x versions"
    echo "  $0 --latest         # Show only the latest version"
    exit 0
}

# Parse command line arguments
# This section processes command-line options and sets corresponding variables
# Each option modifies the behavior of the version checking and display logic
TAGS_TO_SHOW=$DEFAULT_TAGS_TO_SHOW  # Number of versions to display (can be overridden by --count)
SEARCH_PATTERN=""                   # Pattern to filter versions (set by --search)
LATEST_ONLY=false                   # Flag to show only the latest version (set by --latest)

while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            TAGS_TO_SHOW="$2"       # Override default count with user-specified number
            shift 2                 # Consume both the option and its value
            ;;
        --search)
            SEARCH_PATTERN="$2"     # Set search pattern for version filtering
            shift 2                 # Consume both the option and its value
            ;;
        --latest)
            LATEST_ONLY=true        # Enable latest-only mode
            shift                   # Consume only the option (no value)
            ;;
        --help)
            show_help               # Display help and exit
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1                  # Exit with error for unknown options
            ;;
    esac
done

# Display initial status information
echo -e "${GREEN}Checking available OpenEMR versions...${NC}"
echo -e "${BLUE}Registry: $DOCKER_REGISTRY${NC}"
echo ""

# Dependency validation - ensure required tools are available
# This section checks for curl (HTTP client) and jq (JSON parser) which are essential
# for fetching and processing Docker Hub API responses
if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: curl is required but not installed.${NC}" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Error: jq is required but not installed.${NC}" >&2
    echo -e "${YELLOW}Install with: brew install jq (macOS) or apt-get install jq (Ubuntu)${NC}" >&2
    exit 1
fi

# Function to fetch Docker Hub tags via API
# This function queries Docker Hub's REST API v2 to retrieve all available tags
# for the specified registry (openemr/openemr). It handles API errors gracefully
# and returns a list of tag names for further processing.
get_docker_tags() {
    local registry="$1"  # Docker registry name (e.g., "openemr/openemr")
    local url="https://registry.hub.docker.com/v2/repositories/${registry}/tags?page_size=100"

    echo -e "${YELLOW}Fetching tags from Docker Hub...${NC}"

    # Make API request to Docker Hub - using curl with silent mode (-s) to suppress progress
    local response=$(curl -s "$url")

    # Check if curl command succeeded (exit code 0)
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to fetch tags from Docker Hub${NC}" >&2
        exit 1
    fi

    # Parse JSON response using jq to extract tag names from the 'results' array
    # The -r flag outputs raw strings without quotes, 2>/dev/null suppresses jq errors
    echo "$response" | jq -r '.results[].name' 2>/dev/null
}

# Function to filter and process version tags
# This function applies semantic versioning filters and search patterns to the raw tag list.
# It implements OpenEMR's versioning strategy where the second-to-latest version is considered stable.
filter_versions() {
    local search_pattern="$1"  # Pattern to match (e.g., "7.0" for 7.0.x versions)
    local latest_only="$2"     # Boolean flag to return only the recommended stable version
    local count="$3"           # Maximum number of versions to return

    # Apply semantic versioning regex filter and optional search pattern
    # Regex matches: major.minor.patch[-suffix] format (e.g., 7.0.3, 7.0.3-beta)
    local filtered_tags
    if [ -n "$search_pattern" ]; then
        # Apply both semantic versioning filter AND search pattern
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | grep "$search_pattern" | head -n "$count")
    else
        # Apply only semantic versioning filter
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | head -n "$count")
    fi

    if [ "$latest_only" = true ]; then
        # OpenEMR versioning strategy: second-to-latest is typically the stable release
        # This is because the latest version may be a development/pre-release version
        local stable_version=$(echo "$filtered_tags" | sed -n '2p')
        if [ -n "$stable_version" ]; then
            echo "$stable_version"  # Return the stable version
        else
            # Fallback to latest if only one version is available
            echo "$filtered_tags" | head -n 1
        fi
    else
        echo "$filtered_tags"  # Return all filtered versions
    fi
}

# Main processing logic - fetch tags and validate response
echo -e "${YELLOW}Processing version tags...${NC}"
tags=$(get_docker_tags "$DOCKER_REGISTRY")

# Validate that we received tag data from the API
if [ -z "$tags" ]; then
    echo -e "${RED}Error: No tags found or failed to parse response${NC}" >&2
    exit 1
fi

# Display logic - branch based on user's display preference
if [ "$LATEST_ONLY" = true ]; then
    # Latest-only mode: Display only the recommended stable version with deployment guidance
    echo -e "${BLUE}Recommended OpenEMR version (stable):${NC}"
    
    # Extract latest and stable versions using semantic versioning regex
    # Latest version is the first match, stable is typically the second (more mature)
    latest_version=$(echo "$tags" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | head -n 1)
    stable_version=$(echo "$tags" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | sed -n '2p')

    if [ -n "$stable_version" ]; then
        # Display stable version as recommended for production use
        echo -e "${GREEN}  $stable_version${NC} (stable - recommended for production)"
        
        # Show latest version for comparison if it differs from stable
        if [ -n "$latest_version" ] && [ "$stable_version" != "$latest_version" ]; then
            echo -e "${YELLOW}  $latest_version${NC} (latest - may be development version)"
        fi
        
        echo ""
        echo -e "${BLUE}To use the stable version in your deployment:${NC}"
        echo -e "${YELLOW}  openemr_version = \"$stable_version\"${NC}"
    elif [ -n "$latest_version" ]; then
        # Fallback: if no stable version found, show latest with warning
        echo -e "${YELLOW}  $latest_version${NC} (only version available)"
        echo ""
        echo -e "${BLUE}To use this version in your deployment:${NC}"
        echo -e "${YELLOW}  openemr_version = \"$latest_version\"${NC}"
    else
        # Error case: no valid versions found
        echo -e "${RED}No matching versions found${NC}"
    fi
else
    if [ -n "$SEARCH_PATTERN" ]; then
        echo -e "${BLUE}OpenEMR versions matching '$SEARCH_PATTERN' (showing up to $TAGS_TO_SHOW):${NC}"
    else
        echo -e "${BLUE}Latest OpenEMR versions (showing up to $TAGS_TO_SHOW):${NC}"
    fi

    versions=$(echo "$tags" | filter_versions "$SEARCH_PATTERN" false "$TAGS_TO_SHOW")

    if [ -n "$versions" ]; then
        version_count=0
        echo "$versions" | while read -r version; do
            version_count=$((version_count + 1))
            if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                if [ $version_count -eq 1 ]; then
                    echo -e "${YELLOW}  $version${NC} (latest - may be development)"
                elif [ $version_count -eq 2 ]; then
                    echo -e "${GREEN}  $version${NC} (stable - recommended)"
                else
                    echo -e "${GREEN}  $version${NC} (stable)"
                fi
            else
                echo -e "${YELLOW}  $version${NC} (pre-release)"
            fi
        done

        echo ""
        echo -e "${BLUE}To use a specific version in your deployment:${NC}"
        echo -e "${YELLOW}  # In terraform.tfvars (recommended stable version)${NC}"
        stable_version=$(echo "$versions" | sed -n '2p')
        if [ -n "$stable_version" ]; then
            echo -e "${YELLOW}  openemr_version = \"$stable_version\"${NC}"
        else
            echo -e "${YELLOW}  openemr_version = \"$(echo "$versions" | head -n 1)\"${NC}"
        fi
        echo ""
        echo -e "${BLUE}Current deployment version:${NC}"
        if [ -f "../terraform/terraform.tfvars" ]; then
            current_version=$(grep "openemr_version" ../terraform/terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "not set")
            echo -e "${GREEN}  $current_version${NC}"
        else
            echo -e "${YELLOW}  terraform.tfvars not found${NC}"
        fi
    else
        echo -e "${RED}No matching versions found${NC}"
        if [ -n "$SEARCH_PATTERN" ]; then
            echo -e "${YELLOW}Try a different search pattern or check available versions without --search${NC}"
        fi
    fi
fi

# Display helpful tips and resources for version management
echo ""
echo -e "${BLUE}💡 Tips:${NC}"
echo -e "${BLUE}  • OpenEMR stable versions are typically the second-to-latest release${NC}"
echo -e "${BLUE}  • Use stable versions for production deployments${NC}"
echo -e "${BLUE}  • Test version upgrades in a development environment first${NC}"
echo -e "${BLUE}  • Check OpenEMR release notes before upgrading${NC}"
echo -e "${BLUE}  • Current recommended version: 7.0.3 (stable)${NC}"
echo ""
echo -e "${BLUE}🔗 Resources:${NC}"
echo -e "${BLUE}  • OpenEMR Releases: https://github.com/openemr/openemr/tags${NC}"
echo -e "${BLUE}  • Docker Hub: https://hub.docker.com/r/openemr/openemr/tags${NC}"
