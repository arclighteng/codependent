#!/usr/bin/env bash

setup_monitor_env() {
    export TEST_STATE_DIR="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<'CONF'
check_interval=1
health_check=status_page
recovery_successes=3
recovery_window=4
failure_window=2
degraded_threshold=5
on_recovery=notify
on_failure=notify
notify_method=terminal
heartbeat_timeout=600
max_log_size=1048576
network_check_url=https://1.1.1.1
CONF
    # Create a heartbeat so monitor doesn't self-terminate
    touch "$TEST_STATE_DIR/monitor.heartbeat"
}

teardown_monitor_env() {
    # Kill any test monitor processes
    if [[ -f "$TEST_STATE_DIR/monitor.pid" ]]; then
        local pid
        pid=$(cat "$TEST_STATE_DIR/monitor.pid")
        kill "$pid" 2>/dev/null || true
    fi
    rm -rf "$TEST_STATE_DIR" "$TEST_CONF"
}

test_monitor_writes_pid_file() {
    setup_monitor_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    detect_platform
    # Start monitor in background, let it run one cycle
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" &
    local mpid=$!
    sleep 2
    assert_file_exists "$TEST_STATE_DIR/monitor.pid"
    kill "$mpid" 2>/dev/null || true
    wait "$mpid" 2>/dev/null || true
    teardown_monitor_env
}

test_monitor_singleton() {
    setup_monitor_env
    source "$PROJECT_ROOT/lib.sh"
    load_config "$TEST_CONF"
    detect_platform
    # Start first monitor
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" &
    local pid1=$!
    sleep 2
    # Try to start second — should exit immediately
    local output
    output=$(bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" 2>&1) || true
    assert_contains "$output" "already running"
    kill "$pid1" 2>/dev/null || true
    wait "$pid1" 2>/dev/null || true
    teardown_monitor_env
}
