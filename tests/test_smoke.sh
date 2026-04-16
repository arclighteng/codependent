#!/usr/bin/env bash
# tests/test_smoke.sh — verify the test harness itself works

test_harness_works() {
  assert_eq "hello" "hello"
}

test_assert_contains() {
  assert_contains "hello world" "world"
}

test_project_root_set() {
  assert_true "$PROJECT_ROOT" "PROJECT_ROOT should be set"
}
