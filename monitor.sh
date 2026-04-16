#!/usr/bin/env bash
# codependent — background health monitor daemon
# Usage: monitor.sh [--state-dir DIR] [--config FILE] [stop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Parse args
STATE_DIR="$CODEPENDENT_ROOT/state"
CONFIG_FILE="$CODEPENDENT_ROOT/resilience.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --config)    CONFIG_FILE="$2"; shift 2 ;;
        stop)
            if [[ -f "$STATE_DIR/monitor.pid" ]]; then
                pid=$(cat "$STATE_DIR/monitor.pid")
                if kill "$pid" 2>/dev/null; then
                    # Wait up to 10s for graceful shutdown — `sleep` inside
                    # the monitor blocks SIGTERM processing on some platforms
                    # (notably Windows Git Bash), so give it time to drain
                    # before escalating to SIGKILL.
                    for _ in {1..50}; do
                        kill -0 "$pid" 2>/dev/null || break
                        sleep 0.2
                    done
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -KILL "$pid" 2>/dev/null || true
                        echo "Monitor stopped (forced)."
                    else
                        echo "Monitor stopped."
                    fi
                else
                    echo "Monitor not running."
                fi
                rm -f "$STATE_DIR/monitor.pid"
            else
                echo "Monitor not running."
            fi
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

load_config "$CONFIG_FILE"
detect_platform

mkdir -p "$STATE_DIR"

# Singleton check (atomic via noclobber)
PID_FILE="$STATE_DIR/monitor.pid"
if [[ -f "$PID_FILE" ]]; then
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Monitor already running (PID $existing_pid)" >&2
        exit 1
    fi
    rm -f "$PID_FILE"
fi

# Write PID atomically — prevents TOCTOU race with concurrent starts
if ! ( set -o noclobber; echo $$ > "$PID_FILE" ) 2>/dev/null; then
    echo "Monitor already running (lost PID race)" >&2
    exit 1
fi

# Cleanup on exit
cleanup() {
    rm -f "$PID_FILE"
}
trap cleanup EXIT INT TERM

# State machine
DAEMON_STATE="WATCHING"
OUTAGE_STARTED=""
DEGRADED_STARTED=""
CURRENT_INTERVAL="${CFG_check_interval:-30}"
consecutive_network_failures=0

LOG_FILE="$STATE_DIR/monitor.log"

sliding_window_init "${CFG_recovery_window:-12}"

notify "Monitor started (PID $$, state=$DAEMON_STATE)" "$LOG_FILE"

# --- Main Loop ---
# IMPORTANT: No `local` keyword anywhere in this loop — local is only valid inside functions

while true; do
    sleep "$CURRENT_INTERVAL"

    # No self-heartbeat — the daemon runs until explicitly stopped (monitor.sh stop)
    # or killed. Liveness is checked via PID in show_status.

    # Health check
    network_status="up"
    if ! check_network; then
        network_status="down"
    fi

    status_indicator="unknown"
    if [[ "$network_status" == "up" ]]; then
        status_indicator=$(check_status_page)
    fi

    # Track network-failure streak for adaptive backoff in WATCHING
    if [[ "$network_status" == "down" ]]; then
        consecutive_network_failures=$((consecutive_network_failures + 1))
        CURRENT_INTERVAL=$(next_check_interval "${CFG_check_interval:-30}" "$consecutive_network_failures")
    else
        consecutive_network_failures=0
        CURRENT_INTERVAL="${CFG_check_interval:-30}"
    fi

    health=$(classify_health "$network_status" "$status_indicator")

    # Map health to sliding window value
    # Note: `[[ ]] && x=y` would trigger set -e on false; use explicit if
    if [[ "$health" == "healthy" ]]; then
        check_val=1
    else
        check_val=0
    fi

    sliding_window_push "$check_val"

    # State machine transitions
    case "$DAEMON_STATE" in
        WATCHING)
            if [[ "$health" == "network_down" || "$health" == "outage" ]]; then
                if [[ "$(sliding_window_check_failure "${CFG_failure_window:-4}")" == "true" ]]; then
                    DAEMON_STATE="MONITORING_RECOVERY"
                    OUTAGE_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
                    CURRENT_INTERVAL="${CFG_check_interval:-30}"

                    # Find next available tier for the message
                    load_tiers
                    next_tier_msg="no tier available"
                    next_tier_id=""
                    for tline in "${TIERS[@]}"; do
                        parse_tier_line "$tline"
                        [[ "$TIER_id" == "sidecar" ]] && continue
                        [[ "$TIER_id" == "0" ]] && continue
                        if check_tier_prerequisites 2>/dev/null; then
                            next_tier_id="$TIER_id"
                            next_tier_msg="Tier $TIER_id ($TIER_tool)"
                            break
                        fi
                    done

                    if [[ -n "$next_tier_id" ]]; then
                        msg="Anthropic API down. Next available: $next_tier_msg. Run: fallback.sh $next_tier_id"
                    else
                        msg="Anthropic API down. No fallback tier available."
                    fi

                    # Write failover_ready BEFORE logging so observers that
                    # react to the log entry find the state file in place.
                    if [[ -n "$next_tier_id" ]]; then
                        if [[ "${CFG_on_failure:-notify}" == "auto_failover" || "${CFG_on_failure:-notify}" == "both" ]]; then
                            echo "$next_tier_id" > "$STATE_DIR/failover_ready"
                        fi
                    fi

                    notify "$msg" "$LOG_FILE"
                    notify_dispatch "$msg"
                fi
            elif [[ "$health" == "degraded" ]]; then
                DAEMON_STATE="DEGRADED"
                DEGRADED_STARTED=$(date +%s)
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "API degraded (status: $status_indicator). Monitoring." "$LOG_FILE"
                notify_dispatch "$(build_degraded_message)"
            fi
            ;;

        DEGRADED)
            if [[ "$health" == "healthy" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "Degradation cleared. Resuming normal monitoring." "$LOG_FILE"
            elif [[ "$health" == "outage" || "$health" == "network_down" ]]; then
                DAEMON_STATE="MONITORING_RECOVERY"
                # Use degradation start time so metrics capture the full impact window
                OUTAGE_STARTED=$(date -d "@$DEGRADED_STARTED" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -r "$DEGRADED_STARTED" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "Degradation escalated to outage." "$LOG_FILE"
                notify_dispatch "Anthropic API: degradation escalated to full outage. Run: fallback.sh"
                continue  # Skip backoff — already escalated
            else
                # Still degraded — check if past threshold
                now=$(date +%s)
                degraded_duration=$((now - DEGRADED_STARTED))
                if ((degraded_duration > ${CFG_degraded_threshold:-600})); then
                    DAEMON_STATE="MONITORING_RECOVERY"
                    OUTAGE_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
                    notify "Sustained degradation (${degraded_duration}s). Escalating to failover." "$LOG_FILE"
                    notify_dispatch "Anthropic API degraded for ${degraded_duration}s. Run: fallback.sh"
                    continue  # Skip backoff — already escalated
                fi
                # Jittered exponential backoff with 300s cap.
                # Compute from base, using observed degraded_duration / base as failure count.
                base="${CFG_check_interval:-30}"
                deg_failures=$(( degraded_duration / base ))
                if (( deg_failures < 0 )); then deg_failures=0; fi
                CURRENT_INTERVAL=$(next_check_interval "$base" "$deg_failures")
            fi
            ;;

        MONITORING_RECOVERY)
            if [[ "$(sliding_window_check_recovery "${CFG_recovery_successes:-10}" "${CFG_recovery_window:-12}")" == "true" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                recovered_at=$(date '+%Y-%m-%dT%H:%M:%S')

                # Write state files BEFORE logging so observers that react to
                # the "recovered" log entry see the state in its final shape.
                case "${CFG_on_recovery:-notify}" in
                    auto_switch|both)
                        echo "0" > "$STATE_DIR/recovery_ready"
                        ;;
                esac

                # Clean up failover_ready
                rm -f "$STATE_DIR/failover_ready"

                notify "Anthropic API recovered." "$LOG_FILE"

                # Handle on_recovery notifications
                case "${CFG_on_recovery:-notify}" in
                    notify|both)
                        notify_dispatch "$(build_recovery_message)"
                        ;;
                esac

                # Log metrics
                if [[ -n "$OUTAGE_STARTED" ]]; then
                    start_epoch=$(date_to_epoch "$OUTAGE_STARTED")
                    end_epoch=$(date +%s)
                    duration=$(( (end_epoch - start_epoch) / 60 ))
                    log_metrics "$OUTAGE_STARTED" "$recovered_at" "$duration" "outage" \
                        "$(read_state "$STATE_DIR")" "monitor" "true" "$PLATFORM" "$STATE_DIR"
                fi
                OUTAGE_STARTED=""
            fi
            ;;
    esac

    # Log rotation
    rotate_log "$LOG_FILE"
done
