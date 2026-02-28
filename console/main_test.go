package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// ── Test helpers ────────────────────────────────────────────────────────

func testCategories() []category {
	return []category{
		{
			name: "Alpha",
			icon: "A",
			commands: []command{
				{title: "Cmd1", description: "First", script: "/tmp/a.sh"},
				{title: "Cmd2", description: "Second", script: "/tmp/b.sh"},
			},
		},
		{
			name: "Beta",
			icon: "B",
			commands: []command{
				{title: "Cmd3", description: "Third", script: "/tmp/c.sh", args: []string{"--flag"}},
				{title: "Danger", description: "Destructive", script: "/tmp/d.sh", destructive: true},
			},
		},
	}
}

func testModel() model {
	cats := testCategories()
	flat := buildFlatIndex(cats)
	startCursor := 0
	cmdTotal := 0
	for i, e := range flat {
		if !e.isCategory {
			if cmdTotal == 0 {
				startCursor = i
			}
			cmdTotal++
		}
	}
	return model{
		categories:  cats,
		flatIndex:   flat,
		cursor:      startCursor,
		projectRoot: "/tmp/test-project",
		cmdCount:    cmdTotal,
	}
}

// keyMsg constructs a tea.KeyPressMsg suitable for feeding into Update.
func keyMsg(s string) tea.Msg {
	switch s {
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "esc":
		return tea.KeyPressMsg{Code: tea.KeyEscape}
	case "home":
		return tea.KeyPressMsg{Code: tea.KeyHome}
	case "end":
		return tea.KeyPressMsg{Code: tea.KeyEnd}
	case "ctrl+c":
		return tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl}
	default:
		r := []rune(s)
		if len(r) == 1 {
			return tea.KeyPressMsg{Code: r[0], Text: s}
		}
		return tea.KeyPressMsg{Text: s}
	}
}

// ── buildFlatIndex ──────────────────────────────────────────────────────

func TestBuildFlatIndex(t *testing.T) {
	cats := testCategories()
	flat := buildFlatIndex(cats)

	// 2 categories + 2 commands each = 6 entries
	if got := len(flat); got != 6 {
		t.Fatalf("expected 6 flat entries, got %d", got)
	}

	// First entry is always a category header
	if !flat[0].isCategory {
		t.Error("first entry should be a category")
	}
	if flat[0].catIdx != 0 {
		t.Errorf("first category catIdx = %d, want 0", flat[0].catIdx)
	}

	// Second entry is a command under the first category
	if flat[1].isCategory {
		t.Error("second entry should be a command, not a category")
	}
	if flat[1].catIdx != 0 || flat[1].cmdIdx != 0 {
		t.Errorf("second entry = cat %d cmd %d, want cat 0 cmd 0", flat[1].catIdx, flat[1].cmdIdx)
	}

	// Fourth entry is the second category header
	if !flat[3].isCategory || flat[3].catIdx != 1 {
		t.Error("fourth entry should be category 1")
	}
}

func TestBuildFlatIndexEmpty(t *testing.T) {
	flat := buildFlatIndex(nil)
	if len(flat) != 0 {
		t.Fatalf("expected 0 entries for nil categories, got %d", len(flat))
	}
}

func TestBuildFlatIndexSingleCategory(t *testing.T) {
	cats := []category{{
		name:     "Solo",
		commands: []command{{title: "Only"}},
	}}
	flat := buildFlatIndex(cats)
	if len(flat) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(flat))
	}
	if !flat[0].isCategory {
		t.Error("entry 0 should be category")
	}
	if flat[1].isCategory {
		t.Error("entry 1 should be command")
	}
}

// ── moveCursor ──────────────────────────────────────────────────────────

func TestMoveCursorDown(t *testing.T) {
	m := testModel()
	start := m.cursor
	m.moveCursor(1)

	if m.cursor == start {
		t.Error("cursor should have moved")
	}
	if m.flatIndex[m.cursor].isCategory {
		t.Error("cursor should not land on a category")
	}
}

func TestMoveCursorUp(t *testing.T) {
	m := testModel()
	// Move to the last command first
	m.jumpTo(false)
	last := m.cursor
	m.moveCursor(-1)

	if m.cursor == last {
		t.Error("cursor should have moved up from last")
	}
	if m.flatIndex[m.cursor].isCategory {
		t.Error("cursor should not land on a category")
	}
}

func TestMoveCursorSkipsCategories(t *testing.T) {
	m := testModel()
	// Put cursor on last command of first category (index 2)
	m.cursor = 2

	// Move down - should skip the Beta category header at index 3
	m.moveCursor(1)
	if m.flatIndex[m.cursor].isCategory {
		t.Error("moveCursor should skip category headers")
	}
	if m.cursor != 4 {
		t.Errorf("cursor = %d, want 4 (first command in Beta)", m.cursor)
	}
}

func TestMoveCursorWrapsForward(t *testing.T) {
	m := testModel()
	m.jumpTo(false)
	last := m.cursor
	m.moveCursor(1)

	// Should wrap to first command
	if m.cursor >= last {
		t.Errorf("cursor should wrap to beginning, got %d", m.cursor)
	}
	if m.flatIndex[m.cursor].isCategory {
		t.Error("wrapped cursor should land on a command")
	}
}

func TestMoveCursorWrapsBackward(t *testing.T) {
	m := testModel()
	m.jumpTo(true)
	first := m.cursor
	m.moveCursor(-1)

	// Should wrap to last command
	if m.cursor <= first {
		t.Errorf("cursor should wrap to end, got %d", m.cursor)
	}
}

// ── jumpTo ──────────────────────────────────────────────────────────────

func TestJumpToFirst(t *testing.T) {
	m := testModel()
	m.jumpTo(false) // go to last first
	m.jumpTo(true)  // then jump to first

	// Should be on first non-category entry
	if m.flatIndex[m.cursor].isCategory {
		t.Error("jumpTo first should land on a command")
	}
	if m.cursor != 1 {
		t.Errorf("jumpTo first: cursor = %d, want 1", m.cursor)
	}
}

func TestJumpToLast(t *testing.T) {
	m := testModel()
	m.jumpTo(false)

	if m.flatIndex[m.cursor].isCategory {
		t.Error("jumpTo last should land on a command")
	}
	if m.cursor != 5 {
		t.Errorf("jumpTo last: cursor = %d, want 5", m.cursor)
	}
}

// ── commandPosition ─────────────────────────────────────────────────────

func TestCommandPositionFirst(t *testing.T) {
	m := testModel()
	m.jumpTo(true)
	if pos := m.commandPosition(); pos != 1 {
		t.Errorf("first command position = %d, want 1", pos)
	}
}

func TestCommandPositionLast(t *testing.T) {
	m := testModel()
	m.jumpTo(false)
	if pos := m.commandPosition(); pos != m.cmdCount {
		t.Errorf("last command position = %d, want %d", pos, m.cmdCount)
	}
}

func TestCommandPositionTraversal(t *testing.T) {
	m := testModel()
	m.jumpTo(true)
	positions := []int{m.commandPosition()}
	for i := 1; i < m.cmdCount; i++ {
		m.moveCursor(1)
		positions = append(positions, m.commandPosition())
	}

	for i, pos := range positions {
		if pos != i+1 {
			t.Errorf("position[%d] = %d, want %d", i, pos, i+1)
		}
	}
}

func TestCmdCountMatchesCategories(t *testing.T) {
	m := testModel()
	total := 0
	for _, cat := range m.categories {
		total += len(cat.commands)
	}
	if m.cmdCount != total {
		t.Errorf("cmdCount = %d, want %d", m.cmdCount, total)
	}
}

// ── verifyProjectStructure ──────────────────────────────────────────────

func TestVerifyProjectStructureValid(t *testing.T) {
	tmp := t.TempDir()
	for _, dir := range []string{"scripts", "terraform", "k8s"} {
		os.MkdirAll(filepath.Join(tmp, dir), 0755)
	}
	if !verifyProjectStructure(tmp) {
		t.Error("expected valid project structure")
	}
}

func TestVerifyProjectStructureMissingDir(t *testing.T) {
	tmp := t.TempDir()
	os.MkdirAll(filepath.Join(tmp, "scripts"), 0755)
	os.MkdirAll(filepath.Join(tmp, "terraform"), 0755)
	// k8s is missing
	if verifyProjectStructure(tmp) {
		t.Error("expected invalid when k8s is missing")
	}
}

func TestVerifyProjectStructureNonexistent(t *testing.T) {
	if verifyProjectStructure("/nonexistent/path/xyz") {
		t.Error("expected false for nonexistent path")
	}
}

func TestVerifyProjectStructureEmpty(t *testing.T) {
	tmp := t.TempDir()
	if verifyProjectStructure(tmp) {
		t.Error("expected false for empty directory")
	}
}

// ── convertWindowsPathToUnix ────────────────────────────────────────────

func TestConvertWindowsPathBackslashes(t *testing.T) {
	// On non-Windows systems, filepath.Abs won't produce drive letters,
	// but the backslash replacement should still work on the fallback path.
	input := `some\path\to\file.sh`
	result := convertWindowsPathToUnix(input)
	if strings.Contains(result, `\`) {
		t.Errorf("result still contains backslashes: %s", result)
	}
}

// ── Init ────────────────────────────────────────────────────────────────

func TestInitReturnsNil(t *testing.T) {
	m := testModel()
	if cmd := m.Init(); cmd != nil {
		t.Error("Init() should return nil")
	}
}

// ── Update: navigation ──────────────────────────────────────────────────

func TestUpdateDownKey(t *testing.T) {
	m := testModel()
	start := m.cursor
	updated, _ := m.Update(keyMsg("j"))
	m2 := updated.(model)
	if m2.cursor == start {
		t.Error("j key should move cursor down")
	}
}

func TestUpdateUpKey(t *testing.T) {
	m := testModel()
	m.jumpTo(false) // start at last
	last := m.cursor
	updated, _ := m.Update(keyMsg("k"))
	m2 := updated.(model)
	if m2.cursor == last {
		t.Error("k key should move cursor up")
	}
}

func TestUpdateArrowDown(t *testing.T) {
	m := testModel()
	start := m.cursor
	updated, _ := m.Update(keyMsg("down"))
	m2 := updated.(model)
	if m2.cursor == start {
		t.Error("down arrow should move cursor")
	}
}

func TestUpdateArrowUp(t *testing.T) {
	m := testModel()
	m.jumpTo(false)
	last := m.cursor
	updated, _ := m.Update(keyMsg("up"))
	m2 := updated.(model)
	if m2.cursor == last {
		t.Error("up arrow should move cursor")
	}
}

func TestUpdateJumpToFirstG(t *testing.T) {
	m := testModel()
	m.jumpTo(false) // start at last
	updated, _ := m.Update(keyMsg("g"))
	m2 := updated.(model)
	if m2.cursor != 1 {
		t.Errorf("g key: cursor = %d, want 1", m2.cursor)
	}
}

func TestUpdateJumpToLastG(t *testing.T) {
	m := testModel()
	m.jumpTo(true) // start at first
	updated, _ := m.Update(keyMsg("G"))
	m2 := updated.(model)
	if m2.cursor != 5 {
		t.Errorf("G key: cursor = %d, want 5", m2.cursor)
	}
}

// ── Update: quitting ────────────────────────────────────────────────────

func TestUpdateQuitQ(t *testing.T) {
	m := testModel()
	updated, cmd := m.Update(keyMsg("q"))
	m2 := updated.(model)
	if !m2.quitting {
		t.Error("q should set quitting=true")
	}
	if cmd == nil {
		t.Error("q should return tea.Quit command")
	}
}

func TestUpdateQuitEsc(t *testing.T) {
	m := testModel()
	updated, cmd := m.Update(keyMsg("esc"))
	m2 := updated.(model)
	if !m2.quitting {
		t.Error("esc should set quitting=true")
	}
	if cmd == nil {
		t.Error("esc should return tea.Quit command")
	}
}

func TestUpdateQuitCtrlC(t *testing.T) {
	m := testModel()
	updated, cmd := m.Update(keyMsg("ctrl+c"))
	m2 := updated.(model)
	if !m2.quitting {
		t.Error("ctrl+c should set quitting=true")
	}
	if cmd == nil {
		t.Error("ctrl+c should return quit command")
	}
}

// ── Update: help toggle ─────────────────────────────────────────────────

func TestUpdateHelpToggle(t *testing.T) {
	m := testModel()
	if m.showHelp {
		t.Fatal("showHelp should start false")
	}

	updated, _ := m.Update(keyMsg("?"))
	m2 := updated.(model)
	if !m2.showHelp {
		t.Error("? should toggle showHelp to true")
	}

	updated, _ = m2.Update(keyMsg("?"))
	m3 := updated.(model)
	if m3.showHelp {
		t.Error("second ? should toggle showHelp back to false")
	}
}

func TestUpdateEscClosesHelp(t *testing.T) {
	m := testModel()
	m.showHelp = true

	updated, _ := m.Update(keyMsg("esc"))
	m2 := updated.(model)
	if m2.showHelp {
		t.Error("esc should close help panel")
	}
	if m2.quitting {
		t.Error("esc should not quit when help is open")
	}
}

// ── Update: enter on commands ───────────────────────────────────────────

func TestUpdateEnterOnCategorySkips(t *testing.T) {
	m := testModel()
	m.cursor = 0 // category header
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.flatIndex[m2.cursor].isCategory {
		t.Error("enter on category should advance to next command")
	}
}

func TestUpdateEnterOnDestructiveConfirms(t *testing.T) {
	m := testModel()
	// Move to the destructive command "Danger" at flat index 5
	m.cursor = 5
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if !m2.confirming {
		t.Error("enter on destructive command should set confirming=true")
	}
	if m2.executing {
		t.Error("should not be executing yet during confirmation")
	}
}

func TestUpdateConfirmCancel(t *testing.T) {
	m := testModel()
	m.cursor = 5
	m.confirming = true

	updated, _ := m.Update(keyMsg("n"))
	m2 := updated.(model)
	if m2.confirming {
		t.Error("any key other than Y should cancel confirmation")
	}
}

// ── Update: output/error messages ───────────────────────────────────────

func TestUpdateOutputMsg(t *testing.T) {
	m := testModel()
	m.executing = true

	updated, _ := m.Update(outputMsg("done"))
	m2 := updated.(model)
	if m2.executing {
		t.Error("outputMsg should clear executing")
	}
	if m2.output != "done" {
		t.Errorf("output = %q, want %q", m2.output, "done")
	}
}

func TestUpdateErrorMsg(t *testing.T) {
	m := testModel()
	m.executing = true

	updated, _ := m.Update(errorMsg("fail"))
	m2 := updated.(model)
	if m2.executing {
		t.Error("errorMsg should clear executing")
	}
	if m2.error != "fail" {
		t.Errorf("error = %q, want %q", m2.error, "fail")
	}
}

func TestUpdateExecutingDismiss(t *testing.T) {
	m := testModel()
	m.executing = true
	m.output = "some output"

	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.executing {
		t.Error("enter during execution should dismiss")
	}
}

// ── View rendering ──────────────────────────────────────────────────────

func TestViewContainsVersion(t *testing.T) {
	m := testModel()
	v := m.View()
	if !strings.Contains(v.Content, version) {
		t.Errorf("view should contain version %q", version)
	}
}

func TestViewContainsCategoryNames(t *testing.T) {
	m := testModel()
	v := m.View()
	for _, cat := range m.categories {
		if !strings.Contains(v.Content, cat.name) {
			t.Errorf("view should contain category name %q", cat.name)
		}
	}
}

func TestViewContainsCommandTitles(t *testing.T) {
	m := testModel()
	v := m.View()
	for _, cat := range m.categories {
		for _, cmd := range cat.commands {
			if !strings.Contains(v.Content, cmd.title) {
				t.Errorf("view should contain command title %q", cmd.title)
			}
		}
	}
}

func TestViewContainsPositionIndicator(t *testing.T) {
	m := testModel()
	v := m.View()
	pos := m.commandPosition()
	indicator := strings.Contains(v.Content, "1/4") || strings.Contains(v.Content, "2/4") ||
		strings.Contains(v.Content, "3/4") || strings.Contains(v.Content, "4/4")
	if !indicator {
		t.Errorf("view should contain position indicator, pos=%d count=%d", pos, m.cmdCount)
	}
}

func TestViewContainsHelpHint(t *testing.T) {
	m := testModel()
	v := m.View()
	if !strings.Contains(v.Content, "?") {
		t.Error("view should contain help hint '?'")
	}
}

func TestViewQuitting(t *testing.T) {
	m := testModel()
	m.quitting = true
	v := m.View()
	if !strings.Contains(v.Content, "See you later") {
		t.Error("quitting view should contain farewell")
	}
}

func TestViewConfirming(t *testing.T) {
	m := testModel()
	m.cursor = 5 // destructive command
	m.confirming = true
	v := m.View()
	if !strings.Contains(v.Content, "DESTRUCTIVE") {
		t.Error("confirming view should contain DESTRUCTIVE warning")
	}
}

func TestViewExecutingWithOutput(t *testing.T) {
	m := testModel()
	m.cursor = 1
	m.executing = true
	m.output = "execution output here"
	v := m.View()
	if !strings.Contains(v.Content, "execution output here") {
		t.Error("executing view should show output")
	}
}

func TestViewExecutingWithError(t *testing.T) {
	m := testModel()
	m.cursor = 1
	m.executing = true
	m.error = "something broke"
	v := m.View()
	if !strings.Contains(v.Content, "something broke") {
		t.Error("executing view should show error")
	}
}

func TestViewExpandedHelp(t *testing.T) {
	m := testModel()
	m.showHelp = true
	v := m.View()
	if !strings.Contains(v.Content, "First item") {
		t.Error("expanded help should contain 'First item'")
	}
	if !strings.Contains(v.Content, "Last item") {
		t.Error("expanded help should contain 'Last item'")
	}
}

func TestViewDestructiveCommandMarked(t *testing.T) {
	m := testModel()
	v := m.View()
	if !strings.Contains(v.Content, "⚠") {
		t.Error("view should mark destructive commands with ⚠")
	}
}

func TestViewAltScreen(t *testing.T) {
	m := testModel()
	v := m.View()
	if !v.AltScreen {
		t.Error("view should use alt screen")
	}
}

// ── Miscellaneous ───────────────────────────────────────────────────────

func TestVersionNotEmpty(t *testing.T) {
	if version == "" {
		t.Error("version constant should not be empty")
	}
}

func TestModelStartsCursorOnCommand(t *testing.T) {
	m := testModel()
	if m.flatIndex[m.cursor].isCategory {
		t.Error("initial cursor should be on a command, not a category")
	}
}

func TestModelStartsNotQuitting(t *testing.T) {
	m := testModel()
	if m.quitting || m.executing || m.confirming || m.showHelp {
		t.Error("model should start in default idle state")
	}
}

func TestModelStartsWithNilInput(t *testing.T) {
	m := testModel()
	if m.input != nil {
		t.Error("model should start with nil input state")
	}
}

// ── Input system ────────────────────────────────────────────────────────

func testFieldsRequired() []inputField {
	return []inputField{
		{label: "Bucket", placeholder: "my-bucket", required: true},
		{label: "Snapshot", placeholder: "snap-123", required: false},
	}
}

func testFieldsSingle() []inputField {
	return []inputField{
		{label: "Search", placeholder: "term", required: true},
	}
}

func testFieldsWithFlag() []inputField {
	return []inputField{
		{label: "Pattern", placeholder: "e.g. 7.0", required: false, flag: "search"},
	}
}

func testModelWithPrompts() model {
	cats := []category{
		{
			name: "Test",
			icon: "T",
			commands: []command{
				{title: "Plain", description: "No prompts", script: "/tmp/plain.sh"},
				{title: "WithPrompts", description: "Has prompts", script: "/tmp/prompted.sh", prompts: testFieldsRequired()},
				{title: "SinglePrompt", description: "One field", script: "/tmp/single.sh", prompts: testFieldsSingle()},
				{title: "FlagPrompt", description: "Flag field", script: "/tmp/flag.sh", prompts: testFieldsWithFlag()},
			},
		},
	}
	flat := buildFlatIndex(cats)
	return model{
		categories:  cats,
		flatIndex:   flat,
		cursor:      1,
		projectRoot: "/tmp/test",
		cmdCount:    4,
	}
}

func TestNewInputState(t *testing.T) {
	fields := testFieldsRequired()
	inp := newInputState(fields)
	if len(inp.fields) != 2 {
		t.Fatalf("expected 2 fields, got %d", len(inp.fields))
	}
	if len(inp.values) != 2 {
		t.Fatalf("expected 2 values, got %d", len(inp.values))
	}
	if inp.active != 0 {
		t.Errorf("active should start at 0, got %d", inp.active)
	}
	if inp.cursor != 0 {
		t.Errorf("cursor should start at 0, got %d", inp.cursor)
	}
	if inp.attempted {
		t.Error("attempted should start false")
	}
}

func TestEnterOnCommandWithPromptsOpensInput(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2 // "WithPrompts" command
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.input == nil {
		t.Fatal("enter on command with prompts should open input form")
	}
	if len(m2.input.fields) != 2 {
		t.Errorf("expected 2 input fields, got %d", len(m2.input.fields))
	}
}

func TestEnterOnCommandWithoutPromptsDoesNotOpenInput(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 1 // "Plain" command (no prompts)
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.input != nil {
		t.Error("enter on command without prompts should not open input form")
	}
}

func TestInputEscCancels(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	updated, _ := m.Update(keyMsg("esc"))
	m2 := updated.(model)
	if m2.input != nil {
		t.Error("esc should close input form")
	}
	if m2.quitting {
		t.Error("esc in input should not quit the app")
	}
}

func TestInputCtrlCQuits(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	updated, cmd := m.Update(keyMsg("ctrl+c"))
	m2 := updated.(model)
	if !m2.quitting {
		t.Error("ctrl+c in input should quit")
	}
	if cmd == nil {
		t.Error("ctrl+c should return quit command")
	}
}

func TestInputTabAdvancesField(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	if m.input.active != 0 {
		t.Fatal("should start on field 0")
	}
	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	m2 := updated.(model)
	if m2.input.active != 1 {
		t.Errorf("tab should advance to field 1, got %d", m2.input.active)
	}
}

func TestInputTabWraps(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.active = 1 // last field
	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	m2 := updated.(model)
	if m2.input.active != 0 {
		t.Errorf("tab on last field should wrap to 0, got %d", m2.input.active)
	}
}

func TestInputShiftTabGoesBack(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.active = 1
	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift})
	m2 := updated.(model)
	if m2.input.active != 0 {
		t.Errorf("shift+tab should go back to field 0, got %d", m2.input.active)
	}
}

func TestInputTypingInsertsText(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	updated, _ := m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	m2 := updated.(model)
	if m2.input.values[0] != "a" {
		t.Errorf("typing 'a' should set value to 'a', got %q", m2.input.values[0])
	}
	if m2.input.cursor != 1 {
		t.Errorf("cursor should be at 1 after typing, got %d", m2.input.cursor)
	}
}

func TestInputTypingMultipleChars(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.Update(tea.KeyPressMsg{Code: 'h', Text: "h"})
	updated, _ := m.Update(tea.KeyPressMsg{Code: 'i', Text: "i"})
	m2 := updated.(model)
	if m2.input.values[0] != "hi" {
		t.Errorf("expected 'hi', got %q", m2.input.values[0])
	}
}

func TestInputBackspaceDeletesChar(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.values[0] = "abc"
	m.input.cursor = 3
	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyBackspace})
	m2 := updated.(model)
	if m2.input.values[0] != "ab" {
		t.Errorf("backspace should delete last char, got %q", m2.input.values[0])
	}
	if m2.input.cursor != 2 {
		t.Errorf("cursor should be 2 after backspace, got %d", m2.input.cursor)
	}
}

func TestInputBackspaceAtStartNoOp(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.values[0] = "abc"
	m.input.cursor = 0
	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyBackspace})
	m2 := updated.(model)
	if m2.input.values[0] != "abc" {
		t.Errorf("backspace at start should be no-op, got %q", m2.input.values[0])
	}
}

func TestInputDeleteKey(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.values[0] = "abc"
	m.input.cursor = 1
	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyDelete})
	m2 := updated.(model)
	if m2.input.values[0] != "ac" {
		t.Errorf("delete should remove char at cursor, got %q", m2.input.values[0])
	}
}

func TestInputLeftRightArrows(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.values[0] = "abc"
	m.input.cursor = 2

	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyLeft})
	m2 := updated.(model)
	if m2.input.cursor != 1 {
		t.Errorf("left should move cursor to 1, got %d", m2.input.cursor)
	}

	updated, _ = m2.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	m3 := updated.(model)
	if m3.input.cursor != 2 {
		t.Errorf("right should move cursor to 2, got %d", m3.input.cursor)
	}
}

func TestInputHomeEnd(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.values[0] = "abcdef"
	m.input.cursor = 3

	updated, _ := m.Update(keyMsg("home"))
	m2 := updated.(model)
	if m2.input.cursor != 0 {
		t.Errorf("home should move cursor to 0, got %d", m2.input.cursor)
	}

	updated, _ = m2.Update(keyMsg("end"))
	m3 := updated.(model)
	if m3.input.cursor != 6 {
		t.Errorf("end should move cursor to end (6), got %d", m3.input.cursor)
	}
}

func TestInputEnterAdvancesFieldWhenNotLast(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.values[0] = "bucket-name"
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.input == nil {
		t.Fatal("input should still be open")
	}
	if m2.input.active != 1 {
		t.Errorf("enter on non-last field should advance, got active=%d", m2.input.active)
	}
}

func TestInputSubmitRequiredEmpty(t *testing.T) {
	m := testModelWithPrompts()
	m.input = newInputState(testFieldsRequired())
	m.input.active = 1 // last field
	// Field 0 (Bucket) is required but empty
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.input == nil {
		t.Fatal("input should remain open when required fields are empty")
	}
	if !m2.input.attempted {
		t.Error("attempted should be set to true after failed submit")
	}
}

func TestInputSubmitSuccess(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2 // "WithPrompts"
	m.input = newInputState(testFieldsRequired())
	m.input.active = 1 // last field
	m.input.values[0] = "my-bucket"
	m.input.values[1] = "snap-123"
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.input != nil {
		t.Error("input should close after successful submit")
	}
	if !m2.executing {
		t.Error("should be executing after successful submit")
	}
}

func TestInputSubmitOptionalFieldCanBeEmpty(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2 // "WithPrompts"
	m.input = newInputState(testFieldsRequired())
	m.input.active = 1
	m.input.values[0] = "my-bucket"
	// values[1] (Snapshot) is optional, left empty
	updated, _ := m.Update(keyMsg("enter"))
	m2 := updated.(model)
	if m2.input != nil {
		t.Error("optional fields can be empty on submit")
	}
}

// ── buildArgsFromInput ──────────────────────────────────────────────────

func TestBuildArgsPositional(t *testing.T) {
	cmd := command{script: "/tmp/test.sh"}
	inp := &inputState{
		fields: testFieldsRequired(),
		values: []string{"my-bucket", "snap-123"},
	}
	args := buildArgsFromInput(cmd, inp)
	if len(args) != 2 {
		t.Fatalf("expected 2 args, got %d: %v", len(args), args)
	}
	if args[0] != "my-bucket" || args[1] != "snap-123" {
		t.Errorf("unexpected args: %v", args)
	}
}

func TestBuildArgsWithFlag(t *testing.T) {
	cmd := command{script: "/tmp/test.sh"}
	inp := &inputState{
		fields: testFieldsWithFlag(),
		values: []string{"7.0"},
	}
	args := buildArgsFromInput(cmd, inp)
	if len(args) != 2 {
		t.Fatalf("expected 2 args (--search 7.0), got %d: %v", len(args), args)
	}
	if args[0] != "--search" || args[1] != "7.0" {
		t.Errorf("unexpected args: %v", args)
	}
}

func TestBuildArgsEmptyFieldSkipped(t *testing.T) {
	cmd := command{script: "/tmp/test.sh"}
	inp := &inputState{
		fields: testFieldsWithFlag(),
		values: []string{""},
	}
	args := buildArgsFromInput(cmd, inp)
	if len(args) != 0 {
		t.Errorf("empty fields should be skipped, got: %v", args)
	}
}

func TestBuildArgsRestoreLatestSnapshot(t *testing.T) {
	cmd := command{script: "/tmp/scripts/restore.sh"}
	inp := &inputState{
		fields: testFieldsRequired(),
		values: []string{"my-bucket", ""},
	}
	args := buildArgsFromInput(cmd, inp)
	found := false
	for _, a := range args {
		if a == "--latest-snapshot" {
			found = true
		}
	}
	if !found {
		t.Errorf("restore.sh with empty snapshot should add --latest-snapshot, got: %v", args)
	}
}

func TestBuildArgsRestoreWithSnapshot(t *testing.T) {
	cmd := command{script: "/tmp/scripts/restore.sh"}
	inp := &inputState{
		fields: testFieldsRequired(),
		values: []string{"my-bucket", "snap-id"},
	}
	args := buildArgsFromInput(cmd, inp)
	for _, a := range args {
		if a == "--latest-snapshot" {
			t.Error("restore.sh with explicit snapshot should not add --latest-snapshot")
		}
	}
}

func TestBuildArgsPreservesExisting(t *testing.T) {
	cmd := command{script: "/tmp/test.sh", args: []string{"--existing"}}
	inp := &inputState{
		fields: testFieldsSingle(),
		values: []string{"term"},
	}
	args := buildArgsFromInput(cmd, inp)
	if args[0] != "--existing" {
		t.Errorf("should preserve existing args, got: %v", args)
	}
	if args[1] != "term" {
		t.Errorf("should append new args, got: %v", args)
	}
}

// ── fieldIndex ──────────────────────────────────────────────────────────

func TestFieldIndex(t *testing.T) {
	fields := testFieldsRequired()
	if idx := fieldIndex(fields, fields[0]); idx != 0 {
		t.Errorf("expected 0, got %d", idx)
	}
	if idx := fieldIndex(fields, fields[1]); idx != 1 {
		t.Errorf("expected 1, got %d", idx)
	}
}

func TestFieldIndexNotFound(t *testing.T) {
	fields := testFieldsRequired()
	missing := inputField{label: "Missing"}
	if idx := fieldIndex(fields, missing); idx != 0 {
		t.Errorf("not found should return 0, got %d", idx)
	}
}

// ── View: input form rendering ──────────────────────────────────────────

func TestViewInputFormContainsLabels(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2
	m.input = newInputState(testFieldsRequired())
	v := m.View()
	if !strings.Contains(v.Content, "Bucket") {
		t.Error("input form should show field label 'Bucket'")
	}
	if !strings.Contains(v.Content, "Snapshot") {
		t.Error("input form should show field label 'Snapshot'")
	}
}

func TestViewInputFormContainsPlaceholder(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2
	m.input = newInputState(testFieldsRequired())
	m.input.active = 0
	v := m.View()
	if !strings.Contains(v.Content, "snap-123") {
		t.Error("input form should show placeholder for inactive empty field")
	}
}

func TestViewInputFormContainsCommandTitle(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2
	m.input = newInputState(testFieldsRequired())
	v := m.View()
	if !strings.Contains(v.Content, "WithPrompts") {
		t.Error("input form should show the command title")
	}
}

func TestViewInputFormShowsRequired(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2
	m.input = newInputState(testFieldsRequired())
	v := m.View()
	if !strings.Contains(v.Content, "*") {
		t.Error("input form should mark required fields with *")
	}
}

func TestViewInputFormShowsOptional(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2
	m.input = newInputState(testFieldsRequired())
	v := m.View()
	if !strings.Contains(v.Content, "optional") {
		t.Error("input form should mark optional fields")
	}
}

func TestViewInputFormShowsHints(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2
	m.input = newInputState(testFieldsRequired())
	v := m.View()
	if !strings.Contains(v.Content, "Tab") {
		t.Error("input form should show navigation hints")
	}
	if !strings.Contains(v.Content, "Esc") {
		t.Error("input form should show cancel hint")
	}
}

func TestViewInputFormShowsValidationError(t *testing.T) {
	m := testModelWithPrompts()
	m.cursor = 2
	m.input = newInputState(testFieldsRequired())
	m.input.attempted = true
	v := m.View()
	if !strings.Contains(v.Content, "required") {
		t.Error("input form should show validation error when attempted with empty required field")
	}
}
