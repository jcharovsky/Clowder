setup_fixture_repo() {
  ROOT="$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clowder-bats.XXXXXX")"
  REPO="$FIXTURE_ROOT/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -b main >/dev/null
  "$ROOT/scripts/onboard.sh" --repo "$REPO" --name Fixture --jira-project FIX >/dev/null
}

teardown_fixture_repo() {
  rm -rf -- "$FIXTURE_ROOT"
}
