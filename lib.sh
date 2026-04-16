#!/usr/bin/env bash
# codependent — shared functions
# Source this file; do not execute directly.

set -euo pipefail

CODEPENDENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── detect_platform ───────────────────────────────────────────────────────────
# Sets and exports $PLATFORM to one of: macos, windows-git-bash, windows-wsl, linux

detect_platform() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo "Linux")"

  if [[ "$uname_s" == "Darwin" ]]; then
    PLATFORM="macos"
  elif [[ "${MSYSTEM:-}" == MINGW* || "$uname_s" == MSYS* || "$uname_s" == MINGW* ]]; then
    PLATFORM="windows-git-bash"
  elif [[ "$uname_s" == "Linux" && -n "${WSL_DISTRO_NAME:-}" ]]; then
    PLATFORM="windows-wsl"
  else
    PLATFORM="linux"
  fi

  export PLATFORM
}

# ── load_config ───────────────────────────────────────────────────────────────
# Usage: load_config [path]
# Reads key=value pairs from a config file and sets CFG_<key> variables.
# Defaults to $CODEPENDENT_ROOT/resilience.conf.

load_config() {
  local config_file="${1:-$CODEPENDENT_ROOT/resilience.conf}"

  if [[ ! -f "$config_file" ]]; then
    echo "load_config: file not found: $config_file" >&2
    return 1
  fi

  while IFS= read -r line; do
    # Skip blank lines
    [[ -z "${line// }" ]] && continue

    # Skip comment lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Strip inline comments
    local stripped="${line%%#*}"

    # Parse key=value
    if [[ "$stripped" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"

      # Trim trailing whitespace from value
      val="${val%"${val##*[![:space:]]}"}"

      declare -g "CFG_${key}=${val}"
    fi
  done < "$config_file"
}

# ── validate_config ───────────────────────────────────────────────────────────
# Validates loaded CFG_* variables.
# Returns 0 if valid, 1 with error messages to stderr if invalid.

validate_config() {
  local errors=0

  # Enum validations: field -> allowed pipe-separated values
  local -A enum_fields=(
    [health_check]="status_page|api_call|both"
    [on_recovery]="notify|auto_switch|both"
    [on_failure]="notify|auto_failover|both"
    [notify_method]="terminal|toast|both"
  )

  for field in "${!enum_fields[@]}"; do
    local varname="CFG_${field}"
    local val="${!varname:-}"

    if [[ -n "$val" ]]; then
      local allowed="${enum_fields[$field]}"
      # Build a pattern to match exactly one of the allowed values
      if [[ ! "$val" =~ ^(${allowed})$ ]]; then
        echo "validate_config: invalid value for ${field}: '${val}' (allowed: ${allowed})" >&2
        (( errors++ )) || true
      fi
    fi
  done

  # Numeric validations: must be positive integers
  local numeric_fields=(
    check_interval
    recovery_successes
    recovery_window
    failure_window
    degraded_threshold
    heartbeat_timeout
    max_log_size
  )

  for field in "${numeric_fields[@]}"; do
    local varname="CFG_${field}"
    local val="${!varname:-}"

    if [[ -n "$val" ]]; then
      if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
        echo "validate_config: invalid value for ${field}: '${val}' (must be a positive integer)" >&2
        (( errors++ )) || true
      fi
    fi
  done

  if (( errors > 0 )); then
    return 1
  fi
  return 0
}

# --- Stubs (implemented in later tasks) ---
start_monitor() { :; }
stop_monitor() { :; }
