#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
offline=false
json=false

usage() {
  cat <<'EOF'
Usage: doctor.sh [--repo PATH] [--offline] [--json]

Validate local Clowder onboarding and live integration prerequisites.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --offline) offline=true; shift ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

repo_path="$(resolve_repo "$repo_path")"
root="$(clowder_root)"
config="$repo_path/.clowder/project.yaml"
errors=()
warnings=()

add_readiness_issue() {
  if [[ "$offline" == true ]]; then
    warnings+=("$1")
  else
    errors+=("$1")
  fi
}

if [[ ! -f "$config" ]]; then
  errors+=("missing .clowder/project.yaml")
else
  if ! validate_yaml "$config"; then
    errors+=("invalid YAML in .clowder/project.yaml")
  else
    while IFS= read -r schema_error; do
      [[ -n "$schema_error" ]] && errors+=("project schema: $schema_error")
    done < <(schema_validation_errors "$root/schemas/project.schema.json" "$config")
    for path in project.name jira.project-key jira.board-name jira.status-field jira.lifecycle-phase-field jira.native-parent-field jira.child-link-type git.base-branch git.feature-prefix documents.feature-root documents.adr-root; do
      if ! yaml_scalar "$config" "$path" >/dev/null 2>&1; then
        errors+=("missing scalar project field: $path")
      fi
    done
    schema_version_value="$(yaml_scalar "$config" schema-version 2>/dev/null || true)"
    project_name_value="$(yaml_scalar "$config" project.name 2>/dev/null || true)"
    jira_project_value="$(yaml_scalar "$config" jira.project-key 2>/dev/null || true)"
    jira_integration_value="$(yaml_scalar "$config" jira.integration 2>/dev/null || true)"
    jira_board_value="$(yaml_scalar "$config" jira.board-name 2>/dev/null || true)"
    jira_status_field_value="$(yaml_scalar "$config" jira.status-field 2>/dev/null || true)"
    jira_lifecycle_field_value="$(yaml_scalar "$config" jira.lifecycle-phase-field 2>/dev/null || true)"
    jira_columns_value="$(ruby -r yaml -r json -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts JSON.generate(data.dig("jira", "required-columns"))' "$config" 2>/dev/null || true)"
    jira_work_types_value="$(ruby -r yaml -r json -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts JSON.generate(data.dig("jira", "required-work-types"))' "$config" 2>/dev/null || true)"
    jira_parent_field_value="$(yaml_scalar "$config" jira.native-parent-field 2>/dev/null || true)"
    jira_child_link_value="$(yaml_scalar "$config" jira.child-link-type 2>/dev/null || true)"
    branch_prefix_value="$(yaml_scalar "$config" git.feature-prefix 2>/dev/null || true)"
    github_repository_value="$(yaml_scalar "$config" github.repository 2>/dev/null || true)"
    github_review_evidence_value="$(yaml_scalar "$config" github.review-evidence 2>/dev/null || true)"
    [[ -n "$github_review_evidence_value" ]] || github_review_evidence_value="clowder-attestation"
    base_branch_value="$(yaml_scalar "$config" git.base-branch 2>/dev/null || true)"
    required_checks_value="$(ruby -r yaml -r json -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts JSON.generate(data.dig("quality", "required-checks"))' "$config" 2>/dev/null || true)"
    astra_model_value="$(yaml_scalar "$config" models.astra 2>/dev/null || true)"
    configured_quality_count="$(ruby -r yaml -e '
      data = YAML.safe_load(File.read(ARGV[0]), aliases: true)
      commands = data.dig("quality", "commands")
      puts(commands.is_a?(Hash) ? commands.values.count { |value| value.is_a?(String) && !value.empty? } : 0)
    ' "$config" 2>/dev/null || printf '0')"
    [[ "$schema_version_value" == "1" ]] || errors+=("project schema: $.schema-version: expected constant 1")
    [[ -n "$project_name_value" && "$project_name_value" != *replace-with* ]] || errors+=("project.name is still a placeholder")
    [[ "$jira_project_value" =~ ^[A-Z][A-Z0-9]+$ ]] || errors+=("jira.project-key is invalid")
    [[ -n "$jira_board_value" && "$jira_board_value" != *replace-with* ]] || errors+=("jira.board-name is invalid")
    [[ "$jira_status_field_value" == "status" ]] || errors+=("jira.status-field must identify Jira's native status field")
    [[ "$jira_lifecycle_field_value" == "labels" ]] || errors+=("jira.lifecycle-phase-field must identify Jira's native labels field")
    [[ "$jira_columns_value" == '["To Do","Product Manager","Architect","Developer","Tester","Reviewer","Done"]' ]] || errors+=("jira.required-columns must contain the 7 ordered Clowder columns")
    [[ "$jira_work_types_value" == '["Stage","Epic","Feature","Subfeature","Bug"]' ]] || errors+=("jira.required-work-types must contain Stage, Epic, Feature, Subfeature, and Bug in order")
    [[ "$jira_parent_field_value" == "parent" ]] || errors+=("jira.native-parent-field must be parent")
    [[ "$jira_child_link_value" == "Child" ]] || errors+=("jira.child-link-type must be Child")
    [[ "$branch_prefix_value" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || errors+=("git.feature-prefix is invalid")
    git check-ref-format --branch "$base_branch_value" >/dev/null 2>&1 || errors+=("git.base-branch is invalid")
    if [[ "$jira_integration_value" == "offline" || -z "$jira_integration_value" ]]; then
      if [[ "$offline" == true ]]; then
        warnings+=("Jira integration is configured as offline; Jira project access, canonical Statuses, work types, and the Lifecycle Phase label field cannot be verified")
      else
        errors+=("jira.integration must select a live integration outside offline mode")
      fi
    fi
    if [[ -z "$github_repository_value" || "$github_repository_value" == *replace-with* ]]; then
      if [[ "$offline" == true ]]; then
        warnings+=("github.repository is still a placeholder; pull-request stages cannot be verified")
      else
        errors+=("github.repository is still a placeholder")
      fi
    elif [[ ! "$github_repository_value" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      errors+=("github.repository must use owner/repository form")
    fi
    [[ "$github_review_evidence_value" =~ ^(clowder-attestation|github-approval)$ ]] || errors+=("github.review-evidence must be clowder-attestation or github-approval")
    for path in approvals.product-owner approvals.architecture-owner approvals.residual-risk-owner approvals.merge-owner; do
      approval_owner_value="$(yaml_scalar "$config" "$path" 2>/dev/null || true)"
      if [[ -z "$approval_owner_value" || "$approval_owner_value" == *replace-with* ]]; then
        if [[ "$offline" == true ]]; then
          warnings+=("$path is still a placeholder")
        else
          errors+=("$path is still a placeholder")
        fi
      fi
    done
    if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' <<<"${required_checks_value:-null}" >/dev/null 2>&1; then
      if [[ "$offline" == true ]]; then
        warnings+=("quality.required-checks must name at least 1 required CI check before live use")
      else
        errors+=("quality.required-checks must name at least 1 required CI check")
      fi
    fi
    if [[ ! "$configured_quality_count" =~ ^[1-9][0-9]*$ ]]; then
      if [[ "$offline" == true ]]; then
        warnings+=("quality.commands must configure at least 1 executable quality gate before live use")
      else
        errors+=("quality.commands must configure at least 1 executable quality gate")
      fi
    fi
    [[ "$astra_model_value" != "gpt-6-astra" ]] || errors+=("models.astra uses the removed placeholder gpt-6-astra; configure an available model or leave it empty")
    git -C "$repo_path" rev-parse --verify "refs/heads/$base_branch_value" >/dev/null 2>&1 || warnings+=("base branch has no local commit yet: $base_branch_value")
    for path in documents.feature-root documents.adr-root; do
      document_root_value="$(yaml_scalar "$config" "$path" 2>/dev/null || true)"
      [[ "$document_root_value" != /* && "$document_root_value" != *..* ]] || errors+=("$path must be a relative path without parent traversal")
    done
  fi
fi

for file in "$root/.codex/config.toml" "$root/package.json" "$root/package-lock.json" "$root/skill-lock.json" "$root/THIRD_PARTY_NOTICES.md" "$root/schemas/project.schema.json" "$root/schemas/feature.schema.json" "$root/schemas/handoff.schema.json" "$root/templates/pre-push-hook" "$root/CONTEXT.md" "$root/JIRA_RULES.md"; do
  [[ -f "$file" ]] || errors+=("missing Clowder file: ${file#"$root/"}")
done

configured_hooks_path="$(git -C "$repo_path" config --local --get core.hooksPath 2>/dev/null || true)"
[[ "$configured_hooks_path" == ".clowder/hooks" ]] || errors+=("git core.hooksPath must be .clowder/hooks")
configured_guard_branch="$(git -C "$repo_path" config --local --get clowder.baseBranch 2>/dev/null || true)"
[[ -n "${base_branch_value:-}" && "$configured_guard_branch" == "$base_branch_value" ]] || errors+=("git clowder.baseBranch must match git.base-branch")
consumer_pre_push_hook="$repo_path/.clowder/hooks/pre-push"
if [[ ! -f "$consumer_pre_push_hook" || -L "$consumer_pre_push_hook" ]]; then
  errors+=("Clowder direct-push guard is missing or symbolic: .clowder/hooks/pre-push")
else
  [[ -x "$consumer_pre_push_hook" ]] || errors+=("Clowder direct-push guard is not executable: .clowder/hooks/pre-push")
  cmp -s "$root/templates/pre-push-hook" "$consumer_pre_push_hook" || errors+=("Clowder direct-push guard differs from the reviewed template")
fi

for skill_file in "$root/skills/orchestrate-feature/SKILL.md" "$root/skills/verify-feature/SKILL.md" "$root/skills/clowder-help/SKILL.md"; do
  [[ -f "$skill_file" ]] || errors+=("missing Clowder skill: ${skill_file#"$root/"}")
done

skill_lock_valid=false
if [[ -f "$root/skill-lock.json" ]]; then
  if ! jq -e '(.lockVersion == 2) and (.source == "https://github.com/mattpocock/skills") and (.sourceAuthor == "Matt Pocock") and (.sourceLicense == "MIT") and (.sourceCommit | test("^[0-9a-f]{40}$")) and (.skills | type == "object" and length == 16) and all(.skills[]; (.path | test("^skills/(engineering|productivity)/[a-z0-9-]+$")) and (.files | type == "object" and has("SKILL.md") and length > 0) and all(.files[]; test("^[0-9a-f]{64}$")))' "$root/skill-lock.json" >/dev/null 2>&1; then
    errors+=("skill-lock.json contains an invalid lock version, source commit, reviewed file manifest, or SHA-256 hash")
  else
    skill_lock_valid=true
  fi
fi

sha256_available=false
if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
  sha256_available=true
else
  errors+=("required SHA-256 utility unavailable: shasum or sha256sum")
fi

if [[ "$skill_lock_valid" == true && "$sha256_available" == true ]]; then
  while IFS= read -r skill_name; do
    bundled_skill="$root/skills/$skill_name"
    if [[ ! -d "$bundled_skill" ]]; then
      errors+=("reviewed upstream skill is not bundled: $skill_name")
    elif ! skill_tree_matches_lock "$bundled_skill" "$root/skill-lock.json" "$skill_name"; then
      errors+=("bundled upstream skill hash is stale: $skill_name")
    fi
  done < <(jq -r '.skills | keys[]' "$root/skill-lock.json")

  codex_home_for_skills="${CODEX_HOME:-${HOME:?}/.codex}"
  if [[ -n "${CLOWDER_UPSTREAM_SKILLS_ROOT:-}" ]]; then
    upstream_skill_roots=("$CLOWDER_UPSTREAM_SKILLS_ROOT")
  else
    upstream_skill_roots=("${HOME:?}/.agents/skills" "$codex_home_for_skills/skills")
  fi
  while IFS= read -r skill_name; do
    installed_skill_found=false
    installed_skill_current=false
    installed_skill_stale=false
    for upstream_skill_root in "${upstream_skill_roots[@]}"; do
      upstream_skill_dir="$upstream_skill_root/$skill_name"
      [[ -d "$upstream_skill_dir" ]] || continue
      installed_skill_found=true
      if skill_tree_matches_lock "$upstream_skill_dir" "$root/skill-lock.json" "$skill_name"; then
        installed_skill_current=true
      else
        installed_skill_stale=true
      fi
    done
    if [[ "$installed_skill_found" != true ]]; then
      add_readiness_issue "reviewed upstream skill is not installed: $skill_name"
    elif [[ "$installed_skill_current" != true || "$installed_skill_stale" == true ]]; then
      add_readiness_issue "reviewed upstream skill hash is stale: $skill_name"
    fi
  done < <(jq -r '.skills | keys[]' "$root/skill-lock.json")
fi

for role in product-manager architect developer tester reviewer; do
  agent_file="$root/.codex/agents/$role.toml"
  [[ -f "$agent_file" ]] || errors+=("missing custom agent: .codex/agents/$role.toml")
  for key in name description developer_instructions; do
    if [[ -f "$agent_file" ]] && ! grep -q "^$key" "$agent_file"; then
      errors+=("custom agent $role lacks $key")
    fi
  done
done

codex_home_path="${CODEX_HOME:-${HOME:?}/.codex}"
for role in product-manager architect developer tester reviewer; do
  source_agent="$root/.codex/agents/$role.toml"
  installed_agent="$codex_home_path/agents/clowder-$role.toml"
  if [[ ! -f "$installed_agent" ]]; then
    if [[ "$offline" == true ]]; then
      warnings+=("Clowder role is not installed: clowder-$role.toml")
    else
      errors+=("Clowder role is not installed: clowder-$role.toml")
    fi
  elif ! cmp -s "$source_agent" "$installed_agent"; then
    if [[ "$offline" == true ]]; then
      warnings+=("installed Clowder role is stale: clowder-$role.toml")
    else
      errors+=("installed Clowder role is stale: clowder-$role.toml")
    fi
  fi
done

for skill in orchestrate-feature verify-feature clowder-help; do
  source_skill="$root/skills/$skill/SKILL.md"
  installed_skill_name="$(clowder_skill_install_name "$skill")"
  installed_skill="$codex_home_path/skills/$installed_skill_name/SKILL.md"
  if [[ ! -f "$installed_skill" ]]; then
    if [[ "$offline" == true ]]; then
      warnings+=("Clowder skill is not installed: $installed_skill_name/SKILL.md")
    else
      errors+=("Clowder skill is not installed: $installed_skill_name/SKILL.md")
    fi
  elif ! cmp -s "$source_skill" "$installed_skill"; then
    if [[ "$offline" == true ]]; then
      warnings+=("installed Clowder skill is stale: $installed_skill_name/SKILL.md")
    else
      errors+=("installed Clowder skill is stale: $installed_skill_name/SKILL.md")
    fi
  fi
done

for command_name in git ruby jq node; do
  command -v "$command_name" >/dev/null 2>&1 || errors+=("required command unavailable: $command_name")
done

if [[ "$offline" == true ]]; then
  for command_name in codex supacode gh; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      warnings+=("optional integration unavailable: $command_name")
    fi
  done
else
  for command_name in codex supacode gh; do
    command -v "$command_name" >/dev/null 2>&1 || errors+=("required live integration unavailable: $command_name")
  done
  if [[ "${jira_integration_value:-}" == "acli" ]]; then
    command -v acli >/dev/null 2>&1 || errors+=("required live integration unavailable: acli")
  elif [[ -n "${jira_integration_value:-}" && "$jira_integration_value" != "offline" ]]; then
    errors+=("unsupported Jira integration for deterministic health checks: $jira_integration_value")
  fi

  if command -v codex >/dev/null 2>&1; then
    codex_health="$(codex doctor --json 2>/dev/null || true)"
    if ! jq -e '.overallStatus == "ok"' <<<"$codex_health" >/dev/null 2>&1; then
      errors+=("Codex health probe failed")
    fi
  fi

  if command -v supacode >/dev/null 2>&1 && ! supacode socket >/dev/null 2>&1; then
    errors+=("Supacode health probe failed")
  fi

  if [[ "${jira_integration_value:-}" == "acli" ]] && command -v acli >/dev/null 2>&1; then
    if ! acli jira project view --key "$jira_project_value" --json >/dev/null 2>&1; then
      errors+=("Jira project access probe failed for $jira_project_value")
    fi
    jira_status_query="project = $jira_project_value AND status in (\"To Do\", \"Product Manager\", \"Architect\", \"Developer\", \"Tester\", \"Reviewer\", \"Done\")"
    if ! acli jira workitem search --jql "$jira_status_query" --count >/dev/null 2>&1; then
      errors+=("Jira canonical Status values are missing or inaccessible")
    fi
    jira_work_type_query="project = $jira_project_value AND issuetype in (\"Stage\", \"Epic\", \"Feature\", \"Subfeature\", \"Bug\")"
    if ! acli jira workitem search --jql "$jira_work_type_query" --count >/dev/null 2>&1; then
      errors+=("Jira Clowder work types are missing or inaccessible")
    fi
    jira_lifecycle_query="project = $jira_project_value AND $jira_lifecycle_field_value is not EMPTY"
    if ! acli jira workitem search --jql "$jira_lifecycle_query" --count >/dev/null 2>&1; then
      errors+=("Jira Lifecycle Phase label field is missing or inaccessible: $jira_lifecycle_field_value")
    fi
  fi

  if command -v gh >/dev/null 2>&1 && [[ -n "${github_repository_value:-}" && "$github_repository_value" != *replace-with* ]]; then
    if ! gh repo view "$github_repository_value" --json nameWithOwner >/dev/null 2>&1; then
      errors+=("GitHub repository access probe failed for $github_repository_value")
    fi
  fi
fi

if [[ "$json" == true ]]; then
  jq -n --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" --argjson warnings "$(printf '%s\n' "${warnings[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '{ok: ($errors|length == 0), errors: $errors, warnings: $warnings}'
else
  for item in "${warnings[@]:-}"; do [[ -n "$item" ]] && warn "$item"; done
  for item in "${errors[@]:-}"; do [[ -n "$item" ]] && printf 'clowder: error: %s\n' "$item" >&2; done
  if ((${#errors[@]} == 0)); then
    info "doctor passed for $repo_path"
  fi
fi

((${#errors[@]} == 0))
