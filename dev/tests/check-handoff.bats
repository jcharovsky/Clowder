#!/usr/bin/env bats

setup() {
  ROOT="$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clowder-handoff-bats.XXXXXX")"
}

teardown() {
  rm -rf -- "$FIXTURE_ROOT"
}

@test "check-handoff evaluates the complete handoff schema" {
  handoff="$FIXTURE_ROOT/handoff.json"
  jq '.unexpected = true' "$BATS_TEST_DIRNAME/fixtures/handoffs/completed.json" > "$handoff"

  run "$ROOT/scripts/check-handoff.sh" --file "$handoff" --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'handoff schema: $'* ]]
  [[ "$output" == *'must NOT have additional properties'* ]]
}
