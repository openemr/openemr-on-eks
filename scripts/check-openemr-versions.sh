#!/bin/bash

# OpenEMR Version Checker
# This script helps users discover available OpenEMR Docker image versions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOCKER_REGISTRY="openemr/openemr"
DEFAULT_TAGS_TO_SHOW=10

# Help function
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
TAGS_TO_SHOW=$DEFAULT_TAGS_TO_SHOW
SEARCH_PATTERN=""
LATEST_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            TAGS_TO_SHOW="$2"
            shift 2
            ;;
        --search)
            SEARCH_PATTERN="$2"
            shift 2
            ;;
        --latest)
            LATEST_ONLY=true
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}Checking available OpenEMR versions...${NC}"
echo -e "${BLUE}Registry: $DOCKER_REGISTRY${NC}"
echo ""

# Check if required tools are available
if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: curl is required but not installed.${NC}" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Error: jq is required but not installed.${NC}" >&2
    echo -e "${YELLOW}Install with: brew install jq (macOS) or apt-get install jq (Ubuntu)${NC}" >&2
    exit 1
fi

# Function to get Docker Hub tags
get_docker_tags() {
    local registry="$1"
    local url="https://registry.hub.docker.com/v2/repositories/${registry}/tags?page_size=100"

    echo -e "${YELLOW}Fetching tags from Docker Hub...${NC}"

    # Get tags from Docker Hub API
    local response=$(curl -s "$url")

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to fetch tags from Docker Hub${NC}" >&2
        exit 1
    fi

    # Parse JSON response and extract tag names
    echo "$response" | jq -r '.results[].name' 2>/dev/null
}

# Function to filter and sort version tags
filter_versions() {
    local search_pattern="$1"
    local latest_only="$2"
    local count="$3"

    # Filter out non-version tags and apply search pattern
    local filtered_tags
    if [ -n "$search_pattern" ]; then
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | grep "$search_pattern" | head -n "$count")
    else
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | head -n "$count")
    fi

    if [ "$latest_only" = true ]; then
        # For OpenEMR, recommend the stable version (typically second-to-latest)
        local stable_version=$(echo "$filtered_tags" | sed -n '2p')
        if [ -n "$stable_version" ]; then
            echo "$stable_version"
        else
            # Fallback to latest if only one version available
            echo "$filtered_tags" | head -n 1
        fi
    else
        echo "$filtered_tags"
    fi
}

# Get and process tags
echo -e "${YELLOW}Processing version tags...${NC}"
tags=$(get_docker_tags "$DOCKER_REGISTRY")

if [ -z "$tags" ]; then
    echo -e "${RED}Error: No tags found or failed to parse response${NC}" >&2
    exit 1
fi

# Filter and display versions
if [ "$LATEST_ONLY" = true ]; then
    echo -e "${BLUE}Recommended OpenEMR version (stable):${NC}"
    # Get the latest and second-to-latest versions
    latest_version=$(echo "$tags" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | head -n 1)
    stable_version=$(echo "$tags" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | sed -n '2p')

    if [ -n "$stable_version" ]; then
        echo -e "${GREEN}  $stable_version${NC} (stable - recommended for production)"
        if [ -n "$latest_version" ] && [ "$stable_version" != "$latest_version" ]; then
            echo -e "${YELLOW}  $latest_version${NC} (latest - may be development version)"
        fi
        echo ""
        echo -e "${BLUE}To use the stable version in your deployment:${NC}"
        echo -e "${YELLOW}  openemr_version = \"$stable_version\"${NC}"
    elif [ -n "$latest_version" ]; then
        echo -e "${YELLOW}  $latest_version${NC} (only version available)"
        echo ""
        echo -e "${BLUE}To use this version in your deployment:${NC}"
        echo -e "${YELLOW}  openemr_version = \"$latest_version\"${NC}"
    else
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
