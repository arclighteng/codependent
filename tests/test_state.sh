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

test_sliding_window_push_without_init_fails() {
    source "$PROJECT_ROOT/lib.sh"
    # Reset globals to simulate uninitialized state
    SW_SIZE=0
    SW_INDEX=0
    SW_TOTAL_PUSHED=0
    SW_WINDOW=()
    local result=0
    sliding_window_push 1 2>/dev/null || result=$?
    assert_eq "1" "$result" "push without init should return 1"
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
