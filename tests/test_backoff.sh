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
