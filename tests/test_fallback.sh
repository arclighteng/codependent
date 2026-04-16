#!/usr/bin/env bash
# tests/test_fallback.sh — tests for fallback.sh: status and dry-run

setup_fallback_env() {
    export TEST_STATE_DIR="$(mktemp -d)"
    export TEST_TIERS="$(mktemp)"
    export TEST_CONF="$(mktemp)"
    # Minimal tiers — use bash as a "tool" that's guaranteed to exist
    cat > "$TEST_TIERS" <<'TIERS'
0 | bash | echo tier0 |  | command -v bash
1 | bash | echo tier1 | FAKE_MISSING_VAR | command -v bash
TIERS
    cat > "$TEST_CONF" <<'CONF'
check_interval=30
on_failure=notify
on_recovery=notify
notify_method=terminal
health_check=status_page
CONF
}

teardown_fallback_env() {
    rm -rf "$TEST_STATE_DIR" "$TEST_TIERS" "$TEST_CONF"
}

test_fallback_status_shows_tiers() {
    setup_fallback_env
    source "$PROJECT_ROOT/fallback.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform
    local output
    output=$(show_status "$TEST_STATE_DIR" 2>&1)
    assert_contains "$output" "Tier 0"
    assert_contains "$output" "bash"
    teardown_fallback_env
}

test_fallback_dry_run_picks_first_available() {
    setup_fallback_env
    source "$PROJECT_ROOT/fallback.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform
    local output
    output=$(dry_run_tiers "$TEST_STATE_DIR" 2>&1)
    assert_contains "$output" "Tier 0"
    assert_contains "$output" "ready"
    teardown_fallback_env
}

test_fallback_skips_tier_with_missing_env() {
    setup_fallback_env
    source "$PROJECT_ROOT/fallback.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform
    # Tier 1 requires FAKE_MISSING_VAR which isn't set
    local output
    output=$(dry_run_tiers "$TEST_STATE_DIR" 2>&1)
    assert_contains "$output" "FAKE_MISSING_VAR"
    teardown_fallback_env
}
