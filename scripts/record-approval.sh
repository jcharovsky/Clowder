#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
feature_input=""
approval=""
status="approved"
approved_by=""
revision=""

usage() {
  cat <<'EOF'
Usage: record-approval.sh [--repo PATH] [--feature PATH|JIRA-123-slug] --approval KIND --by PERSON --revision REVISION [--status STATUS]

KIND: prd, architecture, residual-risk, review, testing, merge.
STATUS: approved, rejected, pending.
For approved PRD and architecture decisions, --revision must be the current artifact SHA-256. For review, testing, residual-risk, and merge decisions, it must be the reviewed code HEAD. Approved merge decisions also bind the current pull-request body, independent evidence, and non-self-referential manifest state. This records a decision only. It never commits, pushes, merges, or changes Jira.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --feature) feature_input=${2:?missing value for --feature}; shift 2 ;;
    --approval) approval=${2:?missing value for --approval}; shift 2 ;;
    --status) status=${2:?missing value for --status}; shift 2 ;;
    --by) approved_by=${2:?missing value for --by}; shift 2 ;;
    --revision) revision=${2:?missing value for --revision}; shift 2 ;;
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
[[ "$approval" =~ ^(prd|architecture|residual-risk|review|testing|merge)$ ]] || die "invalid approval kind: $approval"
[[ "$status" =~ ^(approved|rejected|pending)$ ]] || die "invalid approval status: $status"
[[ -n "$approved_by" ]] || die "--by is required"
[[ -n "$revision" ]] || die "--revision is required"
[[ "$approved_by" != *$'\n'* && "$revision" != *$'\n'* ]] || die "approval values cannot contain newlines"

case "$approval" in
  prd) configured_approver_path="approvals.product-owner" ;;
  architecture) configured_approver_path="approvals.architecture-owner" ;;
  residual-risk) configured_approver_path="approvals.residual-risk-owner" ;;
  merge) configured_approver_path="approvals.merge-owner" ;;
  review|testing) configured_approver_path="" ;;
esac
if [[ -n "$configured_approver_path" ]]; then
  configured_approver="$(yaml_scalar "$config" "$configured_approver_path" 2>/dev/null || true)"
  [[ -n "$configured_approver" && "$configured_approver" != *replace-with* ]] || die "configured approver is missing: $configured_approver_path"
  [[ "$approved_by" == "$configured_approver" ]] || die "$approval decision-maker does not match $configured_approver_path"
fi

case "$approval" in
  prd) prefix="approvals.prd"; revision_field="revision" ;;
  architecture) prefix="approvals.architecture"; revision_field="revision" ;;
  residual-risk) prefix="approvals.residual-risk"; revision_field="revision" ;;
  review) prefix="approvals.review"; revision_field="head" ;;
  testing) prefix="approvals.testing"; revision_field="head" ;;
  merge) prefix="approvals.merge"; revision_field="head" ;;
esac

if [[ "$approval" == "prd" || "$approval" == "architecture" ]]; then
  expected_revision="$(approval_revision "$repo_path" "$feature_dir" "$approval")"
  [[ "$revision" == "$expected_revision" ]] || die "revision does not match current $approval evidence, expected $expected_revision"
else
  git -C "$repo_path" rev-parse --verify "$revision^{commit}" >/dev/null 2>&1 || die "revision does not identify a Git commit: $revision"
  git -C "$repo_path" merge-base --is-ancestor "$revision" HEAD >/dev/null 2>&1 || die "revision is not an ancestor of current HEAD: $revision"
  non_attestation_changes="$(non_attestation_changes_since "$repo_path" "$feature_dir" "$revision" true)"
  [[ -z "$non_attestation_changes" ]] || die "revision is stale because non-attestation changes follow it: $(printf '%s' "$non_attestation_changes" | paste -sd ', ' -)"
fi

updates=(
  "$prefix.status" "$status"
  "$prefix.$revision_field" "$revision"
  "$prefix.approved-by" "$approved_by"
)

case "$approval" in
  testing)
    feature_risk="$(yaml_scalar "$manifest" feature.risk 2>/dev/null || true)"
    residual_status="not-required"
    [[ "$feature_risk" == "R3" ]] && residual_status="pending"
    updates+=(
      feature.head-revision "$revision"
      approvals.review.status pending
      approvals.review.head ""
      approvals.review.approved-by ""
      approvals.residual-risk.status "$residual_status"
      approvals.residual-risk.revision ""
      approvals.residual-risk.approved-by ""
      approvals.merge.status pending
      approvals.merge.head ""
      approvals.merge.approved-by ""
      approvals.merge.attestation-revision ""
    )
    ;;
  review)
    reviewed_head="$(yaml_scalar "$manifest" feature.head-revision 2>/dev/null || true)"
    [[ "$revision" == "$reviewed_head" ]] || die "review revision does not match the reviewed code HEAD: $reviewed_head"
    if [[ "$status" == "approved" ]]; then
      [[ "$(yaml_scalar "$manifest" approvals.testing.status 2>/dev/null || true)" == "approved" ]] || die "review approval requires approved testing"
      [[ "$(yaml_scalar "$manifest" approvals.testing.head 2>/dev/null || true)" == "$reviewed_head" ]] || die "review approval requires testing of the same code HEAD"
    fi
    updates+=(
      approvals.merge.status pending
      approvals.merge.head ""
      approvals.merge.approved-by ""
      approvals.merge.attestation-revision ""
    )
    ;;
  residual-risk)
    reviewed_head="$(yaml_scalar "$manifest" feature.head-revision 2>/dev/null || true)"
    [[ "$revision" == "$reviewed_head" ]] || die "residual-risk revision does not match the reviewed code HEAD: $reviewed_head"
    ;;
  merge)
    reviewed_head="$(yaml_scalar "$manifest" feature.head-revision 2>/dev/null || true)"
    [[ "$revision" == "$reviewed_head" ]] || die "merge revision does not match the reviewed code HEAD: $reviewed_head"
    if [[ "$status" == "approved" ]]; then
      [[ "$(yaml_scalar "$manifest" approvals.review.status 2>/dev/null || true)" == "approved" ]] || die "merge approval requires an approved review"
      [[ "$(yaml_scalar "$manifest" approvals.testing.status 2>/dev/null || true)" == "approved" ]] || die "merge approval requires approved testing"
      [[ "$(yaml_scalar "$manifest" approvals.review.head 2>/dev/null || true)" == "$reviewed_head" ]] || die "merge approval requires review of the same code HEAD"
      [[ "$(yaml_scalar "$manifest" approvals.testing.head 2>/dev/null || true)" == "$reviewed_head" ]] || die "merge approval requires testing of the same code HEAD"
      merge_attestation="$(merge_attestation_revision "$feature_dir")"
    else
      merge_attestation=""
    fi
    updates+=(approvals.merge.attestation-revision "$merge_attestation")
    ;;
esac

update_yaml_values "$manifest" "${updates[@]}"

info "recorded $status approval for $approval on $(basename -- "$feature_dir")"
