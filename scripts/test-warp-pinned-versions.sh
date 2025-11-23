#!/bin/bash

# =============================================================================
# Test Warp Pinned Versions Compatibility
# =============================================================================
#
# Purpose:
#   Tests that the pinned versions from versions.yaml work correctly with
#   the Warp project and its dependencies. This script automatically reads
#   version numbers from versions.yaml to ensure consistency.
#
# Usage:
#   ./scripts/test-warp-pinned-versions.sh
#
# Prerequisites:
#   - yq (for YAML parsing) - required for reading versions.yaml
#   - Python 3.8+ (Python 3.14 recommended, matches versions.yaml)
#   - Internet connectivity for pip package installation
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="$PROJECT_ROOT/versions.yaml"
WARP_DIR="$PROJECT_ROOT/warp"

# Check if yq is available
if ! command -v yq >/dev/null 2>&1; then
    echo -e "${RED}ERROR: yq is required but not found${NC}"
    echo "Install yq: https://github.com/mikefarah/yq"
    exit 1
fi

# Check if versions.yaml exists
if [ ! -f "$VERSIONS_FILE" ]; then
    echo -e "${RED}ERROR: versions.yaml not found at $VERSIONS_FILE${NC}"
    exit 1
fi

# Check if warp directory exists
if [ ! -d "$WARP_DIR" ]; then
    echo -e "${RED}ERROR: warp directory not found at $WARP_DIR${NC}"
    exit 1
fi

# Function to normalize Python version to major.minor format (e.g., "3.14.0" -> "3.14")
normalize_python_version() {
    local version=$1
    # Extract major.minor (first two components) using awk or cut
    echo "$version" | awk -F. '{print $1"."$2}'
}

# Function to read version from versions.yaml
# Fails if version cannot be read from versions.yaml (no fallback to defaults)
read_version() {
    local path=$1
    local version
    local yq_output
    local yq_exit_code
    
    # Capture both output and exit code from yq
    yq_output=$(yq eval "$path" "$VERSIONS_FILE" 2>&1)
    yq_exit_code=$?
    
    # Check if yq command failed
    if [ $yq_exit_code -ne 0 ]; then
        echo -e "${RED}ERROR: Failed to read version from versions.yaml at path: $path${NC}" >&2
        echo -e "${RED}       yq error: $yq_output${NC}" >&2
        echo -e "${RED}       The test requires all versions to be explicitly defined in versions.yaml${NC}" >&2
        exit 1
    fi
    
    version="$yq_output"
    
    # Check if version is empty or null
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        echo -e "${RED}ERROR: Version not found in versions.yaml at path: $path${NC}" >&2
        echo -e "${RED}       The test requires all versions to be explicitly defined in versions.yaml${NC}" >&2
        exit 1
    fi
    
    echo "$version"
}

# Read Python version from versions.yaml
PYTHON_VERSION_REQUIRED=$(read_version '.applications.python.current')

# Read Python package versions from versions.yaml
PYMYSQL_VERSION=$(read_version '.python_packages.pymysql.current')
BOTO3_VERSION=$(read_version '.python_packages.boto3.current')
PYTEST_VERSION=$(read_version '.python_packages.pytest.current')
PYTEST_COV_VERSION=$(read_version '.python_packages.pytest_cov.current')
FLAKE8_VERSION=$(read_version '.python_packages.flake8.current')
BLACK_VERSION=$(read_version '.python_packages.black.current')
MYPY_VERSION=$(read_version '.python_packages.mypy.current')

echo "=============================================================================="
echo "Testing Warp Pinned Versions Compatibility"
echo "=============================================================================="
echo ""
echo "Reading versions from: $VERSIONS_FILE"
echo ""
echo "Python version (from versions.yaml): $PYTHON_VERSION_REQUIRED"
echo ""
echo "Pinned Python package versions (from versions.yaml):"
echo "  pymysql:     $PYMYSQL_VERSION"
echo "  boto3:       $BOTO3_VERSION"
echo "  pytest:      $PYTEST_VERSION"
echo "  pytest-cov:  $PYTEST_COV_VERSION"
echo "  flake8:      $FLAKE8_VERSION"
echo "  black:       $BLACK_VERSION"
echo "  mypy:        $MYPY_VERSION"
echo ""

# Change to warp directory
cd "$WARP_DIR"

# Detect Python interpreter (prefer 3.14, fallback to python3)
PYTHON_CMD=""
if command -v "python${PYTHON_VERSION_REQUIRED}" >/dev/null 2>&1; then
    PYTHON_CMD="python${PYTHON_VERSION_REQUIRED}"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
    PYTHON_ACTUAL_VERSION=$($PYTHON_CMD --version 2>&1 | awk '{print $2}')
    # Compare only major.minor versions
    PYTHON_ACTUAL_NORMALIZED=$(normalize_python_version "$PYTHON_ACTUAL_VERSION")
    PYTHON_REQUIRED_NORMALIZED=$(normalize_python_version "$PYTHON_VERSION_REQUIRED")
    if [ "$PYTHON_ACTUAL_NORMALIZED" != "$PYTHON_REQUIRED_NORMALIZED" ]; then
        echo -e "${YELLOW}Warning: Python $PYTHON_VERSION_REQUIRED not found, using $PYTHON_ACTUAL_VERSION${NC}"
        echo -e "${YELLOW}Note: Production uses Python $PYTHON_VERSION_REQUIRED (from versions.yaml)${NC}"
        echo ""
    fi
else
    echo -e "${RED}ERROR: Python not found${NC}"
    exit 1
fi

# Create virtual environment for testing
VENV_DIR="$WARP_DIR/.test-venv"
if [ -d "$VENV_DIR" ]; then
    echo "Removing existing virtual environment for clean test..."
    rm -rf "$VENV_DIR"
fi

echo "Creating virtual environment with $PYTHON_CMD..."
$PYTHON_CMD -m venv "$VENV_DIR"

# Activate virtual environment
source "$VENV_DIR/bin/activate"

# Step 1: Check Python version
echo "Step 1: Checking Python version..."
PYTHON_VERSION=$(python --version 2>&1 | awk '{print $2}')
echo "  Python version: $PYTHON_VERSION"
echo "  Required: Python $PYTHON_VERSION_REQUIRED (from versions.yaml)"
if ! python -c "import sys; exit(0 if sys.version_info >= (3, 8) else 1)"; then
    echo -e "${RED}ERROR: Python 3.8+ required${NC}"
    exit 1
fi
# Compare only major.minor versions
PYTHON_VERSION_NORMALIZED=$(normalize_python_version "$PYTHON_VERSION")
PYTHON_REQUIRED_NORMALIZED=$(normalize_python_version "$PYTHON_VERSION_REQUIRED")
if [ "$PYTHON_VERSION_NORMALIZED" != "$PYTHON_REQUIRED_NORMALIZED" ]; then
    echo -e "${YELLOW}⚠ Using Python $PYTHON_VERSION (production uses $PYTHON_VERSION_REQUIRED)${NC}"
    echo -e "${YELLOW}  Consider testing with Python $PYTHON_VERSION_REQUIRED for exact compatibility${NC}"
else
    echo -e "${GREEN}✓ Python version matches versions.yaml${NC}"
fi
echo ""

# Step 2: Install pinned versions
echo "Step 2: Installing pinned versions..."
echo "  Installing runtime dependencies..."
pip install --quiet --upgrade pip
pip install --quiet "pymysql==$PYMYSQL_VERSION" "boto3==$BOTO3_VERSION"
echo "  Installing test dependencies..."
pip install --quiet "pytest==$PYTEST_VERSION" "pytest-cov==$PYTEST_COV_VERSION" \
    "flake8==$FLAKE8_VERSION" "black==$BLACK_VERSION" "mypy==$MYPY_VERSION"
echo -e "${GREEN}✓ Dependencies installed${NC}"
echo ""

# Step 3: Verify installed versions
echo "Step 3: Verifying installed versions..."
check_version_pip() {
    local package=$1
    local expected=$2
    local pip_name=${3:-$package}
    local actual=$(pip show "$pip_name" 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "NOT_FOUND")
    
    if [ "$actual" = "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} $package: $actual (matches)"
        return 0
    else
        echo -e "  ${RED}✗${NC} $package: $actual (expected $expected)"
        return 1
    fi
}

check_version_import() {
    local package=$1
    local expected=$2
    local actual=$(python -c "import $package; print($package.__version__)" 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$actual" = "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} $package: $actual (matches)"
        return 0
    else
        echo -e "  ${RED}✗${NC} $package: $actual (expected $expected)"
        return 1
    fi
}

VERSION_CHECK_FAILED=0

# Check via pip (more reliable for package metadata)
# Note: PyMySQL 1.1.0 has a known issue where __version__ reports 1.4.6, but pip shows correct version
check_version_pip "pymysql" "$PYMYSQL_VERSION" "PyMySQL" || VERSION_CHECK_FAILED=1
check_version_pip "boto3" "$BOTO3_VERSION" || VERSION_CHECK_FAILED=1
check_version_pip "pytest" "$PYTEST_VERSION" || VERSION_CHECK_FAILED=1
check_version_pip "pytest-cov" "$PYTEST_COV_VERSION" || VERSION_CHECK_FAILED=1
check_version_pip "flake8" "$FLAKE8_VERSION" || VERSION_CHECK_FAILED=1
check_version_pip "black" "$BLACK_VERSION" || VERSION_CHECK_FAILED=1
check_version_pip "mypy" "$MYPY_VERSION" || VERSION_CHECK_FAILED=1

# Also verify imports work (functional check)
echo ""
echo "  Verifying imports work..."
python -c "import pymysql; import boto3; import pytest; import flake8; import black; import mypy; print('✓ All packages importable')" 2>/dev/null || {
    echo -e "  ${RED}✗${NC} Some packages failed to import"
    VERSION_CHECK_FAILED=1
}

if [ $VERSION_CHECK_FAILED -eq 1 ]; then
    echo -e "${RED}ERROR: Version check failed${NC}"
    exit 1
fi
echo ""

# Step 4: Install warp in development mode
echo "Step 4: Installing warp in development mode..."
pip install --quiet -e .
echo -e "${GREEN}✓ Warp installed${NC}"
echo ""

# Step 5: Test imports
echo "Step 5: Testing package imports..."
python -c "
import pymysql
import boto3
from warp.core.omop_to_ccda import OMOPToCCDAConverter
from warp.core.db_importer import OpenEMRDBImporter
from warp.core.uploader import Uploader
from warp.core.credential_discovery import CredentialDiscovery
print('✓ All imports successful')
" || {
    echo -e "${RED}ERROR: Import test failed${NC}"
    exit 1
}
echo -e "${GREEN}✓ All imports successful${NC}"
echo ""

# Step 6: Run unit tests
echo "Step 6: Running unit tests..."
if pytest tests/ -v --ignore=tests/benchmarks -x; then
    echo -e "${GREEN}✓ All unit tests passed${NC}"
else
    echo -e "${RED}ERROR: Unit tests failed${NC}"
    exit 1
fi
echo ""

# Step 7: Test code quality tools
echo "Step 7: Testing code quality tools..."

echo "  Testing flake8..."
if flake8 warp/ --max-line-length=127 --extend-ignore=E203 --count --statistics --quiet; then
    echo -e "  ${GREEN}✓ flake8 passed${NC}"
else
    echo -e "  ${YELLOW}⚠ flake8 found issues (non-blocking)${NC}"
fi

echo "  Testing black formatting check..."
if black warp/ tests/ --line-length 127 --check --quiet; then
    echo -e "  ${GREEN}✓ black formatting check passed${NC}"
else
    echo -e "  ${YELLOW}⚠ black formatting issues found (non-blocking)${NC}"
fi

echo "  Testing mypy..."
if mypy warp/ --ignore-missing-imports --quiet 2>/dev/null; then
    echo -e "  ${GREEN}✓ mypy passed${NC}"
else
    echo -e "  ${YELLOW}⚠ mypy found issues (non-blocking)${NC}"
fi
echo ""

# Step 8: Test basic functionality
echo "Step 8: Testing basic functionality..."
python -c "
from warp.core.omop_to_ccda import OMOPToCCDAConverter
import tempfile
import os

# Test converter initialization
temp_dir = tempfile.mkdtemp()
try:
    converter = OMOPToCCDAConverter(data_source=temp_dir, dataset_size='1k')
    print('✓ OMOPToCCDAConverter initialized')
    
    # Test gender mapping
    assert converter._map_gender(8507) == 'M'
    assert converter._map_gender(8532) == 'F'
    print('✓ Gender mapping works')
finally:
    os.rmdir(temp_dir)
" || {
    echo -e "${RED}ERROR: Basic functionality test failed${NC}"
    exit 1
}
echo -e "${GREEN}✓ Basic functionality works${NC}"
echo ""

# Summary
echo "=============================================================================="
echo -e "${GREEN}All tests passed!${NC}"
echo "=============================================================================="
echo ""
echo "Pinned versions are compatible with:"
echo "  ✓ Python $PYTHON_VERSION"
echo "  ✓ Warp package imports"
echo "  ✓ Unit tests"
echo "  ✓ Code quality tools"
echo "  ✓ Basic functionality"
echo ""
echo "Versions tested match versions.yaml:"
echo "  ✓ All package versions verified"
echo ""
# Compare only major.minor versions for summary
PYTHON_VERSION_NORMALIZED=$(normalize_python_version "$PYTHON_VERSION")
PYTHON_REQUIRED_NORMALIZED=$(normalize_python_version "$PYTHON_VERSION_REQUIRED")
if [ "$PYTHON_VERSION_NORMALIZED" != "$PYTHON_REQUIRED_NORMALIZED" ]; then
    echo "=============================================================================="
    echo "For production compatibility testing with Python $PYTHON_VERSION_REQUIRED:"
    echo "=============================================================================="
    echo ""
    echo "Test using Docker (matches production environment):"
    echo "  docker run --rm -v \$(pwd):/app -w /app python:$PYTHON_VERSION_REQUIRED-slim bash -c \\"
    echo "    'pip install -r requirements.txt && pip install -e . && pytest tests/ -v'"
    echo ""
fi

