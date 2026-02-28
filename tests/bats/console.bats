#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: Console TUI structural and cross-file consistency tests
# Purpose: Validate that the console Go source, go.mod, documentation, and
#          versions.yaml stay in sync. Catches version drift, missing commands
#          in docs, and broken module paths.
# Scope:   Read-only — inspects files, never modifies anything.
# -----------------------------------------------------------------------------

load test_helper

setup() {
  CONSOLE_DIR="${PROJECT_ROOT}/console"
  MAIN_GO="${CONSOLE_DIR}/main.go"
  GO_MOD="${CONSOLE_DIR}/go.mod"
  VERSIONS_FILE="${PROJECT_ROOT}/versions.yaml"
  CONSOLE_README="${CONSOLE_DIR}/README.md"
  CONSOLE_GUIDE="${PROJECT_ROOT}/docs/CONSOLE_GUIDE.md"
}

# ── Source file existence ────────────────────────────────────────────────────

@test "console/Makefile exists" {
  [ -f "${CONSOLE_DIR}/Makefile" ]
}

@test "console/main_test.go exists" {
  [ -f "${CONSOLE_DIR}/main_test.go" ]
}

@test "console unit tests pass (go test)" {
  if ! command -v go >/dev/null 2>&1; then skip "go not installed"; fi
  run bash -c "cd '${CONSOLE_DIR}' && go test -count=1 ./... 2>&1"
  [ "$status" -eq 0 ]
}

# ── Go module structure ──────────────────────────────────────────────────────

@test "go.mod uses bubbletea v2 module path (charm.land)" {
  run grep 'charm.land/bubbletea/v2' "$GO_MOD"
  [ "$status" -eq 0 ]
}

@test "go.mod uses lipgloss v2 module path (charm.land)" {
  run grep 'charm.land/lipgloss/v2' "$GO_MOD"
  [ "$status" -eq 0 ]
}

@test "go.mod does not reference old github.com/charmbracelet/bubbletea" {
  run grep 'github.com/charmbracelet/bubbletea' "$GO_MOD"
  [ "$status" -ne 0 ]
}

@test "go.mod does not reference old github.com/charmbracelet/lipgloss" {
  run grep 'github.com/charmbracelet/lipgloss' "$GO_MOD"
  [ "$status" -ne 0 ]
}

@test "main.go imports charm.land/bubbletea/v2" {
  run grep 'charm.land/bubbletea/v2' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go imports charm.land/lipgloss/v2" {
  run grep 'charm.land/lipgloss/v2' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

# ── Cross-file: versions.yaml matches go.mod ────────────────────────────────

@test "CROSS-FILE: versions.yaml bubbletea version matches go.mod" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.go_packages.bubbletea.current' "$VERSIONS_FILE")
  run grep "charm.land/bubbletea/v2" "$GO_MOD"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CROSS-FILE: versions.yaml lipgloss version matches go.mod" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.go_packages.lipgloss.current' "$VERSIONS_FILE")
  run grep "charm.land/lipgloss/v2" "$GO_MOD"
  [[ "$output" == *"$yaml_ver"* ]]
}

# ── TUI structure ────────────────────────────────────────────────────────────

@test "main.go defines category type" {
  run grep 'type category struct' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has Deployment category" {
  run grep '"Deployment"' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has Operations category" {
  run grep '"Operations"' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has Information category" {
  run grep '"Information"' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has destructive flag for destroy command" {
  run grep 'destructive: true' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go supports vim-style j/k navigation" {
  run grep '"j"' "$MAIN_GO"
  [ "$status" -eq 0 ]
  run grep '"k"' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go supports q to quit" {
  run grep '"q"' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has confirmation dialog for destructive actions" {
  run grep 'confirming' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go defines version constant" {
  run grep 'const version' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go supports g/G jump-to-top/bottom navigation" {
  run grep '"g"' "$MAIN_GO"
  [ "$status" -eq 0 ]
  run grep '"G"' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has jumpTo method" {
  run grep 'func (m \*model) jumpTo' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has commandPosition helper" {
  run grep 'func (m model) commandPosition' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has help toggle (showHelp)" {
  run grep 'showHelp' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go tracks command count (cmdCount)" {
  run grep 'cmdCount' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

# ── Input prompt system ─────────────────────────────────────────────────────

@test "main.go defines inputField type" {
  run grep 'type inputField struct' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go defines inputState type" {
  run grep 'type inputState struct' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has prompts field on command struct" {
  run grep 'prompts.*\[\]inputField' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has input field on model struct" {
  run grep 'input.*\*inputState' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go defines prompts for restore.sh" {
  run grep -A5 'restore.sh' "$MAIN_GO"
  [[ "$output" == *"prompts"* ]]
}

@test "main.go defines prompts for search-codebase.sh" {
  run grep -A5 'search-codebase.sh' "$MAIN_GO"
  [[ "$output" == *"prompts"* ]]
}

@test "main.go defines prompts for check-openemr-versions.sh" {
  run grep -A5 'check-openemr-versions.sh' "$MAIN_GO"
  [[ "$output" == *"prompts"* ]]
}

@test "main.go has renderInputForm method" {
  run grep 'func (m model) renderInputForm' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has buildArgsFromInput function" {
  run grep 'func buildArgsFromInput' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has updateInput method" {
  run grep 'func (m model) updateInput' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

@test "main.go has form styling (formBoxStyle)" {
  run grep 'formBoxStyle' "$MAIN_GO"
  [ "$status" -eq 0 ]
}

# ── Scripts referenced by console exist ──────────────────────────────────────

@test "all scripts referenced in main.go exist" {
  local scripts
  scripts=$(grep 'filepath.Join(scriptsPath' "$MAIN_GO" | sed 's/.*"\([^"]*\.sh\)".*/\1/' | sort -u)
  for script in $scripts; do
    [ -f "${PROJECT_ROOT}/scripts/${script}" ] || {
      echo "Missing script: scripts/${script}"
      return 1
    }
  done
}

# ── Documentation consistency ────────────────────────────────────────────────

@test "console README mentions v2 bubbletea" {
  run grep 'bubbletea/v2' "$CONSOLE_README"
  [ "$status" -eq 0 ]
}

@test "console README mentions v2 lipgloss" {
  run grep 'lipgloss/v2' "$CONSOLE_README"
  [ "$status" -eq 0 ]
}

@test "console README documents vim navigation (j/k)" {
  run grep 'j/k' "$CONSOLE_README"
  [ "$status" -eq 0 ]
}

@test "console README documents Restore from Backup" {
  run grep 'Restore from Backup' "$CONSOLE_README"
  [ "$status" -eq 0 ]
}

@test "CONSOLE_GUIDE documents vim navigation (j/k)" {
  run grep 'j/k' "$CONSOLE_GUIDE"
  [ "$status" -eq 0 ]
}

@test "CONSOLE_GUIDE documents Restore from Backup" {
  run grep 'Restore from Backup' "$CONSOLE_GUIDE"
  [ "$status" -eq 0 ]
}

@test "CONSOLE_GUIDE documents destructive action confirmation" {
  run grep -i 'confirmation\|destructive' "$CONSOLE_GUIDE"
  [ "$status" -eq 0 ]
}

@test "console README documents g/G jump navigation" {
  run grep -i 'g.*first\|G.*last\|Home\|End' "$CONSOLE_README"
  [ "$status" -eq 0 ]
}

@test "CONSOLE_GUIDE documents g/G jump navigation" {
  run grep -i 'g.*first\|G.*last\|Home\|End' "$CONSOLE_GUIDE"
  [ "$status" -eq 0 ]
}

@test "CONSOLE_GUIDE documents help toggle (?)" {
  run grep '?' "$CONSOLE_GUIDE"
  [ "$status" -eq 0 ]
}

@test "console README documents input prompts" {
  run grep -i 'input\|prompt\|argument' "$CONSOLE_README"
  [ "$status" -eq 0 ]
}

@test "CONSOLE_GUIDE documents input prompts" {
  run grep -i 'input\|prompt\|argument' "$CONSOLE_GUIDE"
  [ "$status" -eq 0 ]
}

# ── Build validation ────────────────────────────────────────────────────────

@test "console builds successfully (go build)" {
  if ! command -v go >/dev/null 2>&1; then skip "go not installed"; fi
  run bash -c "cd '${CONSOLE_DIR}' && go build -o /dev/null . 2>&1"
  [ "$status" -eq 0 ]
}

@test "console passes go vet" {
  if ! command -v go >/dev/null 2>&1; then skip "go not installed"; fi
  run bash -c "cd '${CONSOLE_DIR}' && go vet ./... 2>&1"
  [ "$status" -eq 0 ]
}
