#!/usr/bin/env bash

test_check_network_success() {
    source "$PROJECT_ROOT/lib.sh"
    # Mock curl to succeed
    curl() { return 0; }
    CFG_network_check_url="https://1.1.1.1"
    local result
    result=$(check_network)
    assert_eq "0" "$?" 2>/dev/null || assert_eq "up" "$result"
    unset -f curl
}

test_check_network_failure() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { return 1; }
    CFG_network_check_url="https://1.1.1.1"
    if check_network 2>/dev/null; then
        assert_true "false" "should fail when curl fails"
    else
        assert_true "0" "correctly detected network down"
    fi
    unset -f curl
}

test_check_status_page_operational() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { echo '{"status":{"indicator":"none","description":"All Systems Operational"}}'; }
    local result
    result=$(check_status_page)
    assert_eq "none" "$result"
    unset -f curl
}

test_check_status_page_major_outage() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { echo '{"status":{"indicator":"major","description":"Major System Outage"}}'; }
    local result
    result=$(check_status_page)
    assert_eq "major" "$result"
    unset -f curl
}

test_check_status_page_curl_failure() {
    source "$PROJECT_ROOT/lib.sh"
    curl() { return 1; }
    local result
    result=$(check_status_page 2>/dev/null)
    assert_eq "unknown" "$result"
    unset -f curl
}

test_classify_health_all_good() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "up" "none")
    assert_eq "healthy" "$result"
}

test_classify_health_network_down() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "down" "unknown")
    assert_eq "network_down" "$result"
}

test_classify_health_api_outage() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "up" "major")
    assert_eq "outage" "$result"
}

test_classify_health_degraded() {
    source "$PROJECT_ROOT/lib.sh"
    local result
    result=$(classify_health "up" "minor")
    assert_eq "degraded" "$result"
}
