#!/usr/bin/env bash

source "$PROJECT_ROOT/lib.sh"

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
max_log_size=1048576
network_check_url=https://1.1.1.1
CONF
}

teardown_monitor_env() {
    # Kill any test monitor processes
    if [[ -f "$TEST_STATE_DIR/monitor.pid" ]]; then
        local pid
        pid=$(cat "$TEST_STATE_DIR/monitor.pid")
        terminate_pid "$pid"
    fi
    rm -rf "$TEST_STATE_DIR" "$TEST_CONF"
}

# Helper: terminate a PID with graceful-then-forced kill.
# Never blocks — SIGTERM, wait up to 2s, then SIGKILL.
# `wait $pid` can block indefinitely on Windows Git Bash when the target
# is blocked inside `sleep` (signals are deferred until sleep returns).
terminate_pid() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    kill -TERM "$pid" 2>/dev/null || return 0
    local i
    for ((i = 0; i < 10; i++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.2
    done
    kill -KILL "$pid" 2>/dev/null || true
}

# Helper: poll for a file to exist (up to 5 seconds)
wait_for_file() {
    local file="$1"
    local max_attempts=25
    for ((i = 0; i < max_attempts; i++)); do
        [[ -f "$file" ]] && return 0
        sleep 0.2
    done
    return 1
}

test_monitor_writes_pid_file() {
    setup_monitor_env
    load_config "$TEST_CONF"
    detect_platform
    # Start monitor in background
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" &
    disown 2>/dev/null || true  # Suppress job-control "Killed" messages on SIGKILL
    local mpid=$!
    # Poll instead of sleep
    if wait_for_file "$TEST_STATE_DIR/monitor.pid"; then
        assert_file_exists "$TEST_STATE_DIR/monitor.pid"
        local stored_pid
        stored_pid=$(cat "$TEST_STATE_DIR/monitor.pid")
        assert_eq "$mpid" "$stored_pid" "PID file should contain the monitor's PID"
    else
        assert_eq "pid_file_created" "timeout" "PID file should be created within 5s"
    fi
    terminate_pid "$mpid"
    teardown_monitor_env
}

test_monitor_singleton() {
    setup_monitor_env
    load_config "$TEST_CONF"
    detect_platform
    # Start first monitor
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" &
    disown 2>/dev/null || true  # Suppress job-control "Killed" messages on SIGKILL
    local pid1=$!
    # Poll for PID file
    wait_for_file "$TEST_STATE_DIR/monitor.pid" || true
    # Try to start second — should exit immediately
    local output
    output=$(bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" 2>&1) || true
    assert_contains "$output" "already running"
    terminate_pid "$pid1"
    teardown_monitor_env
}

test_monitor_stop_command() {
    setup_monitor_env
    load_config "$TEST_CONF"
    detect_platform
    # Start monitor
    bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --config "$TEST_CONF" &
    disown 2>/dev/null || true  # Suppress job-control "Killed" messages on SIGKILL
    local mpid=$!
    wait_for_file "$TEST_STATE_DIR/monitor.pid" || true
    # Stop it
    local output
    output=$(bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" stop 2>&1)
    assert_contains "$output" "stopped"
    # PID file should be gone
    if [[ -f "$TEST_STATE_DIR/monitor.pid" ]]; then
        assert_eq "removed" "exists" "PID file should be removed after stop"
    fi
    # Process should be dead
    sleep 0.5
    if kill -0 "$mpid" 2>/dev/null; then
        assert_eq "dead" "alive" "monitor process should be dead after stop"
    fi
    terminate_pid "$mpid"
    teardown_monitor_env
}

test_monitor_rejects_unknown_args() {
    setup_monitor_env
    local result=0
    local output
    output=$(bash "$PROJECT_ROOT/monitor.sh" --state-dir "$TEST_STATE_DIR" --bogus-flag 2>&1) || result=$?
    assert_eq "1" "$result" "should reject unknown arguments"
    assert_contains "$output" "Unknown argument"
    teardown_monitor_env
}

test_start_monitor_launches_process() {
    setup_monitor_env
    load_config "$TEST_CONF"
    detect_platform
    start_monitor "$TEST_STATE_DIR" "$TEST_CONF"
    # Poll for PID file
    if wait_for_file "$TEST_STATE_DIR/monitor.pid"; then
        local pid
        pid=$(cat "$TEST_STATE_DIR/monitor.pid")
        # Process should be running
        if kill -0 "$pid" 2>/dev/null; then
            assert_eq "0" "0" "start_monitor launched a running process"
        else
            assert_eq "running" "dead" "start_monitor process should be running"
        fi
    else
        assert_eq "pid_file" "missing" "start_monitor should create PID file"
    fi
    teardown_monitor_env
}

test_start_monitor_noop_when_already_running() {
    setup_monitor_env
    load_config "$TEST_CONF"
    detect_platform
    start_monitor "$TEST_STATE_DIR" "$TEST_CONF"
    wait_for_file "$TEST_STATE_DIR/monitor.pid" || true
    local pid1
    pid1=$(cat "$TEST_STATE_DIR/monitor.pid")
    # Call again — should not launch a second process
    start_monitor "$TEST_STATE_DIR" "$TEST_CONF"
    local pid2
    pid2=$(cat "$TEST_STATE_DIR/monitor.pid")
    assert_eq "$pid1" "$pid2" "start_monitor should not change PID when already running"
    teardown_monitor_env
}

test_stop_monitor_kills_and_cleans() {
    setup_monitor_env
    load_config "$TEST_CONF"
    detect_platform
    start_monitor "$TEST_STATE_DIR" "$TEST_CONF"
    wait_for_file "$TEST_STATE_DIR/monitor.pid" || true
    local pid
    pid=$(cat "$TEST_STATE_DIR/monitor.pid")
    stop_monitor "$TEST_STATE_DIR"
    sleep 0.5
    # PID file should be gone
    if [[ -f "$TEST_STATE_DIR/monitor.pid" ]]; then
        assert_eq "removed" "exists" "stop_monitor should remove PID file"
    fi
    # Process should be dead
    if kill -0 "$pid" 2>/dev/null; then
        assert_eq "dead" "alive" "stop_monitor should kill the process"
        terminate_pid "$pid"
    fi
    teardown_monitor_env
}

test_stop_monitor_noop_when_not_running() {
    setup_monitor_env
    # No monitor running — stop should be a no-op
    local rc=0
    stop_monitor "$TEST_STATE_DIR" || rc=$?
    assert_eq "0" "$rc" "stop_monitor should return 0 when no monitor is running"
    teardown_monitor_env
}
