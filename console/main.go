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
//  1. OPENEMR_EKS_PROJECT_ROOT environment variable (highest priority, allows override)
//  2. Embedded project root path (set at build time via -ldflags)
//
// If the project is moved after building, users can set the environment variable
// to point to the new location without rebuilding.
package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// embeddedProjectRoot is set at build time using -ldflags during compilation.
// This allows the binary to remember where it was built from, enabling it to
// locate project scripts and resources even when run from a different directory.
//
// Example build command:
//
//	go build -ldflags "-X main.embeddedProjectRoot=$PWD" -o openemr-eks-console
//
// Users can override this at runtime by setting the OPENEMR_EKS_PROJECT_ROOT
// environment variable, which takes precedence over the embedded path.
var embeddedProjectRoot string

const version = "6.3.0"

// category groups related commands under a visual heading in the menu.
type category struct {
	name     string
	icon     string
	commands []command
}

// TUI styling definitions using lipgloss for consistent terminal UI appearance.
// Color codes reference: https://www.ditig.com/publications/256-colors-cheat-sheet
var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("205")).
			Padding(1, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("205"))

	categoryStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("99")).
			PaddingLeft(1).
			PaddingTop(1)

	itemStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("252")).
			PaddingLeft(4)

	selectedStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("205")).
			Bold(true).
			PaddingLeft(4).
			Background(lipgloss.Color("236"))

	descStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("243")).
			PaddingLeft(6).
			Italic(true)

	scriptStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("240")).
			PaddingLeft(6).
			Faint(true)

	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241")).
			PaddingTop(1)

	statusBarStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("243")).
			Faint(true).
			PaddingTop(1)

	destructiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("196")).
				Bold(true)

	confirmBoxStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("196")).
			Bold(true).
			Padding(1, 2).
			Border(lipgloss.DoubleBorder()).
			BorderForeground(lipgloss.Color("196"))

	formBoxStyle = lipgloss.NewStyle().
			Padding(1, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("99"))

	fieldLabelStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("99")).
			Bold(true)

	fieldActiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("205")).
				Bold(true)

	fieldInactiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("252"))

	placeholderStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("240")).
				Italic(true)

	fieldErrorStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("196")).
			Bold(true)

	requiredMarkerStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("196")).
				Bold(true)
)

// inputField defines a single prompt shown to the user before command execution.
type inputField struct {
	label       string // displayed above the text field
	placeholder string // greyed hint text when the field is empty
	required    bool   // must be non-empty to submit
	flag        string // if non-empty, prepend "--flag" before value; empty means positional arg
}

// inputState holds the transient state while the user fills in a form.
type inputState struct {
	fields    []inputField
	values    []string // current text per field
	active    int      // focused field index
	cursor    int      // cursor position within the active field's text
	attempted bool     // true after a failed submit (shows validation errors)
}

// command represents a single executable command in the console menu.
type command struct {
	title       string
	description string
	script      string
	args        []string
	prompts     []inputField // if non-nil, show input form before execution
	destructive bool         // requires confirmation before execution
}

// model represents the application state for the Bubbletea TUI framework.
type model struct {
	categories  []category
	flatIndex   []flatEntry // flattened list for cursor navigation
	cursor      int
	selected    int
	quitting    bool
	executing   bool
	confirming  bool        // waiting for destructive-action confirmation
	showHelp    bool        // expanded help panel
	input       *inputState // non-nil when collecting user input
	output      string
	error       string
	projectRoot string
	cmdCount    int // total selectable commands (cached)
}

// flatEntry maps a cursor position to either a category header or a command.
type flatEntry struct {
	isCategory bool
	catIdx     int
	cmdIdx     int
}

// verifyProjectStructure validates that a directory contains all required
// project subdirectories (scripts/, terraform/, k8s/).
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

// convertWindowsPathToUnix converts a Windows path to Unix-style path for bash.
// Uses Git Bash format: C:\Users\name\file.sh -> /c/Users/name/file.sh
func convertWindowsPathToUnix(windowsPath string) string {
	absPath, err := filepath.Abs(windowsPath)
	if err != nil {
		return strings.ReplaceAll(windowsPath, "\\", "/")
	}
	unixPath := strings.ReplaceAll(absPath, "\\", "/")
	if len(unixPath) >= 2 && unixPath[1] == ':' {
		drive := strings.ToLower(string(unixPath[0]))
		unixPath = "/" + drive + unixPath[2:]
	}
	return unixPath
}

// buildFlatIndex creates a flattened navigation index from categories.
func buildFlatIndex(cats []category) []flatEntry {
	var entries []flatEntry
	for ci, cat := range cats {
		entries = append(entries, flatEntry{isCategory: true, catIdx: ci})
		for cmi := range cat.commands {
			entries = append(entries, flatEntry{isCategory: false, catIdx: ci, cmdIdx: cmi})
		}
	}
	return entries
}

// initialModel initializes the TUI application model with project root detection
// and categorized command definitions.
//
// Project Root Detection Strategy (in priority order):
//  1. OPENEMR_EKS_PROJECT_ROOT environment variable
//  2. Embedded project root (set at build time via -ldflags)
//  3. Exit with detailed error messages
func initialModel() model {
	var projectRoot string
	var validationErrors []string

	if envRoot := os.Getenv("OPENEMR_EKS_PROJECT_ROOT"); envRoot != "" {
		if verifyProjectStructure(envRoot) {
			projectRoot = envRoot
		} else {
			requiredDirs := []string{"scripts", "terraform", "k8s"}
			for _, dir := range requiredDirs {
				if _, err := os.Stat(filepath.Join(envRoot, dir)); os.IsNotExist(err) {
					validationErrors = append(validationErrors, fmt.Sprintf("OPENEMR_EKS_PROJECT_ROOT: missing '%s' directory", dir))
				}
			}
		}
	}

	if projectRoot == "" && embeddedProjectRoot != "" {
		if verifyProjectStructure(embeddedProjectRoot) {
			projectRoot = embeddedProjectRoot
		} else {
			requiredDirs := []string{"scripts", "terraform", "k8s"}
			for _, dir := range requiredDirs {
				if _, err := os.Stat(filepath.Join(embeddedProjectRoot, dir)); os.IsNotExist(err) {
					validationErrors = append(validationErrors, fmt.Sprintf("Embedded path: missing '%s' directory", dir))
				}
			}
		}
	}

	if projectRoot == "" {
		fmt.Fprintf(os.Stderr, "❌ Error: Project root not found or invalid\n\n")
		if embeddedProjectRoot != "" {
			fmt.Fprintf(os.Stderr, "Embedded project root: %s\n", embeddedProjectRoot)
			if _, err := os.Stat(embeddedProjectRoot); os.IsNotExist(err) {
				fmt.Fprintf(os.Stderr, "  → Directory does not exist\n")
			} else {
				for _, errMsg := range validationErrors {
					if strings.HasPrefix(errMsg, "Embedded path:") {
						fmt.Fprintf(os.Stderr, "  → %s\n", strings.TrimPrefix(errMsg, "Embedded path: "))
					}
				}
			}
		} else {
			fmt.Fprintf(os.Stderr, "No embedded project root found (binary was not built with -ldflags)\n")
		}
		if len(validationErrors) > 0 {
			for _, errMsg := range validationErrors {
				if strings.HasPrefix(errMsg, "OPENEMR_EKS_PROJECT_ROOT:") {
					fmt.Fprintf(os.Stderr, "  → %s\n", strings.TrimPrefix(errMsg, "OPENEMR_EKS_PROJECT_ROOT: "))
				}
			}
		}
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

	scriptsPath := filepath.Join(projectRoot, "scripts")

	categories := []category{
		{
			name: "Deployment",
			icon: "🚀",
			commands: []command{
				{
					title:       "Validate Prerequisites",
					description: "Check required tools, AWS credentials, and deployment readiness",
					script:      filepath.Join(scriptsPath, "validate-deployment.sh"),
				},
				{
					title:       "Quick Deploy",
					description: "Deploy infrastructure, OpenEMR, and monitoring stack in one command",
					script:      filepath.Join(scriptsPath, "quick-deploy.sh"),
				},
				{
					title:       "Deploy Training Setup",
					description: "Deploy OpenEMR with synthetic patient data for training/testing",
					script:      filepath.Join(scriptsPath, "deploy-training-openemr-setup.sh"),
					args:        []string{"--use-default-dataset", "--max-records", "100"},
				},
			},
		},
		{
			name: "Operations",
			icon: "⚙️",
			commands: []command{
				{
					title:       "Check Deployment Health",
					description: "Validate current deployment status and infrastructure health",
					script:      filepath.Join(scriptsPath, "validate-deployment.sh"),
				},
				{
					title:       "Backup Deployment",
					description: "Create comprehensive backup of RDS, Kubernetes configs, and application data",
					script:      filepath.Join(scriptsPath, "backup.sh"),
				},
				{
					title:       "Restore from Backup",
					description: "Restore infrastructure and application data from a previous backup",
					script:      filepath.Join(scriptsPath, "restore.sh"),
					prompts: []inputField{
						{label: "Backup Bucket", placeholder: "my-openemr-backup-bucket", required: true},
						{label: "Snapshot ID", placeholder: "openemr-snapshot-20260227 or leave empty for --latest-snapshot", required: false},
					},
				},
				{
					title:       "Clean Deployment",
					description: "Remove application layer while preserving infrastructure",
					script:      filepath.Join(scriptsPath, "clean-deployment.sh"),
				},
				{
					title:       "Destroy Infrastructure",
					description: "Completely destroy all infrastructure resources",
					script:      filepath.Join(scriptsPath, "destroy.sh"),
					destructive: true,
				},
			},
		},
		{
			name: "Information",
			icon: "📋",
			commands: []command{
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
					prompts: []inputField{
						{label: "Search Pattern", placeholder: "e.g. 7.0 or 8.0 (leave empty to show latest)", required: false, flag: "search"},
					},
				},
				{
					title:       "Search Codebase",
					description: "Search for terms across the entire codebase",
					script:      filepath.Join(scriptsPath, "search-codebase.sh"),
					prompts: []inputField{
						{label: "Search Term", placeholder: "e.g. OPENEMR_VERSION, backup, deploy", required: true},
					},
				},
			},
		},
	}

	flat := buildFlatIndex(categories)
	startCursor := 0
	cmdTotal := 0
	for i, e := range flat {
		if !e.isCategory {
			if startCursor == 0 {
				startCursor = i
			}
			cmdTotal++
		}
	}

	return model{
		categories:  categories,
		flatIndex:   flat,
		cursor:      startCursor,
		projectRoot: projectRoot,
		cmdCount:    cmdTotal,
	}
}

// Init is called by Bubbletea when the program starts.
func (m model) Init() tea.Cmd {
	return nil
}

// Update processes messages/events and updates the model state.
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case outputMsg:
		m.output = string(msg)
		m.executing = false
		return m, nil
	case errorMsg:
		m.error = string(msg)
		m.executing = false
		return m, nil
	}

	// Input form for commands that require arguments
	if m.input != nil {
		if msg, ok := msg.(tea.KeyPressMsg); ok {
			return m.updateInput(msg)
		}
		return m, nil
	}

	// Confirmation dialog for destructive actions
	if m.confirming {
		if msg, ok := msg.(tea.KeyPressMsg); ok {
			switch msg.String() {
			case "y", "Y":
				m.confirming = false
				m.executing = true
				m.output = ""
				m.error = ""
				entry := m.flatIndex[m.cursor]
				cmd := m.categories[entry.catIdx].commands[entry.cmdIdx]
				return m, m.executeCommand(cmd)
			default:
				m.confirming = false
				return m, nil
			}
		}
		return m, nil
	}

	if m.executing {
		if msg, ok := msg.(tea.KeyPressMsg); ok {
			switch msg.String() {
			case "ctrl+c", "esc", "enter":
				m.executing = false
				m.output = ""
				m.error = ""
				return m, nil
			}
		}
		return m, nil
	}

	if msg, ok := msg.(tea.KeyPressMsg); ok {
		switch msg.String() {
		case "ctrl+c", "q":
			m.quitting = true
			return m, tea.Quit
		case "esc":
			if m.showHelp {
				m.showHelp = false
				return m, nil
			}
			m.quitting = true
			return m, tea.Quit

		case "?":
			m.showHelp = !m.showHelp
			return m, nil

		case "up", "k":
			m.moveCursor(-1)
		case "down", "j":
			m.moveCursor(1)
		case "g", "home":
			m.jumpTo(true)
		case "G", "end":
			m.jumpTo(false)

		case "enter":
			entry := m.flatIndex[m.cursor]
			if entry.isCategory {
				m.moveCursor(1)
				return m, nil
			}
			cmd := m.categories[entry.catIdx].commands[entry.cmdIdx]
			if len(cmd.prompts) > 0 {
				m.input = newInputState(cmd.prompts)
				return m, nil
			}
			if cmd.destructive {
				m.confirming = true
				return m, nil
			}
			m.selected = m.cursor
			m.executing = true
			m.output = ""
			m.error = ""
			return m, m.executeCommand(cmd)
		}
	}

	return m, nil
}

// moveCursor advances the cursor by delta, skipping category headers.
func (m *model) moveCursor(delta int) {
	n := len(m.flatIndex)
	next := m.cursor
	for {
		next = (next + delta + n) % n
		if !m.flatIndex[next].isCategory {
			break
		}
		if next == m.cursor {
			break
		}
	}
	m.cursor = next
}

// jumpTo moves the cursor to the first or last selectable command.
func (m *model) jumpTo(first bool) {
	if first {
		for i, e := range m.flatIndex {
			if !e.isCategory {
				m.cursor = i
				return
			}
		}
	} else {
		for i := len(m.flatIndex) - 1; i >= 0; i-- {
			if !m.flatIndex[i].isCategory {
				m.cursor = i
				return
			}
		}
	}
}

// commandPosition returns the 1-based position of the current cursor
// among selectable commands (e.g., "3" out of total).
func (m model) commandPosition() int {
	pos := 0
	for i, e := range m.flatIndex {
		if !e.isCategory {
			pos++
		}
		if i == m.cursor {
			return pos
		}
	}
	return pos
}

// newInputState creates a fresh input form from field definitions.
func newInputState(fields []inputField) *inputState {
	return &inputState{
		fields: fields,
		values: make([]string, len(fields)),
	}
}

// updateInput handles key events while the input form is active.
func (m model) updateInput(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	inp := m.input
	key := msg.String()

	switch key {
	case "esc":
		m.input = nil
		return m, nil

	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit

	case "tab", "down":
		inp.active = (inp.active + 1) % len(inp.fields)
		inp.cursor = len(inp.values[inp.active])
		return m, nil

	case "shift+tab", "up":
		inp.active = (inp.active - 1 + len(inp.fields)) % len(inp.fields)
		inp.cursor = len(inp.values[inp.active])
		return m, nil

	case "enter":
		if inp.active < len(inp.fields)-1 {
			inp.active++
			inp.cursor = len(inp.values[inp.active])
			return m, nil
		}
		return m.submitInput()

	case "left":
		if inp.cursor > 0 {
			inp.cursor--
		}
		return m, nil

	case "right":
		if inp.cursor < len(inp.values[inp.active]) {
			inp.cursor++
		}
		return m, nil

	case "home":
		inp.cursor = 0
		return m, nil

	case "end":
		inp.cursor = len(inp.values[inp.active])
		return m, nil

	case "backspace":
		v := inp.values[inp.active]
		if inp.cursor > 0 {
			inp.values[inp.active] = v[:inp.cursor-1] + v[inp.cursor:]
			inp.cursor--
		}
		return m, nil

	case "delete":
		v := inp.values[inp.active]
		if inp.cursor < len(v) {
			inp.values[inp.active] = v[:inp.cursor] + v[inp.cursor+1:]
		}
		return m, nil

	default:
		if msg.Text != "" && !msg.Mod.Contains(tea.ModCtrl) && !msg.Mod.Contains(tea.ModAlt) {
			v := inp.values[inp.active]
			inp.values[inp.active] = v[:inp.cursor] + msg.Text + v[inp.cursor:]
			inp.cursor += len(msg.Text)
		}
		return m, nil
	}
}

// submitInput validates required fields and, if valid, builds args and executes.
func (m model) submitInput() (tea.Model, tea.Cmd) {
	inp := m.input

	for _, f := range inp.fields {
		if f.required && strings.TrimSpace(inp.values[fieldIndex(inp.fields, f)]) == "" {
			inp.attempted = true
			return m, nil
		}
	}

	entry := m.flatIndex[m.cursor]
	cmd := m.categories[entry.catIdx].commands[entry.cmdIdx]

	built := buildArgsFromInput(cmd, inp)
	execCmd := command{
		title:       cmd.title,
		description: cmd.description,
		script:      cmd.script,
		args:        built,
		destructive: cmd.destructive,
	}

	m.input = nil

	if cmd.destructive {
		m.confirming = true
		return m, nil
	}

	m.selected = m.cursor
	m.executing = true
	m.output = ""
	m.error = ""
	return m, m.executeCommand(execCmd)
}

// buildArgsFromInput assembles command-line arguments from user input.
// For restore.sh: if snapshot ID is empty, append --latest-snapshot instead.
func buildArgsFromInput(cmd command, inp *inputState) []string {
	var args []string
	args = append(args, cmd.args...)

	isRestore := strings.HasSuffix(cmd.script, "restore.sh")
	hasSnapshotValue := false

	for i, f := range inp.fields {
		val := strings.TrimSpace(inp.values[i])
		if val == "" {
			continue
		}
		if f.flag != "" {
			args = append(args, "--"+f.flag, val)
		} else {
			args = append(args, val)
			if isRestore && i == 1 {
				hasSnapshotValue = true
			}
		}
	}

	if isRestore && !hasSnapshotValue {
		args = append(args, "--latest-snapshot")
	}

	return args
}

// fieldIndex returns the index of a field within the fields slice.
func fieldIndex(fields []inputField, target inputField) int {
	for i, f := range fields {
		if f.label == target.label {
			return i
		}
	}
	return 0
}

// executeCommand launches a bash script in a new terminal window.
// macOS uses osascript; Windows uses PowerShell Start-Process.
func (m model) executeCommand(cmd command) tea.Cmd {
	return func() tea.Msg {
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

		// #nosec G302 -- Script must be executable to run
		os.Chmod(cmd.script, 0755)

		scriptPath := cmd.script
		scriptArgs := strings.Join(cmd.args, " ")
		workingDir := filepath.Dir(cmd.script)

		if runtime.GOOS == "darwin" {
			escapedScriptPath := strings.ReplaceAll(scriptPath, "'", "'\"'\"'")
			escapedArgs := strings.ReplaceAll(scriptArgs, "'", "'\"'\"'")
			escapedWorkingDir := strings.ReplaceAll(workingDir, "'", "'\"'\"'")
			command := fmt.Sprintf("cd '%s' && '%s' %s; echo ''; echo 'Press any key and then return to go back to the command line'; read -n 1", escapedWorkingDir, escapedScriptPath, escapedArgs)
			// #nosec G204 -- Command constructed from internal script paths
			execCmd := exec.Command("osascript", "-e", fmt.Sprintf(`tell application "Terminal" to do script "%s"`, command))
			if err := execCmd.Run(); err != nil {
				return errorMsg(fmt.Sprintf("Failed to open terminal window: %s", err.Error()))
			}
		} else if runtime.GOOS == "windows" {
			scriptPathUnix := convertWindowsPathToUnix(scriptPath)
			workingDirUnix := convertWindowsPathToUnix(workingDir)
			scriptPathWin := strings.ReplaceAll(scriptPath, "\\", "/")
			workingDirWin := strings.ReplaceAll(workingDir, "\\", "/")
			workingDirWinPS := workingDir

			escapedScriptPathUnix := strings.ReplaceAll(scriptPathUnix, "'", "''")
			escapedScriptPathWin := strings.ReplaceAll(scriptPathWin, "'", "''")
			escapedArgs := strings.ReplaceAll(scriptArgs, "'", "''")
			escapedWorkingDirUnix := strings.ReplaceAll(workingDirUnix, "'", "''")
			escapedWorkingDirWin := strings.ReplaceAll(workingDirWin, "'", "''")
			escapedWorkingDirWinPS := strings.ReplaceAll(workingDirWinPS, "'", "''")

			var scriptBuf bytes.Buffer
			scriptBuf.WriteString("$ErrorActionPreference = 'Continue'\r\n")
			scriptBuf.WriteString("$Host.UI.RawUI.WindowTitle = 'OpenEMR EKS Console - Script Execution'\r\n")
			scriptBuf.WriteString("Write-Host 'OpenEMR EKS Console - Script Execution' -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("Write-Host '========================================' -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("Write-Host ''\r\n")
			scriptBuf.WriteString("try {\r\n")
			scriptBuf.WriteString(fmt.Sprintf("  $workingDirUnix = '%s'\r\n", escapedWorkingDirUnix))
			scriptBuf.WriteString(fmt.Sprintf("  $scriptPathUnix = '%s'\r\n", escapedScriptPathUnix))
			scriptBuf.WriteString(fmt.Sprintf("  $scriptArgs = '%s'\r\n", escapedArgs))
			scriptBuf.WriteString("  $bashCmd = $null\r\n")
			scriptBuf.WriteString("  $finalScriptPath = $null\r\n")
			scriptBuf.WriteString("  $finalWorkingDir = $null\r\n")
			scriptBuf.WriteString("  $finalWorkingDirPS = $null\r\n")
			scriptBuf.WriteString("  Write-Host 'Looking for bash...' -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("  $gitBashPaths = @('C:\\Program Files\\Git\\bin\\bash.exe', 'C:\\Program Files (x86)\\Git\\bin\\bash.exe', \"$env:LOCALAPPDATA\\Programs\\Git\\bin\\bash.exe\")\r\n")
			scriptBuf.WriteString("  Write-Host 'Checking Git Bash locations...' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("  foreach ($path in $gitBashPaths) {\r\n")
			scriptBuf.WriteString("    Write-Host \"  Checking: $path\" -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    if (Test-Path $path) {\r\n")
			scriptBuf.WriteString("      $bashCmd = $path\r\n")
			scriptBuf.WriteString(fmt.Sprintf("      $finalScriptPath = '%s'\r\n", escapedScriptPathUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDir = '%s'\r\n", escapedWorkingDirUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDirPS = '%s'\r\n", escapedWorkingDirWinPS))
			scriptBuf.WriteString("      Write-Host \"Found Git Bash at: $path\" -ForegroundColor Green\r\n")
			scriptBuf.WriteString("      break\r\n")
			scriptBuf.WriteString("    }\r\n")
			scriptBuf.WriteString("  }\r\n")
			scriptBuf.WriteString("  if (-not $bashCmd) {\r\n")
			scriptBuf.WriteString("    Write-Host 'Checking for WSL...' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue\r\n")
			scriptBuf.WriteString("    if ($wslCmd) {\r\n")
			scriptBuf.WriteString("      Write-Host 'WSL found, converting paths...' -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString(fmt.Sprintf("      $scriptPathWin = '%s'\r\n", escapedScriptPathWin))
			scriptBuf.WriteString(fmt.Sprintf("      $workingDirWin = '%s'\r\n", escapedWorkingDirWin))
			scriptBuf.WriteString("      $wslScriptPath = (wsl wslpath -a $scriptPathWin 2>$null).Trim()\r\n")
			scriptBuf.WriteString("      $wslWorkingDir = (wsl wslpath -a $workingDirWin 2>$null).Trim()\r\n")
			scriptBuf.WriteString("      if ($wslScriptPath -and $wslWorkingDir) {\r\n")
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
			scriptBuf.WriteString("  if (-not $bashCmd) {\r\n")
			scriptBuf.WriteString("    Write-Host 'Checking for system bash in PATH...' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    $sysBash = Get-Command bash -ErrorAction SilentlyContinue\r\n")
			scriptBuf.WriteString("    if ($sysBash) {\r\n")
			scriptBuf.WriteString("      $bashCmd = 'bash'\r\n")
			scriptBuf.WriteString(fmt.Sprintf("      $finalScriptPath = '%s'\r\n", escapedScriptPathUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDir = '%s'\r\n", escapedWorkingDirUnix))
			scriptBuf.WriteString(fmt.Sprintf("      $finalWorkingDirPS = '%s'\r\n", escapedWorkingDirWinPS))
			scriptBuf.WriteString("      Write-Host \"Found system bash at: $($sysBash.Source)\" -ForegroundColor Green\r\n")
			scriptBuf.WriteString("    } else {\r\n")
			scriptBuf.WriteString("      Write-Host 'System bash not found in PATH' -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("    }\r\n")
			scriptBuf.WriteString("  }\r\n")
			scriptBuf.WriteString("  if ($bashCmd) {\r\n")
			scriptBuf.WriteString("    try {\r\n")
			scriptBuf.WriteString("      Set-Location $finalWorkingDirPS\r\n")
			scriptBuf.WriteString("      Write-Host \"Working directory: $finalWorkingDir\" -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("      Write-Host \"Executing: $finalScriptPath $scriptArgs\" -ForegroundColor Cyan\r\n")
			scriptBuf.WriteString("      Write-Host ''\r\n")
			scriptBuf.WriteString("      if ($bashCmd -eq 'wsl') {\r\n")
			scriptBuf.WriteString("        $escapedCmd = \"cd `\"$finalWorkingDir`\" && bash `\"$finalScriptPath`\" $scriptArgs\"\r\n")
			scriptBuf.WriteString("        wsl bash -c $escapedCmd\r\n")
			scriptBuf.WriteString("      } else {\r\n")
			scriptBuf.WriteString("        if ($scriptArgs) {\r\n")
			scriptBuf.WriteString("          $argArray = $scriptArgs -split ' '\r\n")
			scriptBuf.WriteString("          & $bashCmd $finalScriptPath $argArray\r\n")
			scriptBuf.WriteString("        } else {\r\n")
			scriptBuf.WriteString("          & $bashCmd $finalScriptPath\r\n")
			scriptBuf.WriteString("        }\r\n")
			scriptBuf.WriteString("      }\r\n")
			scriptBuf.WriteString("      if ($LASTEXITCODE -ne 0) {\r\n")
			scriptBuf.WriteString("        Write-Host ''\r\n")
			scriptBuf.WriteString("        Write-Host \"Script exited with code $LASTEXITCODE\" -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("      }\r\n")
			scriptBuf.WriteString("    } catch {\r\n")
			scriptBuf.WriteString("      Write-Host ''\r\n")
			scriptBuf.WriteString("      Write-Host \"Error executing script: $_\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Bash command: $bashCmd\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Script path: $finalScriptPath\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Working dir: $finalWorkingDir\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("      Write-Host \"Script args: $scriptArgs\" -ForegroundColor Red\r\n")
			scriptBuf.WriteString("    }\r\n")
			scriptBuf.WriteString("  } else {\r\n")
			scriptBuf.WriteString("    Write-Host 'Error: bash not found.' -ForegroundColor Red\r\n")
			scriptBuf.WriteString("    Write-Host ''\r\n")
			scriptBuf.WriteString("    Write-Host 'Please install one of the following:' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("    Write-Host '  1. Git Bash: https://git-scm.com/download/win' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("    Write-Host '  2. WSL (Windows Subsystem for Linux)' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("  }\r\n")
			scriptBuf.WriteString("} catch {\r\n")
			scriptBuf.WriteString("  Write-Host ''\r\n")
			scriptBuf.WriteString("  Write-Host 'Unexpected error occurred:' -ForegroundColor Red\r\n")
			scriptBuf.WriteString("  Write-Host $_.Exception.Message -ForegroundColor Red\r\n")
			scriptBuf.WriteString("  Write-Host $_.ScriptStackTrace -ForegroundColor Gray\r\n")
			scriptBuf.WriteString("} finally {\r\n")
			scriptBuf.WriteString("  Write-Host ''\r\n")
			scriptBuf.WriteString("  Write-Host 'Press any key to close this window...' -ForegroundColor Yellow\r\n")
			scriptBuf.WriteString("  try {\r\n")
			scriptBuf.WriteString("    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')\r\n")
			scriptBuf.WriteString("  } catch {\r\n")
			scriptBuf.WriteString("    Start-Sleep -Seconds 5\r\n")
			scriptBuf.WriteString("  }\r\n")
			scriptBuf.WriteString("}\r\n")
			powershellScript := scriptBuf.String()

			tmpScript, err := os.CreateTemp("", "openemr-console-*.ps1")
			if err != nil {
				return errorMsg(fmt.Sprintf("Failed to create temporary script: %s", err.Error()))
			}
			bom := []byte{0xEF, 0xBB, 0xBF}
			if _, err := tmpScript.Write(bom); err != nil {
				tmpScript.Close()
				return errorMsg(fmt.Sprintf("Failed to write BOM: %s", err.Error()))
			}
			if _, err := tmpScript.WriteString(powershellScript); err != nil {
				tmpScript.Close()
				return errorMsg(fmt.Sprintf("Failed to write temporary script: %s", err.Error()))
			}
			tmpScript.Close()

			tmpPath := strings.ReplaceAll(tmpScript.Name(), "'", "''")
			startProcessCmd := fmt.Sprintf(
				"Start-Process powershell -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', '%s'",
				tmpPath)
			// #nosec G204 -- Command constructed from internal script paths
			execCmd := exec.Command("powershell", "-Command", startProcessCmd)
			if err := execCmd.Run(); err != nil {
				return errorMsg(fmt.Sprintf("Failed to open PowerShell window: %s", err.Error()))
			}
		} else {
			return errorMsg(fmt.Sprintf("Terminal execution is currently only supported on macOS and Windows. Detected OS: %s", runtime.GOOS))
		}

		return outputMsg(fmt.Sprintf("✅ Command opened in new terminal window\n\nScript: %s\nWorking directory: %s\n\nCheck the terminal window for output.", scriptPath, workingDir))
	}
}

type outputMsg string
type errorMsg string

// View renders the current state of the TUI to the terminal.
func (m model) View() tea.View {
	var content string

	if m.quitting {
		content = "\n  See you later!\n\n"
	} else if m.input != nil {
		entry := m.flatIndex[m.cursor]
		cmd := m.categories[entry.catIdx].commands[entry.cmdIdx]
		content = m.renderInputForm(cmd)
	} else if m.confirming {
		var s strings.Builder
		s.WriteString(titleStyle.Render("OpenEMR on EKS Console"))
		s.WriteString("\n\n")
		entry := m.flatIndex[m.cursor]
		cmd := m.categories[entry.catIdx].commands[entry.cmdIdx]
		s.WriteString(confirmBoxStyle.Render(
			fmt.Sprintf("!! DESTRUCTIVE ACTION: %s\n\nThis will permanently destroy all infrastructure resources.\nThis action is irreversible.\n\nPress Y to confirm, any other key to cancel.", cmd.title),
		))
		s.WriteString("\n")
		content = s.String()
	} else if m.executing {
		var s strings.Builder
		s.WriteString(titleStyle.Render("OpenEMR on EKS Console"))
		s.WriteString("\n\n")
		entry := m.flatIndex[m.cursor]
		cmd := m.categories[entry.catIdx].commands[entry.cmdIdx]
		s.WriteString(itemStyle.Render("Executing: " + cmd.title))
		s.WriteString("\n\n")

		if m.error != "" {
			s.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Bold(true).Render("❌ Error:\n"))
			s.WriteString("\n")
			s.WriteString(m.error)
			s.WriteString("\n\n")
		} else if m.output != "" {
			s.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("46")).Bold(true).Render("✅ Output:\n"))
			s.WriteString("\n")
			lines := strings.Split(m.output, "\n")
			start := 0
			if len(lines) > 100 {
				start = len(lines) - 100
				s.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("243")).Italic(true).Render("(Showing last 100 lines of output)\n\n"))
			}
			s.WriteString(strings.Join(lines[start:], "\n"))
			s.WriteString("\n\n")
		} else {
			s.WriteString(descStyle.Render("⏳ Running command..."))
			s.WriteString("\n\n")
		}

		s.WriteString(helpStyle.Render("Press Enter, Esc, or Ctrl+C to return to menu"))
		content = s.String()
	} else {
		var s strings.Builder
		s.WriteString(titleStyle.Render(fmt.Sprintf("OpenEMR on EKS Console  v%s", version)))
		s.WriteString("\n")

		for _, entry := range m.flatIndex {
			if entry.isCategory {
				cat := m.categories[entry.catIdx]
				s.WriteString(categoryStyle.Render(fmt.Sprintf("%s %s", cat.icon, cat.name)))
				s.WriteString("\n")
				continue
			}

			cmd := m.categories[entry.catIdx].commands[entry.cmdIdx]
			idx := 0
			for fi, fe := range m.flatIndex {
				if fe == entry {
					idx = fi
					break
				}
			}

			cursor := " "
			titleText := cmd.title
			if cmd.destructive {
				titleText = "⚠ " + titleText
			}

			if m.cursor == idx {
				cursor = "▸"
				s.WriteString(selectedStyle.Render(fmt.Sprintf("%s %s", cursor, titleText)))
			} else {
				if cmd.destructive {
					s.WriteString(itemStyle.Render(fmt.Sprintf("%s %s", cursor, destructiveStyle.Render(titleText))))
				} else {
					s.WriteString(itemStyle.Render(fmt.Sprintf("%s %s", cursor, titleText)))
				}
			}
			s.WriteString("\n")

			s.WriteString(descStyle.Render(cmd.description))
			s.WriteString("\n")

			scriptPath := cmd.script
			if absPath, err := filepath.Abs(cmd.script); err == nil {
				if relPath, err := filepath.Rel(m.projectRoot, absPath); err == nil {
					scriptPath = relPath
				}
			}
			scriptDisplay := scriptPath
			if len(cmd.args) > 0 {
				scriptDisplay = fmt.Sprintf("%s %s", scriptPath, strings.Join(cmd.args, " "))
			}
			s.WriteString(scriptStyle.Render(fmt.Sprintf("📜 %s", scriptDisplay)))
			s.WriteString("\n")
		}

		s.WriteString("\n")
		if m.showHelp {
			s.WriteString(helpStyle.Render("  ↑/k  Up          ↓/j  Down        Enter  Execute"))
			s.WriteString("\n")
			s.WriteString(helpStyle.Render("  g    First item   G    Last item   ?      Toggle help"))
			s.WriteString("\n")
			s.WriteString(helpStyle.Render("  q    Quit         Esc  Quit        Y      Confirm destructive"))
		} else {
			s.WriteString(helpStyle.Render("↑/k: Up  ↓/j: Down  Enter: Execute  q: Quit  ?: Help"))
		}
		s.WriteString("\n")
		s.WriteString(statusBarStyle.Render(fmt.Sprintf("📂 %s  ·  %d/%d", m.projectRoot, m.commandPosition(), m.cmdCount)))
		content = s.String()
	}

	v := tea.NewView(content)
	v.AltScreen = true
	return v
}

// renderInputForm draws the styled input form for commands with prompts.
func (m model) renderInputForm(cmd command) string {
	inp := m.input
	var s strings.Builder

	s.WriteString(titleStyle.Render("OpenEMR on EKS Console"))
	s.WriteString("\n\n")

	var formContent strings.Builder
	formContent.WriteString(fieldLabelStyle.Render(fmt.Sprintf("  %s", cmd.title)))
	formContent.WriteString("\n")
	formContent.WriteString(descStyle.Render(cmd.description))
	formContent.WriteString("\n")

	for i, f := range inp.fields {
		formContent.WriteString("\n")

		label := f.label
		if f.required {
			label += " " + requiredMarkerStyle.Render("*")
		} else {
			label += " " + lipgloss.NewStyle().Foreground(lipgloss.Color("243")).Render("(optional)")
		}
		formContent.WriteString("  " + fieldLabelStyle.Render(label))
		formContent.WriteString("\n")

		val := inp.values[i]
		isActive := i == inp.active
		showError := inp.attempted && f.required && strings.TrimSpace(val) == ""

		if isActive {
			var display string
			if val == "" && !isActive {
				display = placeholderStyle.Render(f.placeholder)
			} else {
				before := val[:inp.cursor]
				after := val[inp.cursor:]
				display = fieldActiveStyle.Render("  ▸ "+before) + fieldActiveStyle.Render("█") + fieldActiveStyle.Render(after)
			}
			formContent.WriteString(display)
		} else if val == "" {
			formContent.WriteString("  " + placeholderStyle.Render("  "+f.placeholder))
		} else {
			formContent.WriteString("  " + fieldInactiveStyle.Render("  "+val))
		}
		formContent.WriteString("\n")

		if showError {
			formContent.WriteString("  " + fieldErrorStyle.Render("  ⚠ This field is required"))
			formContent.WriteString("\n")
		}
	}

	formContent.WriteString("\n")
	formContent.WriteString(helpStyle.Render("  Tab/↓: Next field  Shift+Tab/↑: Prev  Enter: Submit  Esc: Cancel"))

	s.WriteString(formBoxStyle.Render(formContent.String()))
	s.WriteString("\n")

	return s.String()
}

func main() {
	p := tea.NewProgram(initialModel())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error: %v", err)
		os.Exit(1)
	}
}
