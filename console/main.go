// Package main implements a Terminal User Interface (TUI) console for managing
// OpenEMR on EKS deployments. The console provides an interactive menu for
// executing deployment scripts, validating infrastructure, and managing backups.
//
// Platform Support:
//   - macOS: Uses osascript to open new Terminal windows
//   - Windows: Uses PowerShell to open new PowerShell windows with bash script execution
//   - Linux: Not supported
//
// The console detects the project root directory at startup using:
//   1. OPENEMR_EKS_PROJECT_ROOT environment variable (highest priority, allows override)
//   2. Embedded project root path (set at build time via -ldflags)
//
// If the project is moved after building, users can set the environment variable
// to point to the new location without rebuilding.
package main

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// embeddedProjectRoot is set at build time using -ldflags during compilation.
// This allows the binary to remember where it was built from, enabling it to
// locate project scripts and resources even when run from a different directory.
//
// Example build command:
//   go build -ldflags "-X main.embeddedProjectRoot=$PWD" -o openemr-eks-console
//
// Users can override this at runtime by setting the OPENEMR_EKS_PROJECT_ROOT
// environment variable, which takes precedence over the embedded path.
var embeddedProjectRoot string

// TUI styling definitions using lipgloss for consistent terminal UI appearance.
// These styles are applied globally throughout the console interface.
var (
	// titleStyle: Bold magenta text with rounded border for the main title
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("205")).
			Padding(1, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("205"))

	// itemStyle: Light gray text for unselected menu items
	itemStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("252")).
			PaddingLeft(2)

	// selectedStyle: Bold magenta text with dark gray background for selected menu items
	selectedStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("205")).
			Bold(true).
			PaddingLeft(2).
			Background(lipgloss.Color("236"))

	// descStyle: Dim gray italic text for command descriptions
	descStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("243")).
			PaddingLeft(4).
			Italic(true)

	// scriptStyle: Very dim gray text for script path display
	scriptStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("240")).
			PaddingLeft(4).
			Faint(true)

	// helpStyle: Dim gray text for help/instruction text at the bottom
	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241")).
			PaddingTop(1)
)

// command represents a single executable command in the console menu.
// Each command has a display title, description, script path, and optional arguments.
type command struct {
	title       string   // Display name shown in the menu
	description string   // Help text explaining what the command does
	script      string   // Full path to the bash script to execute
	args        []string // Command-line arguments to pass to the script
}

// model represents the application state for the Bubbletea TUI framework.
// It follows the Model-Update-View pattern where:
//   - model holds the current state
//   - Update() processes messages/events and returns new state
//   - View() renders the current state to the terminal
type model struct {
	commands    []command // List of available commands to display
	cursor      int       // Current cursor position in the menu (0-indexed)
	selected    int       // Index of the command currently being executed
	quitting    bool      // Flag indicating the user wants to exit
	executing   bool      // Flag indicating a command is currently running
	output      string    // Success output message from command execution
	error       string    // Error message from command execution
	projectRoot string    // Resolved project root directory path
}

// verifyProjectStructure validates that a directory contains all required
// project subdirectories. This is used to confirm that a path is actually
// the OpenEMR on EKS project root, not just any directory.
//
// Required directories:
//   - scripts/: Contains deployment and management bash scripts
//   - terraform/: Contains Terraform infrastructure definitions
//   - k8s/: Contains Kubernetes manifests and configurations
//
// Returns true if all required directories exist, false otherwise.
func verifyProjectStructure(rootPath string) bool {
	requiredDirs := []string{"scripts", "terraform", "k8s"}
	for _, dir := range requiredDirs {
		dirPath := filepath.Join(rootPath, dir)
		if _, err := os.Stat(dirPath); os.IsNotExist(err) {
			return false
		}
	}
	return true
}

// convertWindowsPathToUnix converts a Windows path to Unix-style path for bash
// Uses Git Bash format: C:\Users\name\file.sh -> /c/Users/name/file.sh
// Note: WSL uses /mnt/c/ format, but we'll let WSL handle conversion via wslpath if needed
func convertWindowsPathToUnix(windowsPath string) string {
	// Convert to absolute path first
	absPath, err := filepath.Abs(windowsPath)
	if err != nil {
		// If conversion fails, just use the original path with forward slashes
		return strings.ReplaceAll(windowsPath, "\\", "/")
	}
	
	// Replace backslashes with forward slashes
	unixPath := strings.ReplaceAll(absPath, "\\", "/")
	
	// Convert drive letter to Git Bash format (C: -> /c)
	if len(unixPath) >= 2 && unixPath[1] == ':' {
		drive := strings.ToLower(string(unixPath[0]))
		unixPath = "/" + drive + unixPath[2:]
	}
	
	return unixPath
}

// initialModel initializes the TUI application model with project root detection
// and command definitions. This function is called once at application startup.
//
// Project Root Detection Strategy (in priority order):
//   1. OPENEMR_EKS_PROJECT_ROOT environment variable (highest priority)
//      - Allows users to override the embedded path if the project was moved
//      - Useful when the binary was built in one location but the project moved
//   2. Embedded project root (set at build time via -ldflags)
//      - Automatically embedded during compilation by start_console.ps1 (Windows)
//      - or Makefile (macOS)
//   3. If neither is valid, the application exits with detailed error messages
//
// The function validates that the detected project root contains all required
// subdirectories (scripts/, terraform/, k8s/) before proceeding.
//
// Returns a fully initialized model ready for the TUI, or exits the program
// if project root cannot be determined.
func initialModel() model {
	var projectRoot string
	var validationErrors []string

	// Priority 1: Check environment variable (allows override if project was moved)
	// This takes precedence over the embedded path to support relocating the project
	if envRoot := os.Getenv("OPENEMR_EKS_PROJECT_ROOT"); envRoot != "" {
		// Verify it has all required project directories
		if verifyProjectStructure(envRoot) {
			projectRoot = envRoot
		} else {
			// Collect missing directories for detailed error reporting
			// This helps users understand what's wrong with their path
			requiredDirs := []string{"scripts", "terraform", "k8s"}
			for _, dir := range requiredDirs {
				if _, err := os.Stat(filepath.Join(envRoot, dir)); os.IsNotExist(err) {
					validationErrors = append(validationErrors, fmt.Sprintf("OPENEMR_EKS_PROJECT_ROOT: missing '%s' directory", dir))
				}
			}
		}
	}

	// Priority 2: Use embedded path (set during build/install)
	// Only check this if environment variable wasn't set or wasn't valid
	if projectRoot == "" && embeddedProjectRoot != "" {
		// Verify it has all required project directories
		if verifyProjectStructure(embeddedProjectRoot) {
			projectRoot = embeddedProjectRoot
		} else {
			// Collect missing directories for detailed error reporting
			requiredDirs := []string{"scripts", "terraform", "k8s"}
			for _, dir := range requiredDirs {
				if _, err := os.Stat(filepath.Join(embeddedProjectRoot, dir)); os.IsNotExist(err) {
					validationErrors = append(validationErrors, fmt.Sprintf("Embedded path: missing '%s' directory", dir))
				}
			}
		}
	}

	// If no valid project root found, exit with detailed error messages
	// Provide platform-specific instructions to help users resolve the issue
	if projectRoot == "" {
		fmt.Fprintf(os.Stderr, "❌ Error: Project root not found or invalid\n\n")
		
		// Report embedded path status and issues
		if embeddedProjectRoot != "" {
			fmt.Fprintf(os.Stderr, "Embedded project root: %s\n", embeddedProjectRoot)
			if _, err := os.Stat(embeddedProjectRoot); os.IsNotExist(err) {
				fmt.Fprintf(os.Stderr, "  → Directory does not exist\n")
			} else {
				// Report all missing directories from embedded path validation
				for _, errMsg := range validationErrors {
					if strings.HasPrefix(errMsg, "Embedded path:") {
						fmt.Fprintf(os.Stderr, "  → %s\n", strings.TrimPrefix(errMsg, "Embedded path: "))
					}
				}
			}
		} else {
			fmt.Fprintf(os.Stderr, "No embedded project root found (binary was not built with -ldflags)\n")
		}

		// Report environment variable validation errors if any
		if len(validationErrors) > 0 {
			for _, errMsg := range validationErrors {
				if strings.HasPrefix(errMsg, "OPENEMR_EKS_PROJECT_ROOT:") {
					fmt.Fprintf(os.Stderr, "  → %s\n", strings.TrimPrefix(errMsg, "OPENEMR_EKS_PROJECT_ROOT: "))
				}
			}
		}

		// Provide platform-specific solutions
		fmt.Fprintf(os.Stderr, "\nRequired directories: scripts/, terraform/, k8s/\n")
		fmt.Fprintf(os.Stderr, "\nSolutions:\n")
		fmt.Fprintf(os.Stderr, "1. If you moved the project, set OPENEMR_EKS_PROJECT_ROOT:\n")
		if runtime.GOOS == "windows" {
			fmt.Fprintf(os.Stderr, "   $env:OPENEMR_EKS_PROJECT_ROOT=\"C:\\path\\to\\openemr-on-eks\"\n")
			fmt.Fprintf(os.Stderr, "2. Rebuild the console from the correct project location:\n")
			fmt.Fprintf(os.Stderr, "   cd C:\\path\\to\\openemr-on-eks\n")
			fmt.Fprintf(os.Stderr, "   .\\start_console.ps1\n\n")
		} else {
			fmt.Fprintf(os.Stderr, "   export OPENEMR_EKS_PROJECT_ROOT=/path/to/openemr-on-eks\n")
			fmt.Fprintf(os.Stderr, "2. Reinstall the console from the correct project location:\n")
			fmt.Fprintf(os.Stderr, "   cd /path/to/openemr-on-eks/console && make install\n\n")
		}
		os.Exit(1)
	}

	// Build the path to the scripts directory for command definitions
	scriptsPath := filepath.Join(projectRoot, "scripts")

	// Initialize and return the model with all available commands
	// Each command represents a script that can be executed from the TUI menu
	return model{
		projectRoot: projectRoot,
		commands: []command{
			{
				title:       "Validate Prerequisites",
				description: "Check required tools, AWS credentials, and deployment readiness",
				script:      filepath.Join(scriptsPath, "validate-deployment.sh"),
				args:        []string{},
			},
			{
				title:       "Quick Deploy",
				description: "Deploy infrastructure, OpenEMR, and monitoring stack in one command",
				script:      filepath.Join(scriptsPath, "quick-deploy.sh"),
				args:        []string{},
			},
			{
				title:       "Check Deployment Health",
				description: "Validate current deployment status and infrastructure health",
				script:      filepath.Join(scriptsPath, "validate-deployment.sh"),
				args:        []string{},
			},
			{
				title:       "Backup Deployment",
				description: "Create comprehensive backup of RDS, Kubernetes configs, and application data",
				script:      filepath.Join(scriptsPath, "backup.sh"),
				args:        []string{},
			},
			{
				title:       "Clean Deployment",
				description: "Remove application layer while preserving infrastructure",
				script:      filepath.Join(scriptsPath, "clean-deployment.sh"),
				args:        []string{},
			},
			{
				title:       "Destroy Infrastructure",
				description: "Completely destroy all infrastructure resources (use with caution)",
				script:      filepath.Join(scriptsPath, "destroy.sh"),
				args:        []string{},
			},
			{
				title:       "Check Component Versions",
				description: "Check for available updates across all project components",
				script:      filepath.Join(scriptsPath, "version-manager.sh"),
				args:        []string{"check"},
			},
			{
				title:       "Check OpenEMR Versions",
				description: "Discover available OpenEMR Docker image versions from Docker Hub",
				script:      filepath.Join(scriptsPath, "check-openemr-versions.sh"),
				args:        []string{},
			},
			{
				title:       "Search Codebase",
				description: "Search for terms across the entire codebase (interactive)",
				script:      filepath.Join(scriptsPath, "search-codebase.sh"),
				args:        []string{},
			},
			{
				title:       "Deploy Training Setup",
				description: "Deploy OpenEMR with synthetic patient data for training/testing",
				script:      filepath.Join(scriptsPath, "deploy-training-openemr-setup.sh"),
				args:        []string{"--use-default-dataset", "--max-records", "100"},
			},
		},
	}
}

// Init is called by Bubbletea when the program starts.
// We don't need any initial commands, so we return nil.
func (m model) Init() tea.Cmd {
	return nil
}

// Update processes messages/events and updates the model state accordingly.
// This is the core of the Bubbletea Model-Update-View pattern.
//
// Message handling order:
//   1. Command execution results (outputMsg, errorMsg) - handled first
//   2. User input during command execution (only quit keys allowed)
//   3. User input in menu mode (navigation and selection)
//
// Returns the updated model and any commands to run (for async operations).
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// Handle command execution results first (these come from async operations)
	switch msg := msg.(type) {
	case outputMsg:
		m.output = string(msg)
		m.executing = false
		// Force a refresh by returning a command that does nothing
		// This ensures the View() function is called to display the result
		return m, tea.Batch()
	case errorMsg:
		m.error = string(msg)
		m.executing = false
		// Force a refresh to display the error message
		return m, tea.Batch()
	}

	// If a command is currently executing, only allow quit operations
	// This prevents users from navigating away while a command is running
	if m.executing {
		switch msg := msg.(type) {
		case tea.KeyMsg:
			// Allow user to cancel/return from execution view
			if msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyEsc || msg.Type == tea.KeyEnter {
				m.executing = false
				m.output = ""
				m.error = ""
				return m, nil
			}
		}
		return m, nil
	}

	// Handle user input in menu mode
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC, tea.KeyEsc:
			// Quit the application
			m.quitting = true
			return m, tea.Quit

		case tea.KeyUp:
			// Navigate up in the menu (with wrap-around)
			if m.cursor > 0 {
				m.cursor--
			} else {
				m.cursor = len(m.commands) - 1
			}

		case tea.KeyDown:
			// Navigate down in the menu (with wrap-around)
			if m.cursor < len(m.commands)-1 {
				m.cursor++
			} else {
				m.cursor = 0
			}

		case tea.KeyEnter:
			// Execute the selected command
			m.selected = m.cursor
			m.executing = true
			m.output = ""
			m.error = ""
			// executeCommand returns a tea.Cmd that will send a message when done
			return m, m.executeCommand(m.commands[m.cursor])
		}
	}

	return m, nil
}

// executeCommand launches a bash script in a new terminal window.
// The implementation differs significantly between platforms:
//
// macOS:
//   - Uses osascript to open a new Terminal.app window
//   - Executes the bash script directly in the terminal
//
// Windows:
//   - Uses PowerShell Start-Process to open a new PowerShell window
//   - Generates a temporary PowerShell script that:
//     1. Detects available bash (Git Bash, WSL, or system bash)
//     2. Converts Windows paths to appropriate format for the detected bash
//     3. Executes the bash script with proper error handling
//     4. Keeps the window open even on errors for debugging
//
// The function returns a tea.Cmd that will send an outputMsg or errorMsg
// when the command execution is initiated (not when it completes, since
// execution happens in a separate terminal window).
func (m model) executeCommand(cmd command) tea.Cmd {
	return func() tea.Msg {
		// Validate that the script file exists before attempting execution
		if _, err := os.Stat(cmd.script); os.IsNotExist(err) {
			msg := fmt.Sprintf("Script not found: %s\n\n", cmd.script)
			if embeddedProjectRoot != "" {
				msg += fmt.Sprintf("Embedded project root: %s\n", embeddedProjectRoot)
			}
			msg += "Possible solutions:\n"
			msg += "1. If you moved the project, set OPENEMR_EKS_PROJECT_ROOT environment variable:\n"
			msg += "   export OPENEMR_EKS_PROJECT_ROOT=/path/to/openemr-on-eks\n"
			msg += "2. Run the console from the project root directory\n"
			msg += "3. Reinstall the console from the correct project location"
			return errorMsg(msg)
		}

		// Ensure the script has execute permissions (important for Unix-like systems)
		// On Windows, this is a no-op but doesn't hurt
		os.Chmod(cmd.script, 0755)

		// Prepare script path, arguments, and working directory
		scriptPath := cmd.script
		scriptArgs := strings.Join(cmd.args, " ")
		workingDir := filepath.Dir(cmd.script)

		// Platform-specific execution: open command in a new terminal window
		if runtime.GOOS == "darwin" {
			// macOS: Use osascript to open a new Terminal.app window
			// osascript allows us to programmatically control Terminal.app
			// and execute commands in new windows.
			//
			// We escape single quotes by replacing them with: '"\''"'
			// This is the standard shell escaping technique for single quotes
			escapedScriptPath := strings.ReplaceAll(scriptPath, "'", "'\"'\"'")
			escapedArgs := strings.ReplaceAll(scriptArgs, "'", "'\"'\"'")
			escapedWorkingDir := strings.ReplaceAll(workingDir, "'", "'\"'\"'")

			// Build the command string that will be executed in the new terminal
			// The command changes directory, runs the script, then waits for user input
			command := fmt.Sprintf("cd '%s' && '%s' %s; echo ''; echo 'Press any key and then return to go back to the command line'; read -n 1", escapedWorkingDir, escapedScriptPath, escapedArgs)
			
			// Use osascript to tell Terminal.app to execute the command in a new window
			execCmd := exec.Command("osascript", "-e", fmt.Sprintf(`tell application "Terminal" to do script "%s"`, command))

			// Execute the command to open terminal
			if err := execCmd.Run(); err != nil {
				return errorMsg(fmt.Sprintf("Failed to open terminal window: %s", err.Error()))
			}
		} else if runtime.GOOS == "windows" {
			// Windows: Use PowerShell Start-Process to open a new PowerShell window
			// 
			// Windows execution is complex because:
			// 1. We need to detect which bash is available (Git Bash, WSL, or system bash)
			// 2. Each bash variant requires different path formats:
			//    - Git Bash: /c/Users/... (Unix-style with drive letter conversion)
			//    - WSL: /mnt/c/Users/... (uses wslpath for conversion)
			//    - System bash: Depends on installation, usually Unix-style
			// 3. PowerShell commands (like Set-Location) need Windows paths
			// 4. We generate a temporary PowerShell script to avoid complex escaping issues
			//
			// Path conversion strategy:
			// - Convert to Unix-style for Git Bash and system bash
			// - Keep Windows-style for WSL (WSL will convert via wslpath)
			// - Keep original Windows path for PowerShell Set-Location cmdlet
			
			// Convert Windows paths to Unix-style paths for Git Bash
			scriptPathUnix := convertWindowsPathToUnix(scriptPath)
			workingDirUnix := convertWindowsPathToUnix(workingDir)
			
			// Keep Windows paths with forward slashes for WSL (WSL prefers / over \)
			scriptPathWin := strings.ReplaceAll(scriptPath, "\\", "/")
			workingDirWin := strings.ReplaceAll(workingDir, "\\", "/")
			
			// Keep the original Windows path with backslashes for PowerShell Set-Location
			// PowerShell's Set-Location cmdlet expects Windows paths, not Unix-style paths
			workingDirWinPS := workingDir
			
			// Escape single quotes for PowerShell (PowerShell uses '' to escape single quotes)
			// This is different from bash which uses '\'' for escaping
			escapedScriptPathUnix := strings.ReplaceAll(scriptPathUnix, "'", "''")
			escapedScriptPathWin := strings.ReplaceAll(scriptPathWin, "'", "''")
			escapedArgs := strings.ReplaceAll(scriptArgs, "'", "''")
			escapedWorkingDirUnix := strings.ReplaceAll(workingDirUnix, "'", "''")
			escapedWorkingDirWin := strings.ReplaceAll(workingDirWin, "'", "''")
			escapedWorkingDirWinPS := strings.ReplaceAll(workingDirWinPS, "'", "''")

			// Build PowerShell script that will be written to a temporary file
			// We use bytes.Buffer instead of string concatenation for:
			// 1. Better performance with many string operations
			// 2. Explicit control over newlines (\r\n for Windows)
			// 3. Cleaner code structure
			//
			// The script structure:
			// 1. Set error handling and window title
			// 2. Display header information
			// 3. Try block: Detect bash and execute script
			// 4. Catch block: Display detailed error information
			// 5. Finally block: Keep window open for user to read output
			var scriptBuf bytes.Buffer
			
			// Set error handling: Continue on errors so we can catch and display them
			scriptBuf.WriteString("$ErrorActionPreference = 'Continue'\r\n")
			
			// Set window title for easy identification
			scriptBuf.WriteString("$Host.UI.RawUI.WindowTitle = 'OpenEMR EKS Console - Script Execution'\r\n")
			
			// Display header with colored output
			scriptBuf.WriteString("Write-Host 'OpenEMR EKS Console - Script Execution' -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("Write-Host '========================================' -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("Write-Host ''\r\n")
			
			// Begin try-catch-finally block for error handling
			scriptBuf.WriteString("try {\r\n")
			// Set up path variables that will be used by the bash detection logic
			scriptBuf.WriteString(fmt.Sprintf("  $workingDirUnix = '%s'\r\n", escapedWorkingDirUnix))
			scriptBuf.WriteString(fmt.Sprintf("  $scriptPathUnix = '%s'\r\n", escapedScriptPathUnix))
			scriptBuf.WriteString(fmt.Sprintf("  $scriptArgs = '%s'\r\n", escapedArgs))
			
			// Initialize variables that will be set during bash detection
			scriptBuf.WriteString("  $bashCmd = $null\r\n")
			scriptBuf.WriteString("  $finalScriptPath = $null\r\n")
			scriptBuf.WriteString("  $finalWorkingDir = $null\r\n")
			scriptBuf.WriteString("  $finalWorkingDirPS = $null\r\n")
			
			scriptBuf.WriteString("  Write-Host 'Looking for bash...' -ForegroundColor Cyan\r\n")
			
			// Bash detection strategy (in priority order):
			// 1. Git Bash - Most common on Windows, uses /c/ path format
			// 2. WSL - Windows Subsystem for Linux, uses /mnt/c/ path format
			// 3. System bash - Any bash in PATH (less common)
			//
			// We try Git Bash first because it's the most common installation
			scriptBuf.WriteString("  # Try Git Bash first\r\n")
			// Common Git Bash installation paths (check all to handle different install locations)
			scriptBuf.WriteString("  $gitBashPaths = @('C:\\Program Files\\Git\\bin\\bash.exe', 'C:\\Program Files (x86)\\Git\\bin\\bash.exe', \"$env:LOCALAPPDATA\\Programs\\Git\\bin\\bash.exe\")\r\n")
			// Check each Git Bash path until we find one that exists
			scriptBuf.WriteString("  Write-Host 'Checking Git Bash locations...' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("  foreach ($path in $gitBashPaths) {\r\n")
			scriptBuf.WriteString("    Write-Host \"  Checking: $path\" -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    if (Test-Path $path) {\r\n")
			// Git Bash found: use Unix-style paths (already converted)
			scriptBuf.WriteString("      $bashCmd = $path\r\n")
			scriptBuf.WriteString(fmt.Sprintf("      $finalScriptPath = '%s'\r\n", escapedScriptPathUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDir = '%s'\r\n", escapedWorkingDirUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDirPS = '%s'\r\n", escapedWorkingDirWinPS))
			scriptBuf.WriteString("      Write-Host \"Found Git Bash at: $path\" -ForegroundColor Green\r\n")
			scriptBuf.WriteString("      break\r\n")
			scriptBuf.WriteString("    }\r\n")
			scriptBuf.WriteString("  }\r\n")
			
			// If Git Bash not found, try WSL (Windows Subsystem for Linux)
			// WSL requires different path handling: we use wslpath to convert Windows paths
			scriptBuf.WriteString("  # Try WSL bash\r\n")
			scriptBuf.WriteString("  if (-not $bashCmd) {\r\n")
			scriptBuf.WriteString("    Write-Host 'Checking for WSL...' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue\r\n")
			scriptBuf.WriteString("    if ($wslCmd) {\r\n")
			scriptBuf.WriteString("      Write-Host 'WSL found, converting paths...' -ForegroundColor Cyan\r\n")
			// WSL path conversion: use Windows paths (with forward slashes) and let wslpath convert them
			scriptBuf.WriteString(fmt.Sprintf("      $scriptPathWin = '%s'\r\n", escapedScriptPathWin))
			scriptBuf.WriteString(fmt.Sprintf("      $workingDirWin = '%s'\r\n", escapedWorkingDirWin))
			// Use wslpath -a to convert Windows absolute path to WSL path format
			// This handles the /mnt/c/ conversion automatically
			scriptBuf.WriteString("      $wslScriptPath = (wsl wslpath -a $scriptPathWin 2>$null).Trim()\r\n")
			scriptBuf.WriteString("      $wslWorkingDir = (wsl wslpath -a $workingDirWin 2>$null).Trim()\r\n")
			scriptBuf.WriteString("      if ($wslScriptPath -and $wslWorkingDir) {\r\n")
			// WSL found and paths converted successfully
			scriptBuf.WriteString("        $bashCmd = 'wsl'\r\n")
			scriptBuf.WriteString("        $finalScriptPath = $wslScriptPath\r\n")
			scriptBuf.WriteString("        $finalWorkingDir = $wslWorkingDir\r\n")
			scriptBuf.WriteString(fmt.Sprintf("        $finalWorkingDirPS = '%s'\r\n", escapedWorkingDirWinPS))
			scriptBuf.WriteString("        Write-Host \"Using WSL with path: $finalScriptPath\" -ForegroundColor Green\r\n")
			scriptBuf.WriteString("      } else {\r\n")
			scriptBuf.WriteString("        Write-Host 'WSL path conversion failed' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("      }\r\n")
			scriptBuf.WriteString("    } else {\r\n")
			scriptBuf.WriteString("      Write-Host 'WSL not found' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    }\r\n")
			scriptBuf.WriteString("  }\r\n")
			
			// Last resort: check for any bash in the system PATH
			// This is less common but some users may have bash installed elsewhere
			scriptBuf.WriteString("  # Try system bash\r\n")
			scriptBuf.WriteString("  if (-not $bashCmd) {\r\n")
			scriptBuf.WriteString("    Write-Host 'Checking for system bash in PATH...' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    $sysBash = Get-Command bash -ErrorAction SilentlyContinue\r\n")
			scriptBuf.WriteString("    if ($sysBash) {\r\n")
			// System bash found: assume it uses Unix-style paths (like Git Bash)
			scriptBuf.WriteString("      $bashCmd = 'bash'\r\n")
			scriptBuf.WriteString(fmt.Sprintf("      $finalScriptPath = '%s'\r\n", escapedScriptPathUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDir = '%s'\r\n", escapedWorkingDirUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDirPS = '%s'\r\n", escapedWorkingDirWinPS))
			scriptBuf.WriteString("      Write-Host \"Found system bash at: $($sysBash.Source)\" -ForegroundColor Green\r\n")
			scriptBuf.WriteString("    } else {\r\n")
			scriptBuf.WriteString("      Write-Host 'System bash not found in PATH' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    }\r\n")
			scriptBuf.WriteString("  }\r\n")
			// Execute the script if bash was found
			scriptBuf.WriteString("  if ($bashCmd) {\r\n")
			scriptBuf.WriteString("    try {\r\n")
			// Set-Location requires Windows paths (with backslashes), not Unix-style paths
			// This is why we maintain $finalWorkingDirPS separately
			scriptBuf.WriteString("      # Use Windows path for PowerShell Set-Location\r\n")
			scriptBuf.WriteString("      Set-Location $finalWorkingDirPS\r\n")
			scriptBuf.WriteString("      Write-Host \"Working directory: $finalWorkingDir\" -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("      Write-Host \"Executing: $finalScriptPath $scriptArgs\" -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("      Write-Host ''\r\n")
			
			// WSL requires special handling: we need to pass the entire command as a string
			// to bash -c, with proper escaping of quotes within the command
			scriptBuf.WriteString("      if ($bashCmd -eq 'wsl') {\r\n")
			scriptBuf.WriteString("        # For WSL, properly escape the command\r\n")
			scriptBuf.WriteString("        # Use backticks (`) to escape quotes within the double-quoted string\r\n")
			scriptBuf.WriteString("        $escapedCmd = \"cd `\"$finalWorkingDir`\" && bash `\"$finalScriptPath`\" $scriptArgs\"\r\n")
			scriptBuf.WriteString("        wsl bash -c $escapedCmd\r\n")
			scriptBuf.WriteString("      } else {\r\n")
			// Git Bash and system bash can accept the script path and arguments separately
			// This is simpler and avoids complex escaping issues
			scriptBuf.WriteString("        # For Git Bash or system bash, pass script path and args separately\r\n")
			scriptBuf.WriteString("        if ($scriptArgs) {\r\n")
			scriptBuf.WriteString("          $argArray = $scriptArgs -split ' '\r\n")
			scriptBuf.WriteString("          & $bashCmd $finalScriptPath $argArray\r\n")
			scriptBuf.WriteString("        } else {\r\n")
			scriptBuf.WriteString("          & $bashCmd $finalScriptPath\r\n")
			scriptBuf.WriteString("        }\r\n")
			scriptBuf.WriteString("      }\r\n")
			
			// Check exit code and display warning if script failed
			// Note: We don't treat non-zero exit codes as errors here because
			// the script itself may have valid reasons to exit with non-zero (e.g., validation failures)
			scriptBuf.WriteString("      if ($LASTEXITCODE -ne 0) {\r\n")
			scriptBuf.WriteString("        Write-Host ''\r\n")
			scriptBuf.WriteString("        Write-Host \"Script exited with code $LASTEXITCODE\" -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("      }\r\n")
			scriptBuf.WriteString("    } catch {\r\n")
			// Catch block: Display detailed error information for debugging
			// This helps users understand what went wrong
			scriptBuf.WriteString("      Write-Host ''\r\n")
			scriptBuf.WriteString("      Write-Host \"Error executing script: $_\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Bash command: $bashCmd\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Script path: $finalScriptPath\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Working dir: $finalWorkingDir\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Script args: $scriptArgs\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("    }\r\n")
			scriptBuf.WriteString("  } else {\r\n")
			// No bash found: provide helpful installation instructions
			scriptBuf.WriteString("    Write-Host 'Error: bash not found.' -ForegroundColor Red\r\n")
			scriptBuf.WriteString("    Write-Host ''\r\n")
			scriptBuf.WriteString("    Write-Host 'Please install one of the following:' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("    Write-Host '  1. Git Bash: https://git-scm.com/download/win' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("    Write-Host '  2. WSL (Windows Subsystem for Linux)' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("  }\r\n")
			// Outer catch block: Handle any unexpected errors in the PowerShell script itself
			scriptBuf.WriteString("} catch {\r\n")
			scriptBuf.WriteString("  Write-Host ''\r\n")
			scriptBuf.WriteString("  Write-Host 'Unexpected error occurred:' -ForegroundColor Red\r\n")
			scriptBuf.WriteString("  Write-Host $_.Exception.Message -ForegroundColor Red\r\n")
			scriptBuf.WriteString("  Write-Host $_.ScriptStackTrace -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("} finally {\r\n")
			// Finally block: Always keep the window open so users can read output/errors
			// This is critical for debugging - we want to see what happened even if there's an error
			scriptBuf.WriteString("  Write-Host ''\r\n")
			scriptBuf.WriteString("  Write-Host 'Press any key to close this window...' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("  try {\r\n")
			// ReadKey waits for user input before closing
			scriptBuf.WriteString("    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')\r\n")
			scriptBuf.WriteString("  } catch {\r\n")
			// Fallback: If ReadKey fails (e.g., in some terminal environments), wait 5 seconds
			// This gives users time to read the output before the window closes
			scriptBuf.WriteString("    # If ReadKey fails, wait a bit then exit\r\n")
			scriptBuf.WriteString("    Start-Sleep -Seconds 5\r\n")
			scriptBuf.WriteString("  }\r\n")
			scriptBuf.WriteString("}\r\n")
			powershellScript := scriptBuf.String()

			// Create a temporary PowerShell script file to avoid complex escaping issues
			// Why use a temp file instead of inline execution?
			// 1. Avoids PowerShell's complex quote escaping rules
			// 2. More reliable than base64 encoding (which has encoding issues)
			// 3. Easier to debug (users can inspect the generated script)
			// 4. Handles multi-line scripts cleanly
			tmpScript, err := ioutil.TempFile("", "openemr-console-*.ps1")
			if err != nil {
				return errorMsg(fmt.Sprintf("Failed to create temporary script: %s", err.Error()))
			}
			// Note: We intentionally don't delete the temp file immediately
			// The file will be cleaned up by Windows temp file cleanup (typically on reboot)
			// This is acceptable because:
			// 1. Temp files are small (a few KB)
			// 2. Windows handles cleanup automatically
			// 3. Immediate deletion could cause issues if PowerShell is still reading it
			
			// Write UTF-8 BOM (Byte Order Mark) for PowerShell compatibility
			// PowerShell requires BOM to properly detect UTF-8 encoding
			// Without BOM, PowerShell may misinterpret special characters
			bom := []byte{0xEF, 0xBB, 0xBF}
			if _, err := tmpScript.Write(bom); err != nil {
				tmpScript.Close()
				return errorMsg(fmt.Sprintf("Failed to write BOM: %s", err.Error()))
			}
			// Write the actual script content
			if _, err := tmpScript.WriteString(powershellScript); err != nil {
				tmpScript.Close()
				return errorMsg(fmt.Sprintf("Failed to write temporary script: %s", err.Error()))
			}
			tmpScript.Close()
			
			// Launch PowerShell in a new window with the temporary script
			// Arguments:
			//   -NoExit: Keep the window open after script execution (handled by our script's ReadKey)
			//   -ExecutionPolicy Bypass: Skip execution policy checks (needed for temp scripts)
			//   -File: Execute the script file
			scriptPath := strings.ReplaceAll(tmpScript.Name(), "'", "''")
			startProcessCmd := fmt.Sprintf(
				"Start-Process powershell -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', '%s'",
				scriptPath)
			
			execCmd := exec.Command("powershell", "-Command", startProcessCmd)

			// Execute the command to open PowerShell window
			// This returns immediately - the actual script execution happens in the new window
			if err := execCmd.Run(); err != nil {
				return errorMsg(fmt.Sprintf("Failed to open PowerShell window: %s", err.Error()))
			}
		} else {
			return errorMsg(fmt.Sprintf("Terminal execution is currently only supported on macOS and Windows. Detected OS: %s", runtime.GOOS))
		}

		// Return success message
		return outputMsg(fmt.Sprintf("✅ Command opened in new terminal window\n\nScript: %s\nWorking directory: %s\n\nCheck the terminal window for output.", scriptPath, workingDir))
	}
}

// outputMsg and errorMsg are message types used by Bubbletea to communicate
// command execution results from async operations back to the Update function.
type outputMsg string
type errorMsg string

// View renders the current state of the TUI to the terminal.
// This function is called by Bubbletea whenever the model state changes.
//
// The view has three modes:
//   1. Quitting: Simple goodbye message
//   2. Executing: Shows command execution status with output/error messages
//   3. Menu: Displays the interactive command menu with navigation
//
// Returns the formatted string that will be displayed in the terminal.
func (m model) View() string {
	// Quitting state: Show goodbye message
	if m.quitting {
		return "\n  See you later!\n\n"
	}

	// Executing state: Show command execution status
	if m.executing {
		var view strings.Builder
		view.WriteString(titleStyle.Render("OpenEMR on EKS Console"))
		view.WriteString("\n\n")
		view.WriteString(itemStyle.Render("Executing: " + m.commands[m.selected].title))
		view.WriteString("\n\n")

		// Display error message if command failed
		if m.error != "" {
			view.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Bold(true).Render("❌ Error:\n"))
			view.WriteString("\n")
			// Write error output directly (may contain ANSI codes from script output)
			view.WriteString(m.error)
			view.WriteString("\n\n")
		} else if m.output != "" {
			// Display success message with output
			view.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("46")).Bold(true).Render("✅ Output:\n"))
			view.WriteString("\n")
			// Limit output display to last 100 lines to prevent overwhelming the screen
			// This is important because some scripts produce large amounts of output
			lines := strings.Split(m.output, "\n")
			start := 0
			if len(lines) > 100 {
				start = len(lines) - 100
				view.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("243")).Italic(true).Render("(Showing last 100 lines of output)\n\n"))
			}
			// Preserve ANSI color codes from script output - write raw output
			// This allows scripts' color codes (from tools like kubectl, terraform, etc.)
			// to display properly in the TUI
			view.WriteString(strings.Join(lines[start:], "\n"))
			view.WriteString("\n\n")
		} else {
			// Command is running but no output yet
			view.WriteString(descStyle.Render("⏳ Running command..."))
			view.WriteString("\n\n")
		}

		view.WriteString(helpStyle.Render("Press Enter, Esc, or Ctrl+C to return to menu"))
		return view.String()
	}

	// Menu state: Display the interactive command menu
	var s strings.Builder
	s.WriteString(titleStyle.Render("OpenEMR on EKS Console"))
	s.WriteString("\n\n")

	// Render each command in the menu
	for i, cmd := range m.commands {
		// Determine cursor symbol: ">" for selected item, " " for others
		cursor := " "
		if m.cursor == i {
			cursor = ">"
			// Selected item: Use highlighted style
			s.WriteString(selectedStyle.Render(fmt.Sprintf("%s %s", cursor, cmd.title)))
		} else {
			// Unselected item: Use normal style
			s.WriteString(itemStyle.Render(fmt.Sprintf("%s %s", cursor, cmd.title)))
		}
		s.WriteString("\n")
		
		// Display command description
		s.WriteString(descStyle.Render(cmd.description))
		s.WriteString("\n")
		
		// Display script path (relative to project root for cleaner display)
		// Convert absolute path to relative path if possible
		scriptPath := cmd.script
		if absPath, err := filepath.Abs(cmd.script); err == nil {
			if relPath, err := filepath.Rel(m.projectRoot, absPath); err == nil {
				scriptPath = relPath
			}
		}
		
		// Format script path with arguments if any
		scriptDisplay := scriptPath
		if len(cmd.args) > 0 {
			scriptDisplay = fmt.Sprintf("%s %s", scriptPath, strings.Join(cmd.args, " "))
		}
		s.WriteString(scriptStyle.Render(fmt.Sprintf("📜 %s", scriptDisplay)))
		s.WriteString("\n\n")
	}

	// Display help text at the bottom
	s.WriteString(helpStyle.Render("↑/↓: Navigate  Enter: Execute  Esc/Ctrl+C: Quit"))
	return s.String()
}

// main is the entry point of the application.
// It initializes the Bubbletea program with the initial model and starts the TUI.
//
// tea.WithAltScreen() enables the alternate screen buffer, which:
//   - Clears the terminal when the program starts
//   - Restores the original terminal state when the program exits
//   - Provides a cleaner user experience
func main() {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error: %v", err)
		os.Exit(1)
	}
}
