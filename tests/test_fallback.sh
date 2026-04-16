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

test_full_status_command() {
    source "$PROJECT_ROOT/lib.sh"
    local output
    output=$(bash "$PROJECT_ROOT/fallback.sh" status 2>&1)
    assert_contains "$output" "codependent"
    assert_contains "$output" "Tier 0"
    assert_contains "$output" "Monitor:"
}

test_full_dry_run_command() {
    source "$PROJECT_ROOT/lib.sh"
    local output
    output=$(bash "$PROJECT_ROOT/fallback.sh" --dry-run 2>&1)
    assert_contains "$output" "dry run"
    assert_contains "$output" "Tier 0"
}

test_full_test_command() {
    source "$PROJECT_ROOT/lib.sh"
    local output
    output=$(bash "$PROJECT_ROOT/fallback.sh" --test 2>&1)
    assert_contains "$output" "system test"
    assert_contains "$output" "Config:"
}

# ── walk_tiers ──────────────────────────────────────────────────────────────────

test_walk_tiers_picks_first_available() {
    setup_fallback_env
    source "$PROJECT_ROOT/fallback.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform

    # Override exec and start_monitor to capture what would launch
    exec() { echo "EXEC: $*"; }
    start_monitor() { :; }
    export STATE_DIR="$TEST_STATE_DIR"

    local output
    output=$(walk_tiers 2>&1)
    assert_contains "$output" "Activating Tier 0"

    unset -f exec start_monitor
    teardown_fallback_env
}

test_walk_tiers_skips_unavailable() {
    setup_fallback_env
    # All tiers require a missing env var
    cat > "$TEST_TIERS" <<'TIERS'
0 | bash | echo tier0 | FAKE_MISSING_VAR_1 | command -v bash
1 | bash | echo tier1 | FAKE_MISSING_VAR_2 | command -v bash
TIERS

    # Run in a subshell to capture exit code from walk_tiers' exit 1
    local result=0
    local output
    output=$(bash -c "
        source \"$PROJECT_ROOT/fallback.sh\"
        load_config \"$TEST_CONF\"
        load_tiers \"$TEST_TIERS\"
        detect_platform
        STATE_DIR=\"$TEST_STATE_DIR\"
        walk_tiers
    " 2>&1) || result=$?
    assert_eq "1" "$result" "should exit 1 when all tiers exhausted"
    assert_contains "$output" "All tiers exhausted"

    teardown_fallback_env
}

test_walk_tiers_respects_start_tier() {
    setup_fallback_env
    cat > "$TEST_TIERS" <<'TIERS'
0 | bash | echo tier0 |  | command -v bash
1 | bash | echo tier1 |  | command -v bash
TIERS
    source "$PROJECT_ROOT/fallback.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform

    exec() { echo "EXEC: $*"; }
    start_monitor() { :; }
    export STATE_DIR="$TEST_STATE_DIR"

    local output
    output=$(walk_tiers "1" 2>&1)
    assert_contains "$output" "Activating Tier 1"

    unset -f exec start_monitor
    teardown_fallback_env
}

test_walk_tiers_reads_failover_ready() {
    setup_fallback_env
    cat > "$TEST_TIERS" <<'TIERS'
0 | bash | echo tier0 |  | command -v bash
1 | bash | echo tier1 |  | command -v bash
TIERS
    source "$PROJECT_ROOT/fallback.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform

    exec() { echo "EXEC: $*"; }
    start_monitor() { :; }
    export STATE_DIR="$TEST_STATE_DIR"

    # Write a failover_ready file pointing to tier 1
    echo "1" > "$TEST_STATE_DIR/failover_ready"

    local output
    output=$(walk_tiers 2>&1)
    assert_contains "$output" "Activating Tier 1"

    unset -f exec start_monitor
    teardown_fallback_env
}

test_walk_tiers_skips_sidecar() {
    setup_fallback_env
    cat > "$TEST_TIERS" <<'TIERS'
sidecar | cursor | cursor . |  | command -v bash
TIERS

    local result=0
    local output
    output=$(bash -c "
        source \"$PROJECT_ROOT/fallback.sh\"
        load_config \"$TEST_CONF\"
        load_tiers \"$TEST_TIERS\"
        detect_platform
        STATE_DIR=\"$TEST_STATE_DIR\"
        walk_tiers
    " 2>&1) || result=$?
    assert_eq "1" "$result" "sidecar should be skipped, all tiers exhausted"

    teardown_fallback_env
}

test_walk_tiers_reads_recovery_ready() {
    setup_fallback_env
    cat > "$TEST_TIERS" <<'TIERS'
0 | bash | echo tier0 |  | command -v bash
1 | bash | echo tier1 |  | command -v bash
TIERS
    source "$PROJECT_ROOT/fallback.sh"
    load_config "$TEST_CONF"
    load_tiers "$TEST_TIERS"
    detect_platform

    exec() { echo "EXEC: $*"; }
    start_monitor() { :; }
    export STATE_DIR="$TEST_STATE_DIR"

    # Write a recovery_ready file pointing to tier 0
    echo "0" > "$TEST_STATE_DIR/recovery_ready"

    local output
    output=$(walk_tiers 2>&1)
    assert_contains "$output" "Activating Tier 0"

    unset -f exec start_monitor
    teardown_fallback_env
}
