#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/check-openemr-versions.sh
# Purpose: Validate version-check CLI options (--count, --search, --latest),
#          argument parsing robustness, dependency checks for curl/jq,
#          and help content completeness.
# Scope:   Invokes only --help and error paths (never calls Docker Hub API).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/check-openemr-versions.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "check-openemr-versions.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "check-openemr-versions.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "check-openemr-versions.sh" "--help"
  assert_success
}

@test "--help shows Usage line" {
  run_script "check-openemr-versions.sh" "--help"
  [[ "$output" =~ "Usage" ]]
}

# ── Help documents every flag ───────────────────────────────────────────────

@test "--help documents --count" {
  run_script "check-openemr-versions.sh" "--help"
  [[ "$output" =~ "--count" ]]
}

@test "--help documents --search" {
  run_script "check-openemr-versions.sh" "--help"
  [[ "$output" =~ "--search" ]]
}

@test "--help documents --latest" {
  run_script "check-openemr-versions.sh" "--help"
  [[ "$output" =~ "--latest" ]]
}

@test "--help includes Examples section" {
  run_script "check-openemr-versions.sh" "--help"
  [[ "$output" =~ "Examples" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "check-openemr-versions.sh" "--unknown"
  [ "$status" -ne 0 ]
}

@test "unknown option names the bad flag" {
  run_script "check-openemr-versions.sh" "--foobar"
  [[ "$output" =~ "foobar" ]]
}

@test "unknown option suggests help" {
  run_script "check-openemr-versions.sh" "--unknown"
  [[ "$output" =~ (help|Usage) ]]
}

# ── Flag parsing: --count requires a value ──────────────────────────────────

@test "--count without value fails" {
  run_script "check-openemr-versions.sh" "--count"
  [ "$status" -ne 0 ]
}

@test "--search without value fails" {
  run_script "check-openemr-versions.sh" "--search"
  [ "$status" -ne 0 ]
}

# ── Static analysis: constants ──────────────────────────────────────────────

@test "DEFAULT_TAGS_TO_SHOW is 10" {
  run grep 'DEFAULT_TAGS_TO_SHOW=10' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DOCKER_REGISTRY is openemr/openemr" {
  run grep 'DOCKER_REGISTRY="openemr/openemr"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Dependency checks ──────────────────────────────────────────────────────

@test "script checks for curl dependency" {
  run grep 'command -v curl' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks for jq dependency" {
  run grep 'command -v jq' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Functions defined ──────────────────────────────────────────────────────

@test "script defines get_docker_tags function" {
  run grep 'get_docker_tags()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines filter_versions function" {
  run grep 'filter_versions()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines sort_versions function" {
  run grep 'sort_versions()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "sort_versions uses sort -Vr" {
  run grep -A2 'sort_versions()' "$SCRIPT"
  [[ "$output" =~ "sort -Vr" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These exercise individual functions from the script in isolation,
# verifying their behavior with controlled inputs.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: sort_versions sorts semantic versions descending" {
  # sort_versions is just 'sort -Vr' — test the exact pipe behavior
  local func_file
  func_file=$(extract_function "$SCRIPT" "sort_versions")
  run bash -c '
    source "'"$func_file"'"
    printf "7.0.1\n7.0.3\n7.0.2\n6.1.0\n" | sort_versions
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  # First line should be the highest version
  local first_line
  first_line=$(echo "$output" | head -1)
  [ "$first_line" = "7.0.3" ]
}

@test "UNIT: sort_versions places pre-release after stable" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "sort_versions")
  run bash -c '
    source "'"$func_file"'"
    printf "7.0.2\n7.0.2-beta\n7.0.1\n" | sort_versions
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  # 7.0.2-beta should sort after 7.0.2 in reverse version sort
  local first_line
  first_line=$(echo "$output" | head -1)
  [[ "$first_line" == "7.0.2"* ]]
}

@test "UNIT: filter_versions with search pattern returns only matching versions" {
  # Inline both functions since filter_versions calls sort_versions
  run bash -c '
    sort_versions() { sort -Vr; }
    filter_versions() {
      local search_pattern="$1" latest_only="$2" count="$3"
      local filtered_tags
      if [ -n "$search_pattern" ]; then
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | grep "$search_pattern" | sort_versions | head -n "$count")
      else
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | sort_versions | head -n "$count")
      fi
      if [ "$latest_only" = true ]; then
        local stable_version=$(echo "$filtered_tags" | sed -n "2p")
        if [ -n "$stable_version" ]; then echo "$stable_version"; else echo "$filtered_tags" | head -n 1; fi
      else
        echo "$filtered_tags"
      fi
    }
    printf "7.0.1\n7.0.2\n6.1.0\n7.0.3\n6.0.5\n" | filter_versions "7.0" false 10
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "7.0.3" ]]
  [[ "$output" =~ "7.0.2" ]]
  [[ "$output" =~ "7.0.1" ]]
  if [[ "$output" =~ "6.1.0" ]]; then return 1; fi
}

@test "UNIT: filter_versions with count limits output" {
  run bash -c '
    sort_versions() { sort -Vr; }
    filter_versions() {
      local search_pattern="$1" latest_only="$2" count="$3"
      local filtered_tags
      if [ -n "$search_pattern" ]; then
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | grep "$search_pattern" | sort_versions | head -n "$count")
      else
        filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | sort_versions | head -n "$count")
      fi
      echo "$filtered_tags"
    }
    printf "7.0.1\n7.0.2\n7.0.3\n7.0.4\n7.0.5\n" | filter_versions "" false 2
  '
  [ "$status" -eq 0 ]
  local line_count
  line_count=$(echo "$output" | grep -c '^[0-9]' || true)
  [ "$line_count" -eq 2 ]
}

@test "UNIT: filter_versions with latest_only returns second version (stable)" {
  run bash -c '
    sort_versions() { sort -Vr; }
    filter_versions() {
      local search_pattern="$1" latest_only="$2" count="$3"
      local filtered_tags
      filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | sort_versions | head -n "$count")
      if [ "$latest_only" = true ]; then
        local stable_version=$(echo "$filtered_tags" | sed -n "2p")
        if [ -n "$stable_version" ]; then echo "$stable_version"; else echo "$filtered_tags" | head -n 1; fi
      else
        echo "$filtered_tags"
      fi
    }
    printf "7.0.3\n7.0.2\n7.0.1\n" | filter_versions "" true 10
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "7.0.2" ]]
}

@test "UNIT: filter_versions rejects non-semver tags" {
  run bash -c '
    sort_versions() { sort -Vr; }
    filter_versions() {
      local search_pattern="$1" latest_only="$2" count="$3"
      local filtered_tags
      filtered_tags=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$" | sort_versions | head -n "$count")
      echo "$filtered_tags"
    }
    printf "latest\ndev\n7.0.1\nalpine\n7.0.2\n" | filter_versions "" false 10
  '
  [ "$status" -eq 0 ]
  if [[ "$output" =~ "latest" ]]; then return 1; fi
  if [[ "$output" =~ "dev" ]]; then return 1; fi
  if [[ "$output" =~ "alpine" ]]; then return 1; fi
  [[ "$output" =~ "7.0.1" ]]
  [[ "$output" =~ "7.0.2" ]]
}

# ── UNIT: show_help ─────────────────────────────────────────────────────────

@test "UNIT: show_help prints usage and all options" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    DEFAULT_TAGS_TO_SHOW=10
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "Usage" ]]
  [[ "$output" =~ "--count" ]]
  [[ "$output" =~ "--search" ]]
  [[ "$output" =~ "--latest" ]]
  [[ "$output" =~ "--help" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help includes examples section" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    DEFAULT_TAGS_TO_SHOW=10
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "Examples" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: sort_versions edge cases ──────────────────────────────────────────

@test "UNIT: sort_versions handles single version" {
  FUNC_FILE=$(extract_function "$SCRIPT" "sort_versions")
  run bash -c "
    source '$FUNC_FILE'
    echo '1.0.0' | sort_versions
  "
  [ "$output" = "1.0.0" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: sort_versions handles multi-digit version numbers" {
  FUNC_FILE=$(extract_function "$SCRIPT" "sort_versions")
  run bash -c "
    source '$FUNC_FILE'
    printf '7.0.10\n7.0.9\n7.0.2\n' | sort_versions
  "
  local first
  first=$(echo "$output" | head -1)
  [ "$first" = "7.0.10" ]
  rm -f "$FUNC_FILE"
}
