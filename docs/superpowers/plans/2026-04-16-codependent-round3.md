# Codependent Round 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 8 lightweight additions that make codependent survivable for weeks of
24/7 operation: multi-channel alerts (Slack + generic webhook), jittered
exponential backoff, SQLite corruption recovery, SIGHUP hot-reload, CI matrix,
troubleshooting runbook, architecture diagrams, and `fallback.sh history` CLI.

**Architecture:** Additive only. All new behavior is either in-process helpers
in `lib.sh`, a trap in `monitor.sh`'s main loop, a new subcommand on an existing
script, or new documentation. No new long-running processes. No installer. No
supervisor. Back-compat preserved (`notify_method=both` still means
`terminal,toast`).

**Tech Stack:** Bash 4+ (ubuntu / macos / windows git-bash), curl, sqlite3,
GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-04-16-codependent-round3-design.md`

---

## Orientation — What Already Exists

Before writing any code, read these files end to end. They are the contract this
plan is built against.

- `lib.sh` — core library, ~626 lines. Functions of interest:
  - `load_config` (lines 34-63) — parses `resilience.conf` into `CFG_*` vars
  - `validate_config` (lines 69-127) — validates `CFG_*` against enum/numeric rules
  - `notify` (lines 360-367) — timestamped log append
  - `notify_toast` (lines 369-417), `notify_terminal` (lines 419-421) — channels
  - `notify_dispatch` (lines 423-435) — switches on `CFG_notify_method`
  - `log_metrics` (lines 451-506) — writes to `outage_events` SQLite table
  - `import_csv_to_db` (lines 508-552) — CSV→DB drain after recovery
  - `rotate_log` (lines 556-577) — log rotation with set-e-safe error paths
- `monitor.sh` — daemon, 243 lines. State machine at lines 77-243.
- `fallback.sh` — CLI, 189 lines. Subcommand dispatch at lines 171-188.
- `resilience.conf` — 42 lines of `key=value` config.
- `tests/runner.sh` — test harness. Provides: `assert_eq`, `assert_true`,
  `assert_false`, `assert_contains`, `assert_file_exists`. Test files
  auto-discovered by `test_*.sh` glob.
- `tests/test_notify.sh`, `tests/test_monitor.sh`, `tests/test_state_machine.sh`
  — existing tests. Test files that spawn monitors MUST call `terminate_pid`
  (see `tests/test_monitor.sh`) for cleanup; direct `kill; wait $pid` will hang
  on Windows Git Bash.

## Contracts That Must Not Break

These are the invariants the existing suite enforces. If a task's test changes
one of these, pause and confirm with the human.

1. `notify_method=both` must continue to mean `terminal,toast`
2. `outage_events` SQLite schema (lines 477-487 of lib.sh) is stable — do not
   add/remove/rename columns
3. `notify_dispatch` must stay backward-compatible with **both** its existing
   1-arg form (`notify_dispatch "$message"`) and its 2-arg form
   (`notify_dispatch "$message" "$log_file"`). The `level`/`event` metadata is
   appended as trailing args 3 and 4, so arg 2 remains the log file path.
4. `monitor.sh` must remain a singleton (PID file at `$STATE_DIR/monitor.pid`
   with `noclobber` write)
5. Under `set -e`, never use `((x++))` on a variable that might be zero; always
   `x=$((x + 1))`

## Clarification on Event Taxonomy

The spec references two event systems, and they are intentionally separate:

- **Notification event taxonomy** (`info` / `warning` / `critical`; `startup`,
  `api_down`, `api_degraded`, `api_recovered`, `db_corrupted`, `config_reloaded`)
  — used only in the webhook payload and as a prefix in the Slack payload. Never
  written to the DB.
- **Metrics storage** — unchanged. The existing `outage_events` table keeps
  storing outages; operational events like `config_reloaded` go only to the
  monitor log file and notification channels.

The `fallback.sh history` CLI reads from `outage_events` only. Its columns are
`started_at`, `recovered_at`, `duration_minutes`, `failure_type`, `tier_used`,
`platform` — not the notification taxonomy.

## File Structure Overview

**Modified:**

| File | What changes |
|---|---|
| `lib.sh` | Add `notify_slack`, `notify_webhook`, `parse_notify_channels`, `next_check_interval`, `init_metrics_db`, `check_db_integrity`, `recover_corrupted_db`, `reload_config`. Extend `notify_dispatch` for multi-channel + event metadata. Extend `log_metrics` failure path. Extend `validate_config` for new keys. |
| `monitor.sh` | Add `trap 'reload_config_safe' HUP`, `reload` subcommand, integrate `next_check_interval` in WATCHING + DEGRADED, add `consecutive_network_failures` counter. |
| `fallback.sh` | Add `history` subcommand with arg parser and rendering. |
| `resilience.conf` | Add `notify_slack_url`, `notify_webhook_url`, update `notify_method` comment + enum. |
| `README.md` | One-paragraph callout + link to new docs. |
| `tests/test_notify.sh` | Add multi-channel / Slack / webhook cases. |

**Added:**

| File | Purpose |
|---|---|
| `.github/workflows/ci.yml` | Matrix CI (ubuntu / macos / windows). |
| `docs/troubleshooting.md` | Operator FAQ. |
| `docs/architecture.md` | ASCII diagrams. |
| `tests/test_backoff.sh` | `next_check_interval` coverage. |
| `tests/test_db_recovery.sh` | Integrity check + recreate + CSV fallback. |
| `tests/test_reload.sh` | SIGHUP + `reload` subcommand. |
| `tests/test_history.sh` | `fallback.sh history` parsing + rendering. |

**Untouched:** `generate-configs.sh`, `tiers.conf`, `guardrails.md`, `tools/`,
`state/`.

---

## Task Ordering Rationale

Tasks are ordered so each builds on the previous without forward references.
Dependencies are called out in each task's "Depends on" line.

1. Foundations: helpers with no integration (tasks 1-3)
2. Notifications: taxonomy → channels → dispatch (tasks 4-7)
3. Backoff integration (task 8)
4. DB recovery (tasks 9-11)
5. Hot reload (tasks 12-14)
6. History CLI (tasks 15-17)
7. CI + docs + polish (tasks 18-21)

---

### Task 1: `next_check_interval` helper (no integration yet)

**Files:**
- Modify: `lib.sh` (append new function near existing helpers around line 208)
- Test: `tests/test_backoff.sh` (new)

**Depends on:** none

- [ ] **Step 1: Write the failing tests**

Create `tests/test_backoff.sh`:

```bash
#!/usr/bin/env bash
# tests/test_backoff.sh — unit tests for next_check_interval

source "$PROJECT_ROOT/lib.sh"

test_backoff_floor() {
    # 0 failures → base (no growth), jittered to within ±10%
    local val
    val=$(next_check_interval 30 0)
    if (( val < 27 || val > 33 )); then
        assert_eq "27..33" "$val" "0-failure result should equal base ±10%"
    fi
}

test_backoff_grows() {
    # Monotonic growth (before cap) across failure counts
    local v0 v1 v2
    v0=$(next_check_interval 10 0)
    v1=$(next_check_interval 10 2)   # base * 4 = 40
    v2=$(next_check_interval 10 3)   # base * 8 = 80
    # Allow jitter, so check bounds
    if (( v1 < v0 )); then
        assert_eq "grows" "shrinks" "expected v1 >= v0"
    fi
    if (( v2 < v1 )); then
        assert_eq "grows" "shrinks" "expected v2 >= v1"
    fi
}

test_backoff_caps_at_300() {
    # 10 failures at base=30 → raw = 30 * 1024 = 30720, clamped to 300
    local val
    val=$(next_check_interval 30 10)
    if (( val > 300 )); then
        assert_eq "<=300" "$val" "result must cap at 300"
    fi
    if (( val < 270 )); then
        assert_eq ">=270" "$val" "capped value should still be close to 300 after jitter"
    fi
}

test_backoff_respects_base_above_cap() {
    # base > 300 → floor should still be base (user misconfiguration, but don't go below)
    local val
    val=$(next_check_interval 500 5)
    if (( val < 500 )); then
        assert_eq ">=500" "$val" "result must not fall below configured base"
    fi
}

test_backoff_jitter_within_window() {
    # Run 50 trials at base=100, failures=2 (raw=400, clamped to 300, jitter ±30)
    # All results must be in [270, 330]
    local i val
    for ((i = 0; i < 50; i++)); do
        val=$(next_check_interval 100 2)
        if (( val < 270 || val > 330 )); then
            assert_eq "270..330" "$val" "jitter out of window on trial $i"
            return
        fi
    done
    assert_eq "0" "0" "50 jitter trials all within window"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_backoff.sh`
Expected: All five `test_backoff_*` tests FAIL with "next_check_interval: command not found"

- [ ] **Step 3: Implement `next_check_interval` in `lib.sh`**

Append after the `rotate_log` function (around line 577):

```bash
# --- Adaptive Backoff ---

# next_check_interval BASE FAILURES
# Prints a sleep interval in seconds using jittered exponential growth.
#   raw    = min(300, base * 2^failures)
#   jitter = random int in [-raw/10, +raw/10]
#   out    = max(base, min(300, raw + jitter))
# If base > 300 the floor wins: out = base.
next_check_interval() {
    local base="$1"
    local failures="$2"
    local raw=$base
    local cap=300

    # Exponential growth, clamped BEFORE jitter
    local i
    for ((i = 0; i < failures; i++)); do
        raw=$((raw * 2))
        if ((raw >= cap)); then
            raw=$cap
            break
        fi
    done

    # Jitter window: ±10% of raw. Use $RANDOM (0..32767) mod (2*window+1) − window.
    local window=$((raw / 10))
    local jitter=0
    if ((window > 0)); then
        jitter=$((RANDOM % (2 * window + 1) - window))
    fi

    local out=$((raw + jitter))
    # Clamp to [base, cap]
    if ((out > cap)); then out=$cap; fi
    if ((out < base)); then out=$base; fi
    echo "$out"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/runner.sh test_backoff.sh`
Expected: All five tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_backoff.sh
git commit -m "feat: add next_check_interval helper for jittered exponential backoff"
```

---

### Task 2: Extract `init_metrics_db` from `log_metrics`

**Files:**
- Modify: `lib.sh` (refactor `log_metrics` around lines 451-506)

**Depends on:** none

This is a pure refactor — behavior unchanged. It enables task 10 (corruption
recovery) to reuse the schema without duplicating the heredoc.

- [ ] **Step 1: Write the test to lock in current behavior**

Append to `tests/test_metrics.sh` (file exists):

```bash
test_init_metrics_db_creates_table() {
    local tmpdb
    tmpdb=$(mktemp)
    rm -f "$tmpdb"

    init_metrics_db "$tmpdb"

    # Schema should include outage_events table
    local tables
    tables=$(sqlite3 "$tmpdb" ".tables" 2>/dev/null)
    assert_contains "$tables" "outage_events"

    rm -f "$tmpdb"
}

test_init_metrics_db_idempotent() {
    local tmpdb
    tmpdb=$(mktemp)
    rm -f "$tmpdb"

    init_metrics_db "$tmpdb"
    init_metrics_db "$tmpdb"  # second call must not fail

    assert_eq "0" "$?" "init_metrics_db must be idempotent"
    rm -f "$tmpdb"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_metrics.sh`
Expected: Both new tests FAIL with "init_metrics_db: command not found"

- [ ] **Step 3: Extract `init_metrics_db` and refactor `log_metrics`**

Insert before `log_metrics` in `lib.sh`:

```bash
# init_metrics_db [db_path]
# Creates the outage_events schema. Idempotent.
init_metrics_db() {
    local db="${1:-${CODEPENDENT_DB:-$HOME/.claude/csuite.db}}"
    command -v sqlite3 &>/dev/null || return 1
    sqlite3 "$db" <<'SQL' 2>/dev/null
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
SQL
}
```

Then in `log_metrics`, replace the `sqlite3 "$db" <<SQL … SQL` heredoc (lines
476-490) with:

```bash
        local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"
        init_metrics_db "$db" || true
        if sqlite3 "$db" \
            "INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform) VALUES ('$started_at', '$recovered_at', '$duration_minutes', '$failure_type', '$tier_used', '$tool_used', '$auto_recovered', '$platform');" 2>/dev/null
        then
            import_csv_to_db "$state_dir"
            return 0
        fi
```

- [ ] **Step 4: Run the whole suite to catch regressions**

Run: `bash tests/runner.sh`
Expected: All tests pass (including the existing metrics tests).

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_metrics.sh
git commit -m "refactor: extract init_metrics_db from log_metrics"
```

---

### Task 3: `parse_notify_channels` — comma-split parsing

**Files:**
- Modify: `lib.sh` (new helper near `notify_dispatch`)
- Test: `tests/test_notify.sh` (existing)

**Depends on:** none

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_notify.sh`:

```bash
test_parse_notify_channels_single() {
    local out
    out=$(parse_notify_channels "terminal")
    assert_eq "terminal" "$out" "single channel returns itself"
}

test_parse_notify_channels_comma_list() {
    local out
    out=$(parse_notify_channels "terminal,slack,webhook")
    # Output is newline-delimited
    assert_contains "$out" "terminal"
    assert_contains "$out" "slack"
    assert_contains "$out" "webhook"
}

test_parse_notify_channels_both_backcompat() {
    local out
    out=$(parse_notify_channels "both")
    assert_contains "$out" "terminal"
    assert_contains "$out" "toast"
}

test_parse_notify_channels_trims_whitespace() {
    local out
    out=$(parse_notify_channels " terminal , slack ")
    assert_contains "$out" "terminal"
    assert_contains "$out" "slack"
    # Must NOT contain spaces
    if [[ "$out" == *" "* ]]; then
        assert_eq "no_spaces" "has_spaces" "whitespace must be trimmed"
    fi
}

test_parse_notify_channels_empty() {
    local out
    out=$(parse_notify_channels "")
    assert_eq "" "$out" "empty input returns empty"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_notify.sh`
Expected: Five new tests FAIL with "parse_notify_channels: command not found"

- [ ] **Step 3: Implement `parse_notify_channels` in `lib.sh`**

Insert before `notify_dispatch` (around line 422):

```bash
# parse_notify_channels "comma,separated,list"
# Emits newline-delimited, trimmed channel names.
# Back-compat: "both" expands to "terminal\ntoast".
parse_notify_channels() {
    local raw="$1"
    [[ -z "$raw" ]] && return 0

    local IFS=','
    local ch trimmed
    for ch in $raw; do
        # Trim leading/trailing whitespace
        trimmed="${ch#"${ch%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -z "$trimmed" ]] && continue
        if [[ "$trimmed" == "both" ]]; then
            echo "terminal"
            echo "toast"
        else
            echo "$trimmed"
        fi
    done
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/runner.sh test_notify.sh`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_notify.sh
git commit -m "feat: parse_notify_channels helper for multi-channel notify_method"
```

---

### Task 4: `notify_slack` + `notify_webhook` channel functions

**Files:**
- Modify: `lib.sh` (new functions after `notify_terminal` around line 421)
- Test: `tests/test_notify.sh`

**Depends on:** Task 3

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_notify.sh`:

```bash
# Helper: mock curl to capture invocations
_mock_curl_setup() {
    export _CURL_LOG
    _CURL_LOG=$(mktemp)
    curl() {
        local args=("$@")
        printf '%s\n' "${args[@]}" > "$_CURL_LOG"
        # Read --data payload (the arg after -d)
        local i
        for ((i = 0; i < ${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-d" || "${args[$i]}" == "--data" ]]; then
                echo "${args[$((i + 1))]}" > "${_CURL_LOG}.payload"
            fi
        done
        return 0
    }
    export -f curl
}

_mock_curl_teardown() {
    unset -f curl 2>/dev/null || true
    rm -f "$_CURL_LOG" "${_CURL_LOG}.payload"
    unset _CURL_LOG
}

test_notify_slack_posts_payload() {
    _mock_curl_setup
    notify_slack "https://hooks.slack.com/services/XXX" "critical" "API down"
    local payload
    payload=$(cat "${_CURL_LOG}.payload" 2>/dev/null || echo "")
    assert_contains "$payload" "codependent"
    assert_contains "$payload" "critical"
    assert_contains "$payload" "API down"
    _mock_curl_teardown
}

test_notify_slack_missing_url_warns() {
    _mock_curl_setup
    local out
    out=$(notify_slack "" "info" "hello" 2>&1)
    assert_contains "$out" "empty"
    _mock_curl_teardown
}

test_notify_webhook_posts_json() {
    _mock_curl_setup
    notify_webhook "https://example.com/hook" "warning" "api_degraded" "hello"
    local payload
    payload=$(cat "${_CURL_LOG}.payload" 2>/dev/null || echo "")
    assert_contains "$payload" '"level":"warning"'
    assert_contains "$payload" '"event":"api_degraded"'
    assert_contains "$payload" '"message":"hello"'
    assert_contains "$payload" '"timestamp":'
    _mock_curl_teardown
}

test_notify_webhook_curl_fail_nonfatal() {
    _mock_curl_setup
    curl() { return 7; }
    export -f curl
    local rc=0
    notify_webhook "https://bad.example" "info" "x" "y" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "webhook failures must never crash caller"
    _mock_curl_teardown
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_notify.sh`
Expected: Four new tests FAIL with function-not-found.

- [ ] **Step 3: Implement `notify_slack` and `notify_webhook`**

Append in `lib.sh` after `notify_terminal`:

```bash
# notify_slack URL LEVEL MESSAGE
# Posts `{"text":"codependent [<level>]: <message>"}` to a Slack incoming webhook.
# Failures are logged and swallowed — never fatal.
notify_slack() {
    local url="$1"
    local level="$2"
    local message="$3"

    if [[ -z "$url" ]]; then
        echo "notify_slack: url is empty — skipping" >&2
        return 0
    fi

    # Escape double quotes in message for JSON
    local esc="${message//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    local payload
    payload=$(printf '{"text":"codependent [%s]: %s"}' "$level" "$esc")

    if ! curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$url" >/dev/null 2>&1; then
        echo "notify_slack: POST failed (non-fatal)" >&2
    fi
    return 0
}

# notify_webhook URL LEVEL EVENT MESSAGE
# Posts a structured JSON payload to a generic webhook. Non-fatal.
notify_webhook() {
    local url="$1"
    local level="$2"
    local event="$3"
    local message="$4"

    if [[ -z "$url" ]]; then
        echo "notify_webhook: url is empty — skipping" >&2
        return 0
    fi

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local esc="${message//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    local payload
    payload=$(printf '{"timestamp":"%s","level":"%s","event":"%s","message":"%s"}' \
        "$ts" "$level" "$event" "$esc")

    if ! curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$url" >/dev/null 2>&1; then
        echo "notify_webhook: POST failed (non-fatal)" >&2
    fi
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/runner.sh test_notify.sh`
Expected: All new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_notify.sh
git commit -m "feat: notify_slack and notify_webhook channel functions"
```

---

### Task 5: Extend `notify_dispatch` for multi-channel + event metadata

**Files:**
- Modify: `lib.sh` — replace `notify_dispatch` (lines 423-435)
- Test: `tests/test_notify.sh`

**Depends on:** Tasks 3, 4

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_notify.sh`:

```bash
test_notify_dispatch_multi_channel() {
    _mock_curl_setup
    local test_log; test_log=$(mktemp)

    # Use the notify_method list — the channel selector itself proves toast
    # isn't called (no mocking of notify_toast needed).
    CFG_notify_method="terminal,slack"
    CFG_notify_slack_url="https://example.slack"
    notify_dispatch "test message" "$test_log" "info" "startup"

    # Log always written
    assert_contains "$(cat "$test_log")" "test message"
    # Slack channel must have been called
    local payload
    payload=$(cat "${_CURL_LOG}.payload" 2>/dev/null || echo "")
    assert_contains "$payload" "test message"

    rm -f "$test_log"
    _mock_curl_teardown
}

test_notify_dispatch_backcompat_two_arg() {
    # Existing callers pass notify_dispatch "msg" "$log_file" — must keep working.
    local test_log; test_log=$(mktemp)
    CFG_notify_method="terminal"
    local rc=0
    notify_dispatch "legacy message" "$test_log" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "2-arg form must keep working"
    assert_contains "$(cat "$test_log")" "legacy message"
    rm -f "$test_log"
}

test_notify_dispatch_backcompat_single_arg() {
    CFG_notify_method="terminal"
    local rc=0
    notify_dispatch "legacy message" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "single-arg form must keep working"
}

test_notify_dispatch_unknown_channel_warns() {
    _mock_curl_setup
    local test_log; test_log=$(mktemp)
    CFG_notify_method="terminal,bogus"
    local out
    out=$(notify_dispatch "msg" "$test_log" "info" "startup" 2>&1)
    assert_contains "$out" "bogus"
    rm -f "$test_log"
    _mock_curl_teardown
}

test_notify_dispatch_empty_url_skips() {
    _mock_curl_setup
    local test_log; test_log=$(mktemp)
    CFG_notify_method="slack"
    CFG_notify_slack_url=""
    local out
    out=$(notify_dispatch "msg" "$test_log" "info" "startup" 2>&1)
    assert_contains "$out" "empty"
    rm -f "$test_log"
    _mock_curl_teardown
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_notify.sh`
Expected: New tests FAIL (channels not dispatched).

- [ ] **Step 3: Replace `notify_dispatch`**

Replace the existing `notify_dispatch` (lines 423-435) with:

```bash
# notify_dispatch MESSAGE [LOG_FILE] [LEVEL] [EVENT]
# Logs the message and emits it on every channel listed in CFG_notify_method.
# Arg 2 stays as LOG_FILE for backward compatibility with existing 2-arg
# callers. LEVEL defaults to "info", EVENT defaults to "api_event".
notify_dispatch() {
    local message="$1"
    local log_file="${2:-$CODEPENDENT_ROOT/state/monitor.log}"
    local level="${3:-info}"
    local event="${4:-api_event}"

    # Always log
    notify "$message" "$log_file"

    local channel
    while IFS= read -r channel; do
        [[ -z "$channel" ]] && continue
        case "$channel" in
            terminal) notify_terminal ;;
            toast)    notify_toast "$message" ;;
            slack)
                if [[ -z "${CFG_notify_slack_url:-}" ]]; then
                    echo "notify_dispatch: notify_slack_url is empty — skipping slack channel" >&2
                else
                    notify_slack "$CFG_notify_slack_url" "$level" "$message"
                fi
                ;;
            webhook)
                if [[ -z "${CFG_notify_webhook_url:-}" ]]; then
                    echo "notify_dispatch: notify_webhook_url is empty — skipping webhook channel" >&2
                else
                    notify_webhook "$CFG_notify_webhook_url" "$level" "$event" "$message"
                fi
                ;;
            *)
                echo "notify_dispatch: unknown channel '$channel' — skipping" >&2
                ;;
        esac
    done < <(parse_notify_channels "${CFG_notify_method:-both}")
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh`
Expected: All tests pass. Existing `test_notify.sh` callers (single-arg form)
still work.

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_notify.sh
git commit -m "feat: extend notify_dispatch for multi-channel + level/event metadata"
```

---

### Task 6: Add `notify_slack_url` + `notify_webhook_url` config keys + validator

**Files:**
- Modify: `resilience.conf`
- Modify: `lib.sh` (`validate_config`, lines 69-127)
- Test: `tests/test_config.sh` (existing)

**Depends on:** Task 5

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_config.sh`:

```bash
test_validate_config_accepts_notify_slack_url() {
    CFG_notify_method="terminal,slack"
    CFG_notify_slack_url="https://hooks.slack.com/services/T/B/XYZ"
    CFG_notify_webhook_url=""
    if ! validate_config 2>/dev/null; then
        assert_eq "valid" "invalid" "well-formed slack URL should validate"
    fi
}

test_validate_config_rejects_bad_url() {
    CFG_notify_method="slack"
    CFG_notify_slack_url="not-a-url"
    local rc=0
    validate_config 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "non-URL notify_slack_url must fail validation"
}

test_validate_config_accepts_multi_channel_method() {
    CFG_notify_method="terminal,slack,webhook"
    CFG_notify_slack_url="https://a.example"
    CFG_notify_webhook_url="https://b.example"
    if ! validate_config 2>/dev/null; then
        assert_eq "valid" "invalid" "multi-channel notify_method should validate"
    fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_config.sh`
Expected: Tests FAIL — current `validate_config` only accepts
`terminal|toast|both` for `notify_method`.

- [ ] **Step 3: Update `validate_config` and `resilience.conf`**

In `lib.sh`, replace the `notify_method` enum entry and add URL validators.
Current enum (line 77):

```bash
    [notify_method]="terminal|toast|both"
```

becomes a special-case check (not enum) because it's now a list. Remove
`notify_method` from the `enum_fields` array, and add after the enum loop
(before the numeric block, around line 93):

```bash
    # notify_method: comma-separated list of {terminal, toast, slack, webhook, both}
    local nm_val="${CFG_notify_method:-}"
    if [[ -n "$nm_val" ]]; then
        local ch
        while IFS= read -r ch; do
            [[ -z "$ch" ]] && continue
            if [[ ! "$ch" =~ ^(terminal|toast|slack|webhook)$ ]]; then
                echo "validate_config: invalid channel in notify_method: '${ch}' (allowed: terminal|toast|slack|webhook|both)" >&2
                (( errors++ )) || true
            fi
        done < <(parse_notify_channels "$nm_val")
    fi

    # URL validators: must be http(s)://... when non-empty
    local url_fields=(notify_slack_url notify_webhook_url)
    for field in "${url_fields[@]}"; do
        local varname="CFG_${field}"
        local val="${!varname:-}"
        if [[ -n "$val" && ! "$val" =~ ^https?:// ]]; then
            echo "validate_config: invalid value for ${field}: '${val}' (must start with http:// or https://)" >&2
            (( errors++ )) || true
        fi
    done
```

In `resilience.conf`, update the notification section:

```bash
# Notification — comma-separated list. Channels: terminal, toast, slack, webhook.
# Legacy: "both" = "terminal,toast"
notify_method=both

# Slack incoming webhook URL (used when "slack" is in notify_method)
notify_slack_url=

# Generic JSON webhook URL (used when "webhook" is in notify_method)
# Payload: {timestamp, level, event, message}
notify_webhook_url=
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib.sh resilience.conf tests/test_config.sh
git commit -m "feat: config keys and validation for slack/webhook URLs + multi-channel method"
```

---

### Task 7: Integrate `next_check_interval` into monitor.sh DEGRADED state

**Files:**
- Modify: `monitor.sh` (lines 171-200)

**Depends on:** Task 1

- [ ] **Step 1: Write the integration test**

Append to `tests/test_state_machine.sh`:

```bash
test_sm_degraded_uses_jittered_backoff() {
    setup_sm_env
    # Override check_interval for fast test
    sed -i 's/^check_interval=.*/check_interval=1/' "$SM_CONF" 2>/dev/null || true
    start_mock_monitor

    # Stay in DEGRADED long enough to see at least two backoff steps
    echo "degraded" > "$SM_MOCK_HEALTH_FILE"

    if ! wait_for_log "API degraded"; then
        assert_eq "degraded" "timeout" "should enter DEGRADED"
    fi

    # Check log for evidence of varying intervals — at least the state persists
    # through multiple iterations. We can't easily assert the exact jitter,
    # but we can confirm the daemon doesn't crash during repeated backoff.
    sleep 3
    local log_content
    log_content=$(cat "$SM_STATE_DIR/monitor.log")
    assert_contains "$log_content" "degraded"

    teardown_sm_env
}
```

- [ ] **Step 2: Run to verify it passes with existing behavior**

Run: `bash tests/runner.sh test_state_machine.sh`
Expected: Test passes — it only verifies the daemon stays alive. This is a
smoke check; unit coverage of `next_check_interval` lives in task 1.

- [ ] **Step 3: Replace the DEGRADED backoff block**

In `monitor.sh`, replace lines 195-198 (the existing backoff block):

```bash
                # Exponential backoff
                CURRENT_INTERVAL=$((CURRENT_INTERVAL * 2))
                max_interval=300
                ((CURRENT_INTERVAL > max_interval)) && CURRENT_INTERVAL=$max_interval
```

with:

```bash
                # Jittered exponential backoff with 300s cap.
                # Compute from base, using observed degraded_duration / base as failure count.
                base="${CFG_check_interval:-30}"
                deg_failures=$(( degraded_duration / base ))
                (( deg_failures < 0 )) && deg_failures=0
                CURRENT_INTERVAL=$(next_check_interval "$base" "$deg_failures")
```

Also add a `consecutive_network_failures=0` initializer next to the other
state-machine initializers (`DAEMON_STATE`, `OUTAGE_STARTED`,
`DEGRADED_STARTED`, `CURRENT_INTERVAL`, around lines 78-82):

```bash
consecutive_network_failures=0
```

And in the WATCHING state (just after `status_indicator=$(check_status_page)`,
around line 107), track the counter:

```bash
    # Track network-failure streak for adaptive backoff in WATCHING
    if [[ "$network_status" == "down" ]]; then
        consecutive_network_failures=$((consecutive_network_failures + 1))
        CURRENT_INTERVAL=$(next_check_interval "${CFG_check_interval:-30}" "$consecutive_network_failures")
    else
        consecutive_network_failures=0
        CURRENT_INTERVAL="${CFG_check_interval:-30}"
    fi
```

Place this block after the `status_indicator` assignment (around line 107) and
before `health=$(classify_health ...)` so the next loop iteration sleeps for
the adjusted interval.

- [ ] **Step 4: Run full suite**

Run: `bash tests/runner.sh`
Expected: All tests pass. State machine tests in particular must be green.

- [ ] **Step 5: Commit**

```bash
git add monitor.sh tests/test_state_machine.sh
git commit -m "feat: integrate jittered backoff in monitor.sh WATCHING+DEGRADED states"
```

---

### Task 8: `check_db_integrity` + `recover_corrupted_db` helpers

**Files:**
- Modify: `lib.sh` (new helpers near `log_metrics`)
- Test: `tests/test_db_recovery.sh` (new)

**Depends on:** Task 2

- [ ] **Step 1: Write the failing tests**

Create `tests/test_db_recovery.sh`:

```bash
#!/usr/bin/env bash
# tests/test_db_recovery.sh — SQLite integrity + recovery

source "$PROJECT_ROOT/lib.sh"

_setup_corrupt_db() {
    local db="$1"
    # Write garbage — definitely not a SQLite file
    echo "not a database, just bytes" > "$db"
}

test_check_db_integrity_ok_on_fresh() {
    local db
    db=$(mktemp); rm -f "$db"
    init_metrics_db "$db"

    local result
    result=$(check_db_integrity "$db")
    assert_eq "ok" "$result" "fresh DB must be ok"

    rm -f "$db"
}

test_check_db_integrity_detects_corruption() {
    local db
    db=$(mktemp); rm -f "$db"
    _setup_corrupt_db "$db"

    local result
    result=$(check_db_integrity "$db")
    if [[ "$result" == "ok" ]]; then
        assert_eq "corrupted" "$result" "garbage file must not report ok"
    fi

    rm -f "$db"
}

test_recover_corrupted_db_renames_and_recreates() {
    local db
    db=$(mktemp); rm -f "$db"
    _setup_corrupt_db "$db"

    recover_corrupted_db "$db"

    # Old file moved to .corrupted-*
    local renamed
    renamed=$(ls "${db}.corrupted-"* 2>/dev/null | head -1)
    assert_file_exists "$renamed"

    # New DB exists with schema
    assert_file_exists "$db"
    local tables
    tables=$(sqlite3 "$db" ".tables" 2>/dev/null)
    assert_contains "$tables" "outage_events"

    rm -f "$db" "${db}.corrupted-"*
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_db_recovery.sh`
Expected: Tests FAIL — functions not defined.

- [ ] **Step 3: Implement helpers in `lib.sh`**

Insert between `init_metrics_db` and `log_metrics`:

```bash
# check_db_integrity [db_path]
# Prints "ok" if PRAGMA integrity_check returns ok, otherwise prints "corrupted".
# Returns 0 when ok, 1 when corrupted.
check_db_integrity() {
    local db="${1:-${CODEPENDENT_DB:-$HOME/.claude/csuite.db}}"
    [[ -f "$db" ]] || { echo "ok"; return 0; }  # missing = will be recreated, not corrupt
    command -v sqlite3 &>/dev/null || { echo "ok"; return 0; }  # can't check = assume ok

    local result
    result=$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>/dev/null || echo "corrupted")
    if [[ "$result" == "ok" ]]; then
        echo "ok"
        return 0
    fi
    echo "corrupted"
    return 1
}

# recover_corrupted_db [db_path]
# Renames the corrupted DB to <path>.corrupted-<epoch> and recreates the schema.
# Fires a critical notification. Returns 0 on success, 1 if recreation also fails.
recover_corrupted_db() {
    local db="${1:-${CODEPENDENT_DB:-$HOME/.claude/csuite.db}}"
    local ts
    ts=$(date +%s)

    if [[ -f "$db" ]]; then
        mv "$db" "${db}.corrupted-${ts}" 2>/dev/null || true
    fi

    if ! init_metrics_db "$db"; then
        echo "recover_corrupted_db: failed to recreate $db" >&2
        return 1
    fi

    # Best-effort alert. notify_dispatch may not be configured in all contexts.
    # Args: message, log_file (default), level, event
    if declare -F notify_dispatch >/dev/null 2>&1; then
        notify_dispatch "Metrics DB corrupted — recreated. Old file: ${db}.corrupted-${ts}" \
            "" "critical" "db_corrupted" 2>/dev/null || true
    fi
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/runner.sh test_db_recovery.sh`
Expected: All three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_db_recovery.sh
git commit -m "feat: check_db_integrity and recover_corrupted_db helpers"
```

---

### Task 9: Wire corruption recovery into `log_metrics` failure path

**Files:**
- Modify: `lib.sh` (`log_metrics` function)
- Test: `tests/test_db_recovery.sh`

**Depends on:** Task 8

- [ ] **Step 1: Write the failing test**

Append to `tests/test_db_recovery.sh`:

```bash
test_log_metrics_recovers_corrupt_db() {
    local db
    db=$(mktemp); rm -f "$db"
    _setup_corrupt_db "$db"

    local state_dir
    state_dir=$(mktemp -d)

    CODEPENDENT_DB="$db"
    CFG_log_to_metrics="true"
    export CODEPENDENT_DB CFG_log_to_metrics

    # This should detect corruption, recover, and retry the insert
    log_metrics "2026-04-16T12:00:00" "2026-04-16T12:05:00" "5" "outage" "1" "codex" "true" "linux" "$state_dir"

    # After log_metrics, the DB should be valid and have the row
    local count
    count=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events;" 2>/dev/null || echo "0")
    assert_eq "1" "$count" "row should be present in recovered DB"

    rm -rf "$state_dir"
    rm -f "$db" "${db}.corrupted-"*
    unset CODEPENDENT_DB
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/runner.sh test_db_recovery.sh`
Expected: New test FAILS — corrupt DB isn't recovered automatically yet.

- [ ] **Step 3: Modify `log_metrics` failure path**

Replace the `if sqlite3 ... INSERT ...; then ... return 0; fi` block (roughly
lines 476-495 after Task 2's refactor) with:

```bash
        local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"
        init_metrics_db "$db" || true

        local insert_sql="INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform) VALUES ('$started_at', '$recovered_at', '$duration_minutes', '$failure_type', '$tier_used', '$tool_used', '$auto_recovered', '$platform');"

        if sqlite3 "$db" "$insert_sql" 2>/dev/null; then
            import_csv_to_db "$state_dir"
            return 0
        fi

        # INSERT failed — check for corruption, attempt recovery
        if [[ "$(check_db_integrity "$db")" != "ok" ]]; then
            if recover_corrupted_db "$db"; then
                # Non-recursive retry — plain INSERT, no second recovery loop
                if sqlite3 "$db" "$insert_sql" 2>/dev/null; then
                    return 0
                fi
            fi
        fi
```

The CSV fallback block below (existing lines 498-506) is unchanged — it runs
when both the original and the recovery retry fail.

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh`
Expected: All tests pass, including the new recovery-path test.

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_db_recovery.sh
git commit -m "feat: log_metrics auto-recovers corrupt SQLite DB before CSV fallback"
```

---

### Task 10: `reload_config` function (in-process SIGHUP handler)

**Files:**
- Modify: `lib.sh` (new function near `load_config`)
- Test: `tests/test_reload.sh` (new)

**Depends on:** Task 6

- [ ] **Step 1: Write the failing tests**

Create `tests/test_reload.sh`:

```bash
#!/usr/bin/env bash
# tests/test_reload.sh — reload_config behavior

source "$PROJECT_ROOT/lib.sh"

_make_conf() {
    local f; f=$(mktemp)
    cat > "$f" <<'CONF'
check_interval=30
health_check=status_page
recovery_successes=10
recovery_window=12
failure_window=4
degraded_threshold=600
on_recovery=notify
on_failure=notify
notify_method=both
max_log_size=1048576
network_check_url=https://1.1.1.1
CONF
    echo "$f"
}

test_reload_config_swaps_valid_values() {
    local conf; conf=$(_make_conf)
    load_config "$conf"
    local old_interval="${CFG_check_interval}"

    # Mutate config file
    sed -i 's/^check_interval=.*/check_interval=45/' "$conf" 2>/dev/null || \
        (tmp=$(mktemp); sed 's/^check_interval=.*/check_interval=45/' "$conf" > "$tmp"; mv "$tmp" "$conf")

    reload_config "$conf"
    assert_eq "45" "${CFG_check_interval}" "reload must update CFG_check_interval"
    rm -f "$conf"
}

test_reload_config_rejects_invalid() {
    local conf; conf=$(_make_conf)
    load_config "$conf"
    local old="${CFG_check_interval}"

    # Write invalid value
    sed -i 's/^check_interval=.*/check_interval=not-a-number/' "$conf" 2>/dev/null || \
        (tmp=$(mktemp); sed 's/^check_interval=.*/check_interval=not-a-number/' "$conf" > "$tmp"; mv "$tmp" "$conf")

    reload_config "$conf" 2>/dev/null || true
    assert_eq "$old" "${CFG_check_interval}" "invalid reload must keep old value"
    rm -f "$conf"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_reload.sh`
Expected: Tests FAIL — `reload_config` not defined.

- [ ] **Step 3: Implement `reload_config` in `lib.sh`**

Insert after `validate_config` (around line 127):

```bash
# reload_config [path]
# Re-reads the config file and applies it if validation passes.
# On failure, keeps the current CFG_* values untouched and logs a warning.
reload_config() {
    local config_file="${1:-$CODEPENDENT_ROOT/resilience.conf}"

    # Snapshot current CFG_* vars so we can restore on validation failure
    local -a snap_names=()
    local -a snap_values=()
    local v
    for v in $(compgen -v CFG_); do
        snap_names+=("$v")
        snap_values+=("${!v}")
    done

    if ! load_config "$config_file" 2>/dev/null; then
        echo "reload_config: failed to read $config_file — keeping current config" >&2
        return 1
    fi

    if ! validate_config 2>/dev/null; then
        # Restore snapshot
        local i
        for ((i = 0; i < ${#snap_names[@]}; i++)); do
            printf -v "${snap_names[$i]}" '%s' "${snap_values[$i]}"
        done
        echo "reload_config: validation failed — reverted to prior config" >&2
        return 1
    fi

    return 0
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_reload.sh`
Expected: Both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib.sh tests/test_reload.sh
git commit -m "feat: reload_config with snapshot/restore on validation failure"
```

---

### Task 11: SIGHUP trap in `monitor.sh` main loop

**Files:**
- Modify: `monitor.sh`
- Test: `tests/test_reload.sh`

**Depends on:** Task 10

- [ ] **Step 1: Write the failing integration test**

Append to `tests/test_reload.sh`:

```bash
# This test requires a running monitor — uses the same mock harness as
# test_state_machine.sh. For simplicity, we invoke a minimal subshell with
# the trap installed.

test_sighup_triggers_reload() {
    local conf; conf=$(_make_conf)
    local marker; marker=$(mktemp)

    # Background script that sources lib.sh, installs trap, and writes a marker
    # to the file when SIGHUP is received.
    (
        source "$PROJECT_ROOT/lib.sh"
        load_config "$conf"
        trap 'reload_config "'"$conf"'" >/dev/null 2>&1; echo reloaded >> "'"$marker"'"' HUP
        # Sleep long enough to receive a signal
        for _ in {1..20}; do sleep 0.2; done
    ) &
    local pid=$!

    # Give it a moment to install the trap
    sleep 0.5

    # Update config and send SIGHUP
    sed -i 's/^check_interval=.*/check_interval=77/' "$conf" 2>/dev/null || \
        (tmp=$(mktemp); sed 's/^check_interval=.*/check_interval=77/' "$conf" > "$tmp"; mv "$tmp" "$conf")
    kill -HUP "$pid" 2>/dev/null || true

    # Wait for marker
    for _ in {1..25}; do
        [[ -s "$marker" ]] && break
        sleep 0.2
    done

    assert_contains "$(cat "$marker" 2>/dev/null)" "reloaded"

    kill "$pid" 2>/dev/null || true
    rm -f "$conf" "$marker"
}
```

- [ ] **Step 2: Run to verify it passes standalone**

Run: `bash tests/runner.sh test_reload.sh`
Expected: PASS — the trap is installed inside the subshell directly. This test
does not depend on monitor.sh changes yet.

- [ ] **Step 3: Install the trap in monitor.sh**

In `monitor.sh`, just before the `while true;` loop (around line 88), add:

```bash
# Hot config reload on SIGHUP.
# Keep the handler short; reload_config restores on failure.
_on_hup() {
    # notify_dispatch args: message, log_file, level, event
    if reload_config "$CONFIG_FILE"; then
        notify_dispatch "Config reloaded" "$LOG_FILE" "info" "config_reloaded"
    else
        notify_dispatch "Config reload failed — keeping prior config" "$LOG_FILE" "warning" "config_reloaded"
    fi
}
trap '_on_hup' HUP
```

- [ ] **Step 4: Run full suite**

Run: `bash tests/runner.sh`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add monitor.sh
git commit -m "feat: monitor.sh SIGHUP handler calls reload_config"
```

---

### Task 12: `monitor.sh reload` subcommand

**Files:**
- Modify: `monitor.sh` (subcommand dispatch, around lines 14-47)
- Test: `tests/test_reload.sh`

**Depends on:** Task 11

- [ ] **Step 1: Write the failing test**

Append to `tests/test_reload.sh`:

```bash
test_reload_subcommand_sends_sighup() {
    local state_dir; state_dir=$(mktemp -d)
    local conf; conf=$(_make_conf)

    # Background process that traps HUP and sets a marker
    local marker; marker=$(mktemp)
    (
        trap 'echo got-hup > "'"$marker"'"; exit 0' HUP
        echo $$ > "$state_dir/monitor.pid"
        for _ in {1..40}; do sleep 0.2; done
    ) &
    local pid=$!

    # Wait for the child to write its PID
    for _ in {1..10}; do
        [[ -f "$state_dir/monitor.pid" ]] && break
        sleep 0.1
    done

    # Invoke reload subcommand
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$state_dir" reload >/dev/null 2>&1 || true

    # Wait for marker
    for _ in {1..20}; do
        [[ -s "$marker" ]] && break
        sleep 0.2
    done

    assert_contains "$(cat "$marker" 2>/dev/null)" "got-hup"

    kill "$pid" 2>/dev/null || true
    rm -rf "$state_dir"
    rm -f "$conf" "$marker"
}

test_reload_subcommand_exits_1_when_no_monitor() {
    local state_dir; state_dir=$(mktemp -d)
    local rc=0
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$state_dir" reload >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "reload with no monitor running must exit 1"
    rm -rf "$state_dir"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/runner.sh test_reload.sh`
Expected: Both tests FAIL — `reload` is an unknown argument.

- [ ] **Step 3: Add the `reload` subcommand in `monitor.sh`**

In the arg-parsing `case` (around line 14-46), add a new `reload)` branch
alongside `stop)`:

```bash
        reload)
            if [[ -f "$STATE_DIR/monitor.pid" ]]; then
                pid=$(cat "$STATE_DIR/monitor.pid")
                if kill -0 "$pid" 2>/dev/null; then
                    if kill -HUP "$pid" 2>/dev/null; then
                        echo "SIGHUP sent to monitor (PID $pid)"
                        exit 0
                    fi
                fi
            fi
            echo "monitor not running" >&2
            exit 1
            ;;
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add monitor.sh tests/test_reload.sh
git commit -m "feat: monitor.sh reload subcommand sends SIGHUP to running daemon"
```

---

### Task 13: `fallback.sh history` — argument parser

**Files:**
- Modify: `fallback.sh`
- Test: `tests/test_history.sh` (new)

**Depends on:** none (uses existing `outage_events` schema)

- [ ] **Step 1: Write the failing tests**

Create `tests/test_history.sh`:

```bash
#!/usr/bin/env bash
# tests/test_history.sh — fallback.sh history subcommand

source "$PROJECT_ROOT/lib.sh"

test_history_rejects_bad_limit() {
    local rc=0
    local out
    out=$(bash "$PROJECT_ROOT/fallback.sh" history --limit abc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-integer --limit must exit 1"
    assert_contains "$out" "limit"
}

test_history_rejects_zero_limit() {
    local rc=0
    bash "$PROJECT_ROOT/fallback.sh" history --limit 0 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "--limit 0 must exit 1"
}

test_history_rejects_bad_since() {
    local rc=0
    bash "$PROJECT_ROOT/fallback.sh" history --since "not-a-date" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "malformed --since must exit 1"
}

test_history_accepts_valid_flags() {
    local rc=0
    # Will likely print "no history yet" if DB empty, but should exit 0
    bash "$PROJECT_ROOT/fallback.sh" history --limit 10 --since 2026-01-01 >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "valid flags should not error"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/runner.sh test_history.sh`
Expected: Tests FAIL — `history` is not a subcommand yet.

- [ ] **Step 3: Add the subcommand + arg parser in `fallback.sh`**

In the main case (`"${1:-}"` dispatch around line 171-188), add:

```bash
        history)
            shift
            show_history "$@"
            ;;
```

Then add the `show_history` function (near `show_status`, around line 12):

```bash
show_history() {
    local limit=20
    local since=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                shift
                if [[ ! "${1:-}" =~ ^[1-9][0-9]*$ ]] || (( ${1:-0} > 1000 )); then
                    echo "history: --limit must be a positive integer (1..1000)" >&2
                    exit 1
                fi
                limit="$1"; shift
                ;;
            --since)
                shift
                if [[ ! "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                    echo "history: --since must match YYYY-MM-DD" >&2
                    exit 1
                fi
                since="$1"; shift
                ;;
            *)
                echo "history: unknown flag: $1" >&2
                echo "usage: fallback.sh history [--limit N] [--since YYYY-MM-DD]" >&2
                exit 1
                ;;
        esac
    done

    _render_history "$limit" "$since"
}

# Stub so parser tests pass; real rendering lands in the next task
_render_history() {
    local limit="$1"
    local since="$2"
    echo "codependent — fallback history"
    echo ""
    echo "(history rendering not yet implemented)"
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_history.sh`
Expected: All four parser tests PASS.

- [ ] **Step 5: Commit**

```bash
git add fallback.sh tests/test_history.sh
git commit -m "feat: fallback.sh history subcommand with flag validation"
```

---

### Task 14: `fallback.sh history` — rendering (header + table + graceful degradation)

**Files:**
- Modify: `fallback.sh` (`_render_history`)
- Test: `tests/test_history.sh`

**Depends on:** Tasks 2, 13

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_history.sh`:

```bash
test_history_empty_db() {
    local db; db=$(mktemp); rm -f "$db"
    init_metrics_db "$db"
    CODEPENDENT_DB="$db" bash "$PROJECT_ROOT/fallback.sh" history > /tmp/h.out 2>&1
    local out
    out=$(cat /tmp/h.out)
    assert_contains "$out" "No history yet"
    rm -f "$db" /tmp/h.out
}

test_history_renders_rows() {
    local db; db=$(mktemp); rm -f "$db"
    init_metrics_db "$db"
    sqlite3 "$db" "INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform) VALUES ('2026-04-16T12:00:00','2026-04-16T12:05:00',5,'outage','1','codex','true','linux');"
    sqlite3 "$db" "INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform) VALUES ('2026-04-16T13:00:00','2026-04-16T13:02:00',2,'outage','1','codex','true','linux');"

    local out
    out=$(CODEPENDENT_DB="$db" bash "$PROJECT_ROOT/fallback.sh" history 2>&1)
    assert_contains "$out" "STARTED"
    assert_contains "$out" "2026-04-16T12:00:00"
    assert_contains "$out" "2026-04-16T13:00:00"
    assert_contains "$out" "failovers"

    rm -f "$db"
}

test_history_missing_sqlite3_hint() {
    # If sqlite3 isn't installed on this box, skip; otherwise simulate via PATH.
    if command -v sqlite3 &>/dev/null; then
        # Hide sqlite3 via a PATH override to /dev/null-style dir
        local empty; empty=$(mktemp -d)
        local out
        out=$(PATH="$empty" bash "$PROJECT_ROOT/fallback.sh" history 2>&1)
        assert_contains "$out" "sqlite3"
        rm -rf "$empty"
    fi
}

test_history_missing_db_hint() {
    local db="/tmp/definitely-does-not-exist-$$.db"
    local out
    out=$(CODEPENDENT_DB="$db" bash "$PROJECT_ROOT/fallback.sh" history 2>&1)
    assert_contains "$out" "No history"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/runner.sh test_history.sh`
Expected: New tests FAIL — stub prints "not yet implemented".

- [ ] **Step 3: Replace `_render_history` with the full implementation**

Replace the stub:

```bash
_render_history() {
    # SECURITY NOTE: $since is interpolated into SQL strings below. The arg
    # parser (show_history) rejects anything that doesn't match
    # ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ so the only bytes that reach this function
    # are ASCII digits and two hyphens. This regex is the full boundary; do
    # not relax it without re-reviewing the SQL builders.
    local limit="$1"
    local since="$2"
    local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"

    echo "codependent — fallback history"
    echo ""

    # Graceful degradation: missing sqlite3
    if ! command -v sqlite3 &>/dev/null; then
        echo "sqlite3 not found — install it to enable history."
        return 0
    fi

    # Graceful degradation: missing or empty DB
    if [[ ! -f "$db" ]]; then
        echo "No history yet — daemon hasn't recorded any events."
        return 0
    fi

    local total
    total=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events;" 2>/dev/null || echo 0)
    if [[ "$total" == "0" || -z "$total" ]]; then
        echo "No history yet — daemon hasn't recorded any events."
        return 0
    fi

    # Summary
    local where=""
    [[ -n "$since" ]] && where="WHERE started_at >= '${since}T00:00:00'"

    local failovers recoveries first_ts now_epoch first_epoch total_secs outage_secs uptime_pct
    failovers=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events $where;" 2>/dev/null || echo 0)
    recoveries=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events $where AND recovered_at IS NOT NULL AND recovered_at != '';" 2>/dev/null || echo 0)
    # Strip "AND" prefix hack if $where was empty: recoveries query needs its own where
    if [[ -z "$where" ]]; then
        recoveries=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events WHERE recovered_at IS NOT NULL AND recovered_at != '';" 2>/dev/null || echo 0)
    fi

    first_ts=$(sqlite3 "$db" "SELECT MIN(started_at) FROM outage_events $where;" 2>/dev/null || echo "")

    # Uptime: 1 - (sum of outage_seconds / total_seconds). Needs ≥2 data points.
    local uptime_str="n/a (insufficient data)"
    if [[ -n "$first_ts" && "$total" -ge 2 ]]; then
        first_epoch=$(date_to_epoch "$first_ts" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        total_secs=$((now_epoch - first_epoch))
        outage_secs=$(sqlite3 "$db" "SELECT COALESCE(SUM(duration_minutes * 60), 0) FROM outage_events $where AND recovered_at IS NOT NULL;" 2>/dev/null || echo 0)
        if [[ -z "$where" ]]; then
            outage_secs=$(sqlite3 "$db" "SELECT COALESCE(SUM(duration_minutes * 60), 0) FROM outage_events WHERE recovered_at IS NOT NULL;" 2>/dev/null || echo 0)
        fi
        if (( total_secs > 0 )); then
            # Percentage with 1 decimal. Use awk for float math (bash has none).
            uptime_str=$(awk -v o="$outage_secs" -v t="$total_secs" 'BEGIN { printf "%.1f%%", (1 - o/t) * 100 }')
        fi
    fi

    local since_label="${since:-all time}"
    echo "Summary (last $limit events, since: $since_label):"
    printf "  failovers:  %s\n" "$failovers"
    printf "  recoveries: %s\n" "$recoveries"
    printf "  uptime:     %s\n" "$uptime_str"
    echo ""

    # Table
    local header="STARTED|RECOVERED|DURATION|TYPE|TIER|PLATFORM"
    local rows
    if [[ -n "$since" ]]; then
        rows=$(sqlite3 -separator '|' "$db" "SELECT started_at, COALESCE(recovered_at,'-'), COALESCE(printf('%.1fm', duration_minutes),'-'), failure_type, tier_used, platform FROM outage_events WHERE started_at >= '${since}T00:00:00' ORDER BY started_at DESC LIMIT $limit;" 2>/dev/null)
    else
        rows=$(sqlite3 -separator '|' "$db" "SELECT started_at, COALESCE(recovered_at,'-'), COALESCE(printf('%.1fm', duration_minutes),'-'), failure_type, tier_used, platform FROM outage_events ORDER BY started_at DESC LIMIT $limit;" 2>/dev/null)
    fi

    { echo "$header"; echo "$rows"; } | column -t -s '|'
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/runner.sh test_history.sh`
Expected: All history tests PASS.

- [ ] **Step 5: Commit**

```bash
git add fallback.sh tests/test_history.sh
git commit -m "feat: fallback.sh history renders summary + table with graceful degradation"
```

---

### Task 15: GitHub Actions CI matrix

**Files:**
- Create: `.github/workflows/ci.yml`

**Depends on:** none

- [ ] **Step 1: Verify directory**

Run: `ls .github/workflows/ 2>/dev/null || mkdir -p .github/workflows`
Expected: the directory exists (empty is fine).

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4

      - name: Install sqlite3 (linux)
        if: runner.os == 'Linux'
        run: sudo apt-get update && sudo apt-get install -y sqlite3

      - name: Install sqlite3 (macos)
        if: runner.os == 'macOS'
        run: brew list sqlite3 >/dev/null 2>&1 || brew install sqlite

      - name: Verify sqlite3 available
        run: sqlite3 -version

      - name: Run tests
        run: bash tests/runner.sh
```

- [ ] **Step 3: Validate locally**

Run: `bash tests/runner.sh`
Expected: Everything passes on this machine — CI will repeat on three OSes.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: matrix workflow across ubuntu/macos/windows"
```

- [ ] **Step 5: Push and confirm**

```bash
git push origin main
```

After pushing, watch the CI run. If any matrix leg fails, treat the failure as
a separate bug and fix reactively in a follow-up commit (per spec §4.5: "Any
gap found while green-ing the matrix is fixed reactively").

---

### Task 16: Troubleshooting runbook

**Files:**
- Create: `docs/troubleshooting.md`

**Depends on:** none

- [ ] **Step 1: Write the file**

```markdown
# codependent — Troubleshooting

Operator runbook for the top failure modes. Each entry: symptom → cause →
diagnosis → fix.

## Monitor won't start — "Monitor already running"

**Symptom:** `monitor.sh` exits immediately with `"Monitor already running
(PID <N>)"` but no process with that PID exists.

**Cause:** Stale PID file from a crash or SIGKILL.

**Diagnose:**
```bash
cat state/monitor.pid          # print stored PID
kill -0 $(cat state/monitor.pid) 2>&1 || echo "stale"
```

**Fix:**
```bash
rm state/monitor.pid
bash monitor.sh &
```

## `monitor.sh stop` appears to hang

**Symptom:** `monitor.sh stop` sits for several seconds before returning.

**Cause:** The daemon is inside a `sleep`; on Windows Git Bash signals are
deferred until sleep ends. This is expected for up to 10 seconds before the
SIGKILL fallback fires.

**Diagnose:** Wait 10 seconds. If it still hasn't returned, there's a bug —
open an issue.

**Fix:** None needed — the stop command escalates to SIGKILL automatically.

## Status shows "outage" but Anthropic is up

**Symptom:** `fallback.sh status` reports an active outage; `curl
https://status.anthropic.com/api/v2/status.json` works fine.

**Cause:** `network_check_url` (default `https://1.1.1.1`) is blocked by a
corporate proxy or firewall. The daemon classifies this as `network_down` →
`outage`.

**Diagnose:**
```bash
curl -sf --max-time 5 "$(grep '^network_check_url' resilience.conf | cut -d= -f2)"
```

**Fix:** Edit `resilience.conf`, set `network_check_url` to an internal
reachable endpoint (e.g. your corporate gateway), then hot-reload:
```bash
bash monitor.sh reload
```

## Slack alerts not arriving

**Symptom:** `notify_method=slack` is set, outages fire, but Slack channel is
silent.

**Diagnose:**
```bash
# Test the webhook directly
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"text":"codependent test"}' "$(grep '^notify_slack_url' resilience.conf | cut -d= -f2)"
```

**Common causes and fixes:**
- Webhook URL typo or revoked → regenerate in Slack, update `resilience.conf`,
  run `monitor.sh reload`
- Slack rate-limiting → reduce alert volume; the daemon already rate-limits via
  state-machine transitions, but repeated restarts can spam
- Corporate egress filter blocking `hooks.slack.com` → consult your network
  team; the generic `notify_webhook_url` against an internal receiver is an
  alternative

## Metrics DB missing or corrupted

**Symptom:** `fallback.sh history` says `"No history yet"` despite outages
having happened. Or monitor.log contains `"Metrics DB corrupted — recreated"`.

**Diagnose:**
```bash
ls -la ~/.claude/csuite.db*
sqlite3 ~/.claude/csuite.db 'PRAGMA integrity_check;'
```

**Fix:**
- If the DB is missing, nothing to do — the daemon will recreate it on the
  next metric write
- If corrupted, the daemon auto-renames to `csuite.db.corrupted-<epoch>` and
  recreates. Old data is preserved in the `.corrupted-*` file; open it
  read-only with `sqlite3` to recover specific rows if needed

## "Too many open files"

**Symptom:** Errors in `monitor.log` about file handles, or daemon silently
stops.

**Cause:** Log rotation failing to release the old file handle (rare).

**Diagnose:**
```bash
ls -la state/monitor.log*
ulimit -n
```

**Fix:**
```bash
bash monitor.sh stop
rm state/monitor.log.1 2>/dev/null || true
bash monitor.sh &
```

## CI matrix fails on Windows only

**Symptom:** `ubuntu-latest` and `macos-latest` are green, `windows-latest`
fails.

**Likely causes:**
- CRLF vs LF line endings in a test fixture (check `.gitattributes`)
- Path separator — most often `mktemp` on Windows returns a path like
  `/c/Users/.../Temp/...` that some tools don't accept
- A test uses `kill; wait $pid` instead of `terminate_pid` — `wait` can block
  indefinitely under Git Bash when the child is in `sleep`

**Fix:** Reproduce locally in Git Bash, then correct the offending test. Use
`terminate_pid` (defined in `tests/test_monitor.sh`) for any background
process.
```

- [ ] **Step 2: Commit**

```bash
git add docs/troubleshooting.md
git commit -m "docs: troubleshooting runbook covering top failure modes"
```

---

### Task 17: Architecture diagrams

**Files:**
- Create: `docs/architecture.md`

**Depends on:** none

- [ ] **Step 1: Write the file**

Use the three diagrams from the spec. Render exactly as shown:

````markdown
# codependent — Architecture

Three ASCII diagrams describing the moving parts. ASCII so they render the
same in GitHub, `cat`, `less`, and VS Code preview.

## 1. Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   ┌──────────────┐       ┌──────────────┐       ┌──────────────────┐    │
│   │ resilience   │──────▶│   lib.sh     │◀──────│   tiers.conf     │    │
│   │ .conf        │       │  (shared)    │       └──────────────────┘    │
│   └──────────────┘       └──────┬───────┘                               │
│                                 │                                       │
│       ┌─────────────────────────┼─────────────────────────┐             │
│       ▼                         ▼                         ▼             │
│  ┌─────────────┐          ┌──────────────┐        ┌──────────────┐      │
│  │ monitor.sh  │          │ fallback.sh  │        │ generate-    │      │
│  │  (daemon)   │          │   (CLI)      │        │ configs.sh   │      │
│  └──────┬──────┘          └──────────────┘        └──────────────┘      │
│         │                                                               │
│         ▼                                                               │
│   ┌────────────┐                                                        │
│   │ state/     │   monitor.pid, monitor.log, failover_ready,            │
│   │            │   recovery_ready, metrics.csv (fallback)               │
│   └────────────┘                                                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                │                 │              │
                ▼                 ▼              ▼
         status.anthropic.com    Slack       generic webhook
           (health source)     (alerts)        (alerts)
```

## 2. State Machine

```
             ┌──────────────────────────┐
             │                          │
             │       WATCHING           │
             │   (check every N secs)   │
             │                          │
             └──┬──────────────┬────────┘
                │              │
     health=    │              │   health=degraded
     outage OR  │              │
     network_   │              │
     down       │              │
     (failure_  │              │
     window)    │              │
                │              │
                ▼              ▼
  ┌──────────────────────┐   ┌──────────────────────────┐
  │ MONITORING_RECOVERY  │   │   DEGRADED               │
  │ (watch for return)   │   │  (jittered backoff,      │
  │                      │   │   wait for sustain       │
  │                      │   │   threshold or recover)  │
  └────────┬─────────────┘   └──────────┬───────────────┘
           │                            │
           │ sliding_window_             │
           │ check_recovery()           │  health=outage OR
           │ returns true               │  sustained >
           │                            │  degraded_threshold
           │                            │
           │                            ▼
           │              ┌──────────────────────┐
           └─────────────▶│ MONITORING_RECOVERY  │
                          └──────────────────────┘
```

## 3. Tier Tree

```
                     ┌─────────────────┐
                     │  Tier 0         │
                     │  claude (Code)  │
                     │  prereq: bash   │
                     └────────┬────────┘
                              │
                  (on failure / unavailable)
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 1         │
                     │  codex          │
                     │  prereq: codex  │
                     │  in PATH        │
                     └────────┬────────┘
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 2a        │
                     │  aider+OpenAI   │
                     │  prereq:        │
                     │  OPENAI_API_KEY │
                     └────────┬────────┘
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 2b        │
                     │  aider+Google   │
                     │  prereq:        │
                     │  GEMINI_API_KEY │
                     └────────┬────────┘
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 3         │
                     │  aider+Ollama   │
                     │  prereq: ollama │
                     │  in PATH        │
                     └─────────────────┘
```

Notes:
- Sidecar tier (if present in `tiers.conf`) is never auto-launched; it only
  surfaces when the operator explicitly runs `fallback.sh sidecar`.
- `check_tier_prerequisites` gates each arrow; skips continue down the tree.
````

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.md
git commit -m "docs: ASCII architecture diagrams (component, state machine, tier tree)"
```

---

### Task 18: README callout + finalization

**Files:**
- Modify: `README.md`

**Depends on:** Tasks 1-17

- [ ] **Step 1: Read current README to find the right insertion point**

Run: `grep -n '^##' README.md | head -10`
Expected: listing of top-level sections. Choose the one immediately after the
overview/quick-start.

- [ ] **Step 2: Insert the callout**

After the Quick Start or overview section, add:

```markdown
## New in Round 3

- **Multi-channel alerts** — `notify_method` is now a comma-separated list.
  Channels: `terminal`, `toast`, `slack`, `webhook`, `both` (legacy). See
  `resilience.conf` for the new `notify_slack_url` and `notify_webhook_url`
  keys.
- **Jittered exponential backoff** — `monitor.sh` adapts check interval on
  sustained failure, capped at 5 minutes with ±10% jitter.
- **Self-healing metrics** — on SQLite corruption, the monitor renames the bad
  file and recreates the schema; a `critical` alert fires.
- **Hot config reload** — edit `resilience.conf`, then `monitor.sh reload`.
  Invalid configs are rejected and the prior config is retained.
- **History CLI** — `fallback.sh history [--limit N] [--since YYYY-MM-DD]`
  shows outages with uptime summary.

See [`docs/architecture.md`](docs/architecture.md) for diagrams and
[`docs/troubleshooting.md`](docs/troubleshooting.md) for the operator runbook.
```

- [ ] **Step 3: Run the full suite one last time**

Run: `bash tests/runner.sh`
Expected: Everything green. Suite under 4 minutes.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README callout for Round 3 features"
```

- [ ] **Step 5: Finish the branch**

Per the workflow skill `superpowers:finishing-a-development-branch`, decide
whether to merge, open a PR, or push direct. Default: push to `main` (single
developer workflow), then confirm CI matrix is green on all three OSes.

```bash
git push origin main
```

Then watch Actions → CI. If any leg fails, fix reactively in a follow-up.

---

## Completion Criteria

- [ ] All 18 tasks above committed
- [ ] `bash tests/runner.sh` green locally (8 existing test files + 4 new =
      12 files, ~15 new test cases)
- [ ] CI matrix green on ubuntu-latest, macos-latest, windows-latest
- [ ] `docs/troubleshooting.md` and `docs/architecture.md` exist and render
- [ ] README links to new docs
- [ ] No changes outside the scope declared in §File Structure Overview
