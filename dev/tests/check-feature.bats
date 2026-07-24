#!/usr/bin/env bats

# Public-interface regression tests for Feature gates.

setup() {
  load test_helper
  setup_fixture_repo
}

teardown() {
  teardown_fixture_repo
}

@test "check-feature reports a missing Feature on the base branch" {
  run "$ROOT/scripts/check-feature.sh" --repo "$REPO" --gate feature-created --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing Feature manifest"* ]]
}

@test "check-feature evaluates the complete Feature schema" {
  git -C "$REPO" config user.name 'Clowder Test'
  git -C "$REPO" config user.email 'clowder-test@example.invalid'
  git -C "$REPO" add .
  git -C "$REPO" commit -m 'chore: initialize Feature schema fixture.' >/dev/null
  "$ROOT/scripts/start-feature.sh" --repo "$REPO" --local FIX-2 schema-feature >/dev/null
  worktree="$(source "$ROOT/scripts/lib.sh"; worktree_for_branch "$REPO" feat/FIX-2-schema-feature)"
  manifest="$worktree/docs/features/FIX-2-schema-feature/feature.yaml"
  ruby -r yaml -e '
    file = ARGV.fetch(0)
    data = YAML.safe_load(File.read(file), aliases: true)
    data["feature"]["source-requests"] = [1]
    File.write(file, data.to_yaml)
  ' "$manifest"

  run "$ROOT/scripts/check-feature.sh" --repo "$worktree" --gate feature-created --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'Feature schema: $.feature.source-requests[0]'* ]]
  [[ "$output" == *'must be string'* ]]
}
