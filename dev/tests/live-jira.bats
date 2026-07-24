#!/usr/bin/env bats

setup() {
  ROOT="$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clowder-live-jira-bats.XXXXXX")"
  MOCK_BIN="$FIXTURE_ROOT/bin"
  mkdir -p "$MOCK_BIN"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$MOCK_BIN/git"
  chmod +x "$MOCK_BIN/git"
}

teardown() {
  rm -rf -- "$FIXTURE_ROOT"
}

@test "live Jira integration requires an explicit repository before using integrations" {
  run env PATH="$MOCK_BIN:$PATH" "$ROOT/dev/tests/live-jira-b05.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *'Usage: live-jira-b05.sh REPOSITORY_PATH'* ]]
}
