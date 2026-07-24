#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
worktree_parent=""
dry_run=false
local_mode=false

usage() {
  cat <<'EOF'
Usage: start-feature.sh [--repo PATH] [--worktree-dir PATH] [--dry-run] [--local] JIRA-123 feature-slug

Create a Feature worktree and durable artifacts. The command never commits, pushes, opens a pull request, or changes Jira.
Use --local to exercise Git worktree creation without Supacode.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --worktree-dir) worktree_parent=${2:?missing value for --worktree-dir}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --local) local_mode=true; shift ;;
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
root="$(clowder_root)"
configured_jira_project="$(yaml_scalar "$config" jira.project-key)"
feature_root="$(yaml_scalar "$config" documents.feature-root)"
adr_root="$(yaml_scalar "$config" documents.adr-root)"
base_branch="$(yaml_scalar "$config" git.base-branch)"
prefix="$(yaml_scalar "$config" git.feature-prefix)"
[[ "${jira_key%%-*}" == "$configured_jira_project" ]] || die "Jira key $jira_key does not belong to configured project $configured_jira_project"
[[ "$prefix" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "invalid configured branch prefix: $prefix"
branch="$prefix/$jira_key-$slug"
feature_id="$jira_key-$slug"
feature_dir="$repo_path/$feature_root/$feature_id"
worktree_parent="${worktree_parent:-$(dirname -- "$repo_path")/.clowder-worktrees}"
worktree_path="$worktree_parent/$feature_id"
printf -v recovery_hint 'run %q --repo %q %q %q' "$root/scripts/recover-feature.sh" "$repo_path" "$jira_key" "$slug"

[[ ! -e "$feature_dir" ]] || die "Feature directory already exists: $feature_dir; $recovery_hint"
[[ ! -e "$worktree_path" ]] || die "worktree target already exists: $worktree_path; $recovery_hint"
[[ -z "$(git -C "$repo_path" branch --list "$branch")" ]] || die "branch already exists: $branch; $recovery_hint"
[[ -z "$(worktree_for_branch "$repo_path" "$branch")" ]] || die "a worktree already claims branch: $branch; $recovery_hint"

if ! git -C "$repo_path" rev-parse --verify "refs/heads/$base_branch" >/dev/null 2>&1; then
  if [[ "$dry_run" == true ]]; then
    warn "base branch has no commit yet: $base_branch"
  else
    die "base branch has no local commit: $base_branch; create and authorize an initial product commit before setup"
  fi
fi

if [[ "$dry_run" == true ]]; then
  printf 'repo=%s\nbase=%s\nbranch=%s\nworktree=%s\nfeature=%s\n' "$repo_path" "$base_branch" "$branch" "$worktree_path" "$feature_dir"
  printf 'action=would-create-worktree-and-artifacts\n'
  exit 0
fi

mkdir -p "$worktree_parent"

if [[ "$local_mode" == true ]]; then
  git -C "$repo_path" worktree add -b "$branch" "$worktree_path" "$base_branch"
else
  require_command supacode
  supacode repo open "$repo_path" >/dev/null
  encoded_repo="$(supacode_repo_identifier "$repo_path")"
  repo_id=""
  for _ in {1..20}; do
    repo_id="$(supacode repo list --timeout 10 | awk -v wanted="$encoded_repo" '$0 == wanted { print; exit }')"
    [[ -n "$repo_id" ]] && break
    sleep 1
  done
  [[ -n "$repo_id" ]] || die "Supacode did not expose repository ID for $repo_path"
  supacode repo worktree-new --repo "$repo_id" --branch "$branch" --base "$base_branch" --name "$feature_id" --location "$worktree_parent" --background >/dev/null
  for _ in {1..20}; do
    worktree_for_branch "$repo_path" "$branch" | grep -q . && break
    sleep 1
  done
  worktree_path="$(worktree_for_branch "$repo_path" "$branch")"
  [[ -n "$worktree_path" ]] || die "Supacode did not create a worktree for $branch"
fi

feature_dir="$worktree_path/$feature_root/$feature_id"
mkdir -p "$feature_dir" "$worktree_path/$adr_root"
mkdir -p "$feature_dir/evidence"
render_template "$root/templates/JIRA_FEATURE_TEMPLATE.md" "$feature_dir/JIRA_FEATURE.md" "$jira_key" "$slug" "$feature_id"
render_template "$root/templates/PRD_TEMPLATE.md" "$feature_dir/PRD.md" "$jira_key" "$slug" "$feature_id"
render_template "$root/templates/TECHNICAL_DESIGN_TEMPLATE.md" "$feature_dir/TECHNICAL_DESIGN.md" "$jira_key" "$slug" "$feature_id"
render_template "$root/templates/TEST_PLAN_TEMPLATE.md" "$feature_dir/TEST_PLAN.md" "$jira_key" "$slug" "$feature_id"
render_template "$root/templates/DEVELOPER_EVIDENCE_TEMPLATE.md" "$feature_dir/evidence/developer.md" "$jira_key" "$slug" "$feature_id"
render_template "$root/templates/REVIEWER_EVIDENCE_TEMPLATE.md" "$feature_dir/evidence/reviewer.md" "$jira_key" "$slug" "$feature_id"
render_template "$root/templates/TESTER_EVIDENCE_TEMPLATE.md" "$feature_dir/evidence/tester.md" "$jira_key" "$slug" "$feature_id"
cp "$root/templates/feature-manifest-template.yaml" "$feature_dir/feature.yaml"
update_yaml_values "$feature_dir/feature.yaml" \
  feature.jira-key "$jira_key" \
  feature.slug "$slug" \
  feature.name "$feature_id" \
  feature.branch "$branch" \
  feature.worktree "$worktree_path" \
  feature.base-revision "$(git -C "$worktree_path" rev-parse "$base_branch")" \
  feature.head-revision "$(git -C "$worktree_path" rev-parse HEAD)"

info "created Feature $feature_id"
info "worktree: $worktree_path"
info "branch: $branch"
info "next gate: complete and approve PRD, Technical Design, ADRs, and Test Plan"
