#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/search-codebase.sh
# Purpose: Validate search behavior for matches and misses, exclusion patterns,
#          exit code contracts, case-insensitive search, match counting, and
#          output formatting.
# Scope:   Searches the actual project codebase (read-only).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/search-codebase.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "search-codebase.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "search-codebase.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Positive search ────────────────────────────────────────────────────────

@test "finds known term 'applications' in versions.yaml" {
  run_script "search-codebase.sh" "applications"
  assert_success
  [[ "$output" =~ "applications" ]]
}

@test "search reports match count" {
  run_script "search-codebase.sh" "applications"
  [[ "$output" =~ "match" ]]
}

@test "finds known term 'openemr' in codebase" {
  run_script "search-codebase.sh" "openemr"
  assert_success
}

@test "finds known term 'set -e' in codebase" {
  run_script "search-codebase.sh" "set -e"
  assert_success
}

# ── Negative search ────────────────────────────────────────────────────────

@test "returns non-zero for random non-existent term" {
  local token="__NO_MATCH_$(date +%s%N)__"
  run_script "search-codebase.sh" "$token"
  [ "$status" -ne 0 ]
}

@test "no-match output says 'No matches found'" {
  local token="__XYZZY_$(date +%s%N)__"
  run_script "search-codebase.sh" "$token"
  [[ "$output" =~ "No matches found" ]]
}

# ── Exclusion patterns ─────────────────────────────────────────────────────

@test "script excludes .git directory" {
  run grep 'exclude-dir=.git' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script excludes node_modules" {
  run grep 'exclude-dir=node_modules' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script excludes .terraform" {
  run grep 'exclude-dir=.terraform' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script excludes __pycache__" {
  run grep 'exclude-dir=__pycache__' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script excludes *.log files" {
  run grep 'exclude=\*.log' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Case sensitivity ──────────────────────────────────────────────────────

@test "search is case-insensitive by default (search_codebase uses -i)" {
  run grep 'grep_cmd.*-i' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Script structure ────────────────────────────────────────────────────────

@test "script defines search_codebase function" {
  run grep 'search_codebase()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines main function" {
  run grep 'main()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These extract the search_codebase function and test it against a
# controlled temporary directory with known content.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: search_codebase finds term in temp directory" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  mkdir -p "${tmpdir}/subdir"
  echo "hello world openemr test" > "${tmpdir}/sample.txt"
  echo "nothing here" > "${tmpdir}/subdir/other.txt"

  local func_file
  func_file=$(extract_function "$SCRIPT" "search_codebase")
  run bash -c '
    RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
    BLUE="\033[0;34m"; CYAN="\033[0;36m"; NC="\033[0m"
    PROJECT_ROOT="'"$tmpdir"'"
    source "'"$func_file"'"
    search_codebase "openemr" "false"
  '
  rm -f "$func_file"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1 match" ]]
}

@test "UNIT: search_codebase returns non-zero for missing term" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  echo "hello world" > "${tmpdir}/sample.txt"

  local func_file
  func_file=$(extract_function "$SCRIPT" "search_codebase")
  run bash -c '
    RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
    BLUE="\033[0;34m"; CYAN="\033[0;36m"; NC="\033[0m"
    PROJECT_ROOT="'"$tmpdir"'"
    source "'"$func_file"'"
    search_codebase "zzz_nonexistent_zzz" "false"
  '
  rm -f "$func_file"
  rm -rf "$tmpdir"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No matches found" ]]
}

@test "UNIT: search_codebase counts multiple matches across files" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  echo "match_me here" > "${tmpdir}/a.txt"
  echo "match_me there" > "${tmpdir}/b.txt"
  echo "match_me everywhere" > "${tmpdir}/c.txt"

  local func_file
  func_file=$(extract_function "$SCRIPT" "search_codebase")
  run bash -c '
    RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
    BLUE="\033[0;34m"; CYAN="\033[0;36m"; NC="\033[0m"
    PROJECT_ROOT="'"$tmpdir"'"
    source "'"$func_file"'"
    search_codebase "match_me" "false"
  '
  rm -f "$func_file"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "3 match" ]]
}

@test "UNIT: search_codebase is case-insensitive by default" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  echo "OpenEMR is great" > "${tmpdir}/mixed.txt"

  local func_file
  func_file=$(extract_function "$SCRIPT" "search_codebase")
  run bash -c '
    RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
    BLUE="\033[0;34m"; CYAN="\033[0;36m"; NC="\033[0m"
    PROJECT_ROOT="'"$tmpdir"'"
    source "'"$func_file"'"
    search_codebase "openemr" "false"
  '
  rm -f "$func_file"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1 match" ]]
}
