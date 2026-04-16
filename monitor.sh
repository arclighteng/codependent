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
                kill "$(cat "$STATE_DIR/monitor.pid")" 2>/dev/null && echo "Monitor stopped." || echo "Monitor not running."
                rm -f "$STATE_DIR/monitor.pid"
            else
                echo "Monitor not running."
            fi
            exit 0
            ;;
        *) shift ;;
    esac
done

load_config "$CONFIG_FILE"
detect_platform

mkdir -p "$STATE_DIR"

# Singleton check
PID_FILE="$STATE_DIR/monitor.pid"
if [[ -f "$PID_FILE" ]]; then
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Monitor already running (PID $existing_pid)" >&2
        exit 1
    fi
fi

# Write PID
echo $$ > "$PID_FILE"

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

LOG_FILE="$STATE_DIR/monitor.log"

sliding_window_init "${CFG_recovery_window:-12}"

notify "Monitor started (PID $$, state=$DAEMON_STATE)" "$LOG_FILE"

# --- Main Loop ---
# IMPORTANT: No `local` keyword anywhere in this loop — local is only valid inside functions

while true; do
    sleep "$CURRENT_INTERVAL"

    # Heartbeat check — self-terminate if stale
    if [[ -f "$STATE_DIR/monitor.heartbeat" ]]; then
        hb_mtime=$(stat -c %Y "$STATE_DIR/monitor.heartbeat" 2>/dev/null || stat -f %m "$STATE_DIR/monitor.heartbeat" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - hb_mtime))
        if ((age > ${CFG_heartbeat_timeout:-600})); then
            notify "Heartbeat stale (${age}s). Self-terminating." "$LOG_FILE"
            exit 0
        fi
    fi

    # Health check
    network_status="up"
    if ! check_network; then
        network_status="down"
    fi

    status_indicator="unknown"
    if [[ "$network_status" == "up" ]]; then
        status_indicator=$(check_status_page)
    fi

    health=$(classify_health "$network_status" "$status_indicator")

    # Map health to sliding window value
    check_val=0
    [[ "$health" == "healthy" ]] && check_val=1

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
                    for tline in "${TIERS[@]}"; do
                        parse_tier_line "$tline"
                        [[ "$TIER_id" == "sidecar" ]] && continue
                        [[ "$TIER_id" == "0" ]] && continue
                        if check_tier_prerequisites 2>/dev/null; then
                            next_tier_msg="Tier $TIER_id ($TIER_tool)"
                            break
                        fi
                    done

                    msg="Anthropic API down. Next available: $next_tier_msg. Run: fallback.sh $TIER_id"
                    notify "$msg" "$LOG_FILE"
                    notify_dispatch "$msg"

                    # Write failover_ready if configured
                    if [[ "${CFG_on_failure:-notify}" == "auto_failover" || "${CFG_on_failure:-notify}" == "both" ]]; then
                        echo "$TIER_id" > "$STATE_DIR/failover_ready"
                    fi
                fi
            elif [[ "$health" == "degraded" ]]; then
                DAEMON_STATE="DEGRADED"
                DEGRADED_STARTED=$(date +%s)
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "API degraded (status: $status_indicator). Monitoring." "$LOG_FILE"
                notify_dispatch "Anthropic API degraded — rate limited. Monitoring."
            fi
            ;;

        DEGRADED)
            if [[ "$health" == "healthy" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "Degradation cleared. Resuming normal monitoring." "$LOG_FILE"
            elif [[ "$health" == "outage" || "$health" == "network_down" ]]; then
                DAEMON_STATE="MONITORING_RECOVERY"
                OUTAGE_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                notify "Degradation escalated to outage." "$LOG_FILE"
                notify_dispatch "Anthropic API: degradation escalated to full outage."
                continue  # Skip backoff — already escalated
            else
                # Still degraded — check if past threshold
                now=$(date +%s)
                degraded_duration=$((now - DEGRADED_STARTED))
                if ((degraded_duration > ${CFG_degraded_threshold:-600})); then
                    DAEMON_STATE="MONITORING_RECOVERY"
                    OUTAGE_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
                    notify "Sustained degradation (${degraded_duration}s). Escalating to failover." "$LOG_FILE"
                    notify_dispatch "Anthropic API degraded for ${degraded_duration}s. Consider switching: fallback.sh 1"
                    continue  # Skip backoff — already escalated
                fi
                # Exponential backoff
                CURRENT_INTERVAL=$((CURRENT_INTERVAL * 2))
                max_interval=300
                ((CURRENT_INTERVAL > max_interval)) && CURRENT_INTERVAL=$max_interval
            fi
            ;;

        MONITORING_RECOVERY)
            if [[ "$(sliding_window_check_recovery "${CFG_recovery_successes:-10}" "${CFG_recovery_window:-12}")" == "true" ]]; then
                DAEMON_STATE="WATCHING"
                CURRENT_INTERVAL="${CFG_check_interval:-30}"
                recovered_at=$(date '+%Y-%m-%dT%H:%M:%S')

                notify "Anthropic API recovered." "$LOG_FILE"
                notify_dispatch "$(build_recovery_message)"

                # Clean up failover_ready
                rm -f "$STATE_DIR/failover_ready"

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
