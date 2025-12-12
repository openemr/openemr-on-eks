# =============================================================================
# OpenEMR on EKS Console Launcher (Windows PowerShell)
# =============================================================================
#
# Purpose:
#   Launches the OpenEMR on EKS TUI console application on Windows
#
# Usage:
#   .\start_console.ps1
#
# =============================================================================

# Get the directory where this script is located
# Use $PSScriptRoot which is automatically set by PowerShell to the script's directory
# $PSScriptRoot is already an absolute path
if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
} else {
    # Fallback for older PowerShell versions (PowerShell 2.0)
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    # Convert to absolute path
    $ScriptDir = (Resolve-Path $ScriptDir).Path
}
$ConsoleDir = Join-Path $ScriptDir "console"

# Check if console directory exists
if (-not (Test-Path $ConsoleDir)) {
    Write-Host "Error: Console directory not found at $ConsoleDir" -ForegroundColor Red
    exit 1
}

# Check if Go is installed
$goCommand = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCommand) {
    Write-Host "Error: Go is not installed. Please install Go to use the console." -ForegroundColor Red
    Write-Host "Visit: https://golang.org/dl/" -ForegroundColor Yellow
    exit 1
}

# Check Go version (requires 1.25 or later)
$goVersionOutput = go version
$goVersionMatch = $goVersionOutput -match 'go(\d+)\.(\d+)'
if ($goVersionMatch) {
    $majorVersion = [int]$matches[1]
    $minorVersion = [int]$matches[2]
    
    if ($majorVersion -lt 1 -or ($majorVersion -eq 1 -and $minorVersion -lt 25)) {
        Write-Host "Error: Go version $($matches[0]) is installed, but version 1.25 or later is required." -ForegroundColor Red
        Write-Host "Please upgrade Go: https://golang.org/dl/" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "Warning: Could not parse Go version. Continuing anyway..." -ForegroundColor Yellow
}

# Change to console directory
Set-Location $ConsoleDir

# Check if go.mod exists, if not initialize
if (-not (Test-Path "go.mod")) {
    Write-Host "Initializing Go module..."
    go mod init github.com/openemr/openemr-on-eks/console 2>$null
}

# Download dependencies
Write-Host "Downloading dependencies..."
go mod download 2>$null
go mod tidy 2>$null

# Get the project root directory
# The script is in the project root, so $ScriptDir IS the project root
$ProjectRoot = $ScriptDir

# Build the console
Write-Host "Building console..."
$buildCommand = "go build -ldflags `"-X main.embeddedProjectRoot=$ProjectRoot`" -o openemr-eks-console.exe main.go"
Invoke-Expression $buildCommand

if ($LASTEXITCODE -eq 0) {
    # Run the console
    .\openemr-eks-console.exe
} else {
    Write-Host ""
    Write-Host "Error: Failed to build console application" -ForegroundColor Red
    Write-Host "Please check the error messages above and ensure:" -ForegroundColor Yellow
    Write-Host "  - Go 1.25 or later is installed" -ForegroundColor Yellow
    Write-Host "  - All dependencies are available" -ForegroundColor Yellow
    Write-Host "  - The code compiles without errors" -ForegroundColor Yellow
    exit 1
}

