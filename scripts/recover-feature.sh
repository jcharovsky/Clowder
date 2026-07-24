#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
worktree_parent=""
json=false

usage() {
  cat <<'EOF'
Usage: recover-feature.sh [--repo PATH] [--worktree-dir PATH] [--json] JIRA-123 feature-slug

Inspect Feature setup state and print recovery actions without changing the repository.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --worktree-dir) worktree_parent=${2:?missing value for --worktree-dir}; shift 2 ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; die "unknown argument: $1" ;;
    *) break ;;
  esac
done

[[ $# -eq 2 ]] || { usage >&2; die "expected Jira key and feature slug"; }
jira_key=$1
slug="$(normalize_slug "$2")"
valid_jira_key "$jira_key" || die "invalid Jira key: $jira_key"

repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"
prefix="$(yaml_scalar "$config" git.feature-prefix)"
feature_root="$(yaml_scalar "$config" documents.feature-root)"
base_branch="$(yaml_scalar "$config" git.base-branch)"
feature_id="$jira_key-$slug"
branch="$prefix/$feature_id"
worktree_parent="${worktree_parent:-$(dirname -- "$repo_path")/.clowder-worktrees}"
expected_worktree="$worktree_parent/$feature_id"
base_feature_dir="$repo_path/$feature_root/$feature_id"
registered_worktree="$(worktree_for_branch "$repo_path" "$branch")"
branch_exists=false
[[ -n "$(git -C "$repo_path" branch --list "$branch")" ]] && branch_exists=true
missing_artifacts_json='[]'
branch_merged=false
worktree_clean=false
worktree_locked=false
if [[ "$branch_exists" == true ]] && git -C "$repo_path" merge-base --is-ancestor "$branch" "$base_branch"; then
  branch_merged=true
fi
if [[ -n "$registered_worktree" ]] && git -C "$repo_path" worktree list --porcelain | awk -v wanted="$registered_worktree" '
  $1 == "worktree" { active = (substr($0, 10) == wanted) }
  active && $1 == "locked" { found = 1 }
  END { exit(found ? 0 : 1) }
'; then
  worktree_locked=true
fi

if [[ "$branch_exists" == false && -z "$registered_worktree" && ! -e "$expected_worktree" && ! -e "$base_feature_dir" ]]; then
  state='clean'
  safe_to_retry=true
  printf -v retry_action '%q --repo %q %q %q' "$SCRIPT_DIR/start-feature.sh" "$repo_path" "$jira_key" "$slug"
  actions_json="$(jq -cn --arg action "$retry_action" '[$action]')"
elif [[ "$branch_exists" == false && -z "$registered_worktree" && -e "$expected_worktree" && ! -e "$base_feature_dir" ]]; then
  state='orphaned-directory'
  safe_to_retry=false
  archive_dir="$repo_path/.clowder/runtime/recovery/$feature_id-orphaned-worktree"
  printf -v archive_action 'mkdir -p %q && mv %q %q' "$(dirname -- "$archive_dir")" "$expected_worktree" "$archive_dir"
  printf -v retry_action '%q --repo %q %q %q' "$SCRIPT_DIR/start-feature.sh" "$repo_path" "$jira_key" "$slug"
  actions_json="$(jq -cn --arg archive "$archive_action" --arg retry "$retry_action" '[$archive, $retry]')"
elif [[ "$branch_exists" == true && -n "$registered_worktree" && ! -d "$registered_worktree" ]]; then
  state='stale-registration'
  safe_to_retry=false
  actions_json='[]'
  if [[ "$worktree_locked" == true ]]; then
    printf -v unlock_action 'git -C %q worktree unlock %q' "$repo_path" "$registered_worktree"
    actions_json="$(jq -cn --arg action "$unlock_action" '[$action]')"
  fi
  printf -v prune_action 'git -C %q worktree prune --expire now' "$repo_path"
  printf -v recover_action 'git -C %q worktree add %q %q' "$repo_path" "$expected_worktree" "$branch"
  actions_json="$(jq -cn --argjson current "$actions_json" --arg prune "$prune_action" --arg recover "$recover_action" '$current + [$prune, $recover]')"
elif [[ "$branch_exists" == true && -z "$registered_worktree" && -e "$base_feature_dir" ]]; then
  safe_to_retry=false
  if [[ "$branch_merged" == true ]]; then
    state='completed-on-base'
    printf -v delete_action 'git -C %q branch -d %q' "$repo_path" "$branch"
    actions_json="$(jq -cn --arg action "$delete_action" '[$action]')"
  else
    state='base-present-branch-diverged'
    printf -v recover_action 'git -C %q worktree add %q %q' "$repo_path" "$expected_worktree" "$branch"
    actions_json="$(jq -cn --arg action "$recover_action" '[$action]')"
  fi
elif [[ "$branch_exists" == true && -z "$registered_worktree" && ! -e "$expected_worktree" && ! -e "$base_feature_dir" ]]; then
  state='branch-only'
  safe_to_retry=false
  printf -v recover_action 'git -C %q worktree add %q %q' "$repo_path" "$expected_worktree" "$branch"
  actions_json="$(jq -cn --arg action "$recover_action" '[$action]')"
elif [[ "$branch_exists" == true && -n "$registered_worktree" && -d "$registered_worktree" ]]; then
  feature_dir="$registered_worktree/$feature_root/$feature_id"
  required_artifacts=(
    JIRA_FEATURE.md
    PRD.md
    TECHNICAL_DESIGN.md
    TEST_PLAN.md
    feature.yaml
    evidence/developer.md
    evidence/reviewer.md
    evidence/tester.md
  )
  missing_artifacts=()
  for relative_path in "${required_artifacts[@]}"; do
    [[ -f "$feature_dir/$relative_path" ]] || missing_artifacts+=("$relative_path")
  done
  missing_artifacts_json="$(printf '%s\n' "${missing_artifacts[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  if [[ -z "$(git -C "$registered_worktree" status --porcelain --untracked-files=all)" ]]; then
    worktree_clean=true
  fi
  if ((${#missing_artifacts[@]} > 0)); then
    state='partial-artifacts'
    safe_to_retry=false
    archive_dir="$repo_path/.clowder/runtime/recovery/$feature_id"
    printf -v archive_action 'mkdir -p %q && cp -R %q %q' "$(dirname -- "$archive_dir")" "$feature_dir" "$archive_dir"
    actions_json="$(jq -cn --arg action "$archive_action" '[$action]')"
    unique_commit_count="$(git -C "$repo_path" rev-list --count "$base_branch..$branch")"
    if [[ "$unique_commit_count" == 0 ]]; then
      if [[ "$worktree_locked" == true ]]; then
        printf -v unlock_action 'git -C %q worktree unlock %q' "$repo_path" "$registered_worktree"
        actions_json="$(jq -cn --argjson current "$actions_json" --arg unlock "$unlock_action" '$current + [$unlock]')"
      fi
      printf -v remove_action 'git -C %q worktree remove --force %q' "$repo_path" "$registered_worktree"
      printf -v delete_action 'git -C %q branch -D %q' "$repo_path" "$branch"
      printf -v retry_action '%q --repo %q %q %q' "$SCRIPT_DIR/start-feature.sh" "$repo_path" "$jira_key" "$slug"
      actions_json="$(jq -cn --argjson current "$actions_json" --arg remove "$remove_action" --arg delete "$delete_action" --arg retry "$retry_action" '$current + [$remove, $delete, $retry]')"
    else
      printf -v preserve_action 'git -C %q push -u origin %q' "$registered_worktree" "$branch"
      actions_json="$(jq -cn --argjson current "$actions_json" --arg preserve "$preserve_action" '$current + [$preserve]')"
    fi
  elif [[ "$branch_merged" == true && "$worktree_clean" == true ]]; then
    state='completed-merged'
    safe_to_retry=false
    actions_json='[]'
    if [[ "$worktree_locked" == true ]]; then
      printf -v unlock_action 'git -C %q worktree unlock %q' "$repo_path" "$registered_worktree"
      actions_json="$(jq -cn --arg action "$unlock_action" '[$action]')"
    fi
    printf -v remove_action 'git -C %q worktree remove %q' "$repo_path" "$registered_worktree"
    printf -v delete_action 'git -C %q branch -d %q' "$repo_path" "$branch"
    actions_json="$(jq -cn --argjson current "$actions_json" --arg remove "$remove_action" --arg delete "$delete_action" '$current + [$remove, $delete]')"
  elif [[ "$branch_merged" == true ]]; then
    state='completed-merged-dirty'
    safe_to_retry=false
    printf -v status_action 'git -C %q status --short' "$registered_worktree"
    actions_json="$(jq -cn --arg action "$status_action" '[$action]')"
  else
    state='active-complete'
    safe_to_retry=false
    printf -v continue_action 'cd %q' "$registered_worktree"
    actions_json="$(jq -cn --arg action "$continue_action" '[$action]')"
  fi
else
  die "Feature recovery classification is not implemented for the detected partial state"
fi

if [[ "$json" == true ]]; then
  jq -n \
    --arg repository "$repo_path" \
    --arg feature "$feature_id" \
    --arg branch "$branch" \
    --arg expected_worktree "$expected_worktree" \
    --arg state "$state" \
    --argjson safe_to_retry "$safe_to_retry" \
    --argjson branch_exists "$branch_exists" \
    --argjson branch_merged "$branch_merged" \
    --argjson worktree_clean "$worktree_clean" \
    --argjson worktree_locked "$worktree_locked" \
    --argjson missing_artifacts "$missing_artifacts_json" \
    --argjson actions "$actions_json" \
    '{
      "schema-version": 1,
      kind: "clowder-feature-recovery-assessment",
      repository: $repository,
      feature: $feature,
      branch: $branch,
      "expected-worktree": $expected_worktree,
      state: $state,
      safe_to_retry: $safe_to_retry,
      facts: {
        branch_exists: $branch_exists,
        branch_merged: $branch_merged,
        worktree_clean: $worktree_clean,
        worktree_locked: $worktree_locked
      },
      missing_artifacts: $missing_artifacts,
      actions: $actions
    }'
else
  info "Feature recovery state: $state"
  info "safe to retry: $safe_to_retry"
  jq -r '.[] | "action: \(.)"' <<<"$actions_json"
fi
