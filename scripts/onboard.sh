#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="${PWD}"
project_name=""
jira_key="ABC"
base_branch="main"

usage() {
  cat <<'EOF'
Usage: onboard.sh [--repo PATH] [--name NAME] [--jira-project KEY] [--base-branch BRANCH]

Create missing Clowder project files without overwriting existing product files.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --name) project_name=${2:?missing value for --name}; shift 2 ;;
    --jira-project) jira_key=${2:?missing value for --jira-project}; shift 2 ;;
    --base-branch) base_branch=${2:?missing value for --base-branch}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

repo_path="$(resolve_repo "$repo_path")"
root="$(clowder_root)"
project_name="${project_name:-$(basename -- "$repo_path")}"
valid_jira_key "${jira_key}-1" || die "invalid Jira project key: $jira_key"
[[ "$base_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid base branch: $base_branch"

existing_hooks_path="$(git -C "$repo_path" config --local --get core.hooksPath 2>/dev/null || true)"
if [[ -n "$existing_hooks_path" && "$existing_hooks_path" != ".clowder/hooks" ]]; then
  die "existing core.hooksPath must be composed with Clowder before onboarding: $existing_hooks_path"
fi

mkdir -p "$repo_path/.clowder/hooks" "$repo_path/docs/features" "$repo_path/docs/adr" "$repo_path/.github"

runtime_ignore="$repo_path/.clowder/.gitignore"
if [[ ! -e "$runtime_ignore" ]]; then
  printf '%s\n' 'runtime/' > "$runtime_ignore"
  info "created $runtime_ignore"
fi

config="$repo_path/.clowder/project.yaml"
if [[ ! -e "$config" ]]; then
  cp "$root/templates/project-config-template.yaml" "$config"
  update_yaml_values "$config" \
    project.name "$project_name" \
    jira.project-key "$jira_key" \
    git.base-branch "$base_branch"
  info "created $config"
else
  info "preserved existing $config"
fi

configured_base_branch="$(yaml_scalar "$config" git.base-branch)"
pre_push_hook="$repo_path/.clowder/hooks/pre-push"
if [[ ! -e "$pre_push_hook" ]]; then
  cp "$root/templates/pre-push-hook" "$pre_push_hook"
  chmod +x "$pre_push_hook"
  info "created .clowder/hooks/pre-push"
else
  info "preserved existing .clowder/hooks/pre-push"
fi
git -C "$repo_path" config --local core.hooksPath .clowder/hooks
git -C "$repo_path" config --local clowder.baseBranch "$configured_base_branch"

if [[ ! -e "$repo_path/.github/PULL_REQUEST_TEMPLATE.md" ]]; then
  cp "$root/templates/PULL_REQUEST_TEMPLATE.md" "$repo_path/.github/PULL_REQUEST_TEMPLATE.md"
  info "created .github/PULL_REQUEST_TEMPLATE.md"
fi

if [[ ! -e "$repo_path/AGENTS.md" ]]; then
  cat > "$repo_path/AGENTS.md" <<'EOF'
# Product Repository Instructions

Read `.clowder/project.yaml` and the Feature artifacts before changing product code. Keep changes inside the assigned Feature boundary. Run the configured quality commands before handoff. Record material decisions in durable artifacts.
EOF
  info "created AGENTS.md"
fi

repo_config "$repo_path" >/dev/null
info "onboarding complete for $repo_path"
