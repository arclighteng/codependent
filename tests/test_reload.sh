#!/usr/bin/env bash
# tests/test_reload.sh — reload_config behavior

source "$PROJECT_ROOT/lib.sh"

_make_conf() {
    local f; f=$(mktemp)
    cat > "$f" <<'CONF'
check_interval=30
health_check=status_page
recovery_successes=10
recovery_window=12
failure_window=4
degraded_threshold=600
on_recovery=notify
on_failure=notify
notify_method=both
max_log_size=1048576
network_check_url=https://1.1.1.1
CONF
    echo "$f"
}

test_reload_config_swaps_valid_values() {
    local conf; conf=$(_make_conf)
    load_config "$conf"
    local old_interval="${CFG_check_interval}"

    # Mutate config file
    sed -i 's/^check_interval=.*/check_interval=45/' "$conf" 2>/dev/null || \
        (tmp=$(mktemp); sed 's/^check_interval=.*/check_interval=45/' "$conf" > "$tmp"; mv "$tmp" "$conf")

    reload_config "$conf"
    assert_eq "45" "${CFG_check_interval}" "reload must update CFG_check_interval"
    rm -f "$conf"
}

test_reload_config_rejects_invalid() {
    local conf; conf=$(_make_conf)
    load_config "$conf"
    local old="${CFG_check_interval}"

    # Write invalid value
    sed -i 's/^check_interval=.*/check_interval=not-a-number/' "$conf" 2>/dev/null || \
        (tmp=$(mktemp); sed 's/^check_interval=.*/check_interval=not-a-number/' "$conf" > "$tmp"; mv "$tmp" "$conf")

    reload_config "$conf" 2>/dev/null || true
    assert_eq "$old" "${CFG_check_interval}" "invalid reload must keep old value"
    rm -f "$conf"
}

# This test requires a running monitor — uses the same mock harness as
# test_state_machine.sh. For simplicity, we invoke a minimal subshell with
# the trap installed.

test_sighup_triggers_reload() {
    local conf; conf=$(_make_conf)
    local marker; marker=$(mktemp)

    # Background script that sources lib.sh, installs trap, and writes a marker
    # to the file when SIGHUP is received.
    (
        source "$PROJECT_ROOT/lib.sh"
        load_config "$conf"
        trap 'reload_config "'"$conf"'" >/dev/null 2>&1; echo reloaded >> "'"$marker"'"' HUP
        # Sleep long enough to receive a signal
        for _ in {1..20}; do sleep 0.2; done
    ) &
    local pid=$!

    # Give it a moment to install the trap
    sleep 0.5

    # Update config and send SIGHUP
    sed -i 's/^check_interval=.*/check_interval=77/' "$conf" 2>/dev/null || \
        (tmp=$(mktemp); sed 's/^check_interval=.*/check_interval=77/' "$conf" > "$tmp"; mv "$tmp" "$conf")
    kill -HUP "$pid" 2>/dev/null || true

    # Wait for marker
    for _ in {1..25}; do
        [[ -s "$marker" ]] && break
        sleep 0.2
    done

    assert_contains "$(cat "$marker" 2>/dev/null)" "reloaded"

    kill "$pid" 2>/dev/null || true
    rm -f "$conf" "$marker"
}
