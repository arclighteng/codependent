#!/usr/bin/env bash
# tests/test_tiers.sh — tests for lib.sh: tier parsing and prerequisite checks

# Source lib.sh (PROJECT_ROOT is exported by runner.sh)
source "$PROJECT_ROOT/lib.sh"

# ── parse_tier_line ───────────────────────────────────────────────────────────

test_parse_tier_line() {
  parse_tier_line "1 | codex | codex --model o3 |  | command -v codex"

  assert_eq "1"               "$TIER_id"           "TIER_id should be 1"
  assert_eq "codex"           "$TIER_tool"         "TIER_tool should be codex"
  assert_eq "codex --model o3" "$TIER_command"     "TIER_command should be codex --model o3"
  assert_eq ""                "$TIER_required_env" "TIER_required_env should be empty"
  assert_eq "command -v codex" "$TIER_check_cmd"   "TIER_check_cmd should be 'command -v codex'"
}

test_parse_tier_with_env() {
  parse_tier_line "2a | aider | aider --model gpt-4o | OPENAI_API_KEY | command -v aider"

  assert_eq "2a"              "$TIER_id"           "TIER_id should be 2a"
  assert_eq "aider"           "$TIER_tool"         "TIER_tool should be aider"
  assert_eq "aider --model gpt-4o" "$TIER_command" "TIER_command should be aider --model gpt-4o"
  assert_eq "OPENAI_API_KEY"  "$TIER_required_env" "TIER_required_env should be OPENAI_API_KEY"
  assert_eq "command -v aider" "$TIER_check_cmd"   "TIER_check_cmd should be 'command -v aider'"
}

# ── load_tiers ────────────────────────────────────────────────────────────────

test_load_tiers_skips_comments() {
  local tmpfile
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
# this is a comment
0 | claude | claude |  | command -v claude

# another comment
1 | codex | codex --model o3 | OPENAI_API_KEY | command -v codex
EOF

  TIERS=()
  load_tiers "$tmpfile"
  rm -f "$tmpfile"

  assert_eq "2" "${#TIERS[@]}" "TIERS array should have 2 entries (comments and blanks skipped)"
}

# ── check_tier_prerequisites ──────────────────────────────────────────────────

test_check_tier_prerequisites_missing_tool() {
  parse_tier_line "99 | notarealbinary_xyz | notarealbinary_xyz |  | command -v notarealbinary_xyz"

  local result=0
  check_tier_prerequisites 2>/dev/null || result=$?
  assert_eq "1" "$result" "check_tier_prerequisites should return 1 when tool binary is missing"
}

test_check_tier_prerequisites_missing_env() {
  # Use bash itself as the tool so the binary check passes, but require an unset env var
  local test_env_var="_CODEPENDENT_TEST_UNSET_VAR_$$"
  unset "$test_env_var" 2>/dev/null || true

  parse_tier_line "98 | bash | bash | ${test_env_var} | command -v bash"

  local result=0
  check_tier_prerequisites 2>/dev/null || result=$?
  assert_eq "1" "$result" "check_tier_prerequisites should return 1 when required env var is unset"
}
