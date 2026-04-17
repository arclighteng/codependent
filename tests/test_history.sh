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
