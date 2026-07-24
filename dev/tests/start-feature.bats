#!/usr/bin/env bats

# Public-interface regression tests for Feature setup.

setup() {
  load test_helper
  setup_fixture_repo
}

teardown() {
  teardown_fixture_repo
}

@test "start-feature dry-run is safe for an empty repository" {
  run "$ROOT/scripts/start-feature.sh" --repo "$REPO" --dry-run FIX-1 safe-feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=would-create-worktree-and-artifacts"* ]]
}

@test "start-feature normalizes shell syntax without executing it" {
  run "$ROOT/scripts/start-feature.sh" --repo "$REPO" --dry-run FIX-1 'bad;rm'
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch=feat/FIX-1-bad-rm"* ]]
  [[ "$output" != *";"* ]]
}

@test "start-feature directs existing setup state to the recovery classifier" {
  git -C "$REPO" config user.name 'Clowder Test'
  git -C "$REPO" config user.email 'clowder-test@example.invalid'
  git -C "$REPO" add .
  git -C "$REPO" commit -m 'chore: initialize recovery hint fixture.' >/dev/null
  git -C "$REPO" branch feat/FIX-2-existing-state

  run "$ROOT/scripts/start-feature.sh" --repo "$REPO" --dry-run FIX-2 existing-state

  [ "$status" -ne 0 ]
  [[ "$output" == *'recover-feature.sh'* ]]
  [[ "$output" == *'FIX-2 existing-state'* ]]
}
