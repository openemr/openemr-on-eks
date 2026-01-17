#!/bin/bash

# =============================================================================
# Codebase Search Tool
# =============================================================================
#
# Purpose:
#   Interactive tool to search for terms across the entire codebase
#
# Usage:
#   ./search-codebase.sh [SEARCH_TERM]
#
# =============================================================================

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly SCRIPT_DIR
readonly PROJECT_ROOT

# Function to search codebase
search_codebase() {
    local search_term="$1"
    local case_sensitive="${2:-false}"
    
    echo -e "${CYAN}🔍 Searching codebase for: ${BLUE}'$search_term'${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Define exclusion patterns
    local exclude_patterns=(
        "--exclude-dir=.git"
        "--exclude-dir=node_modules"
        "--exclude-dir=.terraform"
        "--exclude-dir=venv"
        "--exclude-dir=__pycache__"
        "--exclude-dir=.pytest_cache"
        "--exclude-dir=dist"
        "--exclude-dir=build"
        "--exclude=*.log"
        "--exclude=version-update-report-*.md"
        "--exclude=*.pyc"
        "--exclude=*.pyo"
        "--exclude=*.so"
        "--exclude=*.o"
        "--exclude=*.a"
        "--exclude=*.tmp"
        "--exclude=*.temp"
        "--exclude=console/console"
    )
    
    # Build grep command
    local grep_cmd="grep -rn"
    if [ "$case_sensitive" = "false" ]; then
        grep_cmd="$grep_cmd -i"
    fi
    
    # shellcheck disable=SC2124  # Intentionally concatenating array to string for grep command
    grep_cmd="$grep_cmd ${exclude_patterns[*]}"
    
    # Search and display results
    local results
    results=$(cd "$PROJECT_ROOT" && $grep_cmd "$search_term" . 2>/dev/null || true)
    
    if [ -z "$results" ]; then
        echo -e "${YELLOW}No matches found for '$search_term'${NC}"
        echo ""
        return 1
    fi
    
    # Count matches
    local match_count=$(echo "$results" | wc -l | tr -d ' ')
    echo -e "${GREEN}Found $match_count match(es):${NC}"
    echo ""
    
    # Display results with context
    echo "$results" | while IFS= read -r line; do
        if [ -n "$line" ]; then
            # Colorize file path and line number
            file_path=$(echo "$line" | cut -d: -f1)
            line_num=$(echo "$line" | cut -d: -f2)
            content=$(echo "$line" | cut -d: -f3-)
            
            echo -e "${BLUE}$file_path${NC}:${CYAN}$line_num${NC}:$content"
        fi
    done
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Main execution
main() {
    local search_term="${1:-}"
    
    if [ -z "$search_term" ]; then
        echo -e "${CYAN}Codebase Search Tool${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${BLUE}Enter search term:${NC} "
        read -r search_term
        
        if [ -z "$search_term" ]; then
            echo -e "${RED}Error: Search term cannot be empty${NC}"
            exit 1
        fi
    fi
    
    search_codebase "$search_term" "false"
}

main "$@"
