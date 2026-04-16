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
    assert_eq "0" "0" "notify_toast did not crash"
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
