#!/usr/bin/env bash
# tests/runner.sh — minimal test harness for codependent
# Usage: ./tests/runner.sh [test_file.sh] [test_name]

set -euo pipefail

# Disable job-control notifications ("Killed" messages) when we SIGKILL
# unresponsive background processes during test teardown. These are not
# failures — the tests have already passed by the time we force-kill.
set +m

export PROJECT_ROOT
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TESTS_DIR="$PROJECT_ROOT/tests"

# Counters
_PASS=0
_FAIL=0
_CURRENT_TEST=""

# ── Helpers ──────────────────────────────────────────────────────────────────

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assert_eq failed}"
  if [[ "$expected" == "$actual" ]]; then
    return 0
  else
    echo "  FAIL [$_CURRENT_TEST] $msg" >&2
    echo "       expected: $(printf '%q' "$expected")" >&2
    echo "       actual:   $(printf '%q' "$actual")" >&2
    return 1
  fi
}

assert_true() {
  local value="$1"
  local msg="${2:-assert_true failed}"
  if [[ -n "$value" && "$value" != "0" && "$value" != "false" ]]; then
    return 0
  else
    echo "  FAIL [$_CURRENT_TEST] $msg: expected truthy, got $(printf '%q' "$value")" >&2
    return 1
  fi
}

assert_false() {
  local value="$1"
  local msg="${2:-assert_false failed}"
  if [[ -z "$value" || "$value" == "0" || "$value" == "false" ]]; then
    return 0
  else
    echo "  FAIL [$_CURRENT_TEST] $msg: expected falsy, got $(printf '%q' "$value")" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-assert_contains failed}"
  if [[ "$haystack" == *"$needle"* ]]; then
    return 0
  else
    echo "  FAIL [$_CURRENT_TEST] $msg" >&2
    echo "       haystack: $(printf '%q' "$haystack")" >&2
    echo "       needle:   $(printf '%q' "$needle")" >&2
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  local msg="${2:-assert_file_exists failed}"
  if [[ -f "$path" ]]; then
    return 0
  else
    echo "  FAIL [$_CURRENT_TEST] $msg: file not found: $path" >&2
    return 1
  fi
}

# ── Runner internals ──────────────────────────────────────────────────────────

_run_test() {
  local fn="$1"
  _CURRENT_TEST="$fn"
  if ( set -e; $fn ); then
    echo "  PASS $fn"
    (( _PASS++ )) || true
  else
    echo "  FAIL $fn"
    (( _FAIL++ )) || true
  fi
}

_run_file() {
  local file="$1"
  local filter="${2:-}"

  echo ""
  echo "── $(basename "$file") ──"

  # Source the test file in a subshell context to collect function names,
  # then source again in this shell so helpers are available during execution.
  local fns
  fns=$(
    bash -c "
      source \"$file\" 2>/dev/null
      declare -F | awk '{print \$3}' | grep '^test_'
    "
  )

  if [[ -z "$fns" ]]; then
    echo "  (no test_ functions found)"
    return
  fi

  # Source the file into current shell so test functions can call our helpers.
  # shellcheck disable=SC1090
  source "$file"

  while IFS= read -r fn; do
    [[ -z "$fn" ]] && continue
    if [[ -n "$filter" && "$fn" != "$filter" ]]; then
      continue
    fi
    _run_test "$fn"
  done <<< "$fns"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  local file_filter="${1:-}"
  local test_filter="${2:-}"

  if [[ -n "$file_filter" ]]; then
    # Resolve: bare name, relative, or absolute
    local target
    if [[ -f "$file_filter" ]]; then
      target="$file_filter"
    elif [[ -f "$TESTS_DIR/$file_filter" ]]; then
      target="$TESTS_DIR/$file_filter"
    else
      echo "ERROR: test file not found: $file_filter" >&2
      exit 1
    fi
    _run_file "$target" "$test_filter"
  else
    for f in "$TESTS_DIR"/test_*.sh; do
      [[ -f "$f" ]] || continue
      _run_file "$f"
    done
  fi

  echo ""
  echo "Results: $_PASS passed, $_FAIL failed"

  if (( _FAIL > 0 )); then
    exit 1
  fi
}

main "$@"
