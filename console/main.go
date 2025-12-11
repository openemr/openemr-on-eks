package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// This variable is set at build time using -ldflags
// If the project is moved, users can override it with OPENEMR_EKS_PROJECT_ROOT environment variable
var embeddedProjectRoot string

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("205")).
			Padding(1, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("205"))

	itemStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("252")).
			PaddingLeft(2)

	selectedStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("205")).
			Bold(true).
			PaddingLeft(2).
			Background(lipgloss.Color("236"))

	descStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("243")).
			PaddingLeft(4).
			Italic(true)

	scriptStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("240")).
			PaddingLeft(4).
			Faint(true)

	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241")).
			PaddingTop(1)
)

type command struct {
	title       string
	description string
	script      string
	args        []string
}

type model struct {
	commands    []command
	cursor      int
	selected    int
	quitting    bool
	executing   bool
	output      string
	error       string
	projectRoot string
}

// verifyProjectStructure checks if a directory has all required project folders
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

func initialModel() model {
	// Get the project root directory
	// Strategy:
	// 1. Check for OPENEMR_EKS_PROJECT_ROOT environment variable (overrides embedded path)
	// 2. Use embedded project root (set at build/install time)
	// 3. If neither is valid, exit with error

	var projectRoot string
	var validationErrors []string

	// First, check environment variable (allows override if project was moved)
	if envRoot := os.Getenv("OPENEMR_EKS_PROJECT_ROOT"); envRoot != "" {
		// Verify it has all required project directories
		if verifyProjectStructure(envRoot) {
			projectRoot = envRoot
		} else {
			// Collect missing directories for error reporting
			requiredDirs := []string{"scripts", "terraform", "k8s"}
			for _, dir := range requiredDirs {
				if _, err := os.Stat(filepath.Join(envRoot, dir)); os.IsNotExist(err) {
					validationErrors = append(validationErrors, fmt.Sprintf("OPENEMR_EKS_PROJECT_ROOT: missing '%s' directory", dir))
				}
			}
		}
	}

	// If not set via env var, use embedded path (set during build/install)
	if projectRoot == "" && embeddedProjectRoot != "" {
		// Verify it has all required project directories
		if verifyProjectStructure(embeddedProjectRoot) {
			projectRoot = embeddedProjectRoot
		} else {
			// Collect missing directories for error reporting
			requiredDirs := []string{"scripts", "terraform", "k8s"}
			for _, dir := range requiredDirs {
				if _, err := os.Stat(filepath.Join(embeddedProjectRoot, dir)); os.IsNotExist(err) {
					validationErrors = append(validationErrors, fmt.Sprintf("Embedded path: missing '%s' directory", dir))
				}
			}
		}
	}

	// If no valid project root found, exit with error
	if projectRoot == "" {
		fmt.Fprintf(os.Stderr, "❌ Error: Project root not found or invalid\n\n")
		if embeddedProjectRoot != "" {
			fmt.Fprintf(os.Stderr, "Embedded project root: %s\n", embeddedProjectRoot)
			if _, err := os.Stat(embeddedProjectRoot); os.IsNotExist(err) {
				fmt.Fprintf(os.Stderr, "  → Directory does not exist\n")
			} else {
				// Report all missing directories
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

		fmt.Fprintf(os.Stderr, "\nRequired directories: scripts/, terraform/, k8s/\n")
		fmt.Fprintf(os.Stderr, "\nSolutions:\n")
		fmt.Fprintf(os.Stderr, "1. If you moved the project, set OPENEMR_EKS_PROJECT_ROOT:\n")
		fmt.Fprintf(os.Stderr, "   export OPENEMR_EKS_PROJECT_ROOT=/path/to/openemr-on-eks\n")
		fmt.Fprintf(os.Stderr, "2. Reinstall the console from the correct project location:\n")
		fmt.Fprintf(os.Stderr, "   cd /path/to/openemr-on-eks/console && make install\n\n")
		os.Exit(1)
	}

	scriptsPath := filepath.Join(projectRoot, "scripts")

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

func (m model) Init() tea.Cmd {
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// Handle command execution results first
	switch msg := msg.(type) {
	case outputMsg:
		m.output = string(msg)
		m.executing = false
		// Force a refresh by returning a command that does nothing
		return m, tea.Batch()
	case errorMsg:
		m.error = string(msg)
		m.executing = false
		// Force a refresh by returning a command that does nothing
		return m, tea.Batch()
	}

	if m.executing {
		// If executing, only handle quit
		switch msg := msg.(type) {
		case tea.KeyMsg:
			if msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyEsc || msg.Type == tea.KeyEnter {
				m.executing = false
				m.output = ""
				m.error = ""
				return m, nil
			}
		}
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC, tea.KeyEsc:
			m.quitting = true
			return m, tea.Quit

		case tea.KeyUp:
			if m.cursor > 0 {
				m.cursor--
			} else {
				m.cursor = len(m.commands) - 1
			}

		case tea.KeyDown:
			if m.cursor < len(m.commands)-1 {
				m.cursor++
			} else {
				m.cursor = 0
			}

		case tea.KeyEnter:
			m.selected = m.cursor
			m.executing = true
			m.output = ""
			m.error = ""
			return m, m.executeCommand(m.commands[m.cursor])
		}
	}

	return m, nil
}

func (m model) executeCommand(cmd command) tea.Cmd {
	return func() tea.Msg {
		// Check if script exists
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

		// Make script executable
		os.Chmod(cmd.script, 0755)

		// Build the command to run
		scriptPath := cmd.script
		scriptArgs := strings.Join(cmd.args, " ")
		workingDir := filepath.Dir(cmd.script)

		// Open command in a new terminal window (macOS only)
		if runtime.GOOS != "darwin" {
			return errorMsg(fmt.Sprintf("Terminal execution is currently only supported on macOS. Detected OS: %s", runtime.GOOS))
		}

		// Use osascript to open a new Terminal window
		// Escape single quotes in paths and arguments for shell safety
		escapedScriptPath := strings.ReplaceAll(scriptPath, "'", "'\"'\"'")
		escapedArgs := strings.ReplaceAll(scriptArgs, "'", "'\"'\"'")
		escapedWorkingDir := strings.ReplaceAll(workingDir, "'", "'\"'\"'")

		command := fmt.Sprintf("cd '%s' && '%s' %s; echo ''; echo 'Press any key and then return to go back to the command line'; read -n 1", escapedWorkingDir, escapedScriptPath, escapedArgs)
		execCmd := exec.Command("osascript", "-e", fmt.Sprintf(`tell application "Terminal" to do script "%s"`, command))

		// Execute the command to open terminal
		if err := execCmd.Run(); err != nil {
			return errorMsg(fmt.Sprintf("Failed to open terminal window: %s", err.Error()))
		}

		// Return success message
		return outputMsg(fmt.Sprintf("✅ Command opened in new terminal window\n\nScript: %s\nWorking directory: %s\n\nCheck the terminal window for output.", scriptPath, workingDir))
	}
}

type outputMsg string
type errorMsg string

func (m model) View() string {
	if m.quitting {
		return "\n  See you later!\n\n"
	}

	if m.executing {
		var view strings.Builder
		view.WriteString(titleStyle.Render("OpenEMR on EKS Console"))
		view.WriteString("\n\n")
		view.WriteString(itemStyle.Render("Executing: " + m.commands[m.selected].title))
		view.WriteString("\n\n")

		if m.error != "" {
			view.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Bold(true).Render("❌ Error:\n"))
			view.WriteString("\n")
			// Write error output directly (may contain ANSI codes)
			view.WriteString(m.error)
			view.WriteString("\n\n")
		} else if m.output != "" {
			view.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("46")).Bold(true).Render("✅ Output:\n"))
			view.WriteString("\n")
			// Limit output display to last 100 lines to prevent overwhelming the screen
			lines := strings.Split(m.output, "\n")
			start := 0
			if len(lines) > 100 {
				start = len(lines) - 100
				view.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("243")).Italic(true).Render("(Showing last 100 lines of output)\n\n"))
			}
			// Preserve ANSI color codes from script output - write raw output
			// This allows scripts' color codes to display properly
			view.WriteString(strings.Join(lines[start:], "\n"))
			view.WriteString("\n\n")
		} else {
			view.WriteString(descStyle.Render("⏳ Running command..."))
			view.WriteString("\n\n")
		}

		view.WriteString(helpStyle.Render("Press Enter, Esc, or Ctrl+C to return to menu"))
		return view.String()
	}

	var s strings.Builder
	s.WriteString(titleStyle.Render("OpenEMR on EKS Console"))
	s.WriteString("\n\n")

	for i, cmd := range m.commands {
		cursor := " "
		if m.cursor == i {
			cursor = ">"
			s.WriteString(selectedStyle.Render(fmt.Sprintf("%s %s", cursor, cmd.title)))
		} else {
			s.WriteString(itemStyle.Render(fmt.Sprintf("%s %s", cursor, cmd.title)))
		}
		s.WriteString("\n")
		s.WriteString(descStyle.Render(cmd.description))
		s.WriteString("\n")
		// Get relative script path for display
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

	s.WriteString(helpStyle.Render("↑/↓: Navigate  Enter: Execute  Esc/Ctrl+C: Quit"))
	return s.String()
}

func main() {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error: %v", err)
		os.Exit(1)
	}
}
