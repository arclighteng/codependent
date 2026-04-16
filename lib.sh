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

  # Model name validation: no spaces or shell metacharacters
  local model_val="${CFG_local_model:-}"
  if [[ -n "$model_val" && ! "$model_val" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "validate_config: invalid value for local_model: '${model_val}' (must match [A-Za-z0-9._:-]+)" >&2
    (( errors++ )) || true
  fi

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

  # Expand config variables in the command (e.g., $local_model → gemma3)
  TIER_command="${TIER_command//\$local_model/${CFG_local_model:-}}"
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
    if [[ $SW_SIZE -le 0 ]]; then
        echo "sliding_window_push: not initialised (call sliding_window_init first)" >&2
        return 1
    fi
    local value="$1"  # 0=fail, 1=success
    SW_WINDOW[$SW_INDEX]="$value"
    SW_INDEX=$(( (SW_INDEX + 1) % SW_SIZE ))
    # Use $((x + 1)) not ((x++)) — under set -e, ((0++)) returns exit 1 and kills script
    SW_TOTAL_PUSHED=$((SW_TOTAL_PUSHED + 1))
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
                consecutive=$((consecutive + 1))
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
        if [[ "$val" == "1" ]]; then
            successes=$((successes + 1))
        fi
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

# --- Health Checks ---

check_network() {
    if curl -sf --max-time 5 "${CFG_network_check_url:-https://1.1.1.1}" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

check_status_page() {
    local response
    if ! response=$(curl -sf --max-time 10 "https://status.anthropic.com/api/v2/status.json" 2>/dev/null); then
        echo "unknown"
        return
    fi
    # Extract indicator without jq — parse "indicator":"value"
    local indicator
    indicator=$(echo "$response" | grep -o '"indicator":"[^"]*"' | head -1 | sed 's/^"indicator":"//; s/"$//')
    if [[ -n "$indicator" ]]; then
        echo "$indicator"
    else
        echo "unknown"
    fi
}

classify_health() {
    local network="$1"    # up | down
    local indicator="$2"  # none | minor | major | critical | unknown

    if [[ "$network" == "down" ]]; then
        echo "network_down"
        return
    fi

    case "$indicator" in
        none)              echo "healthy" ;;
        minor)             echo "degraded" ;;
        major|critical)    echo "outage" ;;
        *)                 echo "outage" ;;  # unknown = assume outage
    esac
}

# --- Notifications ---

notify() {
    local message="$1"
    local log_file="${2:-$CODEPENDENT_ROOT/state/monitor.log}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$log_file")"
    echo "[$timestamp] $message" >> "$log_file"
}

notify_toast() {
    local message="$1"
    local title="${2:-codependent}"

    # Sanitize inputs to prevent shell/PowerShell injection
    # Strip characters that break out of quoted contexts
    message="${message//\`/}"
    message="${message//\$/}"
    message="${message//\"/}"
    title="${title//\`/}"
    title="${title//\$/}"
    title="${title//\"/}"
    # Escape single quotes for PowerShell single-quoted strings ('' = literal ')
    message="${message//\'/\'\'}"
    title="${title//\'/\'\'}"

    case "${PLATFORM:-}" in
        macos)
            osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
            ;;
        windows-git-bash|windows-wsl)
            # Try native Windows notifications via PowerShell
            if powershell.exe -NoProfile -Command "
                Add-Type -AssemblyName System.Windows.Forms
                \$n = New-Object System.Windows.Forms.NotifyIcon
                \$n.Icon = [System.Drawing.SystemIcons]::Information
                \$n.Visible = \$true
                \$n.ShowBalloonTip(5000, '$title', '$message', 'Info')
                Start-Sleep -Seconds 1
                \$n.Dispose()
            " 2>/dev/null; then
                return 0
            fi
            # Fallback: BurntToast
            if powershell.exe -NoProfile -Command "
                Import-Module BurntToast 2>\$null
                if (\$?) { New-BurntToastNotification -Text '$title','$message' }
                else { exit 1 }
            " 2>/dev/null; then
                return 0
            fi
            # Final fallback: bell
            notify_terminal
            ;;
        *)
            notify_terminal
            ;;
    esac
}

notify_terminal() {
    printf '\a' 2>/dev/null || true
}

notify_dispatch() {
    local message="$1"
    local log_file="${2:-$CODEPENDENT_ROOT/state/monitor.log}"

    # Always log
    notify "$message" "$log_file"

    case "${CFG_notify_method:-both}" in
        toast)    notify_toast "$message" ;;
        terminal) notify_terminal ;;
        both)     notify_toast "$message"; notify_terminal ;;
    esac
}

build_outage_message() {
    echo "Anthropic API down. Next available: Tier ${TIER_id} (${TIER_tool}). Run: fallback.sh ${TIER_id}"
}

build_recovery_message() {
    echo "Anthropic API recovered — stable. Switch back with: fallback.sh 0"
}

build_degraded_message() {
    echo "Anthropic API degraded — rate limited. Monitor with: fallback.sh status"
}

# --- Metrics ---

log_metrics() {
    local started_at="$1"
    local recovered_at="${2:-}"
    local duration_minutes="${3:-}"
    local failure_type="$4"
    local tier_used="$5"
    local tool_used="$6"
    local auto_recovered="${7:-false}"
    local platform="${8:-$PLATFORM}"
    local state_dir="${9:-$CODEPENDENT_ROOT/state}"

    mkdir -p "$state_dir"

    # Escape single quotes for SQL safety
    started_at="${started_at//\'/\'\'}"
    recovered_at="${recovered_at//\'/\'\'}"
    failure_type="${failure_type//\'/\'\'}"
    tier_used="${tier_used//\'/\'\'}"
    tool_used="${tool_used//\'/\'\'}"
    platform="${platform//\'/\'\'}"

    # Try sqlite3 first
    if command -v sqlite3 &>/dev/null && [[ "${CFG_log_to_metrics:-true}" == "true" ]]; then
        local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"

        if sqlite3 "$db" <<SQL 2>/dev/null
CREATE TABLE IF NOT EXISTS outage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    recovered_at TEXT,
    duration_minutes REAL,
    failure_type TEXT NOT NULL,
    tier_used TEXT NOT NULL,
    tool_used TEXT NOT NULL,
    auto_recovered BOOLEAN DEFAULT FALSE,
    platform TEXT NOT NULL
);
INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform)
VALUES ('$started_at', '$recovered_at', '$duration_minutes', '$failure_type', '$tier_used', '$tool_used', '$auto_recovered', '$platform');
SQL
        then
            # Current row succeeded — now drain any pending CSV rows
            import_csv_to_db "$state_dir"
            return 0
        fi
    fi

    # CSV fallback
    local csv="$state_dir/metrics.csv"
    if [[ ! -f "$csv" ]]; then
        echo "started_at,recovered_at,duration_minutes,failure_type,tier_used,tool_used,auto_recovered,platform" > "$csv"
    fi
    printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$started_at" "$recovered_at" "$duration_minutes" "$failure_type" \
        "$tier_used" "$tool_used" "$auto_recovered" "$platform" >> "$csv"
}

import_csv_to_db() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local csv="$state_dir/metrics.csv"

    [[ -f "$csv" ]] || return 0
    command -v sqlite3 &>/dev/null || return 0

    local db="${CODEPENDENT_DB:-$HOME/.claude/csuite.db}"
    local header=""
    header=$(head -1 "$csv")

    # Skip header line, import each row
    # CSV fields are double-quoted; strip quotes before processing
    while IFS=, read -r started_at recovered_at duration_minutes failure_type tier_used tool_used auto_recovered platform; do
        # Strip surrounding double quotes from each field
        started_at="${started_at//\"/}"
        recovered_at="${recovered_at//\"/}"
        duration_minutes="${duration_minutes//\"/}"
        failure_type="${failure_type//\"/}"
        tier_used="${tier_used//\"/}"
        tool_used="${tool_used//\"/}"
        auto_recovered="${auto_recovered//\"/}"
        platform="${platform//\"/}"
        # Escape single quotes for SQL safety
        local sa="${started_at//\'/\'\'}"
        local ra="${recovered_at//\'/\'\'}"
        local ft="${failure_type//\'/\'\'}"
        local tu="${tier_used//\'/\'\'}"
        local tou="${tool_used//\'/\'\'}"
        local pl="${platform//\'/\'\'}"
        if ! sqlite3 "$db" "INSERT INTO outage_events (started_at, recovered_at, duration_minutes, failure_type, tier_used, tool_used, auto_recovered, platform) VALUES ('$sa', '$ra', '$duration_minutes', '$ft', '$tu', '$tou', '$auto_recovered', '$pl');" 2>/dev/null; then
            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$started_at" "$recovered_at" "$duration_minutes" "$failure_type" \
                "$tier_used" "$tool_used" "$auto_recovered" "$platform" >> "$state_dir/metrics.csv.retry"
        fi
    done < <(tail -n +2 "$csv")

    # Replace CSV with retry file (failed rows only), or delete if all succeeded
    rm -f "$csv"
    if [[ -f "$state_dir/metrics.csv.retry" ]]; then
        echo "$header" > "$csv"
        cat "$state_dir/metrics.csv.retry" >> "$csv"
        rm -f "$state_dir/metrics.csv.retry"
    fi
}

# --- Log Rotation ---

rotate_log() {
    local log_file="$1"
    local max_size="${2:-${CFG_max_log_size:-1048576}}"

    [[ -f "$log_file" ]] || return 0

    # wc may fail on Windows Git Bash if the file's parent directory
    # was removed mid-loop (teardown race). Use a local fallback that
    # doesn't invoke any subshell writes — just default to 0 on error.
    local size=0
    if [[ -r "$log_file" ]]; then
        size=$(wc -c < "$log_file" 2>/dev/null) || size=0
        [[ -z "$size" ]] && size=0
    fi

    if ((size > max_size)); then
        # Safe rotation: write-new-then-rename
        touch "${log_file}.tmp" 2>/dev/null || return 0
        mv "$log_file" "${log_file}.1" 2>/dev/null || true
        mv "${log_file}.tmp" "$log_file" 2>/dev/null || true
    fi
}

# --- Adaptive Backoff ---

# next_check_interval BASE FAILURES
# Prints a sleep interval in seconds using jittered exponential growth.
#   raw    = min(300, base * 2^failures)
#   jitter = random int in [-raw/10, +raw/10]
#   out    = max(base, min(300, raw + jitter))
# If base > 300 the floor wins: out = base.
next_check_interval() {
    local base="$1"
    local failures="$2"
    local raw=$base
    local cap=300

    # Exponential growth, clamped BEFORE jitter
    local i
    for ((i = 0; i < failures; i++)); do
        raw=$((raw * 2))
        if ((raw >= cap)); then
            raw=$cap
            break
        fi
    done

    # Jitter window: ±10% of raw. Use $RANDOM (0..32767) mod (2*window+1) − window.
    local window=$((raw / 10))
    local jitter=0
    if ((window > 0)); then
        jitter=$((RANDOM % (2 * window + 1) - window))
    fi

    local out=$((raw + jitter))
    # Clamp to [base, cap]
    if ((out > cap)); then out=$cap; fi
    if ((out < base)); then out=$base; fi
    echo "$out"
}

# --- Monitor Lifecycle ---

start_monitor() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local config="${2:-$CODEPENDENT_ROOT/resilience.conf}"
    local pid_file="$state_dir/monitor.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid=$(cat "$pid_file")
        if kill -0 "$existing_pid" 2>/dev/null; then
            # Already running, just touch heartbeat
            touch "$state_dir/monitor.heartbeat"
            return 0
        fi
    fi

    # Launch in background
    nohup bash "$CODEPENDENT_ROOT/monitor.sh" --state-dir "$state_dir" --config "$config" &>/dev/null &
    disown
    touch "$state_dir/monitor.heartbeat"
}

stop_monitor() {
    local state_dir="${1:-$CODEPENDENT_ROOT/state}"
    local pid_file="$state_dir/monitor.pid"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill "$pid" 2>/dev/null; then
            # Graceful wait, then SIGKILL fallback — the monitor may be
            # blocked in `sleep` and not respond to SIGTERM immediately
            # (Windows Git Bash quirk).
            local i
            for ((i = 0; i < 50; i++)); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.2
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pid_file"
    fi
}
