#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
feature_input=""
output=""
require_ready=false

usage() {
  cat <<'EOF'
Usage: prepare-pr.sh [--repo PATH] [--feature PATH|JIRA-123-slug] [--output PATH|-] [--require-ready]

Render the pull-request body from the Feature contract without contacting GitHub or committing.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --feature) feature_input=${2:?missing value for --feature}; shift 2 ;;
    --output) output=${2:?missing value for --output}; shift 2 ;;
    --require-ready) require_ready=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"
feature_root="$(yaml_scalar "$config" documents.feature-root)"
current_branch="$(git -C "$repo_path" branch --show-current)"
[[ -n "$current_branch" ]] || die "the current worktree is detached"

if [[ -n "$feature_input" ]]; then
  if [[ -d "$feature_input" ]]; then
    feature_dir="$(cd -- "$feature_input" && pwd -P)"
  else
    feature_dir="$repo_path/$feature_root/$feature_input"
  fi
else
  feature_dir="$repo_path/$feature_root/${current_branch#*/}"
fi

path_is_within "$feature_dir" "$repo_path/$feature_root" || die "Feature directory is outside the configured Feature root: $feature_dir"

manifest="$feature_dir/feature.yaml"
[[ -f "$manifest" ]] || die "missing Feature manifest: $manifest"
validate_yaml "$manifest" || die "invalid Feature manifest: $manifest"
[[ -f "$feature_dir/PRD.md" && -f "$feature_dir/TECHNICAL_DESIGN.md" && -f "$feature_dir/TEST_PLAN.md" ]] || die "Feature artifacts are incomplete"

if [[ "$require_ready" == true ]]; then
  "$SCRIPT_DIR/check-feature.sh" --repo "$repo_path" --feature "$feature_dir" --gate ready-for-review >/dev/null
fi

jira_key="$(yaml_scalar "$manifest" feature.jira-key)"
slug="$(yaml_scalar "$manifest" feature.slug)"
feature_name="$(yaml_scalar "$manifest" feature.name)"
target="${output:-$feature_dir/PULL_REQUEST.md}"
existing_body="$feature_dir/PULL_REQUEST.md"

# A role may enrich the generated body with evidence and conclusions. Preserve
# that reviewed body when it exists and is no longer a template, including when
# the caller asks for stdout. This keeps a final PR handoff reproducible instead
# of silently replacing it with a fresh placeholder template.
if [[ -f "$existing_body" ]] && ! grep -Eq 'JIRA-123|Describe the |Pending\.|None or linked files\.' "$existing_body"; then
  if [[ "$target" == "-" ]]; then
    cat "$existing_body"
    exit 0
  fi
  if [[ "$target" == "$existing_body" ]]; then
    info "preserved reviewed pull-request body: $target"
    exit 0
  fi
fi

if [[ "$target" == "-" ]]; then
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/clowder-pr.XXXXXX")"
  render_template "$(clowder_root)/templates/PULL_REQUEST_TEMPLATE.md" "$tmp_file" "$jira_key" "$slug" "$feature_name"
  cat "$tmp_file"
  rm -f -- "$tmp_file"
else
  mkdir -p "$(dirname -- "$target")"
  render_template "$(clowder_root)/templates/PULL_REQUEST_TEMPLATE.md" "$target" "$jira_key" "$slug" "$feature_name"
  info "prepared pull-request body: $target"
fi
