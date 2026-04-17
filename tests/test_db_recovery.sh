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
    result=$(check_db_integrity "$db" || true)
    assert_eq "corrupted" "$result" "garbage file must report corrupted"

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
