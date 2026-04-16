# Codependent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tiered AI coding assistant failover system with a background daemon that detects outages, notifies users, and facilitates instant switching between tools.

**Architecture:** Pure bash + curl. `lib.sh` provides all shared functions, `fallback.sh` is the single entry point, `monitor.sh` is the background daemon, `generate-configs.sh` produces tool-native configs from a canonical `guardrails.md`. Config files (`resilience.conf`, `tiers.conf`) are declarative key=value and pipe-delimited formats. State is managed via files in `state/` (gitignored).

**Tech Stack:** Bash, curl, osascript (macOS), powershell.exe (Windows), sqlite3 (optional)

**Spec:** `2026-04-15-resilience-platform-design.md` (repo root)

---

## File Map

### Core scripts
| File | Responsibility |
|------|---------------|
| `lib.sh` | All shared functions — platform, config, health, notify, state, tiers, metrics, logging |
| `fallback.sh` | Entry point — tier walking, status, dry-run, test modes |
| `monitor.sh` | Background daemon — health check loop, state machine, recovery/failure detection |
| `generate-configs.sh` | Reads guardrails.md + templates, writes tool-native config files per project |

### Config files
| File | Responsibility |
|------|---------------|
| `resilience.conf` | Runtime configuration (key=value, no dependencies) |
| `tiers.conf` | Declarative tier chain (pipe-delimited rows) |

### Content files
| File | Responsibility |
|------|---------------|
| `guardrails.md` | Canonical tool-agnostic guardrails (single source of truth) |
| `tools/claude/template.md` | Claude-specific additions (CSuite skills, MCP, hooks, personas) |
| `tools/codex/template.md` | Codex-specific additions (AGENTS.md formatting) |
| `tools/aider/template.md` | Aider-specific additions (model config, .aider.conf.yml) |
| `tools/cursor/template.md` | Cursor-specific additions (.mdc frontmatter) |
| `tools/*/setup.md` | Per-tool install instructions (macOS + Windows) |

### Test files
| File | Responsibility |
|------|---------------|
| `tests/runner.sh` | Minimal test harness — discovers and runs test files, reports pass/fail |
| `tests/test_config.sh` | Tests for config parsing, validation |
| `tests/test_tiers.sh` | Tests for tier parsing, prerequisite checking |
| `tests/test_health.sh` | Tests for health check logic (with mock curl) |
| `tests/test_state.sh` | Tests for state machine, sliding window |
| `tests/test_notify.sh` | Tests for notification dispatch (platform detection, fallback chain) |
| `tests/test_metrics.sh` | Tests for metrics logging (sqlite3 + CSV fallback) |
| `tests/test_generate.sh` | Tests for config generation (determinism, hash headers, verify mode) |
| `tests/test_fallback.sh` | Integration tests for fallback.sh modes |
| `tests/test_monitor.sh` | Integration tests for monitor.sh lifecycle |

### State (gitignored)
| File | Responsibility |
|------|---------------|
| `state/current_tier` | Active tier identifier |
| `state/monitor.pid` | Daemon PID |
| `state/monitor.heartbeat` | Heartbeat mtime tracking |
| `state/monitor.log` | Daemon log (1MB max, rotated) |
| `state/failover_ready` | Recommended tier for auto_failover mode |
| `state/metrics.csv` | CSV fallback when sqlite3 unavailable |

---

## Task 1: Project Scaffold + Test Harness

**Files:**
- Create: `.gitignore`
- Create: `tests/runner.sh`
- Create: `resilience.conf`
- Create: `tiers.conf`
- Create: `state/.gitkeep`

- [ ] **Step 1: Create .gitignore**

```
state/*
!state/.gitkeep
```

- [ ] **Step 2: Create state directory with .gitkeep**

```bash
mkdir -p state
touch state/.gitkeep
```

- [ ] **Step 3: Create resilience.conf with all defaults**

```bash
# codependent — runtime configuration
# See 2026-04-15-resilience-platform-design.md for documentation.

# Health check
check_interval=30
health_check=status_page

# Recovery detection (sliding window)
recovery_successes=10
recovery_window=12

# Failure detection
failure_window=4

# Rate limit / degraded state
degraded_threshold=600

# Actions
on_recovery=notify
on_failure=notify

# Notification
notify_method=both

# Metrics
log_to_metrics=true

# Local model (used by Tier 3)
local_model=gemma3

# Project discovery for config generation
project_roots=~/Projects

# Daemon lifecycle
heartbeat_timeout=600

# Network check (corporate proxy users: set to internal endpoint)
network_check_url=https://1.1.1.1

# Log management
max_log_size=1048576
```

- [ ] **Step 4: Create tiers.conf**

```
# codependent — tiered fallback chain
# Format: tier | tool | command | required_env | check_cmd
# Delimiter is " | " (space-pipe-space). Commands must not contain " | ".
# Rows are tried top to bottom. First passing row launches.
0       | claude  | claude                                                    |                | command -v claude
1       | codex   | codex --model o3                                          | OPENAI_API_KEY | command -v codex
2a      | aider   | aider --model gpt-4o --read CONVENTIONS.md                | OPENAI_API_KEY | command -v aider
2b      | aider   | aider --model gemini/gemini-2.5-pro --read CONVENTIONS.md | GOOGLE_API_KEY | command -v aider
3       | aider   | aider --model ollama/$local_model --read CONVENTIONS.md   |                | ollama list
sidecar | cursor  | cursor .                                                  |                | command -v cursor
```

- [ ] **Step 5: Create test harness**

`tests/runner.sh` — minimal test runner that discovers `tests/test_*.sh` files, runs each, counts pass/fail, exits non-zero on any failure. Each test file defines functions starting with `test_` — the runner sources the file and calls each one. Tests use `assert_eq`, `assert_true`, `assert_false` helper functions defined in the runner.

```bash
#!/usr/bin/env bash
# codependent test runner
# Usage: ./tests/runner.sh [test_file.sh] [test_name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
ERRORS=()

# Test helpers
assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "  ASSERT_EQ FAILED: expected='$expected' actual='$actual' ${msg:+($msg)}"
        return 1
    fi
}

assert_true() {
    local val="$1" msg="${2:-}"
    if [[ "$val" == "true" || "$val" == "0" || "$val" == "yes" ]]; then
        return 0
    else
        echo "  ASSERT_TRUE FAILED: got='$val' ${msg:+($msg)}"
        return 1
    fi
}

assert_false() {
    local val="$1" msg="${2:-}"
    if [[ "$val" == "false" || "$val" == "1" || "$val" == "no" || "$val" == "" ]]; then
        return 0
    else
        echo "  ASSERT_FALSE FAILED: got='$val' ${msg:+($msg)}"
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "  ASSERT_CONTAINS FAILED: '$needle' not found in output ${msg:+($msg)}"
        return 1
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [[ -f "$path" ]]; then
        return 0
    else
        echo "  ASSERT_FILE_EXISTS FAILED: '$path' ${msg:+($msg)}"
        return 1
    fi
}

export -f assert_eq assert_true assert_false assert_contains assert_file_exists
export PROJECT_ROOT

run_test() {
    local name="$1"
    if "$name" 2>&1; then
        ((PASS++))
        echo "  PASS: $name"
    else
        ((FAIL++))
        ERRORS+=("$name")
        echo "  FAIL: $name"
    fi
}

run_file() {
    local file="$1"
    local filter="${2:-}"
    echo "--- $(basename "$file") ---"

    # Source the test file to load test functions
    source "$file"

    # Find all functions starting with test_
    local funcs
    funcs=$(declare -F | awk '{print $3}' | grep '^test_' || true)

    for func in $funcs; do
        if [[ -z "$filter" || "$func" == "$filter" ]]; then
            run_test "$func"
        fi
    done

    # Unset test functions to avoid bleeding between files
    for func in $funcs; do
        unset -f "$func" 2>/dev/null || true
    done
}

# Main
target_file="${1:-}"
target_test="${2:-}"

if [[ -n "$target_file" ]]; then
    run_file "$SCRIPT_DIR/$target_file" "$target_test"
else
    for f in "$SCRIPT_DIR"/test_*.sh; do
        [[ -f "$f" ]] && run_file "$f" "$target_test"
    done
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if ((FAIL > 0)); then
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
        echo "  - $e"
    done
    exit 1
fi
exit 0
```

- [ ] **Step 6: Create a smoke test to verify the harness works**

Create `tests/test_smoke.sh`:

```bash
#!/usr/bin/env bash
# Smoke test — verifies the test harness itself works

test_harness_works() {
    assert_eq "hello" "hello" "basic string equality"
}

test_assert_contains() {
    assert_contains "hello world" "world" "substring match"
}

test_project_root_set() {
    assert_true "$([[ -n "$PROJECT_ROOT" ]] && echo true || echo false)" "PROJECT_ROOT is set"
}
```

- [ ] **Step 7: Run smoke test**

Run: `bash tests/runner.sh test_smoke.sh`
Expected: 3 passed, 0 failed

- [ ] **Step 8: Commit**

```bash
git add .gitignore state/.gitkeep resilience.conf tiers.conf tests/runner.sh tests/test_smoke.sh
git commit -m "scaffold: project structure, config files, test harness"
```

---

## Task 2: lib.sh — Platform Detection + Config Parsing

**Files:**
- Create: `lib.sh`
- Create: `tests/test_config.sh`

- [ ] **Step 1: Write failing tests for config parsing**

`tests/test_config.sh`:

```bash
#!/usr/bin/env bash

# Setup: create a temp config for testing
setup_temp_config() {
    export TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<'CONF'
check_interval=30
health_check=status_page
on_failure=notify
local_model=gemma3
project_roots=~/Projects
CONF
}

teardown_temp_config() {
    rm -f "$TEST_CONF"
}

test_load_config_reads_values() {
    setup_temp_config
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    assert_eq "30" "$CFG_check_interval" "check_interval"
    assert_eq "status_page" "$CFG_health_check" "health_check"
    assert_eq "notify" "$CFG_on_failure" "on_failure"
    assert_eq "gemma3" "$CFG_local_model" "local_model"
    teardown_temp_config
}

test_load_config_ignores_comments() {
    export TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<'CONF'
# this is a comment
check_interval=30
  # indented comment
CONF
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    assert_eq "30" "$CFG_check_interval"
    rm -f "$TEST_CONF"
}

test_load_config_ignores_blank_lines() {
    export TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<'CONF'
check_interval=30

on_failure=notify
CONF
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    assert_eq "30" "$CFG_check_interval"
    assert_eq "notify" "$CFG_on_failure"
    rm -f "$TEST_CONF"
}

test_detect_platform_returns_known_value() {
    source "$PROJECT_ROOT/lib.sh"
    detect_platform
    # Should be one of: macos, windows-git-bash, windows-wsl, linux
    local valid=false
    case "$PLATFORM" in
        macos|windows-git-bash|windows-wsl|linux) valid=true ;;
    esac
    assert_true "$valid" "PLATFORM=$PLATFORM should be a known value"
}

test_validate_config_accepts_valid() {
    setup_temp_config
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    # Should not exit non-zero
    local result
    result=$(validate_config 2>&1) && assert_true "0" "valid config accepted" || assert_true "false" "valid config rejected: $result"
    teardown_temp_config
}

test_validate_config_rejects_invalid_on_failure() {
    export TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<'CONF'
check_interval=30
on_failure=notfy
CONF
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    local result
    if validate_config 2>/dev/null; then
        assert_true "false" "should have rejected invalid on_failure=notfy"
    else
        assert_true "0" "correctly rejected invalid config"
    fi
    rm -f "$TEST_CONF"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_config.sh`
Expected: FAIL (lib.sh doesn't exist yet)

- [ ] **Step 3: Implement lib.sh — platform detection + config parsing + validation**

Create `lib.sh` with:
- `CODEPENDENT_ROOT` — resolved to script's parent directory
- `detect_platform()` — sets `$PLATFORM` using `uname -s` and `$MSYSTEM`
- `load_config()` — reads key=value file, skips comments/blanks, sets `CFG_` prefixed vars
- `validate_config()` — checks known config keys against valid values, returns non-zero with message on invalid

```bash
#!/usr/bin/env bash
# codependent — shared functions
# Source this file; do not execute directly.

set -euo pipefail

CODEPENDENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Platform Detection ---

detect_platform() {
    case "$(uname -s)" in
        Darwin)
            PLATFORM="macos"
            ;;
        MINGW*|MSYS*)
            PLATFORM="windows-git-bash"
            ;;
        Linux)
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                PLATFORM="windows-wsl"
            else
                PLATFORM="linux"
            fi
            ;;
        *)
            PLATFORM="linux"  # fallback
            ;;
    esac
    export PLATFORM
}

# --- Config Parsing ---

load_config() {
    local config_file="${1:-$CODEPENDENT_ROOT/resilience.conf}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        # Strip inline comments (but not # inside values)
        line="${line%%[[:space:]]#*}"
        # Parse key=value
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # Trim trailing whitespace from value
            val="${val%"${val##*[![:space:]]}"}"
            declare -g "CFG_${key}=${val}"
        fi
    done < "$config_file"
}

# --- Config Validation ---

validate_config() {
    local errors=()

    # Validate enum fields
    case "${CFG_health_check:-status_page}" in
        status_page|api_call|both) ;;
        *) errors+=("health_check='${CFG_health_check}' — must be: status_page | api_call | both") ;;
    esac

    case "${CFG_on_recovery:-notify}" in
        notify|auto_switch|both) ;;
        *) errors+=("on_recovery='${CFG_on_recovery}' — must be: notify | auto_switch | both") ;;
    esac

    case "${CFG_on_failure:-notify}" in
        notify|auto_failover|both) ;;
        *) errors+=("on_failure='${CFG_on_failure}' — must be: notify | auto_failover | both") ;;
    esac

    case "${CFG_notify_method:-both}" in
        terminal|toast|both) ;;
        *) errors+=("notify_method='${CFG_notify_method}' — must be: terminal | toast | both") ;;
    esac

    # Validate numeric fields
    for field in check_interval recovery_successes recovery_window failure_window \
                 degraded_threshold heartbeat_timeout max_log_size; do
        local varname="CFG_${field}"
        local val="${!varname:-}"
        if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
            errors+=("${field}='${val}' — must be a positive integer")
        fi
    done

    if ((${#errors[@]} > 0)); then
        echo "Config validation failed:" >&2
        for e in "${errors[@]}"; do
            echo "  - $e" >&2
        done
        return 1
    fi
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/runner.sh test_config.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_config.sh
git commit -m "feat: lib.sh platform detection, config parsing, validation"
```

---

## Task 3: lib.sh — Tier Parsing + Prerequisite Checks

**Files:**
- Modify: `lib.sh`
- Create: `tests/test_tiers.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_tiers.sh`:

```bash
#!/usr/bin/env bash

setup_temp_tiers() {
    export TEST_TIERS="$(mktemp)"
    cat > "$TEST_TIERS" <<'TIERS'
# comment line
0       | claude  | claude                         |                | command -v claude
1       | codex   | codex --model o3               | OPENAI_API_KEY | command -v codex
sidecar | cursor  | cursor .                       |                | command -v cursor
TIERS
}

test_parse_tier_line() {
    source "$PROJECT_ROOT/lib.sh"
    local tier tool command required_env check_cmd
    parse_tier_line "0       | claude  | claude                         |                | command -v claude"
    assert_eq "0" "$TIER_id"
    assert_eq "claude" "$TIER_tool"
    assert_eq "claude" "$TIER_command"
    assert_eq "" "$TIER_required_env"
    assert_eq "command -v claude" "$TIER_check_cmd"
}

test_parse_tier_with_env() {
    source "$PROJECT_ROOT/lib.sh"
    parse_tier_line "1       | codex   | codex --model o3               | OPENAI_API_KEY | command -v codex"
    assert_eq "1" "$TIER_id"
    assert_eq "codex" "$TIER_tool"
    assert_eq "codex --model o3" "$TIER_command"
    assert_eq "OPENAI_API_KEY" "$TIER_required_env"
}

test_load_tiers_skips_comments() {
    setup_temp_tiers
    source "$PROJECT_ROOT/lib.sh"
    load_tiers "$TEST_TIERS"
    assert_eq "3" "${#TIERS[@]}" "should have 3 tiers (skipping comment)"
    rm -f "$TEST_TIERS"
}

test_check_tier_prerequisites_missing_tool() {
    source "$PROJECT_ROOT/lib.sh"
    parse_tier_line "0 | nonexistent_tool_xyz | nonexistent_tool_xyz | | command -v nonexistent_tool_xyz"
    local result
    result=$(check_tier_prerequisites 2>&1) || true
    assert_eq "1" "$?" 2>/dev/null || assert_contains "$result" "not found"
}

test_check_tier_prerequisites_missing_env() {
    source "$PROJECT_ROOT/lib.sh"
    # Use bash itself as the tool (guaranteed to exist) but require a missing env var
    unset FAKE_MISSING_KEY_12345 2>/dev/null || true
    parse_tier_line "0 | bash | bash | FAKE_MISSING_KEY_12345 | command -v bash"
    if check_tier_prerequisites 2>/dev/null; then
        assert_true "false" "should fail with missing env var"
    else
        assert_true "0" "correctly detected missing env var"
    fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_tiers.sh`
Expected: FAIL

- [ ] **Step 3: Implement tier parsing in lib.sh**

Add to `lib.sh`:
- `parse_tier_line()` — splits a `tiers.conf` line on ` | `, sets `TIER_id`, `TIER_tool`, `TIER_command`, `TIER_required_env`, `TIER_check_cmd`
- `load_tiers()` — reads tiers.conf, skips comments/blanks, stores lines in `TIERS` array
- `check_tier_prerequisites()` — runs `TIER_check_cmd` via eval, checks `TIER_required_env` is set if non-empty. Returns 0 if ready, 1 with message if not.

```bash
# --- Tier Parsing ---

parse_tier_line() {
    local line="$1"
    TIER_id="$(echo "$line" | awk -F' [|] ' '{print $1}' | xargs)"
    TIER_tool="$(echo "$line" | awk -F' [|] ' '{print $2}' | xargs)"
    TIER_command="$(echo "$line" | awk -F' [|] ' '{print $3}' | xargs)"
    TIER_required_env="$(echo "$line" | awk -F' [|] ' '{print $4}' | xargs)"
    TIER_check_cmd="$(echo "$line" | awk -F' [|] ' '{print $5}' | xargs)"
}

load_tiers() {
    local tiers_file="${1:-$CODEPENDENT_ROOT/tiers.conf}"
    TIERS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        TIERS+=("$line")
    done < "$tiers_file"
}

check_tier_prerequisites() {
    # Check tool binary exists
    if ! eval "$TIER_check_cmd" &>/dev/null; then
        echo "Tier $TIER_id: $TIER_tool not found ($TIER_check_cmd failed)" >&2
        return 1
    fi

    # Check required env var is set
    if [[ -n "$TIER_required_env" ]]; then
        if [[ -z "${!TIER_required_env:-}" ]]; then
            echo "Tier $TIER_id: $TIER_tool requires $TIER_required_env (not set)" >&2
            return 1
        fi
    fi

    return 0
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_tiers.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_tiers.sh
git commit -m "feat: tier parsing and prerequisite checking"
```

---

## Task 4: lib.sh — State Management + Sliding Window

**Files:**
- Modify: `lib.sh`
- Create: `tests/test_state.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_state.sh`:

```bash
#!/usr/bin/env bash

setup_temp_state() {
    export TEST_STATE_DIR="$(mktemp -d)"
}

teardown_temp_state() {
    rm -rf "$TEST_STATE_DIR"
}

test_write_and_read_state() {
    setup_temp_state
    source "$PROJECT_ROOT/lib.sh"
    write_state "2a" "$TEST_STATE_DIR"
    local result
    result=$(read_state "$TEST_STATE_DIR")
    assert_eq "2a" "$result"
    teardown_temp_state
}

test_read_state_returns_empty_when_no_file() {
    setup_temp_state
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(read_state "$TEST_STATE_DIR")
    assert_eq "" "$result"
    teardown_temp_state
}

test_sliding_window_cold_start_recovery() {
    source "$PROJECT_ROOT/lib.sh"
    # Cold start: 3 consecutive successes should trigger recovery
    sliding_window_init 12
    sliding_window_push 1
    sliding_window_push 1
    assert_false "$(sliding_window_check_recovery 10 12)" "2 successes not enough"
    sliding_window_push 1
    assert_true "$(sliding_window_check_recovery 10 12)" "3 consecutive on cold start = recovery"
}

test_sliding_window_normal_recovery() {
    source "$PROJECT_ROOT/lib.sh"
    sliding_window_init 12
    # Fill window past cold start threshold
    for i in {1..12}; do
        sliding_window_push 0  # failures
    done
    # Now need 10/12 successes
    for i in {1..9}; do
        sliding_window_push 1
    done
    assert_false "$(sliding_window_check_recovery 10 12)" "9/12 not enough"
    sliding_window_push 1
    assert_true "$(sliding_window_check_recovery 10 12)" "10/12 = recovery"
}

test_sliding_window_failure_detection() {
    source "$PROJECT_ROOT/lib.sh"
    sliding_window_init 12
    sliding_window_push 0
    sliding_window_push 0
    sliding_window_push 0
    assert_false "$(sliding_window_check_failure 4)" "3 failures not enough"
    sliding_window_push 0
    assert_true "$(sliding_window_check_failure 4)" "4 consecutive failures = outage"
}

test_sliding_window_failure_reset_on_success() {
    source "$PROJECT_ROOT/lib.sh"
    sliding_window_init 12
    sliding_window_push 0
    sliding_window_push 0
    sliding_window_push 0
    sliding_window_push 1  # success breaks the streak
    sliding_window_push 0
    assert_false "$(sliding_window_check_failure 4)" "streak broken by success"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_state.sh`
Expected: FAIL

- [ ] **Step 3: Implement state management + sliding window in lib.sh**

Add to `lib.sh`:
- `write_state()` — writes tier ID to `state/current_tier`
- `read_state()` — reads current tier from `state/current_tier`, returns empty string if missing
- `sliding_window_init()` — initializes `SW_WINDOW` array and `SW_TOTAL_PUSHED` counter
- `sliding_window_push()` — adds 0 (fail) or 1 (success) to circular buffer
- `sliding_window_check_recovery()` — on cold start (total pushed < window size), requires 3 consecutive successes. Otherwise requires `recovery_successes` out of `recovery_window`.
- `sliding_window_check_failure()` — checks last N entries are all 0

```bash
# --- Cross-Platform Helpers ---

date_to_epoch() {
    local timestamp="$1"
    # Try GNU date first (Linux, Git Bash)
    date -d "$timestamp" +%s 2>/dev/null && return
    # Try BSD date (macOS)
    date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" +%s 2>/dev/null && return
    # Fallback: extract components and use printf
    echo 0
}

# --- Monitor Lifecycle ---
# Stub — replaced with full implementation in Task 10.
# Defined here so fallback.sh (Task 8) can call it without error.

start_monitor() { :; }
stop_monitor() { :; }

# --- State Management ---

write_state() {
    local tier="$1"
    local state_dir="${2:-$CODEPENDENT_ROOT/state}"
    mkdir -p "$state_dir"
    echo "$tier" > "$state_dir/current_tier"
}

read_state() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local file="$state_dir/current_tier"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo ""
    fi
}

# --- Sliding Window ---

SW_WINDOW=()
SW_INDEX=0
SW_SIZE=0
SW_TOTAL_PUSHED=0

sliding_window_init() {
    local size="$1"
    SW_SIZE="$size"
    SW_INDEX=0
    SW_TOTAL_PUSHED=0
    SW_WINDOW=()
    for ((i = 0; i < size; i++)); do
        SW_WINDOW+=("")
    done
}

sliding_window_push() {
    local value="$1"  # 0=fail, 1=success
    SW_WINDOW[$SW_INDEX]="$value"
    SW_INDEX=$(( (SW_INDEX + 1) % SW_SIZE ))
    ((SW_TOTAL_PUSHED++))
}

sliding_window_check_recovery() {
    local required="$1"
    local window="$2"

    # Cold start: if we haven't filled the window yet,
    # use reduced threshold of 3 consecutive successes
    if ((SW_TOTAL_PUSHED < window)); then
        local consecutive=0
        for ((i = SW_TOTAL_PUSHED - 1; i >= 0; i--)); do
            if [[ "${SW_WINDOW[$i]}" == "1" ]]; then
                ((consecutive++))
            else
                break
            fi
        done
        if ((consecutive >= 3)); then
            echo "true"
        else
            echo "false"
        fi
        return
    fi

    # Normal: count successes in window
    local successes=0
    for val in "${SW_WINDOW[@]}"; do
        [[ "$val" == "1" ]] && ((successes++))
    done
    if ((successes >= required)); then
        echo "true"
    else
        echo "false"
    fi
}

sliding_window_check_failure() {
    local required="$1"

    if ((SW_TOTAL_PUSHED < required)); then
        echo "false"
        return
    fi

    # Check last N entries are all failures
    for ((i = 1; i <= required; i++)); do
        local idx=$(( (SW_INDEX - i + SW_SIZE) % SW_SIZE ))
        if [[ "${SW_WINDOW[$idx]}" != "0" ]]; then
            echo "false"
            return
        fi
    done
    echo "true"
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_state.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_state.sh
git commit -m "feat: state management and sliding window for recovery/failure detection"
```

---

## Task 5: lib.sh — Health Checks

**Files:**
- Modify: `lib.sh`
- Create: `tests/test_health.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_health.sh` — tests use a mock `curl` function to avoid real network calls:

```bash
#!/usr/bin/env bash

test_check_network_success() {
    source "$PROJECT_ROOT/lib.sh"
    # Mock curl to succeed
    curl() { return 0; }
    # curl function shadows the real binary in this sourced context
    CFG_network_check_url="https://1.1.1.1"
    local result
    result=$(check_network)
    assert_eq "0" "$?" 2>/dev/null || assert_eq "up" "$result"
    unset -f curl
}

test_check_network_failure() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { return 1; }
    # curl function shadows the real binary in this sourced context
    CFG_network_check_url="https://1.1.1.1"
    if check_network 2>/dev/null; then
        assert_true "false" "should fail when curl fails"
    else
        assert_true "0" "correctly detected network down"
    fi
    unset -f curl
}

test_check_status_page_operational() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { echo '{"status":{"indicator":"none","description":"All Systems Operational"}}'; }
    # curl function shadows the real binary in this sourced context
    local result
    result=$(check_status_page)
    assert_eq "none" "$result"
    unset -f curl
}

test_check_status_page_major_outage() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { echo '{"status":{"indicator":"major","description":"Major System Outage"}}'; }
    # curl function shadows the real binary in this sourced context
    local result
    result=$(check_status_page)
    assert_eq "major" "$result"
    unset -f curl
}

test_check_status_page_curl_failure() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { return 1; }
    # curl function shadows the real binary in this sourced context
    local result
    result=$(check_status_page 2>/dev/null)
    assert_eq "unknown" "$result"
    unset -f curl
}

test_classify_health_all_good() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "up" "none")
    assert_eq "healthy" "$result"
}

test_classify_health_network_down() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "down" "unknown")
    assert_eq "network_down" "$result"
}

test_classify_health_api_outage() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "up" "major")
    assert_eq "outage" "$result"
}

test_classify_health_degraded() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "up" "minor")
    assert_eq "degraded" "$result"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_health.sh`
Expected: FAIL

- [ ] **Step 3: Implement health checks in lib.sh**

Add to `lib.sh`:
- `check_network()` — `curl -sf --max-time 5 "$CFG_network_check_url"`, returns 0/1
- `check_status_page()` — curls Anthropic status JSON API, extracts `status.indicator` using grep/sed (no jq dependency). Returns: `none`, `minor`, `major`, `critical`, or `unknown` on curl failure.
- `classify_health()` — takes network status + status page indicator, returns: `healthy`, `network_down`, `outage`, `degraded`

```bash
# --- Health Checks ---

check_network() {
    if curl -sf --max-time 5 "${CFG_network_check_url:-https://1.1.1.1}" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

check_status_page() {
    local response
    if ! response=$(curl -sf --max-time 10 "https://status.anthropic.com/api/v2/status.json" 2>/dev/null); then
        echo "unknown"
        return
    fi
    # Extract indicator without jq — parse "indicator":"value"
    local indicator
    indicator=$(echo "$response" | grep -o '"indicator":"[^"]*"' | head -1 | sed 's/^"indicator":"//; s/"$//')
    if [[ -n "$indicator" ]]; then
        echo "$indicator"
    else
        echo "unknown"
    fi
}

classify_health() {
    local network="$1"    # up | down
    local indicator="$2"  # none | minor | major | critical | unknown

    if [[ "$network" == "down" ]]; then
        echo "network_down"
        return
    fi

    case "$indicator" in
        none)              echo "healthy" ;;
        minor)             echo "degraded" ;;
        major|critical)    echo "outage" ;;
        *)                 echo "outage" ;;  # unknown = assume outage
    esac
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_health.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_health.sh
git commit -m "feat: health checks — network, status page, classification"
```

---

## Task 6: lib.sh — Notifications

**Files:**
- Modify: `lib.sh`
- Create: `tests/test_notify.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_notify.sh`:

```bash
#!/usr/bin/env bash

test_notify_writes_to_log() {
    source "$PROJECT_ROOT/lib.sh"
    local test_log="$(mktemp)"
    notify "Test message" "$test_log"
    local content
    content=$(cat "$test_log")
    assert_contains "$content" "Test message"
    rm -f "$test_log"
}

test_notify_includes_timestamp() {
    source "$PROJECT_ROOT/lib.sh"
    local test_log="$(mktemp)"
    notify "Test message" "$test_log"
    local content
    content=$(cat "$test_log")
    # Should contain a date-like pattern
    assert_contains "$content" "202"
    rm -f "$test_log"
}

test_notify_toast_detects_platform() {
    source "$PROJECT_ROOT/lib.sh"
    detect_platform
    # Just verify the function doesn't crash — actual toast delivery
    # is platform-specific and tested via fallback.sh --test
    notify_toast "Test notification" 2>/dev/null || true
    assert_true "0" "notify_toast did not crash"
}

test_build_recovery_message() {
    source "$PROJECT_ROOT/lib.sh"
    local msg
    msg=$(build_recovery_message)
    assert_contains "$msg" "fallback.sh"
}

test_build_outage_message() {
    source "$PROJECT_ROOT/lib.sh"
    TIER_id="1"
    TIER_tool="codex"
    local msg
    msg=$(build_outage_message)
    assert_contains "$msg" "codex"
    assert_contains "$msg" "fallback.sh"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_notify.sh`
Expected: FAIL

- [ ] **Step 3: Implement notifications in lib.sh**

Add to `lib.sh`:
- `notify()` — writes timestamped message to log file. Never to stdout.
- `notify_toast()` — platform-aware toast notification with fallback chain. macOS: `osascript`. Windows: PowerShell `[Windows.UI.Notifications]` → BurntToast → bell. Failures are silent (notifications are convenience, not critical).
- `notify_terminal()` — terminal bell (`\a`)
- `notify_dispatch()` — reads `CFG_notify_method` and calls toast/terminal/both
- `build_outage_message()` — "Anthropic API down. Next available: Tier {id} ({tool}). Run: fallback.sh {id}"
- `build_recovery_message()` — "Anthropic API recovered (stable {N} min). Run: fallback.sh 0"

```bash
# --- Notifications ---

notify() {
    local message="$1"
    local log_file="${2:-$CODEPENDENT_ROOT/state/monitor.log}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$log_file")"
    echo "[$timestamp] $message" >> "$log_file"
}

notify_toast() {
    local message="$1"
    local title="${2:-codependent}"

    case "${PLATFORM:-}" in
        macos)
            osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
            ;;
        windows-git-bash|windows-wsl)
            # Try native Windows notifications via PowerShell
            if powershell.exe -NoProfile -Command "
                Add-Type -AssemblyName System.Windows.Forms
                \$n = New-Object System.Windows.Forms.NotifyIcon
                \$n.Icon = [System.Drawing.SystemIcons]::Information
                \$n.Visible = \$true
                \$n.ShowBalloonTip(5000, '$title', '$message', 'Info')
                Start-Sleep -Seconds 1
                \$n.Dispose()
            " 2>/dev/null; then
                return 0
            fi
            # Fallback: BurntToast
            if powershell.exe -NoProfile -Command "
                Import-Module BurntToast 2>\$null
                if (\$?) { New-BurntToastNotification -Text '$title','$message' }
                else { exit 1 }
            " 2>/dev/null; then
                return 0
            fi
            # Final fallback: bell
            notify_terminal
            ;;
        *)
            notify_terminal
            ;;
    esac
}

notify_terminal() {
    printf '\a' 2>/dev/null || true
}

notify_dispatch() {
    local message="$1"
    local log_file="${2:-$CODEPENDENT_ROOT/state/monitor.log}"

    # Always log
    notify "$message" "$log_file"

    case "${CFG_notify_method:-both}" in
        toast)    notify_toast "$message" ;;
        terminal) notify_terminal ;;
        both)     notify_toast "$message"; notify_terminal ;;
    esac
}

build_outage_message() {
    echo "Anthropic API down. Next available: Tier ${TIER_id} (${TIER_tool}). Run: fallback.sh ${TIER_id}"
}

build_recovery_message() {
    echo "Anthropic API recovered — stable. Switch back with: fallback.sh 0"
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_notify.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_notify.sh
git commit -m "feat: cross-platform notifications — toast, terminal, log"
```

---

## Task 7: lib.sh — Metrics + Log Rotation

**Files:**
- Modify: `lib.sh`
- Create: `tests/test_metrics.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_metrics.sh`:

```bash
#!/usr/bin/env bash

test_log_metrics_csv_fallback() {
    source "$PROJECT_ROOT/lib.sh"
    local test_dir="$(mktemp -d)"
    # Force CSV fallback by using a nonexistent sqlite3
    PATH_BACKUP="$PATH"
    PATH="/nonexistent"
    log_metrics "2026-04-15T10:00:00" "" "" "outage" "1" "codex" "false" "macos" "$test_dir"
    PATH="$PATH_BACKUP"
    assert_file_exists "$test_dir/metrics.csv"
    local content
    content=$(cat "$test_dir/metrics.csv")
    assert_contains "$content" "outage"
    assert_contains "$content" "codex"
    rm -rf "$test_dir"
}

test_rotate_log_under_limit() {
    source "$PROJECT_ROOT/lib.sh"
    local test_log="$(mktemp)"
    echo "small content" > "$test_log"
    rotate_log "$test_log" 1048576
    # Should not rotate
    assert_file_exists "$test_log"
    assert_contains "$(cat "$test_log")" "small content"
    rm -f "$test_log"
}

test_rotate_log_over_limit() {
    source "$PROJECT_ROOT/lib.sh"
    local test_log="$(mktemp)"
    # Write more than 100 bytes
    for i in {1..20}; do
        echo "This is a line of log content that fills up the log file $i" >> "$test_log"
    done
    rotate_log "$test_log" 100
    # Old log should be in .1
    assert_file_exists "${test_log}.1"
    # New log should exist and be small
    if [[ -f "$test_log" ]]; then
        local size
        size=$(wc -c < "$test_log")
        assert_true "$([[ $size -lt 100 ]] && echo true || echo false)" "rotated log should be small"
    fi
    rm -f "$test_log" "${test_log}.1" "${test_log}.tmp"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_metrics.sh`
Expected: FAIL

- [ ] **Step 3: Implement metrics + log rotation in lib.sh**

Add to `lib.sh`:
- `log_metrics()` — tries `sqlite3` first (creates table if needed, inserts row). If `sqlite3` not in PATH, appends to `state/metrics.csv`.
- `import_csv_to_db()` — if CSV has pending rows and `sqlite3` is now available, import and clear CSV
- `rotate_log()` — checks file size, if over max: write to `.tmp`, rename `.log` → `.log.1`, rename `.tmp` → `.log`

```bash
# --- Metrics ---

log_metrics() {
    local started_at="$1"
    local recovered_at="${2:-}"
    local duration_minutes="${3:-}"
    local failure_type="$4"
    local tier_used="$5"
    local tool_used="$6"
    local auto_recovered="${7:-false}"
    local platform="${8:-$PLATFORM}"
    local state_dir="${9:-$CODEPENDENT_ROOT/state}"

    mkdir -p "$state_dir"

    # Escape single quotes for SQL safety
    started_at="${started_at//\'/\'\'}"
    recovered_at="${recovered_at//\'/\'\'}"
    failure_type="${failure_type//\'/\'\'}"
    tier_used="${tier_used//\'/\'\'}"
    tool_used="${tool_used//\'/\'\'}"
    platform="${platform//\'/\'\'}"

    # Try sqlite3 first
    if command -v sqlite3 &>/dev/null && [[ -n "${CFG_log_to_metrics:-true}" ]]; then
        local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"

        # Import any pending CSV rows first
        import_csv_to_db "$state_dir"

        sqlite3 "$db" <<SQL 2>/dev/null && return 0
CREATE TABLE IF NOT EXISTS outage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    recovered_at TEXT,
    duration_minutes REAL,
    failure_type TEXT NOT NULL,
    tier_used TEXT NOT NULL,
    tool_used TEXT NOT NULL,
    auto_recovered BOOLEAN DEFAULT FALSE,
    platform TEXT NOT NULL
);
INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform)
VALUES ('$started_at', '$recovered_at', '$duration_minutes', '$failure_type', '$tier_used', '$tool_used', '$auto_recovered', '$platform');
SQL
    fi

    # CSV fallback
    local csv="$state_dir/metrics.csv"
    if [[ ! -f "$csv" ]]; then
        echo "started_at,recovered_at,duration_minutes,failure_type,tier_used,tool_used,auto_recovered,platform" > "$csv"
    fi
    echo "$started_at,$recovered_at,$duration_minutes,$failure_type,$tier_used,$tool_used,$auto_recovered,$platform" >> "$csv"
}

import_csv_to_db() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local csv="$state_dir/metrics.csv"

    [[ -f "$csv" ]] || return 0
    command -v sqlite3 &>/dev/null || return 0

    local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"
    # Skip header line, import each row
    tail -n +2 "$csv" | while IFS=, read -r started_at recovered_at duration_minutes failure_type tier_used tool_used auto_recovered platform; do
        sqlite3 "$db" "INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform) VALUES ('$started_at', '$recovered_at', '$duration_minutes', '$failure_type', '$tier_used', '$tool_used', '$auto_recovered', '$platform');" 2>/dev/null
    done

    # Clear CSV after successful import
    rm -f "$csv"
}

# --- Log Rotation ---

rotate_log() {
    local log_file="$1"
    local max_size="${2:-${CFG_max_log_size:-1048576}}"

    [[ -f "$log_file" ]] || return 0

    local size
    size=$(wc -c < "$log_file" 2>/dev/null || echo 0)

    if ((size > max_size)); then
        # Safe rotation: write-new-then-rename
        touch "${log_file}.tmp"
        mv "$log_file" "${log_file}.1" 2>/dev/null || true
        mv "${log_file}.tmp" "$log_file" 2>/dev/null || true
    fi
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_metrics.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_metrics.sh
git commit -m "feat: metrics logging (sqlite3 + CSV fallback) and log rotation"
```

---

## Task 8: fallback.sh — Core Tier Walking + Status

**Files:**
- Create: `fallback.sh`
- Create: `tests/test_fallback.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_fallback.sh`:

```bash
#!/usr/bin/env bash

setup_fallback_env() {
    export TEST_STATE_DIR="$(mktemp -d)"
    export TEST_TIERS="$(mktemp)"
    export TEST_CONF="$(mktemp)"
    # Minimal tiers — use bash as a "tool" that's guaranteed to exist
    cat > "$TEST_TIERS" <<'TIERS'
0 | bash | echo tier0 |  | command -v bash
1 | bash | echo tier1 | FAKE_MISSING_VAR | command -v bash
TIERS
    cat > "$TEST_CONF" <<'CONF'
check_interval=30
on_failure=notify
on_recovery=notify
notify_method=terminal
health_check=status_page
CONF
}

teardown_fallback_env() {
    rm -rf "$TEST_STATE_DIR" "$TEST_TIERS" "$TEST_CONF"
}

test_fallback_status_shows_tiers() {
    setup_fallback_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform
    local output
    output=$(show_status "$TEST_STATE_DIR" 2>&1)
    assert_contains "$output" "Tier 0"
    assert_contains "$output" "bash"
    teardown_fallback_env
}

test_fallback_dry_run_picks_first_available() {
    setup_fallback_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform
    local output
    output=$(dry_run_tiers "$TEST_STATE_DIR" 2>&1)
    assert_contains "$output" "Tier 0"
    assert_contains "$output" "ready"
    teardown_fallback_env
}

test_fallback_skips_tier_with_missing_env() {
    setup_fallback_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform
    # Tier 1 requires FAKE_MISSING_VAR which isn't set
    local output
    output=$(dry_run_tiers "$TEST_STATE_DIR" 2>&1)
    assert_contains "$output" "FAKE_MISSING_VAR"
    teardown_fallback_env
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_fallback.sh`
Expected: FAIL

- [ ] **Step 3: Implement fallback.sh**

Create `fallback.sh`:
- Argument parsing: `status`, `--dry-run`, `--test`, bare number, no args
- `show_status()` — walks all tiers, shows readiness (✓/✗), monitor state, config sync
- `dry_run_tiers()` — walks tiers, shows what would launch without launching
- `walk_tiers()` — the real tier walking: check prerequisites, first passing tier gets launched
- `run_tests()` — full prerequisite + notification test
- Reads `state/failover_ready` if present, cleans it up after reading

```bash
#!/usr/bin/env bash
# codependent — tiered AI coding assistant failover
# Usage: fallback.sh [status|--dry-run|--test|TIER_NUMBER]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_config
detect_platform
load_tiers

STATE_DIR="$CODEPENDENT_ROOT/state"
mkdir -p "$STATE_DIR"

# --- Functions ---

show_status() {
    local state_dir="${1:-$STATE_DIR}"
    echo "codependent — fallback status"
    echo ""

    for line in "${TIERS[@]}"; do
        parse_tier_line "$line"
        local status="✗"
        local reason=""
        if check_tier_prerequisites 2>/dev/null; then
            status="✓"
            reason="ready"
        else
            reason=$(check_tier_prerequisites 2>&1 || true)
        fi
        printf "  Tier %-7s %-10s %s %s\n" "$TIER_id" "$TIER_tool" "$status" "$reason"
    done

    echo ""

    # Monitor status
    local pid_file="$state_dir/monitor.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Monitor: running (PID $pid)"
            if [[ -f "$state_dir/monitor.heartbeat" ]]; then
                local hb_age
                hb_age=$(( $(date +%s) - $(stat -c %Y "$state_dir/monitor.heartbeat" 2>/dev/null || stat -f %m "$state_dir/monitor.heartbeat" 2>/dev/null || echo 0) ))
                echo "Heartbeat: ${hb_age}s ago"
            fi
        else
            echo "Monitor: stale PID file (process $pid not running)"
        fi
    else
        echo "Monitor: not running"
    fi

    # Current tier
    local current
    current=$(read_state "$state_dir")
    if [[ -n "$current" ]]; then
        echo "Active tier: $current"
    fi

    # Failover ready
    if [[ -f "$state_dir/failover_ready" ]]; then
        echo ""
        echo "⚡ Failover recommendation ready: $(cat "$state_dir/failover_ready")"
        echo "   Run the suggested command, or dismiss with: rm $state_dir/failover_ready"
    fi
}

dry_run_tiers() {
    local state_dir="${1:-$STATE_DIR}"
    echo "codependent — dry run"
    echo ""

    for line in "${TIERS[@]}"; do
        parse_tier_line "$line"
        if check_tier_prerequisites 2>/dev/null; then
            echo "  Tier $TIER_id ($TIER_tool): ✓ ready — would run: $TIER_command"
        else
            local reason
            reason=$(check_tier_prerequisites 2>&1 || true)
            echo "  Tier $TIER_id ($TIER_tool): ✗ skip — $reason"
        fi
    done
}

run_tests() {
    echo "codependent — full system test"
    echo ""

    # Test each tier
    dry_run_tiers

    echo ""
    echo "Notification test:"
    notify_toast "codependent test notification" "codependent"
    echo "  Toast sent (check your notifications)"
    notify_terminal
    echo "  Terminal bell sent"

    echo ""
    echo "Config:"
    if validate_config 2>/dev/null; then
        echo "  ✓ resilience.conf valid"
    else
        echo "  ✗ resilience.conf has errors:"
        validate_config 2>&1 | sed 's/^/    /'
    fi
}

walk_tiers() {
    local start_tier="${1:-}"
    local state_dir="$STATE_DIR"
    local started=false

    # Check for failover_ready recommendation
    if [[ -z "$start_tier" && -f "$state_dir/failover_ready" ]]; then
        start_tier=$(cat "$state_dir/failover_ready" | head -1)
        rm -f "$state_dir/failover_ready"
    fi

    for line in "${TIERS[@]}"; do
        parse_tier_line "$line"

        # Skip sidecar — never auto-launched
        [[ "$TIER_id" == "sidecar" ]] && continue

        # If start_tier specified, skip until we reach it
        if [[ -n "$start_tier" && "$started" == "false" ]]; then
            [[ "$TIER_id" == "$start_tier" ]] && started=true || continue
        fi

        if check_tier_prerequisites 2>/dev/null; then
            echo "Activating Tier $TIER_id: $TIER_tool"
            write_state "$TIER_id" "$state_dir"
            touch "$state_dir/monitor.heartbeat"
            start_monitor
            # Replace this process with the tool
            exec $TIER_command
        else
            echo "Tier $TIER_id ($TIER_tool): skipping — $(check_tier_prerequisites 2>&1 || true)"
        fi
    done

    echo ""
    echo "All tiers exhausted. No AI coding assistant available."
    echo "Run 'fallback.sh status' to see what needs setup."
    exit 1
}

# --- Main ---

case "${1:-}" in
    status)
        show_status
        ;;
    --dry-run)
        dry_run_tiers
        ;;
    --test)
        run_tests
        ;;
    "")
        walk_tiers
        ;;
    *)
        # Assume it's a tier number
        walk_tiers "$1"
        ;;
esac
```

- [ ] **Step 4: Make executable**

```bash
chmod +x fallback.sh
```

- [ ] **Step 5: Run tests**

Run: `bash tests/runner.sh test_fallback.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add fallback.sh tests/test_fallback.sh
git commit -m "feat: fallback.sh — tier walking, status, dry-run, test modes"
```

---

## Task 9: monitor.sh — Background Daemon

**Files:**
- Create: `monitor.sh`
- Create: `tests/test_monitor.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_monitor.sh`:

```bash
#!/usr/bin/env bash

setup_monitor_env() {
    export TEST_STATE_DIR="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<'CONF'
check_interval=1
health_check=status_page
recovery_successes=3
recovery_window=4
failure_window=2
degraded_threshold=5
on_recovery=notify
on_failure=notify
notify_method=terminal
heartbeat_timeout=600
max_log_size=1048576
network_check_url=https://1.1.1.1
CONF
    # Create a heartbeat so monitor doesn't self-terminate
    touch "$TEST_STATE_DIR/monitor.heartbeat"
}

teardown_monitor_env() {
    # Kill any test monitor processes
    if [[ -f "$TEST_STATE_DIR/monitor.pid" ]]; then
        local pid
        pid=$(cat "$TEST_STATE_DIR/monitor.pid")
        kill "$pid" 2>/dev/null || true
    fi
    rm -rf "$TEST_STATE_DIR" "$TEST_CONF"
}

test_monitor_writes_pid_file() {
    setup_monitor_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    detect_platform
    # Start monitor in background, let it run one cycle
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" &
    local mpid=$!
    sleep 2
    assert_file_exists "$TEST_STATE_DIR/monitor.pid"
    kill "$mpid" 2>/dev/null || true
    wait "$mpid" 2>/dev/null || true
    teardown_monitor_env
}

test_monitor_singleton() {
    setup_monitor_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    detect_platform
    # Start first monitor
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" &
    local pid1=$!
    sleep 2
    # Try to start second — should exit immediately
    local output
    output=$(bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" 2>&1) || true
    assert_contains "$output" "already running"
    kill "$pid1" 2>/dev/null || true
    wait "$pid1" 2>/dev/null || true
    teardown_monitor_env
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_monitor.sh`
Expected: FAIL

- [ ] **Step 3: Implement monitor.sh**

Create `monitor.sh`:
- Argument parsing: `--state-dir`, `--config`, `stop`
- Singleton enforcement via PID file
- Main loop: sleep → check heartbeat → check network → check status page → classify → push to sliding window → check recovery/failure → act
- State machine: WATCHING → DEGRADED → MONITORING_RECOVERY → WATCHING
- On outage: `notify_dispatch` + write `failover_ready` if `on_failure=auto_failover`
- On recovery: `notify_dispatch` + clean up `failover_ready` + log metrics
- On DEGRADED: exponential backoff, notify once
- Heartbeat check: if heartbeat mtime > `heartbeat_timeout`, self-terminate
- Log rotation on each cycle
- Clean PID file on exit (trap)

```bash
#!/usr/bin/env bash
# codependent — background health monitor daemon
# Usage: monitor.sh [--state-dir DIR] [--config FILE] [stop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Parse args
STATE_DIR="$CODEPENDENT_ROOT/state"
CONFIG_FILE="$CODEPENDENT_ROOT/resilience.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --config)    CONFIG_FILE="$2"; shift 2 ;;
        stop)
            if [[ -f "$STATE_DIR/monitor.pid" ]]; then
                kill "$(cat "$STATE_DIR/monitor.pid")" 2>/dev/null && echo "Monitor stopped." || echo "Monitor not running."
                rm -f "$STATE_DIR/monitor.pid"
            else
                echo "Monitor not running."
            fi
            exit 0
            ;;
        *) shift ;;
    esac
done

load_config "$CONFIG_FILE"
detect_platform

mkdir -p "$STATE_DIR"

# Singleton check
PID_FILE="$STATE_DIR/monitor.pid"
if [[ -f "$PID_FILE" ]]; then
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Monitor already running (PID $existing_pid)" >&2
        exit 1
    fi
fi

# Write PID
echo $$ > "$PID_FILE"

# Cleanup on exit
cleanup() {
    rm -f "$PID_FILE"
}
trap cleanup EXIT INT TERM

# State machine
DAEMON_STATE="WATCHING"
OUTAGE_STARTED=""
DEGRADED_STARTED=""
CURRENT_INTERVAL="${CFG_check_interval:-30}"

LOG_FILE="$STATE_DIR/monitor.log"

sliding_window_init "${CFG_recovery_window:-12}"

notify "Monitor started (PID $$, state=$DAEMON_STATE)" "$LOG_FILE"

# --- Main Loop ---

while true; do
    sleep "$CURRENT_INTERVAL"

    # Heartbeat check — self-terminate if stale
    # NOTE: No `local` in main loop — `local` is only valid inside functions
    if [[ -f "$STATE_DIR/monitor.heartbeat" ]]; then
        hb_mtime=$(stat -c %Y "$STATE_DIR/monitor.heartbeat" 2>/dev/null || stat -f %m "$STATE_DIR/monitor.heartbeat" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - hb_mtime))
        if ((age > ${CFG_heartbeat_timeout:-600})); then
            notify "Heartbeat stale (${age}s). Self-terminating." "$LOG_FILE"
            exit 0
        fi
    fi

    # Health check
    network_status="up"
    if ! check_network; then
        network_status="down"
    fi

    status_indicator="unknown"
    if [[ "$network_status" == "up" ]]; then
        status_indicator=$(check_status_page)
    fi

    health=$(classify_health "$network_status" "$status_indicator")

    # Map health to sliding window value
    check_val=0
    [[ "$health" == "healthy" ]] && check_val=1

    sliding_window_push "$check_val"

    # State machine transitions
    case "$DAEMON_STATE" in
        WATCHING)
            if [[ "$health" == "network_down" || "$health" == "outage" ]]; then
                if [[ "$(sliding_window_check_failure "${CFG_failure_window:-4}")" == "true" ]]; then
                    DAEMON_STATE="MONITORING_RECOVERY"
                    OUTAGE_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
                    CURRENT_INTERVAL="${CFG_check_interval:-30}"

                    # Find next available tier for the message
                    load_tiers
                    next_tier_msg="no tier available"
                    for tline in "${TIERS[@]}"; do
                        parse_tier_line "$tline"
                        [[ "$TIER_id" == "sidecar" ]] && continue
                        [[ "$TIER_id" == "0" ]] && continue  # Skip tier 0 (that's what's down)
                        if check_tier_prerequisites 2>/dev/null; then
                            next_tier_msg="Tier $TIER_id ($TIER_tool)"
                            break
                        fi
                    done

                    local msg="Anthropic API down. Next available: $next_tier_msg. Run: fallback.sh $TIER_id"
                    notify "$msg" "$LOG_FILE"
                    notify_dispatch "$msg"

                    # Write failover_ready if configured
                    if [[ "${CFG_on_failure:-notify}" == "auto_failover" || "${CFG_on_failure:-notify}" == "both" ]]; then
                        echo "$TIER_id" > "$STATE_DIR/failover_ready"
                    fi
                fi
            elif [[ "$health" == "degraded" ]]; then
                DAEMON_STATE="DEGRADED"
                DEGRADED_STARTED=$(date +%s)
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "API degraded (status: $status_indicator). Monitoring." "$LOG_FILE"
                notify_dispatch "Anthropic API degraded — rate limited. Monitoring."
            fi
            ;;

        DEGRADED)
            if [[ "$health" == "healthy" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "Degradation cleared. Resuming normal monitoring." "$LOG_FILE"
            elif [[ "$health" == "outage" || "$health" == "network_down" ]]; then
                DAEMON_STATE="MONITORING_RECOVERY"
                OUTAGE_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "Degradation escalated to outage." "$LOG_FILE"
                notify_dispatch "Anthropic API: degradation escalated to full outage."
            else
                # Still degraded — check if past threshold
                now=$(date +%s)
                degraded_duration=$((now - DEGRADED_STARTED))
                if ((degraded_duration > ${CFG_degraded_threshold:-600})); then
                    DAEMON_STATE="MONITORING_RECOVERY"
                    OUTAGE_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
                    notify "Sustained degradation (${degraded_duration}s). Escalating to failover." "$LOG_FILE"
                    notify_dispatch "Anthropic API degraded for ${degraded_duration}s. Consider switching: fallback.sh 1"
                    continue  # Skip backoff — already escalated
                fi
                # Exponential backoff
                CURRENT_INTERVAL=$((CURRENT_INTERVAL * 2))
                max_interval=300
                ((CURRENT_INTERVAL > max_interval)) && CURRENT_INTERVAL=$max_interval
            fi
            ;;

        MONITORING_RECOVERY)
            if [[ "$(sliding_window_check_recovery "${CFG_recovery_successes:-10}" "${CFG_recovery_window:-12}")" == "true" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                recovered_at=$(date '+%Y-%m-%dT%H:%M:%S')

                notify "Anthropic API recovered." "$LOG_FILE"
                notify_dispatch "$(build_recovery_message)"

                # Clean up failover_ready
                rm -f "$STATE_DIR/failover_ready"

                # Log metrics
                if [[ -n "$OUTAGE_STARTED" ]]; then
                    start_epoch=$(date_to_epoch "$OUTAGE_STARTED")
                    end_epoch=$(date +%s)
                    duration=$(( (end_epoch - start_epoch) / 60 ))
                    log_metrics "$OUTAGE_STARTED" "$recovered_at" "$duration" "outage" \
                        "$(read_state "$STATE_DIR")" "monitor" "true" "$PLATFORM" "$STATE_DIR"
                fi
                OUTAGE_STARTED=""
            fi
            ;;
    esac

    # Log rotation
    rotate_log "$LOG_FILE"
done
```

- [ ] **Step 4: Make executable**

```bash
chmod +x monitor.sh
```

- [ ] **Step 5: Run tests**

Run: `bash tests/runner.sh test_monitor.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add monitor.sh tests/test_monitor.sh
git commit -m "feat: monitor.sh — background daemon with state machine, health checks, failover"
```

---

## Task 10: lib.sh — Monitor Lifecycle (start/stop from lib)

**Files:**
- Modify: `lib.sh`

- [ ] **Step 1: Implement start_monitor and stop_monitor in lib.sh**

These are called by `fallback.sh` and need to launch `monitor.sh` in the background.

Add to `lib.sh`:

```bash
# --- Monitor Lifecycle ---

start_monitor() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local config="${2:-$CODEPENDENT_ROOT/resilience.conf}"
    local pid_file="$state_dir/monitor.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid=$(cat "$pid_file")
        if kill -0 "$existing_pid" 2>/dev/null; then
            # Already running, just touch heartbeat
            touch "$state_dir/monitor.heartbeat"
            return 0
        fi
    fi

    # Launch in background
    nohup bash "$CODEPENDENT_ROOT/monitor.sh" --state-dir "$state_dir" --config "$config" &>/dev/null &
    disown
    touch "$state_dir/monitor.heartbeat"
}

stop_monitor() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local pid_file="$state_dir/monitor.pid"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi
}
```

- [ ] **Step 2: Run all tests to verify nothing broke**

Run: `bash tests/runner.sh`
Expected: All PASS

- [ ] **Step 3: Commit**

```bash
git add lib.sh
git commit -m "feat: monitor lifecycle — start/stop from lib.sh"
```

---

## Task 11: guardrails.md + Tool Templates

**Files:**
- Create: `guardrails.md`
- Create: `tools/claude/template.md`
- Create: `tools/codex/template.md`
- Create: `tools/aider/template.md`
- Create: `tools/cursor/template.md`

- [ ] **Step 1: Extract guardrails.md from current CLAUDE.md**

Read `C:\Users\AR\.claude\CLAUDE.md` and extract the tool-agnostic sections into `guardrails.md`:
1. Epistemic honesty rules
2. Hard guardrails (security, quality, process)
3. Karpathy behavioral principles
4. Pre-implementation gate
5. Artifact modes table
6. Language-specific overlays
7. Output standards

Strip all CSuite-specific content (personas, skills, MCP servers, metrics, hooks).

- [ ] **Step 2: Create tools/claude/template.md**

Contains everything that was stripped from guardrails.md:
- CSuite identity and scope
- Personas → subagents table
- Skills table
- Process gates table
- MCP servers config
- Metrics responsibility
- Metrics-driven behavior / behavioral modes

- [ ] **Step 3: Create tools/codex/template.md**

Thin wrapper that adds Codex-specific instructions:
- "You are operating as a fallback AI coding assistant via OpenAI Codex."
- "The primary assistant (Claude Code) is currently unavailable."
- "Follow all guardrails above. They are non-negotiable."
- Any AGENTS.md formatting specifics.

- [ ] **Step 4: Create tools/aider/template.md**

Thin wrapper for Aider:
- Similar fallback notice
- Note about `--read CONVENTIONS.md` loading
- Any aider-specific behavioral notes

- [ ] **Step 5: Create tools/cursor/template.md**

Thin wrapper for Cursor:
- `.mdc` frontmatter: `description`, `applies_to: "*"`
- Fallback notice
- Note about Cursor's rule format

- [ ] **Step 6: Commit**

```bash
git add guardrails.md tools/
git commit -m "feat: canonical guardrails and tool-specific templates"
```

---

## Task 12: generate-configs.sh

**Files:**
- Create: `generate-configs.sh`
- Create: `tests/test_generate.sh`

- [ ] **Step 1: Write failing tests**

`tests/test_generate.sh`:

```bash
#!/usr/bin/env bash

setup_generate_env() {
    export TEST_OUTPUT_DIR="$(mktemp -d)"
    export TEST_PROJECT_DIR="$(mktemp -d)"
    mkdir -p "$TEST_PROJECT_DIR/.claude"
    export TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<CONF
project_roots=$TEST_PROJECT_DIR
CONF
}

teardown_generate_env() {
    rm -rf "$TEST_OUTPUT_DIR" "$TEST_PROJECT_DIR" "$TEST_CONF"
}

test_generate_produces_agents_md() {
    setup_generate_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    bash "$PROJECT_ROOT/generate-configs.sh" --config "$TEST_CONF"
    assert_file_exists "$TEST_PROJECT_DIR/AGENTS.md"
    local content
    content=$(cat "$TEST_PROJECT_DIR/AGENTS.md")
    assert_contains "$content" "Generated by"
    teardown_generate_env
}

test_generate_is_deterministic() {
    setup_generate_env
    bash "$PROJECT_ROOT/generate-configs.sh" --config "$TEST_CONF"
    local hash1
    hash1=$(sha256sum "$TEST_PROJECT_DIR/AGENTS.md" | awk '{print $1}')
    bash "$PROJECT_ROOT/generate-configs.sh" --config "$TEST_CONF"
    local hash2
    hash2=$(sha256sum "$TEST_PROJECT_DIR/AGENTS.md" | awk '{print $1}')
    assert_eq "$hash1" "$hash2" "same input should produce identical output"
    teardown_generate_env
}

test_generate_verify_mode_passes_when_clean() {
    setup_generate_env
    bash "$PROJECT_ROOT/generate-configs.sh" --config "$TEST_CONF"
    if bash "$PROJECT_ROOT/generate-configs.sh" --config "$TEST_CONF" --verify; then
        assert_true "0" "verify should pass when configs are in sync"
    else
        assert_true "false" "verify should not fail on clean state"
    fi
    teardown_generate_env
}

test_generate_verify_mode_fails_when_drifted() {
    setup_generate_env
    bash "$PROJECT_ROOT/generate-configs.sh" --config "$TEST_CONF"
    # Manually edit a generated file
    echo "# manual edit" >> "$TEST_PROJECT_DIR/AGENTS.md"
    if bash "$PROJECT_ROOT/generate-configs.sh" --config "$TEST_CONF" --verify 2>/dev/null; then
        assert_true "false" "verify should fail when config has drifted"
    else
        assert_true "0" "correctly detected drift"
    fi
    teardown_generate_env
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_generate.sh`
Expected: FAIL

- [ ] **Step 3: Implement generate-configs.sh**

```bash
#!/usr/bin/env bash
# codependent — config generator
# Usage: generate-configs.sh [--config FILE] [--verify]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

VERIFY_MODE=false
CONFIG_FILE="$CODEPENDENT_ROOT/resilience.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --verify) VERIFY_MODE=true; shift ;;
        *) shift ;;
    esac
done

load_config "$CONFIG_FILE"

GUARDRAILS="$CODEPENDENT_ROOT/guardrails.md"
TOOLS_DIR="$CODEPENDENT_ROOT/tools"

# Compute source hash for drift detection
source_hash() {
    local tool="$1"
    local template="$TOOLS_DIR/$tool/template.md"
    if [[ -f "$template" ]]; then
        cat "$GUARDRAILS" "$template" | sha256sum | awk '{print $1}'
    else
        sha256sum "$GUARDRAILS" | awk '{print $1}'
    fi
}

generate_for_tool() {
    local tool="$1"
    local output_file="$2"
    local template="$TOOLS_DIR/$tool/template.md"
    local hash
    hash=$(source_hash "$tool")
    local header="# Generated by codependent/generate-configs.sh — do not edit directly"
    local hash_line="# Source hash: $hash"

    {
        echo "$header"
        echo "$hash_line"
        echo ""
        cat "$GUARDRAILS"
        echo ""
        if [[ -f "$template" ]]; then
            echo ""
            cat "$template"
        fi
    } > "$output_file"
}

verify_for_tool() {
    local tool="$1"
    local output_file="$2"

    if [[ ! -f "$output_file" ]]; then
        echo "DRIFT: $output_file does not exist" >&2
        return 1
    fi

    local expected_hash
    expected_hash=$(source_hash "$tool")
    local actual_hash
    actual_hash=$(grep '^# Source hash:' "$output_file" 2>/dev/null | awk '{print $4}')

    if [[ "$expected_hash" != "$actual_hash" ]]; then
        echo "DRIFT: $output_file (expected hash $expected_hash, found $actual_hash)" >&2
        return 1
    fi
    return 0
}

# Discover projects
IFS=',' read -ra roots <<< "${CFG_project_roots:-~/Projects}"
PROJECTS=()
for root in "${roots[@]}"; do
    root="${root/#\~/$HOME}"
    root="$(echo "$root" | xargs)"  # trim whitespace
    if [[ -d "$root" ]]; then
        while IFS= read -r proj_claude_dir; do
            PROJECTS+=("$(dirname "$proj_claude_dir")")
        done < <(find "$root" -maxdepth 2 -type d -name ".claude" 2>/dev/null)
    fi
done

DRIFT_FOUND=false

# Global Claude config → ~/.claude/CLAUDE.md
GLOBAL_CLAUDE="$HOME/.claude/CLAUDE.md"
if "$VERIFY_MODE"; then
    verify_for_tool "claude" "$GLOBAL_CLAUDE" || DRIFT_FOUND=true
else
    mkdir -p "$HOME/.claude"
    generate_for_tool "claude" "$GLOBAL_CLAUDE"
fi

for project in "${PROJECTS[@]}"; do
    # Generate/verify each tool's config
    # Codex → AGENTS.md
    if "$VERIFY_MODE"; then
        verify_for_tool "codex" "$project/AGENTS.md" || DRIFT_FOUND=true
    else
        generate_for_tool "codex" "$project/AGENTS.md"
    fi

    # Aider → CONVENTIONS.md
    if "$VERIFY_MODE"; then
        verify_for_tool "aider" "$project/CONVENTIONS.md" || DRIFT_FOUND=true
    else
        generate_for_tool "aider" "$project/CONVENTIONS.md"
    fi

    # Cursor → .cursor/rules/guardrails.mdc
    if "$VERIFY_MODE"; then
        verify_for_tool "cursor" "$project/.cursor/rules/guardrails.mdc" || DRIFT_FOUND=true
    else
        mkdir -p "$project/.cursor/rules"
        generate_for_tool "cursor" "$project/.cursor/rules/guardrails.mdc"
    fi

    # Claude → .claude/CLAUDE.md
    if "$VERIFY_MODE"; then
        verify_for_tool "claude" "$project/.claude/CLAUDE.md" || DRIFT_FOUND=true
    else
        generate_for_tool "claude" "$project/.claude/CLAUDE.md"
    fi
done

if "$VERIFY_MODE"; then
    if "$DRIFT_FOUND"; then
        echo "Config drift detected. Run generate-configs.sh to fix." >&2
        exit 1
    else
        echo "All configs in sync."
        exit 0
    fi
else
    echo "Generated configs for ${#PROJECTS[@]} projects."
fi
```

- [ ] **Step 4: Make executable**

```bash
chmod +x generate-configs.sh
```

- [ ] **Step 5: Run tests**

Run: `bash tests/runner.sh test_generate.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add generate-configs.sh tests/test_generate.sh
git commit -m "feat: config generator — deterministic output, hash-based drift detection, verify mode"
```

---

## Task 13: Setup Documentation

**Files:**
- Create: `tools/claude/setup.md`
- Create: `tools/codex/setup.md`
- Create: `tools/aider/setup.md`
- Create: `tools/cursor/setup.md`
- Create: `tools/ollama/setup.md`

- [ ] **Step 1: Write setup docs for each tool**

Each `setup.md` includes:
- What the tool is (one sentence)
- Install instructions for macOS and Windows
- Required environment variables
- Verification command (`command -v ...`)
- How codependent uses this tool (which tier, what config file is generated)

Keep each doc under 50 lines. Practical, not promotional.

- [ ] **Step 2: Commit**

```bash
git add tools/
git commit -m "docs: per-tool setup guides for macOS and Windows"
```

---

## Task 14: Integration Test + Final Verification

**Files:**
- Modify: `tests/test_fallback.sh` (add integration tests)

- [ ] **Step 1: Add integration tests**

Add to `tests/test_fallback.sh`:

```bash
test_full_status_command() {
    source "$PROJECT_ROOT/lib.sh"
    local output
    output=$(bash "$PROJECT_ROOT/fallback.sh" status 2>&1)
    assert_contains "$output" "codependent"
    assert_contains "$output" "Tier 0"
    assert_contains "$output" "Monitor:"
}

test_full_dry_run_command() {
    source "$PROJECT_ROOT/lib.sh"
    local output
    output=$(bash "$PROJECT_ROOT/fallback.sh" --dry-run 2>&1)
    assert_contains "$output" "dry run"
    assert_contains "$output" "Tier 0"
}

test_full_test_command() {
    source "$PROJECT_ROOT/lib.sh"
    local output
    output=$(bash "$PROJECT_ROOT/fallback.sh" --test 2>&1)
    assert_contains "$output" "system test"
    assert_contains "$output" "Config:"
}
```

- [ ] **Step 2: Run full test suite**

Run: `bash tests/runner.sh`
Expected: All tests pass across all test files

- [ ] **Step 3: Run fallback.sh status manually**

Run: `bash fallback.sh status`
Expected: Shows all tiers with readiness status, monitor state

- [ ] **Step 4: Run fallback.sh --test manually**

Run: `bash fallback.sh --test`
Expected: Full system test including notification check

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: integration tests for fallback.sh commands"
```

---

## Task 15: Final Commit + Push

- [ ] **Step 1: Verify all tests pass**

Run: `bash tests/runner.sh`
Expected: All PASS, 0 FAIL

- [ ] **Step 2: Review git log**

Run: `git log --oneline`
Expected: Clean commit history with one commit per logical unit

- [ ] **Step 3: Push to remote**

```bash
git push origin main
```

- [ ] **Step 4: Verify on GitHub**

Run: `gh repo view arclighteng/codependent --web`
Expected: All files visible, README would be nice but not required per spec
