#!/usr/bin/env bash

# Source lib.sh once at file scope (not per-function)
source "$PROJECT_ROOT/lib.sh"

test_check_network_success() {
    curl() { return 0; }
    CFG_network_check_url="https://1.1.1.1"
    local rc=0
    check_network 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "check_network should return 0 when curl succeeds"
    unset -f curl
}

test_check_network_failure() {
    curl() { return 1; }
    CFG_network_check_url="https://1.1.1.1"
    local rc=0
    check_network 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "check_network should return 1 when curl fails"
    unset -f curl
}

test_check_status_page_operational() {
    curl() { echo '{"status":{"indicator":"none","description":"All Systems Operational"}}'; }
    local result
    result=$(check_status_page)
    assert_eq "none" "$result"
    unset -f curl
}

test_check_status_page_major_outage() {
    curl() { echo '{"status":{"indicator":"major","description":"Major System Outage"}}'; }
    local result
    result=$(check_status_page)
    assert_eq "major" "$result"
    unset -f curl
}

test_check_status_page_curl_failure() {
    curl() { return 1; }
    local result
    result=$(check_status_page 2>/dev/null)
    assert_eq "unknown" "$result"
    unset -f curl
}

test_classify_health_healthy() {
    local result
    result=$(classify_health "up" "none")
    assert_eq "healthy" "$result"
}

test_classify_health_network_down() {
    local result
    result=$(classify_health "down" "unknown")
    assert_eq "network_down" "$result"
}

test_classify_health_major_outage() {
    local result
    result=$(classify_health "up" "major")
    assert_eq "outage" "$result"
}

test_classify_health_critical_outage() {
    local result
    result=$(classify_health "up" "critical")
    assert_eq "outage" "$result"
}

test_classify_health_unknown_treated_as_outage() {
    local result
    result=$(classify_health "up" "unknown")
    assert_eq "outage" "$result"
}

test_classify_health_degraded() {
    local result
    result=$(classify_health "up" "minor")
    assert_eq "degraded" "$result"
}
