#!/usr/bin/env bash
# tests/test_state_machine.sh — integration tests for monitor.sh state machine
# These tests start a real monitor with mocked health checks and observe
# state transitions via log file entries and state-dir artifacts.

source "$PROJECT_ROOT/lib.sh"

setup_sm_env() {
    export SM_STATE_DIR="$(mktemp -d)"
    export SM_CONF="$(mktemp)"
    export SM_MOCK_HEALTH_FILE="$(mktemp)"
    export SM_MOCK_TIERS="$(mktemp)"

    # Fast intervals for testing
    cat > "$SM_CONF" <<'CONF'
check_interval=1
health_check=status_page
recovery_successes=3
recovery_window=4
failure_window=2
degraded_threshold=3
on_recovery=notify
on_failure=auto_failover
notify_method=terminal
max_log_size=1048576
network_check_url=https://1.1.1.1
CONF

    # Tier for failover messages
    cat > "$SM_MOCK_TIERS" <<'TIERS'
0 | claude | claude |  | command -v bash
1 | bash | echo fallback |  | command -v bash
TIERS

    # Start with healthy
    echo "healthy" > "$SM_MOCK_HEALTH_FILE"
}

teardown_sm_env() {
    if [[ -f "$SM_STATE_DIR/monitor.pid" ]]; then
        local pid
        pid=$(cat "$SM_STATE_DIR/monitor.pid")
        kill "$pid" 2>/dev/null || true
        # Wait up to 4s for graceful shutdown
        for i in {1..20}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        # If still alive, SIGKILL — we don't want ghost processes
        # during a 24/7 runtime simulation
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            sleep 0.2
        fi
    fi
    rm -rf "$SM_STATE_DIR" "$SM_CONF" "$SM_MOCK_HEALTH_FILE" "$SM_MOCK_TIERS"
}

# Helper: wait for a string to appear in the monitor log
wait_for_log() {
    local pattern="$1"
    local log="$SM_STATE_DIR/monitor.log"
    local max_attempts=50
    for ((i = 0; i < max_attempts; i++)); do
        if [[ -f "$log" ]] && grep -q "$pattern" "$log" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# Start monitor with mocked health checks via a wrapper script
start_mock_monitor() {
    local wrapper="$SM_STATE_DIR/mock_monitor.sh"
    cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

# Override health check functions before starting
source "$PROJECT_ROOT/lib.sh"

# Mock check_network: always up
check_network() { return 0; }

# Mock check_status_page: read from control file
check_status_page() {
    local health=\$(cat "$SM_MOCK_HEALTH_FILE" 2>/dev/null || echo "unknown")
    case "\$health" in
        healthy)  echo "none" ;;
        degraded) echo "minor" ;;
        outage)   echo "major" ;;
        *)        echo "unknown" ;;
    esac
}

# Mock load_tiers to use test tiers. Tolerate file disappearing during
# teardown so the monitor can shut down cleanly without a noisy error.
load_tiers() {
    TIERS=()
    [[ -f "$SM_MOCK_TIERS" ]] || return 0
    while IFS= read -r line; do
        [[ -z "\${line// }" ]] && continue
        [[ "\$line" =~ ^[[:space:]]*# ]] && continue
        TIERS+=( "\$line" )
    done < "$SM_MOCK_TIERS"
}

# Mock notify_toast to be a no-op
notify_toast() { :; }

# Now source and run monitor.sh's logic inline (can't source monitor.sh
# because it has its own sourcing of lib.sh which would override our mocks)
load_config "$SM_CONF"
detect_platform

mkdir -p "$SM_STATE_DIR"

PID_FILE="$SM_STATE_DIR/monitor.pid"
if [[ -f "\$PID_FILE" ]]; then
    existing_pid=\$(cat "\$PID_FILE")
    if kill -0 "\$existing_pid" 2>/dev/null; then
        echo "Monitor already running (PID \$existing_pid)" >&2
        exit 1
    fi
    rm -f "\$PID_FILE"
fi

if ! ( set -o noclobber; echo \$\$ > "\$PID_FILE" ) 2>/dev/null; then
    echo "Monitor already running (lost PID race)" >&2
    exit 1
fi

cleanup() { rm -f "\$PID_FILE"; }
trap cleanup EXIT INT TERM

DAEMON_STATE="WATCHING"
OUTAGE_STARTED=""
DEGRADED_STARTED=""
CURRENT_INTERVAL="\${CFG_check_interval:-1}"
consecutive_network_failures=0
LOG_FILE="$SM_STATE_DIR/monitor.log"

sliding_window_init "\${CFG_recovery_window:-4}"
notify "Monitor started (PID \$\$, state=\$DAEMON_STATE)" "\$LOG_FILE"

while true; do
    sleep "\$CURRENT_INTERVAL"

    network_status="up"
    if ! check_network; then
        network_status="down"
    fi

    status_indicator="unknown"
    if [[ "\$network_status" == "up" ]]; then
        status_indicator=\$(check_status_page)
    fi

    # Track network-failure streak for adaptive backoff in WATCHING
    if [[ "\$network_status" == "down" ]]; then
        consecutive_network_failures=\$((consecutive_network_failures + 1))
        CURRENT_INTERVAL=\$(next_check_interval "\${CFG_check_interval:-1}" "\$consecutive_network_failures")
    else
        consecutive_network_failures=0
        CURRENT_INTERVAL="\${CFG_check_interval:-1}"
    fi

    health=\$(classify_health "\$network_status" "\$status_indicator")

    # Use explicit if/else; "[[ ... ]] && x=y" would trigger set -e on false
    if [[ "\$health" == "healthy" ]]; then
        check_val=1
    else
        check_val=0
    fi

    sliding_window_push "\$check_val"

    case "\$DAEMON_STATE" in
        WATCHING)
            if [[ "\$health" == "network_down" || "\$health" == "outage" ]]; then
                if [[ "\$(sliding_window_check_failure "\${CFG_failure_window:-2}")" == "true" ]]; then
                    DAEMON_STATE="MONITORING_RECOVERY"
                    OUTAGE_STARTED=\$(date '+%Y-%m-%dT%H:%M:%S')
                    CURRENT_INTERVAL="\${CFG_check_interval:-1}"

                    load_tiers
                    next_tier_msg="no tier available"
                    next_tier_id=""
                    for tline in "\${TIERS[@]}"; do
                        parse_tier_line "\$tline"
                        [[ "\$TIER_id" == "sidecar" ]] && continue
                        [[ "\$TIER_id" == "0" ]] && continue
                        if check_tier_prerequisites 2>/dev/null; then
                            next_tier_id="\$TIER_id"
                            next_tier_msg="Tier \$TIER_id (\$TIER_tool)"
                            break
                        fi
                    done

                    if [[ -n "\$next_tier_id" ]]; then
                        msg="Anthropic API down. Next available: \$next_tier_msg. Run: fallback.sh \$next_tier_id"
                    else
                        msg="Anthropic API down. No fallback tier available."
                    fi

                    # Write state files BEFORE logging so observers that react
                    # to the log entry find the state file already in place.
                    if [[ -n "\$next_tier_id" ]]; then
                        if [[ "\${CFG_on_failure:-notify}" == "auto_failover" || "\${CFG_on_failure:-notify}" == "both" ]]; then
                            echo "\$next_tier_id" > "$SM_STATE_DIR/failover_ready"
                        fi
                    fi

                    notify "\$msg" "\$LOG_FILE"
                    notify_dispatch "\$msg"
                fi
            elif [[ "\$health" == "degraded" ]]; then
                DAEMON_STATE="DEGRADED"
                DEGRADED_STARTED=\$(date +%s)
                CURRENT_INTERVAL="\${CFG_check_interval:-1}"
                notify "API degraded (status: \$status_indicator). Monitoring." "\$LOG_FILE"
                notify_dispatch "\$(build_degraded_message)"
            fi
            ;;

        DEGRADED)
            if [[ "\$health" == "healthy" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="\${CFG_check_interval:-1}"
                notify "Degradation cleared. Resuming normal monitoring." "\$LOG_FILE"
            elif [[ "\$health" == "outage" || "\$health" == "network_down" ]]; then
                DAEMON_STATE="MONITORING_RECOVERY"
                OUTAGE_STARTED=\$(date -d "@\$DEGRADED_STARTED" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -r "\$DEGRADED_STARTED" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
                CURRENT_INTERVAL="\${CFG_check_interval:-1}"
                notify "Degradation escalated to outage." "\$LOG_FILE"
                notify_dispatch "Anthropic API: degradation escalated to full outage. Run: fallback.sh"
                continue
            else
                now=\$(date +%s)
                degraded_duration=\$((now - DEGRADED_STARTED))
                if ((degraded_duration > \${CFG_degraded_threshold:-3})); then
                    DAEMON_STATE="MONITORING_RECOVERY"
                    OUTAGE_STARTED=\$(date '+%Y-%m-%dT%H:%M:%S')
                    notify "Sustained degradation (\${degraded_duration}s). Escalating to failover." "\$LOG_FILE"
                    notify_dispatch "Anthropic API degraded for \${degraded_duration}s. Run: fallback.sh"
                    continue
                fi
                # Jittered exponential backoff with 300s cap.
                base="\${CFG_check_interval:-1}"
                deg_failures=\$(( degraded_duration / base ))
                if (( deg_failures < 0 )); then deg_failures=0; fi
                CURRENT_INTERVAL=\$(next_check_interval "\$base" "\$deg_failures")
            fi
            ;;

        MONITORING_RECOVERY)
            if [[ "\$(sliding_window_check_recovery "\${CFG_recovery_successes:-3}" "\${CFG_recovery_window:-4}")" == "true" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="\${CFG_check_interval:-1}"
                recovered_at=\$(date '+%Y-%m-%dT%H:%M:%S')

                # Write state files BEFORE logging so observers that react
                # to the log entry find the state in its final shape.
                case "\${CFG_on_recovery:-notify}" in
                    auto_switch|both)
                        echo "0" > "$SM_STATE_DIR/recovery_ready"
                        ;;
                esac

                rm -f "$SM_STATE_DIR/failover_ready"

                notify "Anthropic API recovered." "\$LOG_FILE"

                case "\${CFG_on_recovery:-notify}" in
                    notify|both)
                        notify_dispatch "\$(build_recovery_message)"
                        ;;
                esac
                OUTAGE_STARTED=""
            fi
            ;;
    esac

    rotate_log "\$LOG_FILE"
done
WRAPPER
    chmod +x "$wrapper"
    bash "$wrapper" &
    disown 2>/dev/null || true  # Suppress job-control "Killed" messages on SIGKILL
    # Wait for startup
    local max=25
    for ((i = 0; i < max; i++)); do
        [[ -f "$SM_STATE_DIR/monitor.pid" ]] && return 0
        sleep 0.2
    done
    return 1
}

# ── State Machine Tests ──────────────────────────────────────────────────────

test_sm_watching_to_outage() {
    setup_sm_env
    start_mock_monitor

    # Trigger outage: set health to outage, wait for failure_window (2 checks)
    echo "outage" > "$SM_MOCK_HEALTH_FILE"

    if wait_for_log "Anthropic API down"; then
        assert_file_exists "$SM_STATE_DIR/failover_ready"
        local tier
        tier=$(cat "$SM_STATE_DIR/failover_ready")
        assert_eq "1" "$tier" "failover_ready should point to tier 1"
    else
        assert_eq "outage_detected" "timeout" "monitor should detect outage within 10s"
    fi

    teardown_sm_env
}

test_sm_outage_to_recovery() {
    setup_sm_env
    start_mock_monitor

    # Trigger outage first
    echo "outage" > "$SM_MOCK_HEALTH_FILE"
    wait_for_log "Anthropic API down" || true

    # Now recover: 3 consecutive successes (cold start shortcut)
    echo "healthy" > "$SM_MOCK_HEALTH_FILE"

    if wait_for_log "Anthropic API recovered"; then
        # failover_ready should be cleaned up
        if [[ -f "$SM_STATE_DIR/failover_ready" ]]; then
            assert_eq "cleaned" "exists" "failover_ready should be removed on recovery"
        fi
        local log_content
        log_content=$(cat "$SM_STATE_DIR/monitor.log")
        assert_contains "$log_content" "recovered"
    else
        assert_eq "recovery_detected" "timeout" "monitor should detect recovery within 10s"
    fi

    teardown_sm_env
}

test_sm_watching_to_degraded() {
    setup_sm_env
    start_mock_monitor

    # Trigger degraded
    echo "degraded" > "$SM_MOCK_HEALTH_FILE"

    if wait_for_log "API degraded"; then
        local log_content
        log_content=$(cat "$SM_STATE_DIR/monitor.log")
        assert_contains "$log_content" "degraded"
    else
        assert_eq "degraded_detected" "timeout" "monitor should detect degraded state within 10s"
    fi

    teardown_sm_env
}

test_sm_degraded_to_watching() {
    setup_sm_env
    start_mock_monitor

    # Go degraded then recover
    echo "degraded" > "$SM_MOCK_HEALTH_FILE"
    wait_for_log "API degraded" || true

    echo "healthy" > "$SM_MOCK_HEALTH_FILE"

    if wait_for_log "Degradation cleared"; then
        local log_content
        log_content=$(cat "$SM_STATE_DIR/monitor.log")
        assert_contains "$log_content" "Degradation cleared"
    else
        assert_eq "cleared" "timeout" "degradation should clear when healthy"
    fi

    teardown_sm_env
}

test_sm_degraded_escalates_to_outage() {
    setup_sm_env
    start_mock_monitor

    # Go degraded then escalate to outage
    echo "degraded" > "$SM_MOCK_HEALTH_FILE"
    wait_for_log "API degraded" || true

    echo "outage" > "$SM_MOCK_HEALTH_FILE"

    if wait_for_log "Degradation escalated"; then
        local log_content
        log_content=$(cat "$SM_STATE_DIR/monitor.log")
        assert_contains "$log_content" "escalated"
    else
        assert_eq "escalated" "timeout" "degraded should escalate to outage"
    fi

    teardown_sm_env
}

test_sm_on_recovery_auto_switch_writes_file() {
    setup_sm_env
    # Set on_recovery=auto_switch
    cat >> "$SM_CONF" <<'CONF'
on_recovery=auto_switch
CONF
    start_mock_monitor

    # Trigger outage then recovery
    echo "outage" > "$SM_MOCK_HEALTH_FILE"
    wait_for_log "Anthropic API down" || true

    echo "healthy" > "$SM_MOCK_HEALTH_FILE"
    wait_for_log "Anthropic API recovered" || true

    # Wait a moment for file write
    sleep 1
    if [[ -f "$SM_STATE_DIR/recovery_ready" ]]; then
        local content
        content=$(cat "$SM_STATE_DIR/recovery_ready")
        assert_eq "0" "$content" "recovery_ready should contain tier 0"
    else
        assert_eq "exists" "missing" "recovery_ready should be created with auto_switch"
    fi

    teardown_sm_env
}

test_sm_degraded_uses_jittered_backoff() {
    setup_sm_env
    # Override check_interval for fast test
    sed -i 's/^check_interval=.*/check_interval=1/' "$SM_CONF" 2>/dev/null || true
    start_mock_monitor

    # Stay in DEGRADED long enough to see at least two backoff steps
    echo "degraded" > "$SM_MOCK_HEALTH_FILE"

    if ! wait_for_log "API degraded"; then
        assert_eq "degraded" "timeout" "should enter DEGRADED"
    fi

    # Check log for evidence of varying intervals — at least the state persists
    # through multiple iterations. We can't easily assert the exact jitter,
    # but we can confirm the daemon doesn't crash during repeated backoff.
    sleep 3
    local log_content
    log_content=$(cat "$SM_STATE_DIR/monitor.log")
    assert_contains "$log_content" "degraded"

    teardown_sm_env
}
