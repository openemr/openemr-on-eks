#!/bin/bash

# =============================================================================
# Python Docker Image Version Manager
# =============================================================================
#
# Purpose:
#   Retrieves the Python Docker image version from versions.yaml and optionally
#   auto-detects the latest Python 3.xx version from Docker Hub. Used by
#   Kubernetes jobs to automatically use the latest Python 3.x image without
#   requiring manual version updates.
#
# Key Features:
#   - Reads Python version from centralized versions.yaml configuration
#   - Auto-detects latest Python 3.xx version from Docker Hub when enabled
#   - Supports image variant suffixes (slim, alpine, etc.)
#   - Provides fallback to default version if configuration unavailable
#   - Outputs Docker image tag format for direct use in Kubernetes manifests
#
# Prerequisites:
#   - yq (for YAML parsing) - optional, falls back to default if unavailable
#   - curl (for Docker Hub API queries) - optional, only needed for auto-detection
#   - jq (for JSON parsing) - optional, only needed for auto-detection
#   - Internet connectivity (for Docker Hub API queries when auto-detection enabled)
#
# Usage:
#   ./get-python-image-version.sh [SUFFIX]
#
# Arguments:
#   SUFFIX              Image variant suffix (default: "slim")
#                      Examples: "slim", "alpine", "bullseye"
#
# Environment Variables:
#   None - Script uses fixed paths relative to project root
#
# Configuration:
#   Version is managed in versions.yaml under applications.python:
#     - current: Version number (e.g., "3.14")
#     - auto_detect_latest: Enable automatic latest version detection (true/false)
#     - registry: Docker registry (default: "library/python")
#
# Examples:
#   ./get-python-image-version.sh             # Returns: python:3.14-slim
#   ./get-python-image-version.sh slim        # Returns: python:3.14-slim
#   ./get-python-image-version.sh alpine      # Returns: python:3.14-alpine
#
# Output:
#   Prints Docker image tag to stdout (e.g., "python:3.14-slim")
#   Status messages printed to stderr for logging/debugging
#
# =============================================================================

set -e

# Configuration variables - default values used when versions.yaml unavailable
DEFAULT_VERSION="3.14" # Default Python version fallback
SUFFIX="${1:-slim}"    # Image variant suffix (default: slim)

# Script directory detection - allows script to be run from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Function to read Python version from versions.yaml
# This function attempts to locate and parse versions.yaml from multiple locations
# to support running the script from different directories
get_python_version_from_config() {
    local versions_file=""
    
    # Try current directory first
    if [ -f "versions.yaml" ]; then
        versions_file="versions.yaml"
    # Try project root directory
    elif [ -f "$PROJECT_ROOT/versions.yaml" ]; then
        versions_file="$PROJECT_ROOT/versions.yaml"
    fi
    
    # Extract Python version if versions.yaml found
    if [ -n "$versions_file" ]; then
        yq eval '.applications.python.current' "$versions_file" 2>/dev/null || echo "$DEFAULT_VERSION"
    else
        echo "$DEFAULT_VERSION"
    fi
}

# Function to check if auto-detection is enabled in versions.yaml
# Returns "true" if auto_detect_latest is enabled, "false" otherwise
is_auto_detect_enabled() {
    local versions_file=""
    
    # Try current directory first
    if [ -f "versions.yaml" ]; then
        versions_file="versions.yaml"
    # Try project root directory
    elif [ -f "$PROJECT_ROOT/versions.yaml" ]; then
        versions_file="$PROJECT_ROOT/versions.yaml"
    fi
    
    # Extract auto_detect_latest setting if versions.yaml found
    if [ -n "$versions_file" ]; then
        yq eval '.applications.python.auto_detect_latest' "$versions_file" 2>/dev/null || echo "false"
    else
        echo "false"
    fi
}

# Function to query Docker Hub for latest Python 3.xx version
# This function queries the Docker Hub API to find the latest Python 3.x version
# matching the specified suffix pattern (e.g., 3.14-slim, 3.15-slim)
get_latest_python_version_from_docker_hub() {
    local suffix="$1"
    
    echo "Detecting latest Python 3.xx${suffix:+-$suffix} version from Docker Hub..." >&2
    
    # Query Docker Hub API for Python tags matching 3.x pattern
    local tags_url="https://registry.hub.docker.com/v2/repositories/library/python/tags?page_size=100&name=3."
    local response=$(curl -s "$tags_url" 2>/dev/null || echo "")
    
    if [ -n "$response" ]; then
        # Extract 3.xx versions matching the suffix pattern, sort, and get latest
        local latest=$(echo "$response" | jq -r '.results[].name' 2>/dev/null | \
            grep -E "^3\.[0-9]+(-${suffix})?$" | \
            sort -V -r | \
            head -1 || echo "")
        
        if [ -n "$latest" ]; then
            # Remove suffix to get version number only
            echo "$latest" | sed -E "s/-${suffix}$//"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

# Main execution logic
# 1. Read version from versions.yaml (or use default)
PYTHON_VERSION=$(get_python_version_from_config)

# 2. Check if auto-detection is enabled
AUTO_DETECT=$(is_auto_detect_enabled)

# 3. If auto-detection enabled, query Docker Hub for latest version
if [ "$AUTO_DETECT" = "true" ]; then
    detected_version=$(get_latest_python_version_from_docker_hub "$SUFFIX")
    
    if [ -n "$detected_version" ]; then
        PYTHON_VERSION="$detected_version"
        echo "Found latest Python version: ${PYTHON_VERSION}${SUFFIX:+-$SUFFIX}" >&2
    fi
fi

# 4. Output Docker image tag in standard format
echo "python:${PYTHON_VERSION}${SUFFIX:+-$SUFFIX}"

