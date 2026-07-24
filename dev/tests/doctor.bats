#!/usr/bin/env bats

# Public-interface regression tests for Doctor.

setup() {
  load test_helper
  setup_fixture_repo
}

teardown() {
  teardown_fixture_repo
}

@test "doctor validates an onboarded repository offline" {
  run "$ROOT/scripts/doctor.sh" --repo "$REPO" --offline
  [ "$status" -eq 0 ]
}

@test "doctor evaluates the complete project schema" {
  ruby -r yaml -e '
    file = ARGV.fetch(0)
    data = YAML.safe_load(File.read(file), aliases: true)
    data["git"]["remote"] = ""
    File.write(file, data.to_yaml)
  ' "$REPO/.clowder/project.yaml"

  run "$ROOT/scripts/doctor.sh" --repo "$REPO" --offline --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'project schema: $.git.remote'* ]]
  [[ "$output" == *'must NOT have fewer than 1 characters'* ]]
}
