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
    assert_eq "$(printf 'terminal\ntoast')" "$out" "both expands to terminal then toast in order"
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

test_parse_notify_channels_no_glob_expansion() {
    # Regression: unquoted word-splitting would expand * against the cwd.
    # Verify that a literal '*' token survives untouched.
    local out
    out=$(parse_notify_channels "terminal,*,toast")
    assert_eq "$(printf 'terminal\n*\ntoast')" "$out" "glob metachars should not expand"
}

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

test_json_escape_backslash() {
    local out
    out=$(_json_escape 'a\b')
    assert_eq 'a\\b' "$out" "backslash should be doubled"
}

test_json_escape_quotes() {
    local out
    out=$(_json_escape 'say "hi"')
    assert_eq 'say \"hi\"' "$out" "double quotes should be escaped"
}

test_json_escape_newline() {
    local out
    out=$(_json_escape $'line1\nline2')
    assert_eq 'line1\nline2' "$out" "newline should become \\n"
}

test_json_escape_mixed() {
    local out
    out=$(_json_escape $'a\\b"c\nd')
    assert_eq 'a\\b\"c\nd' "$out" "all special chars should be escaped"
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
    assert_contains "$out" "url is empty"
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
