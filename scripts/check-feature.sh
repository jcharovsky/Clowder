#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
feature_input=""
gate="feature-created"
json=false
run_configured=false
receipt_path=""

usage() {
  cat <<'EOF'
Usage: check-feature.sh [--repo PATH] [--feature PATH|JIRA-123-slug] [--gate NAME] [--json] [--run-configured] [--receipt PATH]

Gates: feature-created, ready-for-development, ready-for-review, ready-for-merge.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --feature) feature_input=${2:?missing value for --feature}; shift 2 ;;
    --gate) gate=${2:?missing value for --gate}; shift 2 ;;
    --json) json=true; shift ;;
    --run-configured) run_configured=true; shift ;;
    --receipt) receipt_path=${2:?missing value for --receipt}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"
feature_root="$(yaml_scalar "$config" documents.feature-root)"
adr_root="$(yaml_scalar "$config" documents.adr-root)"
prefix="$(yaml_scalar "$config" git.feature-prefix)"
configured_jira_project="$(yaml_scalar "$config" jira.project-key)"
current_branch="$(git -C "$repo_path" branch --show-current)"
[[ -n "$current_branch" ]] || die "the current worktree is detached; a Feature branch is required"

if [[ -n "$feature_input" ]]; then
  if [[ -d "$feature_input" ]]; then
    feature_dir="$(cd -- "$feature_input" && pwd -P)"
  else
    feature_dir="$repo_path/$feature_root/$feature_input"
  fi
else
  feature_id="${current_branch#*/}"
  feature_dir="$repo_path/$feature_root/$feature_id"
fi

manifest="$feature_dir/feature.yaml"
errors=()
warnings=()

add_error() { errors+=("$*"); }
add_warning() { warnings+=("$*"); }

if [[ ! -f "$manifest" ]]; then
  add_error "missing Feature manifest: $manifest"
else
  if ! validate_yaml "$manifest"; then
    add_error "invalid Feature manifest YAML: $manifest"
  else
    while IFS= read -r schema_error; do
      [[ -n "$schema_error" ]] && add_error "Feature schema: $schema_error"
    done < <(schema_validation_errors "$(clowder_root)/schemas/feature.schema.json" "$manifest")
  fi
fi

if [[ -f "$manifest" ]]; then
  schema_version="$(yaml_scalar "$manifest" schema-version 2>/dev/null || true)"
  jira_key="$(yaml_scalar "$manifest" feature.jira-key 2>/dev/null || true)"
  slug="$(yaml_scalar "$manifest" feature.slug 2>/dev/null || true)"
  feature_name="$(yaml_scalar "$manifest" feature.name 2>/dev/null || true)"
  lifecycle_phase="$(yaml_scalar "$manifest" feature.lifecycle-phase 2>/dev/null || true)"
  risk="$(yaml_scalar "$manifest" feature.risk 2>/dev/null || true)"
  manifest_branch="$(yaml_scalar "$manifest" feature.branch 2>/dev/null || true)"
  manifest_worktree="$(yaml_scalar "$manifest" feature.worktree 2>/dev/null || true)"
  base_revision="$(yaml_scalar "$manifest" feature.base-revision 2>/dev/null || true)"
  manifest_head="$(yaml_scalar "$manifest" feature.head-revision 2>/dev/null || true)"
  [[ "$schema_version" == "1" ]] || add_error "Feature schema: $.schema-version: expected constant 1"
  [[ -n "$jira_key" ]] || add_error "manifest lacks feature.jira-key"
  [[ -z "$jira_key" ]] || valid_jira_key "$jira_key" || add_error "Feature schema: $.feature.jira-key is invalid"
  [[ -z "$jira_key" || "${jira_key%%-*}" == "$configured_jira_project" ]] || add_error "manifest Jira key does not belong to configured project"
  [[ -n "$slug" ]] || add_error "manifest lacks feature.slug"
  [[ -z "$slug" ]] || valid_slug "$slug" || add_error "Feature schema: $.feature.slug is invalid"
  [[ -n "$feature_name" ]] || add_error "manifest lacks feature.name"
  [[ "$lifecycle_phase" =~ ^(intake|discovery|feature-definition|prd|design|test-planning|ready-for-development|orchestration|development|developer-verification|testing|review|remediation|ready-for-merge|production|complete|needs-information|rejected)$ ]] || add_error "Feature schema: $.feature.lifecycle-phase is invalid"
  [[ "$risk" =~ ^R[123]$ ]] || add_error "Feature schema: $.feature.risk: expected one of R1, R2, R3"
  [[ "$manifest_branch" == "$current_branch" ]] || add_error "manifest branch does not match current branch"
  [[ "$manifest_worktree" == "$repo_path" ]] || add_error "manifest worktree does not match current worktree"
  if [[ -z "$base_revision" ]]; then
    add_error "manifest lacks feature.base-revision"
  elif ! git -C "$repo_path" rev-parse --verify "$base_revision^{commit}" >/dev/null 2>&1; then
    add_error "manifest base revision does not identify a commit"
  elif ! git -C "$repo_path" merge-base --is-ancestor "$base_revision" HEAD >/dev/null 2>&1; then
    add_error "manifest base revision is not an ancestor of current HEAD"
  fi
  if [[ -n "$manifest_head" ]]; then
    current_head="$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$manifest_head" != "$current_head" && "$gate" != "ready-for-merge" ]]; then
      add_warning "manifest reviewed head differs from current HEAD"
    fi
  fi
fi

if [[ -n "${jira_key:-}" && -n "${slug:-}" ]]; then
  expected_branch="$prefix/$jira_key-$slug"
  [[ "$current_branch" == "$expected_branch" ]] || add_error "branch mapping is invalid, expected $expected_branch"
  [[ "$(basename -- "$feature_dir")" == "$jira_key-$slug" ]] || add_error "Feature directory name does not match Jira key and slug"
fi

for artifact in PRD.md TECHNICAL_DESIGN.md TEST_PLAN.md evidence/developer.md evidence/reviewer.md evidence/tester.md; do
  [[ -f "$feature_dir/$artifact" ]] || add_error "missing Feature artifact: $artifact"
done

if [[ -f "$manifest" ]]; then
  for path in feature.jira-key feature.slug feature.lifecycle-phase feature.branch feature.worktree artifacts.prd artifacts.technical-design artifacts.test-plan; do
    yaml_scalar "$manifest" "$path" >/dev/null 2>&1 || add_error "missing manifest field: $path"
  done
  [[ "$(yaml_scalar "$manifest" artifacts.prd 2>/dev/null || true)" == "PRD.md" ]] || add_error "Feature schema: $.artifacts.prd must equal PRD.md"
  [[ "$(yaml_scalar "$manifest" artifacts.technical-design 2>/dev/null || true)" == "TECHNICAL_DESIGN.md" ]] || add_error "Feature schema: $.artifacts.technical-design must equal TECHNICAL_DESIGN.md"
  [[ "$(yaml_scalar "$manifest" artifacts.test-plan 2>/dev/null || true)" == "TEST_PLAN.md" ]] || add_error "Feature schema: $.artifacts.test-plan must equal TEST_PLAN.md"
fi

feature_rel="${feature_dir#"$repo_path/"}"
if [[ "$feature_rel" == "$feature_dir" ]]; then
  add_error "Feature directory is outside the product repository"
else
  allowed_adrs=()
  if [[ -f "$manifest" ]]; then
    while IFS= read -r adr_path; do
      [[ -n "$adr_path" ]] && allowed_adrs+=("$adr_path")
    done < <(ruby -r yaml -e '
      data = YAML.safe_load(File.read(ARGV[0]), aliases: true)
      Array(data.dig("artifacts", "adrs")).each { |path| puts path }
    ' "$manifest")
  fi
  adr_is_allowed() {
    local candidate=$1
    local allowed
    for allowed in "${allowed_adrs[@]:-}"; do
      [[ "$candidate" == "$allowed" ]] && return 0
    done
    return 1
  }
  validate_scope_path() {
    local changed_path=$1
    [[ -n "$changed_path" ]] || return 0
    if [[ "$changed_path" == "$feature_rel"/* ]]; then
      return 0
    fi
    if [[ "$changed_path" == "$feature_root"/* ]]; then
      add_error "changed file belongs to another Feature: $changed_path"
      return 0
    fi
    if [[ "$changed_path" == "$adr_root"/* ]]; then
      adr_is_allowed "$changed_path" || add_error "changed ADR is not listed in Feature manifest: $changed_path"
      return 0
    fi
    if [[ "$changed_path" == .clowder/* ]]; then
      add_error "Clowder project configuration is outside Feature scope: $changed_path"
    fi
  }
  while IFS= read -r path; do
    validate_scope_path "$path"
  done < <({
    if git -C "$repo_path" rev-parse --verify HEAD >/dev/null 2>&1; then
      git -C "$repo_path" -c diff.renames=false diff --name-only HEAD
      git -C "$repo_path" -c diff.renames=false diff --cached --name-only HEAD
    fi
    git -C "$repo_path" ls-files --others --exclude-standard
  } | awk 'NF && !seen[$0]++')
  if [[ -n "${base_revision:-}" ]] && git -C "$repo_path" rev-parse --verify "$base_revision^{commit}" >/dev/null 2>&1; then
    while IFS= read -r path; do
      validate_scope_path "$path"
    done < <(git -C "$repo_path" -c diff.renames=false diff --name-only "$base_revision"..HEAD)
  fi
fi

contains_placeholder() {
  local file=$1
  grep -Eq 'Replace with|Describe the |Pending\.' "$file"
}

if [[ "$gate" != "feature-created" ]]; then
  for artifact in PRD.md TECHNICAL_DESIGN.md TEST_PLAN.md; do
    contains_placeholder "$feature_dir/$artifact" && add_error "artifact still contains template placeholder: $artifact"
  done
fi

if [[ "$gate" == "ready-for-development" || "$gate" == "ready-for-review" || "$gate" == "ready-for-merge" ]]; then
  for path in approvals.prd.status approvals.architecture.status; do
    [[ "$(yaml_scalar "$manifest" "$path" 2>/dev/null || true)" == "approved" ]] || add_error "approval is not approved: $path"
  done
  for kind in prd architecture; do
    approval_value="$(yaml_scalar "$manifest" "approvals.$kind.revision" 2>/dev/null || true)"
    expected_value="$(approval_revision "$repo_path" "$feature_dir" "$kind" 2>/dev/null || true)"
    [[ -n "$approval_value" && "$approval_value" == "$expected_value" ]] || add_error "approval revision is stale: $kind"
  done
  product_owner="$(yaml_scalar "$config" approvals.product-owner 2>/dev/null || true)"
  architecture_owner="$(yaml_scalar "$config" approvals.architecture-owner 2>/dev/null || true)"
  [[ -n "$product_owner" && "$(yaml_scalar "$manifest" approvals.prd.approved-by 2>/dev/null || true)" == "$product_owner" ]] || add_error "PRD decision-maker does not match configured product owner"
  [[ -n "$architecture_owner" && "$(yaml_scalar "$manifest" approvals.architecture.approved-by 2>/dev/null || true)" == "$architecture_owner" ]] || add_error "architecture decision-maker does not match configured architecture owner"
fi

if [[ "$gate" == "ready-for-review" || "$gate" == "ready-for-merge" ]]; then
  [[ -z "$(git -C "$repo_path" status --porcelain=v1 --untracked-files=all)" ]] || add_error "Feature worktree has uncommitted changes"
  grep -Eq '^\| Status \| (Verified|Passed|Approved)' "$feature_dir/evidence/developer.md" || add_error "Developer evidence is not verified"
fi

if [[ "$gate" == "ready-for-merge" ]]; then
  if [[ ! -f "$feature_dir/PULL_REQUEST.md" ]]; then
    add_error "missing Feature artifact: PULL_REQUEST.md"
  elif contains_placeholder "$feature_dir/PULL_REQUEST.md"; then
    add_error "pull-request body still contains a template placeholder"
  fi
  [[ "$(yaml_scalar "$manifest" approvals.review.status 2>/dev/null || true)" == "approved" ]] || add_error "Reviewer approval is not current"
  [[ "$(yaml_scalar "$manifest" approvals.testing.status 2>/dev/null || true)" == "approved" ]] || add_error "Tester approval is not current"
  [[ "$(yaml_scalar "$manifest" approvals.merge.status 2>/dev/null || true)" == "approved" ]] || add_error "HITL merge approval is missing"
  reviewed_head="$(yaml_scalar "$manifest" feature.head-revision 2>/dev/null || true)"
  [[ -n "$reviewed_head" ]] || add_error "Feature reviewed head is missing"
  if [[ -n "$reviewed_head" ]]; then
    if ! git -C "$repo_path" rev-parse --verify "$reviewed_head^{commit}" >/dev/null 2>&1; then
      add_error "Feature reviewed head does not identify a commit"
    elif ! git -C "$repo_path" merge-base --is-ancestor "$reviewed_head" HEAD >/dev/null 2>&1; then
      add_error "Feature reviewed head is not an ancestor of current HEAD"
    else
      while IFS= read -r changed_path; do
        [[ -n "$changed_path" ]] && add_error "non-attestation change after reviewed head: $changed_path"
      done < <(non_attestation_changes_since "$repo_path" "$feature_dir" "$reviewed_head")
    fi
  fi
  [[ "$(yaml_scalar "$manifest" approvals.review.head 2>/dev/null || true)" == "$reviewed_head" ]] || add_error "Reviewer approval head is stale"
  [[ "$(yaml_scalar "$manifest" approvals.testing.head 2>/dev/null || true)" == "$reviewed_head" ]] || add_error "Tester approval head is stale"
  [[ "$(yaml_scalar "$manifest" approvals.merge.head 2>/dev/null || true)" == "$reviewed_head" ]] || add_error "HITL merge approval head is stale"
  merge_owner="$(yaml_scalar "$config" approvals.merge-owner 2>/dev/null || true)"
  [[ -n "$merge_owner" && "$(yaml_scalar "$manifest" approvals.merge.approved-by 2>/dev/null || true)" == "$merge_owner" ]] || add_error "merge decision-maker does not match configured merge owner"
  recorded_attestation_revision="$(yaml_scalar "$manifest" approvals.merge.attestation-revision 2>/dev/null || true)"
  expected_attestation_revision="$(merge_attestation_revision "$feature_dir" 2>/dev/null || true)"
  [[ -n "$recorded_attestation_revision" && "$recorded_attestation_revision" == "$expected_attestation_revision" ]] || add_error "merge attestation revision is stale"
  if [[ "${risk:-}" == "R3" ]]; then
    [[ "$(yaml_scalar "$manifest" approvals.residual-risk.status 2>/dev/null || true)" == "approved" ]] || add_error "R3 residual-risk approval is missing"
    [[ "$(yaml_scalar "$manifest" approvals.residual-risk.revision 2>/dev/null || true)" == "$reviewed_head" ]] || add_error "R3 residual-risk approval head is stale"
    residual_risk_owner="$(yaml_scalar "$config" approvals.residual-risk-owner 2>/dev/null || true)"
    [[ -n "$residual_risk_owner" && "$(yaml_scalar "$manifest" approvals.residual-risk.approved-by 2>/dev/null || true)" == "$residual_risk_owner" ]] || add_error "residual-risk decision-maker does not match configured owner"
  fi
  grep -Eq '^\| Status \| (Passed|Approved)' "$feature_dir/evidence/reviewer.md" || add_error "Reviewer evidence is not approved"
  grep -Eq '^\| Status \| (Passed|Approved)' "$feature_dir/evidence/tester.md" || add_error "Tester evidence is not approved"

  pull_request="$(yaml_scalar "$manifest" feature.pull-request 2>/dev/null || true)"
  github_repository="$(yaml_scalar "$config" github.repository 2>/dev/null || true)"
  github_review_evidence="$(yaml_scalar "$config" github.review-evidence 2>/dev/null || true)"
  [[ -n "$github_review_evidence" ]] || github_review_evidence="clowder-attestation"
  [[ "$github_review_evidence" =~ ^(clowder-attestation|github-approval)$ ]] || add_error "github.review-evidence must be clowder-attestation or github-approval"
  current_head="$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)"
  pull_request_prefix="https://github.com/$github_repository/pull/"
  if [[ -z "$pull_request" ]]; then
    add_error "Feature pull request is missing"
  elif [[ -z "$github_repository" || "$pull_request" != "$pull_request_prefix"* || ! "${pull_request#"$pull_request_prefix"}" =~ ^[0-9]+$ ]]; then
    add_error "Feature pull request does not belong to configured GitHub repository"
  elif ! command -v gh >/dev/null 2>&1; then
    add_error "required command unavailable: gh"
  else
    pull_request_json=""
    if ! pull_request_json="$(gh pr view "$pull_request" --json state,isDraft,headRefOid,reviewDecision,statusCheckRollup 2>/dev/null)"; then
      add_error "GitHub pull request could not be inspected"
    elif ! jq -e 'type == "object"' <<<"$pull_request_json" >/dev/null 2>&1; then
      add_error "GitHub pull request returned invalid JSON"
    else
      [[ "$(jq -r '.state // ""' <<<"$pull_request_json")" == "OPEN" ]] || add_error "pull request is not open"
      jq -e '.isDraft == false' <<<"$pull_request_json" >/dev/null 2>&1 || add_error "pull request is still a draft"
      [[ "$(jq -r '.headRefOid // ""' <<<"$pull_request_json")" == "$current_head" ]] || add_error "pull request head does not match current HEAD"
      review_decision="$(jq -r '.reviewDecision // ""' <<<"$pull_request_json")"
      [[ "$review_decision" != "CHANGES_REQUESTED" ]] || add_error "pull request has unresolved GitHub change requests"
      if [[ "$github_review_evidence" == "github-approval" && "$review_decision" != "APPROVED" ]]; then
        add_error "pull request does not have an approved GitHub review"
      fi

      while IFS= read -r required_check; do
        [[ -n "$required_check" ]] || continue
        if ! jq -e --arg check "$required_check" '
          [.statusCheckRollup[]? |
            select((.name // .context // "") == $check) |
            select(
              ((.status // "") == "COMPLETED" and (.conclusion // "") == "SUCCESS") or
              ((.state // "") == "SUCCESS")
            )
          ] | length > 0
        ' <<<"$pull_request_json" >/dev/null 2>&1; then
          add_error "required GitHub check is not successful: $required_check"
        fi
      done < <(ruby -r yaml -e '
        data = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        Array(data.dig("quality", "required-checks")).each { |check| puts check }
      ' "$config")
    fi
  fi
fi

case "$gate" in
  feature-created|ready-for-development|ready-for-review|ready-for-merge) ;;
  *) add_error "unknown gate: $gate" ;;
esac

receipt_parent=""
if [[ -n "$receipt_path" && "$gate" != "ready-for-merge" ]]; then
  add_error "Ready for Merge receipts require --gate ready-for-merge"
elif [[ -n "$receipt_path" ]]; then
  receipt_parent="$(dirname -- "$receipt_path")"
  receipt_name="$(basename -- "$receipt_path")"
  if [[ ! -d "$receipt_parent" ]]; then
    add_error "receipt parent directory does not exist: $receipt_parent"
  elif [[ -e "$receipt_path" || -L "$receipt_path" ]]; then
    add_error "receipt path already exists: $receipt_path"
  else
    receipt_parent="$(cd -- "$receipt_parent" && pwd -P)"
    receipt_path="$receipt_parent/$receipt_name"
    case "$receipt_path" in
      "$repo_path"|"$repo_path"/*) add_error "receipt path must be outside the product repository" ;;
    esac
  fi
fi

if [[ "$gate" == "ready-for-review" || "$gate" == "ready-for-merge" ]]; then
  run_configured=true
fi

if [[ "$run_configured" == true && ${#errors[@]} -gt 0 ]]; then
  add_warning "configured quality commands were skipped because deterministic validation failed"
elif [[ "$run_configured" == true ]]; then
  for command_name in format lint typecheck build unit integration e2e; do
    command_value="$(yaml_scalar "$config" "quality.commands.$command_name" 2>/dev/null || true)"
    [[ -n "$command_value" ]] || continue
    info "running configured $command_name check"
    (cd -- "$repo_path" && bash -c "$command_value") || add_error "configured $command_name check failed"
  done
fi

receipt_written=""
if [[ -n "$receipt_path" && ${#errors[@]} -eq 0 ]]; then
  if ((${#errors[@]} == 0)); then
    generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    required_checks_json="$(ruby -r yaml -r json -e '
      data = YAML.safe_load(File.read(ARGV[0]), aliases: true)
      checks = Array(data.dig("quality", "required-checks")).map { |name| {"name" => name, "result" => "passed"} }
      puts JSON.generate(checks)
    ' "$config")"
    receipt_tmp="$(mktemp "$receipt_parent/.clowder-ready-for-merge.XXXXXX")"
    trap 'rm -f -- "$receipt_tmp"' EXIT
    jq -n \
      --arg generated_at "$generated_at" \
      --arg repository "$github_repository" \
      --arg jira_feature "$jira_key" \
      --arg pull_request "$pull_request" \
      --arg review_evidence "$github_review_evidence" \
      --arg reviewed_head "$reviewed_head" \
      --arg final_head "$current_head" \
      --arg attestation_revision "$recorded_attestation_revision" \
      --argjson required_checks "$required_checks_json" \
      '{
        "schema-version": 1,
        kind: "clowder-ready-for-merge-receipt",
        result: "passed",
        "generated-at": $generated_at,
        repository: $repository,
        "jira-feature": $jira_feature,
        "pull-request": $pull_request,
        "review-evidence": $review_evidence,
        "reviewed-code-head": $reviewed_head,
        "final-pull-request-head": $final_head,
        "attestation-revision": $attestation_revision,
        "required-checks": $required_checks
      }' > "$receipt_tmp"
    mv -- "$receipt_tmp" "$receipt_path"
    trap - EXIT
    receipt_written="$receipt_path"
  fi
fi

if [[ "$json" == true ]]; then
  jq -n --arg gate "$gate" --arg feature "$feature_dir" --arg receipt "$receipt_written" --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" --argjson warnings "$(printf '%s\n' "${warnings[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '{ok: ($errors|length == 0), gate: $gate, feature: $feature, receipt: (if $receipt == "" then null else $receipt end), errors: $errors, warnings: $warnings}'
else
  for item in "${warnings[@]:-}"; do [[ -n "$item" ]] && warn "$item"; done
  for item in "${errors[@]:-}"; do [[ -n "$item" ]] && printf 'clowder: error: %s\n' "$item" >&2; done
  if ((${#errors[@]} == 0)); then
    info "$gate gate passed for $feature_dir"
    [[ -z "$receipt_written" ]] || info "Ready for Merge receipt written to $receipt_written"
  fi
fi

((${#errors[@]} == 0))
