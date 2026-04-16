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

# ── parse_tier_line ───────────────────────────────────────────────────────────
# Usage: parse_tier_line "<line>"
# Parses one line from tiers.conf (delimited by " | ") and sets:
#   TIER_id, TIER_tool, TIER_command, TIER_required_env, TIER_check_cmd

parse_tier_line() {
  local line="$1"

  TIER_id="$(          echo "$line" | awk -F' [|] ' '{print $1}' | xargs )"
  TIER_tool="$(        echo "$line" | awk -F' [|] ' '{print $2}' | xargs )"
  TIER_command="$(     echo "$line" | awk -F' [|] ' '{print $3}' | xargs )"
  TIER_required_env="$(echo "$line" | awk -F' [|] ' '{print $4}' | xargs )"
  TIER_check_cmd="$(   echo "$line" | awk -F' [|] ' '{print $5}' | xargs )"
}

# ── load_tiers ────────────────────────────────────────────────────────────────
# Usage: load_tiers [path]
# Reads tiers.conf line by line, skipping comments and blanks.
# Stores each valid line in the TIERS array.

load_tiers() {
  local tiers_file="${1:-$CODEPENDENT_ROOT/tiers.conf}"

  if [[ ! -f "$tiers_file" ]]; then
    echo "load_tiers: file not found: $tiers_file" >&2
    return 1
  fi

  TIERS=()

  while IFS= read -r line; do
    # Skip blank lines
    [[ -z "${line// }" ]] && continue

    # Skip comment lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    TIERS+=( "$line" )
  done < "$tiers_file"
}

# ── check_tier_prerequisites ──────────────────────────────────────────────────
# Checks the currently parsed tier (TIER_* variables) for readiness.
# Returns 0 if ready, 1 with a message to stderr if not.

check_tier_prerequisites() {
  # Run the check command (comes from our own config, not user input — eval is safe here)
  if [[ -n "$TIER_check_cmd" ]]; then
    if ! eval "$TIER_check_cmd" > /dev/null 2>&1; then
      echo "check_tier_prerequisites: tool not available for tier '${TIER_id}': ${TIER_check_cmd}" >&2
      return 1
    fi
  fi

  # Check required environment variable
  if [[ -n "$TIER_required_env" ]]; then
    local env_val="${!TIER_required_env:-}"
    if [[ -z "$env_val" ]]; then
      echo "check_tier_prerequisites: required env var '${TIER_required_env}' is not set (tier '${TIER_id}')" >&2
      return 1
    fi
  fi

  return 0
}

# --- Cross-Platform Helpers ---

date_to_epoch() {
    local timestamp="$1"
    # Try GNU date first (Linux, Git Bash)
    date -d "$timestamp" +%s 2>/dev/null && return
    # Try BSD date (macOS)
    date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" +%s 2>/dev/null && return
    # Fallback: extract components and use printf
    echo 0
}

# --- State Management ---

write_state() {
    local tier="$1"
    local state_dir="${2:-$CODEPENDENT_ROOT/state}"
    mkdir -p "$state_dir"
    echo "$tier" > "$state_dir/current_tier"
}

read_state() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local file="$state_dir/current_tier"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo ""
    fi
}

# --- Sliding Window ---

SW_WINDOW=()
SW_INDEX=0
SW_SIZE=0
SW_TOTAL_PUSHED=0

sliding_window_init() {
    local size="$1"
    SW_SIZE="$size"
    SW_INDEX=0
    SW_TOTAL_PUSHED=0
    SW_WINDOW=()
    for ((i = 0; i < size; i++)); do
        SW_WINDOW+=("")
    done
}

sliding_window_push() {
    local value="$1"  # 0=fail, 1=success
    SW_WINDOW[$SW_INDEX]="$value"
    SW_INDEX=$(( (SW_INDEX + 1) % SW_SIZE ))
    ((SW_TOTAL_PUSHED++))
}

sliding_window_check_recovery() {
    local required="$1"
    local window="$2"

    # Cold start: if we haven't filled the window yet,
    # use reduced threshold of 3 consecutive successes
    if ((SW_TOTAL_PUSHED < window)); then
        local consecutive=0
        for ((i = SW_TOTAL_PUSHED - 1; i >= 0; i--)); do
            if [[ "${SW_WINDOW[$i]}" == "1" ]]; then
                ((consecutive++))
            else
                break
            fi
        done
        if ((consecutive >= 3)); then
            echo "true"
        else
            echo "false"
        fi
        return
    fi

    # Normal: count successes in window
    local successes=0
    for val in "${SW_WINDOW[@]}"; do
        [[ "$val" == "1" ]] && ((successes++))
    done
    if ((successes >= required)); then
        echo "true"
    else
        echo "false"
    fi
}

sliding_window_check_failure() {
    local required="$1"

    if ((SW_TOTAL_PUSHED < required)); then
        echo "false"
        return
    fi

    # Check last N entries are all failures
    for ((i = 1; i <= required; i++)); do
        local idx=$(( (SW_INDEX - i + SW_SIZE) % SW_SIZE ))
        if [[ "${SW_WINDOW[$idx]}" != "0" ]]; then
            echo "false"
            return
        fi
    done
    echo "true"
}

# --- Stubs (implemented in later tasks) ---
start_monitor() { :; }
stop_monitor() { :; }
