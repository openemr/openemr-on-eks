#!/bin/bash
# =============================================================================
# OpenEMR EKS Version Dashboard
# =============================================================================
# Human-friendly wrapper around version-manager.sh for quick version status.
# Referenced by the monthly version-check workflow and VERSION_MANAGEMENT.md.
#
# Usage:
#   ./scripts/version-dashboard.sh              # Show current pinned versions
#   ./scripts/version-dashboard.sh check        # Check for available updates
#   ./scripts/version-dashboard.sh check applications
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    echo "OpenEMR EKS Version Dashboard"
    echo ""
    echo "Usage: $0 [check [COMPONENTS]]"
    echo ""
    echo "Commands:"
    echo "  (none)              Show current version status (same as version-manager.sh status)"
    echo "  check               Check all components for available updates"
    echo "  check COMPONENTS    Check specific component group (e.g. applications, monitoring)"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 check"
    echo "  $0 check --components applications"
    exit 0
}

case "${1:-status}" in
    -h|--help|help)
        show_help
        ;;
    check)
        shift
        exec "$SCRIPT_DIR/version-manager.sh" check "$@"
        ;;
    status)
        exec "$SCRIPT_DIR/version-manager.sh" status
        ;;
    *)
        echo "Unknown command: $1" >&2
        show_help
        ;;
esac
