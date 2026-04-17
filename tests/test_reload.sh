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
