#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
request_file=""
receipt_file=""
json=false

relationship_die() {
  local message=$1
  if [[ "$json" == true ]]; then
    jq -n --arg error "$message" '{ok: false, error: $error}' >&2
  else
    printf 'clowder: %s\n' "$message" >&2
  fi
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --request) request_file=${2:?missing value for --request}; shift 2 ;;
    --receipt) receipt_file=${2:?missing value for --receipt}; shift 2 ;;
    --json) json=true; shift ;;
    *) relationship_die "unknown argument: $1" ;;
  esac
done

[[ -n "$request_file" ]] || relationship_die 'request path is required'
[[ -n "$receipt_file" ]] || relationship_die 'receipt path is required'
repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"
[[ -f "$request_file" && ! -L "$request_file" ]] || relationship_die "request must be a regular, non-symbolic file: $request_file"
validate_json "$request_file" || relationship_die "request is not valid JSON: $request_file"
path_is_within "$request_file" "$repo_path" && relationship_die 'request path must be outside the product repository'
receipt_parent="$(dirname -- "$receipt_file")"
[[ -d "$receipt_parent" ]] || relationship_die "receipt parent directory does not exist: $receipt_parent"
[[ ! -e "$receipt_file" && ! -L "$receipt_file" ]] || relationship_die "receipt path already exists: $receipt_file"
path_is_within "$receipt_file" "$repo_path" && relationship_die 'receipt path must be outside the product repository'

require_command jq
require_command acli
jira_integration="$(yaml_scalar "$config" jira.integration 2>/dev/null || true)"
jira_project="$(yaml_scalar "$config" jira.project-key 2>/dev/null || true)"
jira_link_type="$(yaml_scalar "$config" jira.child-link-type 2>/dev/null || true)"
jira_lifecycle_field="$(yaml_scalar "$config" jira.lifecycle-phase-field 2>/dev/null || true)"
github_repository="$(yaml_scalar "$config" github.repository 2>/dev/null || true)"
[[ "$jira_integration" == acli ]] || relationship_die 'Jira integration must be configured as acli'
[[ -n "$jira_project" ]] || relationship_die 'Jira project key is missing from project configuration'
[[ "$jira_link_type" == Child ]] || relationship_die 'Jira child link type must be Child'
[[ "$jira_lifecycle_field" == labels ]] || relationship_die 'Jira Lifecycle Phase field must be the native labels field'
[[ -n "$github_repository" ]] || relationship_die 'GitHub repository is missing from project configuration'

if ! jq -e '
  type == "object" and length == 7 and
  .["schema-version"] == 1 and
  .kind == "clowder-jira-mutation" and
  (.["mutation-id"] | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
  .operation == "relationship" and
  (.actor | IN("Orchestrator", "Product Manager", "Architect", "Developer", "Tester", "Reviewer")) and
  (.card | type == "object" and length == 3) and
  (.relationship | type == "object" and length == 5) and
  (.relationship.from == null or (.relationship.from | type == "string")) and
  (.relationship.to == null or (.relationship.to | type == "string")) and
  (.relationship.from != .relationship.to) and
  (.relationship.reason | type == "string" and length > 0 and (contains("\n") | not)) and
  (.relationship.evidence | type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))) and
  (.relationship["next-action"] | type == "string" and length > 0 and (contains("\n") | not))
' "$request_file" >/dev/null; then
  relationship_die 'request does not satisfy the Jira relationship mutation contract'
fi

mutation_id="$(jq -r '.["mutation-id"]' "$request_file")"
actor="$(jq -r '.actor' "$request_file")"
card_id="$(jq -r '.card["key"]' "$request_file")"
work_type="$(jq -r '.card["work-type"]' "$request_file")"
stage_parent="$(jq -r '.card["stage-parent"] // empty' "$request_file")"
from_parent="$(jq -r '.relationship.from // empty' "$request_file")"
to_parent="$(jq -r '.relationship.to // empty' "$request_file")"
reason="$(jq -r '.relationship.reason' "$request_file")"
next_action="$(jq -r '.relationship["next-action"]' "$request_file")"

valid_jira_key "$card_id" || relationship_die "invalid Jira card key: $card_id"
[[ "${card_id%%-*}" == "$jira_project" ]] || relationship_die 'Jira card belongs to a different configured project'
[[ "$work_type" =~ ^(Stage|Epic|Feature|Subfeature|Bug)$ ]] || relationship_die "invalid Jira work type: $work_type"
if [[ "$work_type" == Stage ]]; then
  [[ -z "$stage_parent" ]] || relationship_die 'a Stage cannot have a native Parent'
  [[ -z "$to_parent" ]] || relationship_die 'a Stage cannot receive a linked Child parent'
elif [[ "$work_type" == Epic ]]; then
  valid_jira_key "$stage_parent" || relationship_die 'an Epic requires a valid native Stage Parent'
  [[ -z "$to_parent" ]] || relationship_die 'an Epic cannot receive a linked Child parent'
else
  valid_jira_key "$stage_parent" || relationship_die "$work_type requires a valid native Stage Parent"
  valid_jira_key "$to_parent" || relationship_die "$work_type relationship target must be a valid linked Child parent"
fi
[[ -z "$from_parent" ]] || valid_jira_key "$from_parent" || relationship_die 'relationship source must be a valid Jira key or null'

request_digest="$(jq -cS . "$request_file" | sha256_stream)"
intent_marker="CLOWDER_JIRA_MUTATION_INTENT v1 id=$mutation_id sha256=$request_digest"
completion_marker="CLOWDER_JIRA_MUTATION_COMPLETION v1 id=$mutation_id sha256=$request_digest"
intent_prefix="CLOWDER_JIRA_MUTATION_INTENT v1 id=$mutation_id "
completion_prefix="CLOWDER_JIRA_MUTATION_COMPLETION v1 id=$mutation_id "

tmp_dir="$(mktemp -d "$receipt_parent/.clowder-jira-relationship.XXXXXX")"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

read_card_key() {
  local target_card=$1
  local target_file=$2
  if ! acli jira workitem view "$target_card" --fields 'key,summary,status,labels,issuetype,parent,issuelinks' --json > "$target_file"; then
    relationship_die "failed to read Jira card: $target_card"
  fi
  validate_json "$target_file" || relationship_die "Jira returned invalid JSON for card: $target_card"
}

read_card() {
  local target=$1
  read_card_key "$card_id" "$target"
}

parent_count() {
  local card_file=$1
  jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null)] | length' "$card_file"
}

current_parent() {
  local card_file=$1
  jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue["key"]' "$card_file"
}

current_link_id() {
  local card_file=$1
  local wanted=$2
  jq -r --arg link_type "$jira_link_type" --arg wanted "$wanted" '.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue["key"] == $wanted) | .id // empty' "$card_file"
}

validate_card() {
  local card_file=$1
  local actual_type actual_status actual_stage actual_stage_type
  local label_count label observed_phase count invalid_direction_count actual_parent_type
  actual_type="$(jq -r '.fields.issuetype.name // empty' "$card_file")"
  actual_status="$(jq -r '.fields.status.name // empty' "$card_file")"
  actual_stage="$(jq -r '.fields.parent["key"] // empty' "$card_file")"
  actual_stage_type="$(jq -r '.fields.parent.fields.issuetype.name // empty' "$card_file")"
  [[ "$actual_type" == "$work_type" ]] || relationship_die "Jira work type differs from request: expected $work_type, found ${actual_type:-missing}"
  [[ "$actual_status" =~ ^(To\ Do|Product\ Manager|Architect|Developer|Tester|Reviewer|Done)$ ]] || relationship_die "Jira card has a noncanonical Status: ${actual_status:-missing}"

  jq -e '.fields.labels | type == "array" and all(.[]; type == "string")' "$card_file" >/dev/null || relationship_die 'Jira Labels field is missing or invalid'
  label_count="$(jq '.fields.labels | length' "$card_file")"
  [[ "$label_count" == 1 ]] || relationship_die "Jira card must have exactly 1 Lifecycle Phase label, found $label_count"
  label="$(jq -r '.fields.labels[0]' "$card_file")"
  observed_phase="$(lifecycle_label_phase "$label" 2>/dev/null || true)"
  [[ -n "$observed_phase" ]] || relationship_die "noncanonical Lifecycle Phase label: $label"

  if [[ "$work_type" == Stage ]]; then
    [[ -z "$actual_stage" ]] || relationship_die "Stage has an unexpected native Parent: $actual_stage"
  else
    [[ "$actual_stage" == "$stage_parent" ]] || relationship_die "native Stage Parent differs from request: expected $stage_parent, found ${actual_stage:-missing}"
    [[ "$actual_stage_type" == Stage ]] || relationship_die "native Parent is not a Stage: ${actual_stage_type:-missing}"
  fi

  count="$(parent_count "$card_file")"
  ((count <= 1)) || relationship_die "$work_type has more than 1 linked Child parent"
  invalid_direction_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null and .type.outward != "is child of")] | length' "$card_file")"
  [[ "$invalid_direction_count" == 0 ]] || relationship_die 'linked Child relationship has an invalid parent direction'
  if ((count == 1)) && [[ "$work_type" =~ ^(Feature|Subfeature|Bug)$ ]]; then
    actual_parent_type="$(jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[] | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue.fields.issuetype.name // empty' "$card_file")"
    case "$work_type" in
      Feature) [[ "$actual_parent_type" == Epic ]] || relationship_die 'Feature linked parent is not an Epic' ;;
      Subfeature) [[ "$actual_parent_type" == Feature ]] || relationship_die 'Subfeature linked parent is not a Feature' ;;
      Bug) [[ "$actual_parent_type" == Subfeature ]] || relationship_die 'Bug linked parent is not a Subfeature' ;;
    esac
  fi
  printf '%s\n' "$actual_status"
}

expected_parent_type=''
case "$work_type" in
  Feature) expected_parent_type=Epic ;;
  Subfeature) expected_parent_type=Feature ;;
  Bug) expected_parent_type=Subfeature ;;
esac

validate_parent_card() {
  local parent_card=$1
  local parent_file="$tmp_dir/parent-$parent_card.json"
  local actual_type actual_stage actual_stage_type
  [[ "$parent_card" != "$card_id" ]] || relationship_die 'a card cannot be its own linked parent'
  read_card_key "$parent_card" "$parent_file"
  actual_type="$(jq -r '.fields.issuetype.name // empty' "$parent_file")"
  actual_stage="$(jq -r '.fields.parent["key"] // empty' "$parent_file")"
  actual_stage_type="$(jq -r '.fields.parent.fields.issuetype.name // empty' "$parent_file")"
  [[ "$actual_type" == "$expected_parent_type" ]] || relationship_die "$work_type linked parent must be a $expected_parent_type, found ${actual_type:-missing}"
  [[ "$actual_stage" == "$stage_parent" && "$actual_stage_type" == Stage ]] || relationship_die 'linked parent belongs to a different or invalid Stage'
}

if [[ -n "$to_parent" ]]; then
  validate_parent_card "$to_parent"
fi
if [[ -n "$from_parent" && -n "$expected_parent_type" ]]; then
  validate_parent_card "$from_parent"
fi

read_comments() {
  local target=$1
  if ! acli jira workitem comment list --key "$card_id" --paginate --json > "$target"; then
    relationship_die "failed to read Jira mutation records for card: $card_id"
  fi
  validate_json "$target" || relationship_die "Jira returned invalid comment JSON for card: $card_id"
}

count_line() {
  local file=$1
  local wanted=$2
  awk -v wanted="$wanted" '$0 == wanted { count += 1 } END { print count + 0 }' "$file"
}

count_prefix() {
  local file=$1
  local wanted=$2
  awk -v wanted="$wanted" 'index($0, wanted) == 1 { count += 1 } END { print count + 0 }' "$file"
}

post_comment() {
  local body_file=$1
  local output_file=$2
  if ! acli jira workitem comment create --key "$card_id" --body-file "$body_file" --json > "$output_file"; then
    relationship_die "failed to record Jira mutation evidence for card: $card_id"
  fi
}

before_file="$tmp_dir/card-before.json"
comments_file="$tmp_dir/comments.json"
comments_lines="$tmp_dir/comments.txt"
read_card "$before_file"
observed_status="$(validate_card "$before_file")"
observed_parent="$(current_parent "$before_file")"

case "$observed_status" in
  'To Do') [[ "$actor" =~ ^(Orchestrator|Product\ Manager|Architect)$ ]] || relationship_die 'only the Orchestrator, Product Manager, or Architect may change an unowned To Do hierarchy' ;;
  Done) [[ "$actor" == Orchestrator ]] || relationship_die 'only the Orchestrator may administratively repair a Done hierarchy' ;;
  *) [[ "$actor" == "$observed_status" ]] || relationship_die 'the actor must match the current player Status' ;;
esac

read_comments "$comments_file"
jq -r '.. | strings' "$comments_file" > "$comments_lines"
intent_count="$(count_line "$comments_lines" "$intent_marker")"
completion_count="$(count_line "$comments_lines" "$completion_marker")"
intent_prefix_count="$(count_prefix "$comments_lines" "$intent_prefix")"
completion_prefix_count="$(count_prefix "$comments_lines" "$completion_prefix")"
((intent_prefix_count == 0 || intent_count == 1)) || relationship_die 'mutation ID already exists with a different request digest'
((completion_prefix_count == 0 || completion_count == 1)) || relationship_die 'mutation ID already exists with a different request digest'
((intent_count <= 1)) || relationship_die 'Jira contains duplicate mutation intent records'
((completion_count <= 1)) || relationship_die 'Jira contains duplicate mutation completion records'
if ((completion_count == 1 && intent_count != 1)); then
  relationship_die 'Jira mutation completion exists without its intent record'
fi

mode=applied
if ((completion_count == 1)); then
  [[ "$observed_parent" == "$to_parent" ]] || relationship_die 'completed Jira relationship drifted from its target'
  mode=replayed
elif ((intent_count == 1)); then
  [[ -z "$observed_parent" || "$observed_parent" == "$from_parent" || "$observed_parent" == "$to_parent" ]] || relationship_die 'partial Jira relationship mutation is ambiguous'
  mode=recovered
else
  [[ "$observed_parent" == "$from_parent" ]] || relationship_die "Jira linked parent differs from request: expected ${from_parent:-none}, found ${observed_parent:-none}"
  intent_body="$tmp_dir/intent.txt"
  {
    printf '%s\n' "$intent_marker"
    printf '%s\n' 'Operation: relationship'
    printf 'Actor: %s\n' "$actor"
    printf 'Card: %s\n' "$card_id"
    printf 'Work Type: %s\n' "$work_type"
    printf 'Linked Child Parent: %s to %s\n' "${from_parent:-none}" "${to_parent:-none}"
    printf 'Reason: %s\n' "$reason"
    jq -r '.relationship.evidence[] | "Evidence: " + .' "$request_file"
    printf 'Next Action: %s\n' "$next_action"
  } > "$intent_body"
  post_comment "$intent_body" "$tmp_dir/intent-result.json"
fi

if [[ "$observed_parent" == "$from_parent" && -n "$from_parent" ]]; then
  old_link_id="$(current_link_id "$before_file" "$from_parent")"
  [[ -n "$old_link_id" ]] || relationship_die 'source linked-parent relation has no Jira link ID'
  if ! acli jira workitem link delete --id "$old_link_id" --yes > "$tmp_dir/link-delete-result.txt"; then
    relationship_die 'Jira linked-parent deletion failed after durable intent was recorded. Retry the same request to resume safely'
  fi
fi

middle_file="$tmp_dir/card-middle.json"
read_card "$middle_file"
validate_card "$middle_file" >/dev/null
middle_parent="$(current_parent "$middle_file")"
[[ -z "$middle_parent" || "$middle_parent" == "$to_parent" ]] || relationship_die 'Jira linked parent changed unexpectedly during relationship mutation'
if [[ -z "$middle_parent" && -n "$to_parent" ]]; then
  if ! acli jira workitem link create --out "$to_parent" --in "$card_id" --type "$jira_link_type" --yes > "$tmp_dir/link-create-result.txt"; then
    relationship_die 'Jira linked-parent creation failed after durable intent was recorded. Retry the same request to resume safely'
  fi
fi

after_file="$tmp_dir/card-after.json"
read_card "$after_file"
after_status="$(validate_card "$after_file")"
after_parent="$(current_parent "$after_file")"
[[ "$after_status" == "$observed_status" ]] || relationship_die 'Jira Status changed during relationship mutation'
[[ "$after_parent" == "$to_parent" ]] || relationship_die "Jira linked-parent verification failed: expected ${to_parent:-none}, found ${after_parent:-none}"

if ((completion_count == 0)); then
  completion_body="$tmp_dir/completion.txt"
  {
    printf '%s\n' "$completion_marker"
    printf '%s\n' 'Result: passed'
    printf '%s\n' 'Operation: relationship'
    printf 'Actor: %s\n' "$actor"
    printf 'Card: %s\n' "$card_id"
    printf 'Verified Work Type: %s\n' "$work_type"
    printf 'Verified Native Stage Parent: %s\n' "${stage_parent:-none}"
    printf 'Verified Linked Child Parent: %s\n' "${to_parent:-none}"
    printf 'Next Action: %s\n' "$next_action"
  } > "$completion_body"
  post_comment "$completion_body" "$tmp_dir/completion-result.json"
fi

read_comments "$comments_file"
jq -r '.. | strings' "$comments_file" > "$comments_lines"
[[ "$(count_line "$comments_lines" "$intent_marker")" == 1 ]] || relationship_die 'durable Jira mutation intent could not be verified'
[[ "$(count_line "$comments_lines" "$completion_marker")" == 1 ]] || relationship_die 'durable Jira mutation completion could not be verified'

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
receipt_tmp="$tmp_dir/receipt.json"
jq -n \
  --arg generated_at "$generated_at" \
  --arg repository "$github_repository" \
  --arg jira_project "$jira_project" \
  --arg mutation_id "$mutation_id" \
  --arg request_digest "$request_digest" \
  --arg mode "$mode" \
  --arg actor "$actor" \
  --argjson card "$(jq -c '.card' "$request_file")" \
  --argjson change "$(jq -c '.relationship' "$request_file")" \
  '{
    "schema-version": 1,
    kind: "clowder-jira-mutation-receipt",
    result: "passed",
    "generated-at": $generated_at,
    repository: $repository,
    "jira-project": $jira_project,
    "mutation-id": $mutation_id,
    "request-sha256": $request_digest,
    operation: "relationship",
    mode: $mode,
    actor: $actor,
    card: $card,
    change: $change,
    before: {"linked-parent": $change.from},
    after: {"linked-parent": $change.to},
    "durable-records": {intent: "jira-comment", completion: "jira-comment"}
  }' > "$receipt_tmp"

ln "$receipt_tmp" "$receipt_file" || relationship_die "receipt path was created concurrently: $receipt_file"
if [[ "$json" == true ]]; then
  jq -n --arg receipt "$receipt_file" --arg mode "$mode" --arg card "$card_id" '{ok: true, receipt: $receipt, mode: $mode, card: $card}'
else
  info "Jira mutation passed: $mutation_id ($mode)"
  info "receipt: $receipt_file"
fi
