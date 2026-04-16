#!/usr/bin/env bash

test_log_metrics_csv_fallback() {
    source "$PROJECT_ROOT/lib.sh"
    local test_dir="$(mktemp -d)"
    # Mock sqlite3 to fail so we exercise CSV fallback
    sqlite3() { return 1; }
    log_metrics "2026-04-15T10:00:00" "" "" "outage" "1" "codex" "false" "macos" "$test_dir"
    unset -f sqlite3
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
