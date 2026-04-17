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
