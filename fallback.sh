#!/usr/bin/env bash
# codependent — tiered AI coding assistant failover
# Usage: fallback.sh [status|--dry-run|--test|TIER_NUMBER]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Functions ---

show_status() {
    local state_dir="${1:-${STATE_DIR:-$CODEPENDENT_ROOT/state}}"
    echo "codependent — fallback status"
    echo ""

    for line in "${TIERS[@]}"; do
        parse_tier_line "$line"
        local status="✗"
        local reason=""
        if check_tier_prerequisites 2>/dev/null; then
            status="✓"
            reason="ready"
        else
            reason=$(check_tier_prerequisites 2>&1 || true)
        fi
        printf "  Tier %-7s %-10s %s %s\n" "$TIER_id" "$TIER_tool" "$status" "$reason"
    done

    echo ""

    # Monitor status
    local pid_file="$state_dir/monitor.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Monitor: running (PID $pid)"
            if [[ -f "$state_dir/monitor.heartbeat" ]]; then
                local hb_age
                hb_age=$(( $(date +%s) - $(stat -c %Y "$state_dir/monitor.heartbeat" 2>/dev/null || stat -f %m "$state_dir/monitor.heartbeat" 2>/dev/null || echo 0) ))
                echo "Heartbeat: ${hb_age}s ago"
            fi
        else
            echo "Monitor: stale PID file (process $pid not running)"
        fi
    else
        echo "Monitor: not running"
    fi

    # Current tier
    local current
    current=$(read_state "$state_dir")
    if [[ -n "$current" ]]; then
        echo "Active tier: $current"
    fi

    # Failover ready
    if [[ -f "$state_dir/failover_ready" ]]; then
        echo ""
        echo "⚡ Failover recommendation ready: $(cat "$state_dir/failover_ready")"
        echo "   Run the suggested command, or dismiss with: rm $state_dir/failover_ready"
    fi
}

dry_run_tiers() {
    local state_dir="${1:-${STATE_DIR:-$CODEPENDENT_ROOT/state}}"
    echo "codependent — dry run"
    echo ""

    for line in "${TIERS[@]}"; do
        parse_tier_line "$line"
        if check_tier_prerequisites 2>/dev/null; then
            echo "  Tier $TIER_id ($TIER_tool): ✓ ready — would run: $TIER_command"
        else
            local reason
            reason=$(check_tier_prerequisites 2>&1 || true)
            echo "  Tier $TIER_id ($TIER_tool): ✗ skip — $reason"
        fi
    done
}

run_tests() {
    echo "codependent — full system test"
    echo ""

    # Test each tier
    dry_run_tiers

    echo ""
    echo "Notification test:"
    notify_toast "codependent test notification" "codependent"
    echo "  Toast sent (check your notifications)"
    notify_terminal
    echo "  Terminal bell sent"

    echo ""
    echo "Config:"
    if validate_config 2>/dev/null; then
        echo "  ✓ resilience.conf valid"
    else
        echo "  ✗ resilience.conf has errors:"
        validate_config 2>&1 | sed 's/^/    /'
    fi
}

walk_tiers() {
    local start_tier="${1:-}"
    local state_dir="${STATE_DIR:-$CODEPENDENT_ROOT/state}"
    local started=false

    # Check for failover_ready recommendation
    if [[ -z "$start_tier" && -f "$state_dir/failover_ready" ]]; then
        start_tier=$(cat "$state_dir/failover_ready" | head -1)
        rm -f "$state_dir/failover_ready"
    fi

    for line in "${TIERS[@]}"; do
        parse_tier_line "$line"

        # Skip sidecar — never auto-launched
        [[ "$TIER_id" == "sidecar" ]] && continue

        # If start_tier specified, skip until we reach it
        if [[ -n "$start_tier" && "$started" == "false" ]]; then
            [[ "$TIER_id" == "$start_tier" ]] && started=true || continue
        fi

        if check_tier_prerequisites 2>/dev/null; then
            echo "Activating Tier $TIER_id: $TIER_tool"
            write_state "$TIER_id" "$state_dir"
            touch "$state_dir/monitor.heartbeat"
            start_monitor
            # Replace this process with the tool
            exec $TIER_command
        else
            echo "Tier $TIER_id ($TIER_tool): skipping — $(check_tier_prerequisites 2>&1 || true)"
        fi
    done

    echo ""
    echo "All tiers exhausted. No AI coding assistant available."
    echo "Run 'fallback.sh status' to see what needs setup."
    exit 1
}

# --- Main (only when executed directly) ---

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    load_config
    detect_platform
    load_tiers

    STATE_DIR="$CODEPENDENT_ROOT/state"
    mkdir -p "$STATE_DIR"

    case "${1:-}" in
        status)
            show_status
            ;;
        --dry-run)
            dry_run_tiers
            ;;
        --test)
            run_tests
            ;;
        "")
            walk_tiers
            ;;
        *)
            # Assume it's a tier number
            walk_tiers "$1"
            ;;
    esac
fi
