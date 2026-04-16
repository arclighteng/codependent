#!/usr/bin/env bash

source "$PROJECT_ROOT/lib.sh"

test_notify_writes_to_log() {
    local test_log="$(mktemp)"
    notify "Test message" "$test_log"
    local content
    content=$(cat "$test_log")
    assert_contains "$content" "Test message"
    rm -f "$test_log"
}

test_notify_includes_timestamp() {
    local test_log="$(mktemp)"
    notify "Test message" "$test_log"
    local content
    content=$(cat "$test_log")
    # Should contain a date-like pattern
    assert_contains "$content" "202"
    rm -f "$test_log"
}

test_notify_toast_does_not_crash() {
    detect_platform
    # Verify the function completes without error — actual toast delivery
    # is platform-specific and tested via fallback.sh --test
    local result=0
    notify_toast "Test notification" 2>/dev/null || result=$?
    # On CI/headless, toast may fail gracefully (falls back to terminal bell)
    # but should never crash with a non-zero exit from the function itself
    assert_eq "0" "$result" "notify_toast should not crash"
}

test_build_recovery_message() {
    local msg
    msg=$(build_recovery_message)
    assert_contains "$msg" "fallback.sh"
    assert_contains "$msg" "recovered"
}

test_build_outage_message() {
    TIER_id="1"
    TIER_tool="codex"
    local msg
    msg=$(build_outage_message)
    assert_contains "$msg" "codex"
    assert_contains "$msg" "fallback.sh"
}

test_build_degraded_message() {
    local msg
    msg=$(build_degraded_message)
    assert_contains "$msg" "degraded"
    assert_contains "$msg" "fallback.sh"
}

test_notify_dispatch_toast_only() {
    detect_platform
    CFG_notify_method="toast"
    local test_log="$(mktemp)"
    # Mock notify_toast to record it was called
    local toast_called=false
    notify_toast() { toast_called=true; }
    notify_terminal() { echo "TERMINAL_CALLED"; }

    local output
    output=$(notify_dispatch "test msg" "$test_log" 2>&1)

    # Log should always be written regardless of method
    assert_contains "$(cat "$test_log")" "test msg"
    # Terminal bell should NOT appear in output for toast-only
    if [[ "$output" == *"TERMINAL_CALLED"* ]]; then
        assert_eq "should not call terminal" "but did" "toast mode should not call notify_terminal"
    fi

    unset -f notify_toast notify_terminal
    rm -f "$test_log"
}

test_notify_dispatch_terminal_only() {
    CFG_notify_method="terminal"
    local test_log="$(mktemp)"
    local toast_called="false"
    notify_toast() { toast_called="true"; }

    notify_dispatch "test msg" "$test_log" 2>/dev/null

    assert_contains "$(cat "$test_log")" "test msg"
    assert_eq "false" "$toast_called" "terminal mode should not call notify_toast"

    unset -f notify_toast
    rm -f "$test_log"
}

test_notify_dispatch_both() {
    detect_platform
    CFG_notify_method="both"
    local test_log="$(mktemp)"
    local toast_called="false"
    notify_toast() { toast_called="true"; }

    notify_dispatch "test msg" "$test_log" 2>/dev/null

    assert_contains "$(cat "$test_log")" "test msg"
    assert_eq "true" "$toast_called" "both mode should call notify_toast"

    unset -f notify_toast
    rm -f "$test_log"
}

test_parse_notify_channels_single() {
    local out
    out=$(parse_notify_channels "terminal")
    assert_eq "terminal" "$out" "single channel returns itself"
}

test_parse_notify_channels_comma_list() {
    local output
    output=$(parse_notify_channels "terminal,toast,slack")
    local line1 line2 line3
    line1=$(echo "$output" | sed -n '1p')
    line2=$(echo "$output" | sed -n '2p')
    line3=$(echo "$output" | sed -n '3p')
    assert_eq "terminal" "$line1" "first channel should be terminal"
    assert_eq "toast"    "$line2" "second channel should be toast"
    assert_eq "slack"    "$line3" "third channel should be slack"
}

test_parse_notify_channels_both_backcompat() {
    local out
    out=$(parse_notify_channels "both")
    assert_contains "$out" "terminal"
    assert_contains "$out" "toast"
}

test_parse_notify_channels_trims_whitespace() {
    local output
    output=$(parse_notify_channels " terminal , toast ")
    assert_eq "$(printf 'terminal\ntoast')" "$output" "whitespace should be trimmed"
}

test_parse_notify_channels_empty() {
    local out
    out=$(parse_notify_channels "")
    assert_eq "" "$out" "empty input returns empty"
}
