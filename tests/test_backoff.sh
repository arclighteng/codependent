#!/usr/bin/env bash
# tests/test_backoff.sh — unit tests for next_check_interval

source "$PROJECT_ROOT/lib.sh"

test_backoff_floor() {
    # 0 failures → base floor absorbs negative jitter, so range is [base, base + 10%].
    # Upper bound is +jitter (base + raw/10 = 33). Lower bound is exactly base (30).
    local val
    val=$(next_check_interval 30 0)
    if (( val < 30 || val > 33 )); then
        assert_eq "30..33" "$val" "0-failure result should be base (floor clamped) or above"
    fi
}

test_backoff_grows() {
    # Monotonic growth (before cap) across failure counts.
    # Parameter choices below guarantee non-overlapping jitter windows, so the
    # comparison is deterministic despite live $RANDOM:
    #   failures=0 → raw=10, jitter disabled (window=1 but floor clamps): [10,11]
    #   failures=2 → raw=40, jitter±4: [36,44]
    #   failures=3 → raw=80, jitter±8: [72,88]
    local v0 v1 v2
    v0=$(next_check_interval 10 0)
    v1=$(next_check_interval 10 2)
    v2=$(next_check_interval 10 3)
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
