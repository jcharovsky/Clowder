#!/usr/bin/env bats

# Public-interface regression tests for launcher behavior.

setup() {
  load test_helper
  setup_fixture_repo
}

teardown() {
  teardown_fixture_repo
}

@test "no-ui launch prints the configured Codex command" {
  run "$ROOT/scripts/clowder" --repo "$REPO" --no-ui --offline
  [ "$status" -eq 0 ]
  [[ "$output" == *"dangerously-bypass-approvals-and-sandbox"* ]]
}
