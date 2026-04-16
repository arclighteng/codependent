#!/usr/bin/env bash
# tests/test_config.sh — tests for lib.sh: platform detection, config parsing, validation

# Source lib.sh (PROJECT_ROOT is exported by runner.sh)
source "$PROJECT_ROOT/lib.sh"

# ── load_config ───────────────────────────────────────────────────────────────

test_load_config_reads_values() {
  local tmpfile
  tmpfile="$(mktemp)"
  printf 'check_interval=30\non_failure=notify\n' > "$tmpfile"

  load_config "$tmpfile"
  rm -f "$tmpfile"

  assert_eq "30"     "$CFG_check_interval" "CFG_check_interval should be 30"
  assert_eq "notify" "$CFG_on_failure"     "CFG_on_failure should be notify"
}

test_load_config_ignores_comments() {
  local tmpfile
  tmpfile="$(mktemp)"
  printf '# this is a comment\ncheck_interval=60\n' > "$tmpfile"

  load_config "$tmpfile"
  rm -f "$tmpfile"

  assert_eq "60" "$CFG_check_interval" "CFG_check_interval should be 60"
}

test_load_config_ignores_blank_lines() {
  local tmpfile
  tmpfile="$(mktemp)"
  printf '\n\ncheck_interval=45\n\n' > "$tmpfile"

  load_config "$tmpfile"
  rm -f "$tmpfile"

  assert_eq "45" "$CFG_check_interval" "CFG_check_interval should be 45"
}

# ── detect_platform ───────────────────────────────────────────────────────────

test_detect_platform_returns_known_value() {
  detect_platform

  local known_values="macos windows-git-bash windows-wsl linux"
  assert_contains "$known_values" "$PLATFORM" \
    "PLATFORM '$PLATFORM' should be one of: $known_values"
}

# ── validate_config ───────────────────────────────────────────────────────────

test_validate_config_accepts_valid() {
  local tmpfile
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
check_interval=30
health_check=status_page
recovery_successes=10
recovery_window=12
failure_window=4
degraded_threshold=600
on_recovery=notify
on_failure=notify
notify_method=both
heartbeat_timeout=600
max_log_size=1048576
EOF

  load_config "$tmpfile"
  rm -f "$tmpfile"

  local result=0
  validate_config 2>/dev/null || result=$?
  assert_eq "0" "$result" "validate_config should return 0 for valid config"
}

test_load_config_missing_file_returns_error() {
  local result=0
  load_config "/nonexistent/path/to/config.conf" 2>/dev/null || result=$?
  assert_eq "1" "$result" "load_config should return 1 for missing file"
}

test_validate_config_rejects_zero_numeric() {
  local tmpfile
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
check_interval=0
EOF

  load_config "$tmpfile"
  rm -f "$tmpfile"

  local result=0
  validate_config 2>/dev/null || result=$?
  assert_eq "1" "$result" "validate_config should reject 0 for check_interval"
}

test_validate_config_rejects_invalid_local_model() {
  local tmpfile
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
local_model=gemma3 --evil-flag
EOF

  load_config "$tmpfile"
  rm -f "$tmpfile"

  local result=0
  validate_config 2>/dev/null || result=$?
  assert_eq "1" "$result" "validate_config should reject local_model with spaces"
}

test_validate_config_rejects_invalid_on_failure() {
  local tmpfile
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
check_interval=30
health_check=status_page
recovery_successes=10
recovery_window=12
failure_window=4
degraded_threshold=600
on_recovery=notify
on_failure=notfy
notify_method=both
heartbeat_timeout=600
max_log_size=1048576
EOF

  load_config "$tmpfile"
  rm -f "$tmpfile"

  local result=0
  validate_config 2>/dev/null || result=$?
  assert_eq "1" "$result" "validate_config should return 1 for on_failure=notfy (typo)"
}
