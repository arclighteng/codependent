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
        echo "⚡ Failover recommendation ready: Tier $(cat "$state_dir/failover_ready")"
        echo "   Run the suggested command, or dismiss with: rm $state_dir/failover_ready"
    fi

    # Recovery ready
    if [[ -f "$state_dir/recovery_ready" ]]; then
        echo ""
        echo "✓ Recovery detected — Claude Code is back. Run: fallback.sh 0"
        echo "   Dismiss with: rm $state_dir/recovery_ready"
    fi
}

show_history() {
    local limit=20
    local since=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                shift
                if [[ ! "${1:-}" =~ ^[1-9][0-9]*$ ]] || (( ${1:-0} > 1000 )); then
                    echo "history: --limit must be a positive integer (1..1000)" >&2
                    exit 1
                fi
                limit="$1"; shift
                ;;
            --since)
                shift
                if [[ ! "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                    echo "history: --since must match YYYY-MM-DD" >&2
                    exit 1
                fi
                since="$1"; shift
                ;;
            *)
                echo "history: unknown flag: $1" >&2
                echo "usage: fallback.sh history [--limit N] [--since YYYY-MM-DD]" >&2
                exit 1
                ;;
        esac
    done

    _render_history "$limit" "$since"
}

_render_history() {
    # SECURITY NOTE: $since is interpolated into SQL strings below. The arg
    # parser (show_history) rejects anything that doesn't match
    # ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ so the only bytes that reach this function
    # are ASCII digits and two hyphens. This regex is the full boundary; do
    # not relax it without re-reviewing the SQL builders.
    local limit="$1"
    local since="$2"
    local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"

    echo "codependent — fallback history"
    echo ""

    # Graceful degradation: missing sqlite3
    if ! command -v sqlite3 &>/dev/null; then
        echo "sqlite3 not found — install it to enable history."
        return 0
    fi

    # Graceful degradation: missing or empty DB
    if [[ ! -f "$db" ]]; then
        echo "No history yet — daemon hasn't recorded any events."
        return 0
    fi

    local total
    total=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events;" 2>/dev/null || echo 0)
    if [[ "$total" == "0" || -z "$total" ]]; then
        echo "No history yet — daemon hasn't recorded any events."
        return 0
    fi

    # Summary
    local where=""
    [[ -n "$since" ]] && where="WHERE started_at >= '${since}T00:00:00'"

    local failovers recoveries first_ts now_epoch first_epoch total_secs outage_secs uptime_pct
    failovers=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events $where;" 2>/dev/null || echo 0)
    recoveries=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events $where AND recovered_at IS NOT NULL AND recovered_at != '';" 2>/dev/null || echo 0)
    # Strip "AND" prefix hack if $where was empty: recoveries query needs its own where
    if [[ -z "$where" ]]; then
        recoveries=$(sqlite3 "$db" "SELECT COUNT(*) FROM outage_events WHERE recovered_at IS NOT NULL AND recovered_at != '';" 2>/dev/null || echo 0)
    fi

    first_ts=$(sqlite3 "$db" "SELECT MIN(started_at) FROM outage_events $where;" 2>/dev/null || echo "")

    # Uptime: 1 - (sum of outage_seconds / total_seconds). Needs ≥2 data points.
    local uptime_str="n/a (insufficient data)"
    if [[ -n "$first_ts" && "$total" -ge 2 ]]; then
        first_epoch=$(date_to_epoch "$first_ts" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        total_secs=$((now_epoch - first_epoch))
        outage_secs=$(sqlite3 "$db" "SELECT COALESCE(SUM(duration_minutes * 60), 0) FROM outage_events $where AND recovered_at IS NOT NULL;" 2>/dev/null || echo 0)
        if [[ -z "$where" ]]; then
            outage_secs=$(sqlite3 "$db" "SELECT COALESCE(SUM(duration_minutes * 60), 0) FROM outage_events WHERE recovered_at IS NOT NULL;" 2>/dev/null || echo 0)
        fi
        if (( total_secs > 0 )); then
            # Percentage with 1 decimal. Use awk for float math (bash has none).
            uptime_str=$(awk -v o="$outage_secs" -v t="$total_secs" 'BEGIN { printf "%.1f%%", (1 - o/t) * 100 }')
        fi
    fi

    local since_label="${since:-all time}"
    echo "Summary (last $limit events, since: $since_label):"
    printf "  failovers:  %s\n" "$failovers"
    printf "  recoveries: %s\n" "$recoveries"
    printf "  uptime:     %s\n" "$uptime_str"
    echo ""

    # Table
    local header="STARTED|RECOVERED|DURATION|TYPE|TIER|PLATFORM"
    local rows
    if [[ -n "$since" ]]; then
        rows=$(sqlite3 -separator '|' "$db" "SELECT started_at, COALESCE(recovered_at,'-'), COALESCE(printf('%.1fm', duration_minutes),'-'), failure_type, tier_used, platform FROM outage_events WHERE started_at >= '${since}T00:00:00' ORDER BY started_at DESC LIMIT $limit;" 2>/dev/null)
    else
        rows=$(sqlite3 -separator '|' "$db" "SELECT started_at, COALESCE(recovered_at,'-'), COALESCE(printf('%.1fm', duration_minutes),'-'), failure_type, tier_used, platform FROM outage_events ORDER BY started_at DESC LIMIT $limit;" 2>/dev/null)
    fi

    { echo "$header"; echo "$rows"; } | column -t -s '|'
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

    # Check for recovery_ready — switch back to Tier 0
    if [[ -z "$start_tier" && -f "$state_dir/recovery_ready" ]]; then
        start_tier=$(<"$state_dir/recovery_ready")
        rm -f "$state_dir/recovery_ready"
    fi

    # Check for failover_ready recommendation
    if [[ -z "$start_tier" && -f "$state_dir/failover_ready" ]]; then
        start_tier=$(<"$state_dir/failover_ready")
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
            # Replace this process with the tool (array prevents glob expansion)
            read -ra _cmd <<< "$TIER_command"
            exec "${_cmd[@]}"
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
        history)
            shift
            show_history "$@"
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
