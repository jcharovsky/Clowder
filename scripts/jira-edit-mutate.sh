#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
request_file=""
receipt_file=""
json=false

edit_die() {
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
    *) edit_die "unknown argument: $1" ;;
  esac
done

[[ -n "$request_file" ]] || edit_die 'request path is required'
[[ -n "$receipt_file" ]] || edit_die 'receipt path is required'
repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"
[[ -f "$request_file" && ! -L "$request_file" ]] || edit_die "request must be a regular, non-symbolic file: $request_file"
validate_json "$request_file" || edit_die "request is not valid JSON: $request_file"
path_is_within "$request_file" "$repo_path" && edit_die 'request path must be outside the product repository'
receipt_parent="$(dirname -- "$receipt_file")"
[[ -d "$receipt_parent" ]] || edit_die "receipt parent directory does not exist: $receipt_parent"
[[ ! -e "$receipt_file" && ! -L "$receipt_file" ]] || edit_die "receipt path already exists: $receipt_file"
path_is_within "$receipt_file" "$repo_path" && edit_die 'receipt path must be outside the product repository'

require_command jq
require_command acli
jira_integration="$(yaml_scalar "$config" jira.integration 2>/dev/null || true)"
jira_project="$(yaml_scalar "$config" jira.project-key 2>/dev/null || true)"
jira_link_type="$(yaml_scalar "$config" jira.child-link-type 2>/dev/null || true)"
jira_lifecycle_field="$(yaml_scalar "$config" jira.lifecycle-phase-field 2>/dev/null || true)"
github_repository="$(yaml_scalar "$config" github.repository 2>/dev/null || true)"
[[ "$jira_integration" == acli ]] || edit_die 'Jira integration must be configured as acli'
[[ -n "$jira_project" ]] || edit_die 'Jira project key is missing from project configuration'
[[ "$jira_link_type" == Child ]] || edit_die 'Jira child link type must be Child'
[[ "$jira_lifecycle_field" == labels ]] || edit_die 'Jira Lifecycle Phase field must be the native labels field'
[[ -n "$github_repository" ]] || edit_die 'GitHub repository is missing from project configuration'

if ! jq -e '
  type == "object" and length == 7 and
  .["schema-version"] == 1 and
  .kind == "clowder-jira-mutation" and
  (.["mutation-id"] | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
  .operation == "edit" and
  (.actor | IN("Orchestrator", "Product Manager", "Architect", "Developer", "Tester", "Reviewer")) and
  (.card | type == "object" and length == 4) and
  (.edit | type == "object" and length == 5) and
  (.edit.from | type == "object" and length == 2) and
  (.edit.to | type == "object" and length == 2) and
  (.edit.from.summary | type == "string" and length > 0 and (contains("\n") | not)) and
  (.edit.to.summary | type == "string" and length > 0 and (contains("\n") | not)) and
  (.edit.from.description | type == "string" and length > 0) and
  (.edit.to.description | type == "string" and length > 0) and
  (.edit.from != .edit.to) and
  (.edit.reason | type == "string" and length > 0 and (contains("\n") | not)) and
  (.edit.evidence | type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))) and
  (.edit["next-action"] | type == "string" and length > 0 and (contains("\n") | not))
' "$request_file" >/dev/null; then
  edit_die 'request does not satisfy the Jira edit mutation contract'
fi

mutation_id="$(jq -r '.["mutation-id"]' "$request_file")"
actor="$(jq -r '.actor' "$request_file")"
card_id="$(jq -r '.card["key"]' "$request_file")"
work_type="$(jq -r '.card["work-type"]' "$request_file")"
stage_parent="$(jq -r '.card["stage-parent"] // empty' "$request_file")"
linked_parent="$(jq -r '.card["linked-parent"] // empty' "$request_file")"
from_summary="$(jq -r '.edit.from.summary' "$request_file")"
to_summary="$(jq -r '.edit.to.summary' "$request_file")"
from_description="$(jq -r '.edit.from.description' "$request_file")"
to_description="$(jq -r '.edit.to.description' "$request_file")"
reason="$(jq -r '.edit.reason' "$request_file")"
next_action="$(jq -r '.edit["next-action"]' "$request_file")"

valid_jira_key "$card_id" || edit_die "invalid Jira card key: $card_id"
[[ "${card_id%%-*}" == "$jira_project" ]] || edit_die 'Jira card belongs to a different configured project'
[[ "$work_type" =~ ^(Stage|Epic|Feature|Subfeature|Bug)$ ]] || edit_die "invalid Jira work type: $work_type"
[[ "$from_description" != *CLOWDER_JIRA_* && "$to_description" != *CLOWDER_JIRA_* ]] || edit_die 'logical description contains a reserved Clowder mutation marker'

case "$work_type" in
  Stage)
    [[ -z "$stage_parent" && -z "$linked_parent" ]] || edit_die 'a Stage cannot have a native or linked parent'
    ;;
  Epic)
    valid_jira_key "$stage_parent" || edit_die 'an Epic requires a valid native Stage Parent'
    [[ -z "$linked_parent" ]] || edit_die 'an Epic cannot have a linked Child parent'
    ;;
  Feature|Subfeature|Bug)
    valid_jira_key "$stage_parent" || edit_die "$work_type requires a valid native Stage Parent"
    valid_jira_key "$linked_parent" || edit_die "$work_type requires a valid linked Child parent"
    ;;
esac

request_digest="$(jq -cS . "$request_file" | sha256_stream)"
intent_marker="CLOWDER_JIRA_MUTATION_INTENT v1 id=$mutation_id sha256=$request_digest"
completion_marker="CLOWDER_JIRA_MUTATION_COMPLETION v1 id=$mutation_id sha256=$request_digest"
intent_prefix="CLOWDER_JIRA_MUTATION_INTENT v1 id=$mutation_id "
completion_prefix="CLOWDER_JIRA_MUTATION_COMPLETION v1 id=$mutation_id "

tmp_dir="$(mktemp -d "$receipt_parent/.clowder-jira-edit.XXXXXX")"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

read_card() {
  local target=$1
  if ! acli jira workitem view "$card_id" --fields 'key,summary,description,status,labels,issuetype,parent,issuelinks' --json > "$target"; then
    edit_die "failed to read Jira card: $card_id"
  fi
  validate_json "$target" || edit_die "Jira returned invalid JSON for card: $card_id"
}

plain_description() {
  local card_file=$1
  jq -r '
    def text:
      if type == "string" then .
      elif type != "object" then ""
      elif .type == "text" then (.text // "")
      elif .type == "hardBreak" then "\n"
      elif (.content | type) == "array" then
        ([.content[] | text] | join("")) + (if (.type == "paragraph" or .type == "heading") then "\n" else "" end)
      else ""
      end;
    if (.fields.description | type) == "string" then .fields.description
    elif .fields.description == null then ""
    else (.fields.description | text | sub("\n$"; ""))
    end
  ' "$card_file"
}

description_marker() {
  local value=$1
  local count
  count="$(printf '%s\n' "$value" | grep -Ec '^CLOWDER_JIRA_CREATION v1 id=[A-Za-z0-9][A-Za-z0-9._:-]{0,127} sha256=[0-9a-f]{64}$' || true)"
  ((count <= 1)) || edit_die 'Jira description contains duplicate creation recovery markers'
  printf '%s\n' "$value" | grep -E '^CLOWDER_JIRA_CREATION v1 id=[A-Za-z0-9][A-Za-z0-9._:-]{0,127} sha256=[0-9a-f]{64}$' || true
}

logical_description() {
  local value=$1
  local marker=$2
  if [[ -n "$marker" ]]; then
    local suffix=$'\n\n'"$marker"
    [[ "$value" == *"$suffix" ]] || edit_die 'Jira creation recovery marker is not the final description record'
    printf '%s\n' "${value%"$suffix"}"
  else
    printf '%s\n' "$value"
  fi
}

validate_structure() {
  local card_file=$1
  local actual_type actual_status actual_stage actual_stage_type
  local parent_count actual_parent actual_parent_type invalid_direction_count
  local label_count label observed_phase

  actual_type="$(jq -r '.fields.issuetype.name // empty' "$card_file")"
  actual_status="$(jq -r '.fields.status.name // empty' "$card_file")"
  actual_stage="$(jq -r '.fields.parent["key"] // empty' "$card_file")"
  actual_stage_type="$(jq -r '.fields.parent.fields.issuetype.name // empty' "$card_file")"
  [[ "$actual_type" == "$work_type" ]] || edit_die "Jira work type differs from request: expected $work_type, found ${actual_type:-missing}"
  [[ "$actual_status" =~ ^(To\ Do|Product\ Manager|Architect|Developer|Tester|Reviewer|Done)$ ]] || edit_die "Jira card has a noncanonical Status: ${actual_status:-missing}"

  jq -e '.fields.labels | type == "array" and all(.[]; type == "string")' "$card_file" >/dev/null || edit_die 'Jira Labels field is missing or invalid'
  label_count="$(jq '.fields.labels | length' "$card_file")"
  [[ "$label_count" == 1 ]] || edit_die "Jira card must have exactly 1 Lifecycle Phase label, found $label_count"
  label="$(jq -r '.fields.labels[0]' "$card_file")"
  observed_phase="$(lifecycle_label_phase "$label" 2>/dev/null || true)"
  [[ -n "$observed_phase" ]] || edit_die "noncanonical Lifecycle Phase label: $label"

  if [[ "$work_type" == Stage ]]; then
    [[ -z "$actual_stage" ]] || edit_die "Stage has an unexpected native Parent: $actual_stage"
  else
    [[ "$actual_stage" == "$stage_parent" ]] || edit_die "native Stage Parent differs from request: expected $stage_parent, found ${actual_stage:-missing}"
    [[ "$actual_stage_type" == Stage ]] || edit_die "native Parent is not a Stage: ${actual_stage_type:-missing}"
  fi

  parent_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null)] | length' "$card_file")"
  invalid_direction_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null and .type.outward != "is child of")] | length' "$card_file")"
  [[ "$invalid_direction_count" == 0 ]] || edit_die 'linked Child relationship has an invalid parent direction'
  case "$work_type" in
    Stage|Epic)
      [[ "$parent_count" == 0 ]] || edit_die "$work_type has an unexpected linked Child parent"
      ;;
    Feature|Subfeature|Bug)
      [[ "$parent_count" == 1 ]] || edit_die "$work_type must have exactly 1 linked Child parent, found $parent_count"
      actual_parent="$(jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[] | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue["key"]' "$card_file")"
      actual_parent_type="$(jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[] | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue.fields.issuetype.name // empty' "$card_file")"
      [[ "$actual_parent" == "$linked_parent" ]] || edit_die "linked Child parent differs from request: expected $linked_parent, found ${actual_parent:-missing}"
      case "$work_type" in
        Feature) [[ "$actual_parent_type" == Epic ]] || edit_die 'Feature linked parent is not an Epic' ;;
        Subfeature) [[ "$actual_parent_type" == Feature ]] || edit_die 'Subfeature linked parent is not a Feature' ;;
        Bug) [[ "$actual_parent_type" == Subfeature ]] || edit_die 'Bug linked parent is not a Subfeature' ;;
      esac
      ;;
  esac
  printf '%s\n' "$actual_status"
}

read_comments() {
  local target=$1
  if ! acli jira workitem comment list --key "$card_id" --paginate --json > "$target"; then
    edit_die "failed to read Jira mutation records for card: $card_id"
  fi
  validate_json "$target" || edit_die "Jira returned invalid comment JSON for card: $card_id"
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
    edit_die "failed to record Jira mutation evidence for card: $card_id"
  fi
}

before_file="$tmp_dir/card-before.json"
comments_file="$tmp_dir/comments.json"
comments_lines="$tmp_dir/comments.txt"
read_card "$before_file"
observed_status="$(validate_structure "$before_file")"
observed_summary="$(jq -r '.fields.summary // empty' "$before_file")"
observed_full_description="$(plain_description "$before_file")"
retained_creation_marker="$(description_marker "$observed_full_description")"
observed_description="$(logical_description "$observed_full_description" "$retained_creation_marker")"

case "$observed_status" in
  'To Do') [[ "$actor" =~ ^(Orchestrator|Product\ Manager|Architect)$ ]] || edit_die 'only the Orchestrator, Product Manager, or Architect may edit an unowned To Do card' ;;
  Done) [[ "$actor" == Orchestrator ]] || edit_die 'only the Orchestrator may administratively edit a Done card' ;;
  *) [[ "$actor" == "$observed_status" ]] || edit_die 'the actor must match the current player Status' ;;
esac

read_comments "$comments_file"
jq -r '.. | strings' "$comments_file" > "$comments_lines"
intent_count="$(count_line "$comments_lines" "$intent_marker")"
completion_count="$(count_line "$comments_lines" "$completion_marker")"
intent_prefix_count="$(count_prefix "$comments_lines" "$intent_prefix")"
completion_prefix_count="$(count_prefix "$comments_lines" "$completion_prefix")"
((intent_prefix_count == 0 || intent_count == 1)) || edit_die 'mutation ID already exists with a different request digest'
((completion_prefix_count == 0 || completion_count == 1)) || edit_die 'mutation ID already exists with a different request digest'
((intent_count <= 1)) || edit_die 'Jira contains duplicate mutation intent records'
((completion_count <= 1)) || edit_die 'Jira contains duplicate mutation completion records'
if ((completion_count == 1 && intent_count != 1)); then
  edit_die 'Jira mutation completion exists without its intent record'
fi

mode=applied
needs_edit=true
if ((completion_count == 1)); then
  [[ "$observed_summary" == "$to_summary" ]] || edit_die 'completed Jira edit summary drifted from its target'
  [[ "$observed_description" == "$to_description" ]] || edit_die 'completed Jira edit description drifted from its target'
  mode=replayed
  needs_edit=false
elif ((intent_count == 1)); then
  mode=recovered
  [[ "$observed_summary" == "$from_summary" || "$observed_summary" == "$to_summary" ]] || edit_die 'partial Jira edit summary is ambiguous'
  [[ "$observed_description" == "$from_description" || "$observed_description" == "$to_description" ]] || edit_die 'partial Jira edit description is ambiguous'
  if [[ "$observed_summary" == "$to_summary" && "$observed_description" == "$to_description" ]]; then
    needs_edit=false
  fi
else
  [[ "$observed_summary" == "$from_summary" ]] || edit_die 'Jira summary differs from the requested source value'
  [[ "$observed_description" == "$from_description" ]] || edit_die 'Jira description differs from the requested source value'
  intent_body="$tmp_dir/intent.txt"
  {
    printf '%s\n' "$intent_marker"
    printf '%s\n' 'Operation: edit'
    printf 'Actor: %s\n' "$actor"
    printf 'Card: %s\n' "$card_id"
    printf 'Work Type: %s\n' "$work_type"
    printf 'Summary: %s to %s\n' "$from_summary" "$to_summary"
    printf 'Description SHA-256: %s to %s\n' "$(printf '%s' "$from_description" | sha256_stream)" "$(printf '%s' "$to_description" | sha256_stream)"
    printf 'Reason: %s\n' "$reason"
    jq -r '.edit.evidence[] | "Evidence: " + .' "$request_file"
    printf 'Next Action: %s\n' "$next_action"
  } > "$intent_body"
  post_comment "$intent_body" "$tmp_dir/intent-result.json"
fi

if [[ -n "$retained_creation_marker" ]]; then
  target_full_description="$to_description"$'\n\n'"$retained_creation_marker"
else
  target_full_description="$to_description"
fi

if [[ "$needs_edit" == true ]]; then
  edit_description_file="$tmp_dir/edit-description.txt"
  printf '%s\n' "$target_full_description" > "$edit_description_file"
  if ! acli jira workitem edit --key "$card_id" --summary "$to_summary" --description-file "$edit_description_file" --yes --json > "$tmp_dir/edit-result.json"; then
    edit_die 'Jira metadata edit failed after durable intent was recorded. Retry the same request to resume safely'
  fi
fi

after_file="$tmp_dir/card-after.json"
read_card "$after_file"
after_status="$(validate_structure "$after_file")"
after_summary="$(jq -r '.fields.summary // empty' "$after_file")"
after_full_description="$(plain_description "$after_file")"
after_creation_marker="$(description_marker "$after_full_description")"
after_description="$(logical_description "$after_full_description" "$after_creation_marker")"
[[ "$after_status" == "$observed_status" ]] || edit_die 'Jira Status changed during metadata edit'
[[ "$after_summary" == "$to_summary" ]] || edit_die 'Jira summary edit verification failed'
[[ "$after_description" == "$to_description" ]] || edit_die 'Jira description edit verification failed'
[[ "$after_creation_marker" == "$retained_creation_marker" ]] || edit_die 'Jira metadata edit changed the creation recovery marker'

if ((completion_count == 0)); then
  completion_body="$tmp_dir/completion.txt"
  {
    printf '%s\n' "$completion_marker"
    printf '%s\n' 'Result: passed'
    printf '%s\n' 'Operation: edit'
    printf 'Actor: %s\n' "$actor"
    printf 'Card: %s\n' "$card_id"
    printf 'Verified Summary: %s\n' "$after_summary"
    printf 'Verified Description SHA-256: %s\n' "$(printf '%s' "$after_description" | sha256_stream)"
    printf 'Next Action: %s\n' "$next_action"
  } > "$completion_body"
  post_comment "$completion_body" "$tmp_dir/completion-result.json"
fi

read_comments "$comments_file"
jq -r '.. | strings' "$comments_file" > "$comments_lines"
[[ "$(count_line "$comments_lines" "$intent_marker")" == 1 ]] || edit_die 'durable Jira mutation intent could not be verified'
[[ "$(count_line "$comments_lines" "$completion_marker")" == 1 ]] || edit_die 'durable Jira mutation completion could not be verified'

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
  --argjson change "$(jq -c '.edit' "$request_file")" \
  '{
    "schema-version": 1,
    kind: "clowder-jira-mutation-receipt",
    result: "passed",
    "generated-at": $generated_at,
    repository: $repository,
    "jira-project": $jira_project,
    "mutation-id": $mutation_id,
    "request-sha256": $request_digest,
    operation: "edit",
    mode: $mode,
    actor: $actor,
    card: $card,
    change: $change,
    before: $change.from,
    after: $change.to,
    "durable-records": {intent: "jira-comment", completion: "jira-comment"}
  }' > "$receipt_tmp"

ln "$receipt_tmp" "$receipt_file" || edit_die "receipt path was created concurrently: $receipt_file"
if [[ "$json" == true ]]; then
  jq -n --arg receipt "$receipt_file" --arg mode "$mode" --arg card "$card_id" '{ok: true, receipt: $receipt, mode: $mode, card: $card}'
else
  info "Jira mutation passed: $mutation_id ($mode)"
  info "receipt: $receipt_file"
fi
