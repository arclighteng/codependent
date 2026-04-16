#!/usr/bin/env bash

source "$PROJECT_ROOT/lib.sh"

test_log_metrics_csv_fallback() {
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

test_log_metrics_csv_fields_are_quoted() {
    local test_dir="$(mktemp -d)"
    sqlite3() { return 1; }
    log_metrics "2026-04-15T10:00:00" "2026-04-15T11:00:00" "60" "outage" "2a" "aider" "true" "linux" "$test_dir"
    unset -f sqlite3
    local content
    content=$(tail -1 "$test_dir/metrics.csv")
    # Each field should be double-quoted
    assert_contains "$content" '"outage"'
    assert_contains "$content" '"aider"'
    rm -rf "$test_dir"
}

test_import_csv_to_db_clears_csv_on_success() {
    local test_dir="$(mktemp -d)"
    # Create a CSV with a header and one row
    cat > "$test_dir/metrics.csv" <<'CSV'
started_at,recovered_at,duration_minutes,failure_type,tier_used,tool_used,auto_recovered,platform
"2026-04-15T10:00:00","2026-04-15T11:00:00","60","outage","1","codex","true","linux"
CSV
    # Mock sqlite3 to succeed
    sqlite3() { return 0; }
    import_csv_to_db "$test_dir"
    unset -f sqlite3
    # CSV should be deleted after successful import
    if [[ -f "$test_dir/metrics.csv" ]]; then
        assert_eq "deleted" "exists" "CSV should be deleted after successful import"
    fi
    rm -rf "$test_dir"
}

test_import_csv_to_db_keeps_failed_rows() {
    local test_dir="$(mktemp -d)"
    # Create a CSV with two rows
    cat > "$test_dir/metrics.csv" <<'CSV'
started_at,recovered_at,duration_minutes,failure_type,tier_used,tool_used,auto_recovered,platform
"2026-04-15T10:00:00","","","outage","1","codex","false","linux"
"2026-04-15T12:00:00","","","outage","2a","aider","false","linux"
CSV
    # Mock sqlite3 to always fail
    sqlite3() { return 1; }
    import_csv_to_db "$test_dir"
    unset -f sqlite3
    # CSV should still exist with failed rows
    assert_file_exists "$test_dir/metrics.csv"
    local line_count
    line_count=$(wc -l < "$test_dir/metrics.csv")
    # Header + 2 failed rows = 3 lines
    assert_eq "3" "$line_count" "CSV should have header + 2 failed rows"
    rm -rf "$test_dir"
}

test_import_csv_to_db_noop_without_csv() {
    local test_dir="$(mktemp -d)"
    # No CSV file exists — should be a no-op
    local rc=0
    import_csv_to_db "$test_dir" || rc=$?
    assert_eq "0" "$rc" "import_csv_to_db should return 0 when no CSV exists"
    rm -rf "$test_dir"
}

test_rotate_log_under_limit() {
    local test_log="$(mktemp)"
    echo "small content" > "$test_log"
    rotate_log "$test_log" 1048576
    # Should not rotate
    assert_file_exists "$test_log"
    assert_contains "$(cat "$test_log")" "small content"
    rm -f "$test_log"
}

test_rotate_log_over_limit() {
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

test_date_to_epoch_returns_nonzero_for_valid_timestamp() {
    local result
    result=$(date_to_epoch "2026-04-15T10:00:00")
    # Should return a large positive integer (epoch seconds)
    if [[ "$result" =~ ^[0-9]+$ && "$result" -gt 1000000000 ]]; then
        assert_eq "0" "0" "date_to_epoch returned valid epoch: $result"
    else
        assert_eq "valid_epoch" "$result" "date_to_epoch should return a valid epoch for a known timestamp"
    fi
}

test_date_to_epoch_fallback_returns_zero() {
    # Mock both date variants to fail
    date() {
        if [[ "$1" == "-d" || "$1" == "-j" ]]; then
            return 1
        fi
        command date "$@"
    }
    local result
    result=$(date_to_epoch "invalid-not-a-date")
    assert_eq "0" "$result" "date_to_epoch should return 0 when both date variants fail"
    unset -f date
}

test_init_metrics_db_creates_table() {
    local tmpdb
    tmpdb=$(mktemp)
    rm -f "$tmpdb"

    init_metrics_db "$tmpdb"

    # Schema should include outage_events table
    local tables
    tables=$(sqlite3 "$tmpdb" ".tables" 2>/dev/null)
    assert_contains "$tables" "outage_events"

    # Column-level invariant: schema must preserve all known columns. Round 3
    # adds no columns; any future migration must update this test deliberately.
    local cols
    cols=$(sqlite3 "$tmpdb" "PRAGMA table_info(outage_events);" 2>/dev/null)
    assert_contains "$cols" "started_at"
    assert_contains "$cols" "recovered_at"
    assert_contains "$cols" "duration_minutes"
    assert_contains "$cols" "failure_type"
    assert_contains "$cols" "tier_used"
    assert_contains "$cols" "tool_used"
    assert_contains "$cols" "auto_recovered"
    assert_contains "$cols" "platform"

    rm -f "$tmpdb"
}

test_init_metrics_db_idempotent() {
    local tmpdb
    tmpdb=$(mktemp)
    rm -f "$tmpdb"

    init_metrics_db "$tmpdb"
    local rc=0
    init_metrics_db "$tmpdb" || rc=$?  # second call must not fail
    assert_eq "0" "$rc" "init_metrics_db must be idempotent"
    rm -f "$tmpdb"
}
