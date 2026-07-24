#!/usr/bin/env bats

# Public-interface regression tests for Feature recovery.

setup() {
  load test_helper
  setup_fixture_repo
  git -C "$REPO" config user.name 'Clowder Test'
  git -C "$REPO" config user.email 'clowder-test@example.invalid'
  git -C "$REPO" add .
  git -C "$REPO" commit -m 'chore: initialize recovery fixture.' >/dev/null
}

teardown() {
  teardown_fixture_repo
}

@test "recover-feature classifies a clean Feature as safe to retry without mutation" {
  before_head="$(git -C "$REPO" rev-parse HEAD)"

  run "$ROOT/scripts/recover-feature.sh" --repo "$REPO" --json FIX-1 safe-feature

  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = clean ]
  [ "$(jq -r '.safe_to_retry' <<<"$output")" = true ]
  [[ "$(jq -r '.actions[0]' <<<"$output")" == *'start-feature.sh'* ]]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ]
  [ -z "$(git -C "$REPO" status --short)" ]
  [ -z "$(git -C "$REPO" branch --list 'feat/FIX-1-safe-feature')" ]
}

@test "recover-feature reconnects a branch-only Feature through an exact worktree action" {
  git -C "$REPO" branch feat/FIX-2-branch-only
  before_head="$(git -C "$REPO" rev-parse feat/FIX-2-branch-only)"

  run "$ROOT/scripts/recover-feature.sh" --repo "$REPO" --json FIX-2 branch-only

  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = branch-only ]
  [ "$(jq -r '.safe_to_retry' <<<"$output")" = false ]
  [[ "$(jq -r '.actions[0]' <<<"$output")" == *'git -C '*' worktree add '*'feat/FIX-2-branch-only'* ]]
  [ "$(git -C "$REPO" rev-parse feat/FIX-2-branch-only)" = "$before_head" ]
  [ "$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}

@test "recover-feature identifies partial artifacts and prints preservation-first reset actions" {
  "$ROOT/scripts/start-feature.sh" --repo "$REPO" --local FIX-3 partial-feature >/dev/null
  worktree="$(source "$ROOT/scripts/lib.sh"; worktree_for_branch "$REPO" feat/FIX-3-partial-feature)"
  feature_dir="$worktree/docs/features/FIX-3-partial-feature"
  rm -f -- "$feature_dir/TEST_PLAN.md"
  git -C "$REPO" worktree lock --reason '{"owner":"supacode"}' "$worktree"

  run "$ROOT/scripts/recover-feature.sh" --repo "$REPO" --json FIX-3 partial-feature

  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = partial-artifacts ]
  [ "$(jq -r '.safe_to_retry' <<<"$output")" = false ]
  [ "$(jq -r '.missing_artifacts | join(",")' <<<"$output")" = TEST_PLAN.md ]
  actions="$(jq -r '.actions[]' <<<"$output")"
  grep -Fq 'cp -R' <<<"$actions"
  grep -Fq 'worktree unlock' <<<"$actions"
  grep -Fq 'worktree remove --force' <<<"$actions"
  [ -d "$feature_dir" ]
  [ -n "$(git -C "$REPO" branch --list 'feat/FIX-3-partial-feature')" ]
}

@test "recover-feature marks a clean merged Feature worktree as removable without changing it" {
  "$ROOT/scripts/start-feature.sh" --repo "$REPO" --local FIX-4 completed-feature >/dev/null
  worktree="$(source "$ROOT/scripts/lib.sh"; worktree_for_branch "$REPO" feat/FIX-4-completed-feature)"
  git -C "$worktree" add .
  git -C "$worktree" commit -m 'feat: complete recovery fixture.' >/dev/null
  git -C "$REPO" merge --no-ff feat/FIX-4-completed-feature -m 'merge: complete recovery fixture.' >/dev/null
  git -C "$REPO" worktree lock --reason '{"owner":"supacode"}' "$worktree"

  run "$ROOT/scripts/recover-feature.sh" --repo "$REPO" --json FIX-4 completed-feature

  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = completed-merged ]
  [ "$(jq -r '.safe_to_retry' <<<"$output")" = false ]
  [ "$(jq -r '.facts.branch_merged' <<<"$output")" = true ]
  [ "$(jq -r '.facts.worktree_clean' <<<"$output")" = true ]
  [[ "$(jq -r '.actions | join("\n")' <<<"$output")" == *'worktree unlock'* ]]
  [[ "$(jq -r '.actions | join("\n")' <<<"$output")" == *'worktree remove'* ]]
  [ -d "$worktree" ]
  git -C "$REPO" worktree list --porcelain | grep -Fq 'locked '
}

@test "recover-feature preserves an orphaned target directory before retry" {
  orphan="$FIXTURE_ROOT/.clowder-worktrees/FIX-5-orphaned-directory"
  mkdir -p "$orphan"
  printf '%s\n' 'partial setup evidence' > "$orphan/recovery-note.txt"

  run "$ROOT/scripts/recover-feature.sh" --repo "$REPO" --json FIX-5 orphaned-directory

  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = orphaned-directory ]
  [ "$(jq -r '.safe_to_retry' <<<"$output")" = false ]
  [[ "$(jq -r '.actions | join("\n")' <<<"$output")" == *'mv '* ]]
  [[ "$(jq -r '.actions | join("\n")' <<<"$output")" == *'start-feature.sh'* ]]
  [ -f "$orphan/recovery-note.txt" ]
}

@test "recover-feature repairs a stale Git worktree registration without deleting its branch" {
  "$ROOT/scripts/start-feature.sh" --repo "$REPO" --local FIX-6 stale-registration >/dev/null
  worktree="$(source "$ROOT/scripts/lib.sh"; worktree_for_branch "$REPO" feat/FIX-6-stale-registration)"
  preserved="$FIXTURE_ROOT/preserved-stale-worktree"
  mv "$worktree" "$preserved"

  run "$ROOT/scripts/recover-feature.sh" --repo "$REPO" --json FIX-6 stale-registration

  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = stale-registration ]
  [ "$(jq -r '.safe_to_retry' <<<"$output")" = false ]
  [[ "$(jq -r '.actions | join("\n")' <<<"$output")" == *'worktree prune'* ]]
  [[ "$(jq -r '.actions | join("\n")' <<<"$output")" == *'worktree add'* ]]
  [ -d "$preserved" ]
  [ -n "$(git -C "$REPO" branch --list 'feat/FIX-6-stale-registration')" ]
}

@test "recover-feature recognizes a merged Feature after its worktree is removed" {
  "$ROOT/scripts/start-feature.sh" --repo "$REPO" --local FIX-7 merged-feature >/dev/null
  worktree="$(source "$ROOT/scripts/lib.sh"; worktree_for_branch "$REPO" feat/FIX-7-merged-feature)"
  git -C "$worktree" add .
  git -C "$worktree" commit -m 'feat: complete merged recovery fixture.' >/dev/null
  git -C "$REPO" merge --no-ff feat/FIX-7-merged-feature -m 'merge: complete merged recovery fixture.' >/dev/null
  git -C "$REPO" worktree remove "$worktree"

  run "$ROOT/scripts/recover-feature.sh" --repo "$REPO" --json FIX-7 merged-feature

  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = completed-on-base ]
  [ "$(jq -r '.safe_to_retry' <<<"$output")" = false ]
  [ "$(jq -r '.facts.branch_merged' <<<"$output")" = true ]
  [ "$(jq -r '.actions | length' <<<"$output")" -eq 1 ]
  [[ "$(jq -r '.actions[0]' <<<"$output")" == *'branch -d'* ]]
}
