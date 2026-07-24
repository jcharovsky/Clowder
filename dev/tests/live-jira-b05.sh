#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"

usage() {
  printf '%s\n' 'Usage: live-jira-b05.sh REPOSITORY_PATH'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

repo_path=$1
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/clowder-b05-live.XXXXXX")"
created_cards=()
created_journals=()

cleanup() {
  local index card_id
  for ((index=${#created_cards[@]} - 1; index >= 0; index--)); do
    card_id=${created_cards[$index]}
    if [[ "$card_id" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
      acli jira workitem delete --key "$card_id" --yes --json >/dev/null 2>&1 || true
    fi
  done
  for journal in "${created_journals[@]}"; do
    [[ "$journal" == "$repo_path/.clowder/runtime/jira-creation/"*.json ]] && rm -f -- "$journal"
  done
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

source "$ROOT/scripts/lib.sh"
repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"
project_key="$(yaml_scalar "$config" jira.project-key)"
run_id="b05-$(date -u '+%Y%m%dT%H%M%SZ')-$$"

create_card() {
  local actor=$1
  local work_type=$2
  local stage_parent=$3
  local linked_parent=$4
  local phase=$5
  local summary=$6
  local slug=$7
  local request="$tmp_dir/create-$slug.json"
  local receipt="$tmp_dir/create-$slug-receipt.json"
  created_journals+=("$repo_path/.clowder/runtime/jira-creation/$run_id-create-$slug.json")

  jq -n \
    --arg mutation_id "$run_id-create-$slug" \
    --arg actor "$actor" \
    --arg work_type "$work_type" \
    --arg stage_parent "$stage_parent" \
    --arg linked_parent "$linked_parent" \
    --arg phase "$phase" \
    --arg summary "$summary" \
    '{
      "schema-version": 1,
      kind: "clowder-jira-mutation",
      "mutation-id": $mutation_id,
      operation: "create",
      actor: $actor,
      card: {
        "work-type": $work_type,
        "stage-parent": (if $stage_parent == "" then null else $stage_parent end),
        "linked-parent": (if $linked_parent == "" then null else $linked_parent end)
      },
      create: {
        summary: $summary,
        description: ("Outcome: verify " + $work_type + " creation.\nReason: exercise the complete B-05 Jira adapter.\nSource: disposable live integration test."),
        status: "To Do",
        "lifecycle-phase": $phase,
        reason: "Run the disposable B-05 live integration test.",
        evidence: ["The required parent state was verified by the adapter."],
        "next-action": "Continue the disposable integration sequence."
      }
    }' > "$request"

  "$ROOT/scripts/jira-mutate.sh" --repo "$repo_path" --request "$request" --receipt "$receipt" --json >/dev/null
  last_card="$(jq -r '.card["key"]' "$receipt")"
  valid_jira_key "$last_card" || die "live creation did not return a Jira key for $work_type"
  [[ "${last_card%%-*}" == "$project_key" ]] || die "live creation returned a card in the wrong project: $last_card"
  created_cards+=("$last_card")
  printf 'created %s %s\n' "$work_type" "$last_card"
}

create_card 'Product Manager' Stage '' '' Intake 'B-05 Live Test Stage' stage
stage_card=$last_card
create_card 'Product Manager' Epic "$stage_card" '' Discovery 'B-05 Live Test Epic' epic
epic_card=$last_card
create_card 'Product Manager' Feature "$stage_card" "$epic_card" 'Feature Definition' 'B-05 Live Test Feature A' feature-a
feature_a=$last_card
create_card 'Product Manager' Feature "$stage_card" "$epic_card" 'Feature Definition' 'B-05 Live Test Feature B' feature-b
feature_b=$last_card
create_card Architect Subfeature "$stage_card" "$feature_a" Design 'B-05 Live Test Subfeature' subfeature
subfeature_card=$last_card
create_card Tester Bug "$stage_card" "$subfeature_card" Testing 'B-05 Live Test Bug' bug
bug_card=$last_card

bug_replay_receipt="$tmp_dir/create-bug-replay-receipt.json"
"$ROOT/scripts/jira-mutate.sh" --repo "$repo_path" --request "$tmp_dir/create-bug.json" --receipt "$bug_replay_receipt" --json >/dev/null
[[ "$(jq -r '.mode' "$bug_replay_receipt")" == replayed ]] || die 'live creation replay did not return replayed mode'
[[ "$(jq -r '.card["key"]' "$bug_replay_receipt")" == "$bug_card" ]] || die 'live creation replay returned a different Jira card'

edit_request="$tmp_dir/edit.json"
edit_receipt="$tmp_dir/edit-receipt.json"
jq -n \
  --arg mutation_id "$run_id-edit-subfeature" \
  --arg card_id "$subfeature_card" \
  --arg stage "$stage_card" \
  --arg parent "$feature_a" \
  '{
    "schema-version": 1,
    kind: "clowder-jira-mutation",
    "mutation-id": $mutation_id,
    operation: "edit",
    actor: "Architect",
    card: {key: $card_id, "work-type": "Subfeature", "stage-parent": $stage, "linked-parent": $parent},
    edit: {
      from: {
        summary: "B-05 Live Test Subfeature",
        description: "Outcome: verify Subfeature creation.\nReason: exercise the complete B-05 Jira adapter.\nSource: disposable live integration test."
      },
      to: {
        summary: "B-05 Live Test Edited Subfeature",
        description: "Outcome: verify non-phase Jira editing.\nReason: exercise the complete B-05 Jira adapter.\nSource: disposable live integration test."
      },
      reason: "Verify deterministic non-phase editing.",
      evidence: ["The disposable Subfeature is in the expected source state."],
      "next-action": "Verify linked-parent replacement."
    }
  }' > "$edit_request"
"$ROOT/scripts/jira-mutate.sh" --repo "$repo_path" --request "$edit_request" --receipt "$edit_receipt" --json >/dev/null
printf 'edited Subfeature %s\n' "$subfeature_card"

relationship_request="$tmp_dir/relationship.json"
relationship_receipt="$tmp_dir/relationship-receipt.json"
jq -n \
  --arg mutation_id "$run_id-reparent-subfeature" \
  --arg card_id "$subfeature_card" \
  --arg stage "$stage_card" \
  --arg from_parent "$feature_a" \
  --arg to_parent "$feature_b" \
  '{
    "schema-version": 1,
    kind: "clowder-jira-mutation",
    "mutation-id": $mutation_id,
    operation: "relationship",
    actor: "Architect",
    card: {key: $card_id, "work-type": "Subfeature", "stage-parent": $stage},
    relationship: {
      from: $from_parent,
      to: $to_parent,
      reason: "Verify deterministic linked-parent replacement.",
      evidence: ["Both disposable Features have the same native Stage Parent."],
      "next-action": "Complete and clean up the disposable integration test."
    }
  }' > "$relationship_request"
"$ROOT/scripts/jira-mutate.sh" --repo "$repo_path" --request "$relationship_request" --receipt "$relationship_receipt" --json >/dev/null

relationship_replay_receipt="$tmp_dir/relationship-replay-receipt.json"
"$ROOT/scripts/jira-mutate.sh" --repo "$repo_path" --request "$relationship_request" --receipt "$relationship_replay_receipt" --json >/dev/null
[[ "$(jq -r '.mode' "$relationship_replay_receipt")" == replayed ]] || die 'live relationship replay did not return replayed mode'
printf 'reparented Subfeature %s from %s to %s\n' "$subfeature_card" "$feature_a" "$feature_b"
printf '%s\n' 'live Jira B-05 integration test passed'
