#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
request_file=""
receipt_file=""
json=false

usage() {
  printf '%s\n' 'Usage: jira-mutate.sh --repo PATH --request REQUEST.json --receipt RECEIPT.json [--json]'
}

mutation_die() {
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
    -h|--help) usage; exit 0 ;;
    *) usage >&2; mutation_die "unknown argument: $1" ;;
  esac
done

[[ -n "$request_file" ]] || { usage >&2; mutation_die 'request path is required'; }
[[ -n "$receipt_file" ]] || { usage >&2; mutation_die 'receipt path is required'; }

repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"

[[ -f "$request_file" && ! -L "$request_file" ]] || mutation_die "request must be a regular, non-symbolic file: $request_file"
validate_json "$request_file" || mutation_die "request is not valid JSON: $request_file"
if path_is_within "$request_file" "$repo_path"; then
  mutation_die 'request path must be outside the product repository'
fi

receipt_parent="$(dirname -- "$receipt_file")"
[[ -d "$receipt_parent" ]] || mutation_die "receipt parent directory does not exist: $receipt_parent"
[[ ! -e "$receipt_file" && ! -L "$receipt_file" ]] || mutation_die "receipt path already exists: $receipt_file"
if path_is_within "$receipt_file" "$repo_path"; then
  mutation_die 'receipt path must be outside the product repository'
fi

require_command jq
require_command acli

jira_integration="$(yaml_scalar "$config" jira.integration 2>/dev/null || true)"
[[ "$jira_integration" == acli ]] || mutation_die 'Jira integration must be configured as acli'
jira_project="$(yaml_scalar "$config" jira.project-key 2>/dev/null || true)"
jira_link_type="$(yaml_scalar "$config" jira.child-link-type 2>/dev/null || true)"
jira_lifecycle_field="$(yaml_scalar "$config" jira.lifecycle-phase-field 2>/dev/null || true)"
github_repository="$(yaml_scalar "$config" github.repository 2>/dev/null || true)"
[[ -n "$jira_project" ]] || mutation_die 'Jira project key is missing from project configuration'
[[ "$jira_link_type" == Child ]] || mutation_die 'Jira child link type must be Child'
[[ "$jira_lifecycle_field" == labels ]] || mutation_die 'Jira Lifecycle Phase field must be the native labels field'
[[ -n "$github_repository" ]] || mutation_die 'GitHub repository is missing from project configuration'

requested_operation="$(jq -r '.operation // empty' "$request_file")"
entity_args=(--repo "$repo_path" --request "$request_file" --receipt "$receipt_file")
[[ "$json" == true ]] && entity_args+=(--json)
case "$requested_operation" in
  transition) ;;
  create) exec "$SCRIPT_DIR/jira-entity-mutate.sh" "${entity_args[@]}" ;;
  edit) exec "$SCRIPT_DIR/jira-edit-mutate.sh" "${entity_args[@]}" ;;
  relationship) exec "$SCRIPT_DIR/jira-relationship-mutate.sh" "${entity_args[@]}" ;;
  *) mutation_die "unsupported Jira mutation operation: ${requested_operation:-missing}" ;;
esac

if ! jq -e '
  type == "object" and
  length == 8 and
  .["schema-version"] == 1 and
  .kind == "clowder-jira-mutation" and
  (."mutation-id" | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
  .operation == "transition" and
  (.actor | IN("Orchestrator", "Product Manager", "Architect", "Developer", "Tester", "Reviewer")) and
  (.card | type == "object" and length == 4) and
  (.transition | type == "object" and length == 5) and
  (.["lifecycle-phase"] | type == "object" and length == 2) and
  (.["lifecycle-phase"].from == null or (.["lifecycle-phase"].from | type == "string")) and
  (.["lifecycle-phase"].to | type == "string")
' "$request_file" >/dev/null; then
  mutation_die 'request does not satisfy the Jira mutation request contract'
fi

mutation_id="$(jq -r '."mutation-id"' "$request_file")"
operation="$(jq -r '.operation' "$request_file")"
actor="$(jq -r '.actor' "$request_file")"
card_key="$(jq -r '.card["key"]' "$request_file")"
work_type="$(jq -r '.card["work-type"]' "$request_file")"
stage_parent="$(jq -r '.card["stage-parent"] // empty' "$request_file")"
linked_parent="$(jq -r '.card["linked-parent"] // empty' "$request_file")"
from_status="$(jq -r '.transition.from' "$request_file")"
to_status="$(jq -r '.transition.to' "$request_file")"
reason="$(jq -r '.transition.reason' "$request_file")"
next_action="$(jq -r '.transition["next-action"]' "$request_file")"
if jq -e '.["lifecycle-phase"].from == null' "$request_file" >/dev/null; then
  from_phase=""
else
  from_phase="$(jq -r '.["lifecycle-phase"].from' "$request_file")"
fi
to_phase="$(jq -r '.["lifecycle-phase"].to' "$request_file")"

valid_jira_key "$card_key" || mutation_die "invalid Jira card key: $card_key"
[[ "${card_key%%-*}" == "$jira_project" ]] || mutation_die 'Jira card belongs to a different configured project'
[[ "$work_type" =~ ^(Stage|Epic|Feature|Subfeature|Bug)$ ]] || mutation_die "invalid Jira work type: $work_type"
[[ "$from_status" =~ ^(To\ Do|Product\ Manager|Architect|Developer|Tester|Reviewer)$ ]] || mutation_die "invalid source Status: $from_status"
[[ "$to_status" =~ ^(To\ Do|Product\ Manager|Architect|Developer|Tester|Reviewer|Done)$ ]] || mutation_die "invalid target Status: $to_status"
[[ -z "$from_phase" ]] || valid_lifecycle_phase "$from_phase" || mutation_die "invalid source Lifecycle Phase: $from_phase"
valid_lifecycle_phase "$to_phase" || mutation_die "invalid target Lifecycle Phase: $to_phase"
from_label=""
if [[ -n "$from_phase" ]]; then
  from_label="$(lifecycle_phase_label "$from_phase")"
fi
to_label="$(lifecycle_phase_label "$to_phase")"
[[ "$from_status" != "$to_status" || "$from_phase" != "$to_phase" ]] || mutation_die 'Status or Lifecycle Phase must change'
if [[ "$from_status" != "$to_status" && "$to_status" == 'To Do' ]]; then
  mutation_die 'a player-owned card cannot transition back to the To Do queue'
fi
[[ -n "$reason" && "$reason" != *$'\n'* ]] || mutation_die 'transition reason must be 1 non-empty line'
[[ -n "$next_action" && "$next_action" != *$'\n'* ]] || mutation_die 'transition next action must be 1 non-empty line'
if ! jq -e '.transition.evidence | type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))' "$request_file" >/dev/null; then
  mutation_die 'transition evidence must contain at least 1 non-empty single-line string'
fi

case "$work_type" in
  Stage)
    [[ -z "$stage_parent" && -z "$linked_parent" ]] || mutation_die 'a Stage cannot have a native or linked parent in the request'
    ;;
  Epic)
    valid_jira_key "$stage_parent" || mutation_die 'an Epic requires a valid native Stage Parent'
    [[ -z "$linked_parent" ]] || mutation_die 'an Epic cannot have a linked Child parent in the request'
    ;;
  Feature|Subfeature|Bug)
    valid_jira_key "$stage_parent" || mutation_die "$work_type requires a valid native Stage Parent"
    valid_jira_key "$linked_parent" || mutation_die "$work_type requires a valid linked Child parent"
    ;;
esac

if [[ "$from_status" == 'To Do' ]]; then
  if [[ "$to_status" == Done ]]; then
    [[ "$actor" == 'Product Manager' && "$work_type" == Feature ]] || mutation_die 'only the Product Manager may close a To Do Feature directly to Done'
  else
    [[ "$actor" == Orchestrator ]] || mutation_die 'only the Orchestrator may dispatch a To Do card to a player'
  fi
else
  [[ "$actor" == "$from_status" ]] || mutation_die 'the actor must match the current player Status'
fi

request_digest="$(jq -cS . "$request_file" | sha256_stream)"

tmp_dir="$(mktemp -d "$receipt_parent/.clowder-jira-mutate.XXXXXX")"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

read_card_key() {
  local item=$1
  local target=$2
  if ! acli jira workitem view "$item" --fields 'key,summary,status,labels,issuetype,parent,issuelinks' --json > "$target"; then
    mutation_die "failed to read Jira card: $item"
  fi
  validate_json "$target" || mutation_die "Jira returned invalid JSON for card: $item"
}

read_card_lifecycle_phase() {
  local card_file=$1
  local label_count label phase

  jq -e '.fields.labels | type == "array" and all(.[]; type == "string")' "$card_file" >/dev/null || mutation_die 'Jira Labels field is missing or invalid'
  label_count="$(jq '.fields.labels | length' "$card_file")"
  case "$label_count" in
    0)
      printf '\n'
      ;;
    1)
      label="$(jq -r '.fields.labels[0]' "$card_file")"
      if ! phase="$(lifecycle_label_phase "$label")"; then
        mutation_die "noncanonical Lifecycle Phase label: $label"
      fi
      printf '%s\n' "$phase"
      ;;
    *)
      mutation_die "Jira card must have exactly 1 Lifecycle Phase label, found $label_count"
      ;;
  esac
}

read_card() {
  local target=$1
  read_card_key "$card_key" "$target"
}

validate_card_structure() {
  local card_file=$1
  local actual_type actual_status actual_stage actual_stage_type
  local linked_count actual_linked_parent actual_linked_type invalid_direction_count

  actual_type="$(jq -r '.fields.issuetype.name // empty' "$card_file")"
  actual_status="$(jq -r '.fields.status.name // empty' "$card_file")"
  actual_stage="$(jq -r '.fields.parent["key"] // empty' "$card_file")"
  actual_stage_type="$(jq -r '.fields.parent.fields.issuetype.name // empty' "$card_file")"

  [[ "$actual_type" == "$work_type" ]] || mutation_die "Jira work type differs from request: expected $work_type, found ${actual_type:-missing}"
  [[ "$actual_status" =~ ^(To\ Do|Product\ Manager|Architect|Developer|Tester|Reviewer|Done)$ ]] || mutation_die "Jira card has a noncanonical Status: ${actual_status:-missing}"

  if [[ "$work_type" == Stage ]]; then
    [[ -z "$actual_stage" ]] || mutation_die "Stage has an unexpected native Parent: $actual_stage"
  else
    [[ "$actual_stage" == "$stage_parent" ]] || mutation_die "native Stage Parent differs from request: expected $stage_parent, found ${actual_stage:-missing}"
    [[ "$actual_stage_type" == Stage ]] || mutation_die "native Parent is not a Stage: ${actual_stage_type:-missing}"
  fi

  linked_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null)] | length' "$card_file")"
  invalid_direction_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null and .type.outward != "is child of")] | length' "$card_file")"
  [[ "$invalid_direction_count" == 0 ]] || mutation_die 'linked Child relationship has an invalid parent direction'

  case "$work_type" in
    Stage|Epic)
      [[ "$linked_count" == 0 ]] || mutation_die "$work_type has an unexpected linked Child parent"
      ;;
    Feature|Subfeature|Bug)
      [[ "$linked_count" == 1 ]] || mutation_die "$work_type must have exactly 1 linked Child parent, found $linked_count"
      actual_linked_parent="$(jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[] | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue["key"]' "$card_file")"
      actual_linked_type="$(jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[] | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue.fields.issuetype.name // empty' "$card_file")"
      [[ "$actual_linked_parent" == "$linked_parent" ]] || mutation_die "linked Child parent differs from request: expected $linked_parent, found ${actual_linked_parent:-missing}"
      case "$work_type" in
        Feature) [[ "$actual_linked_type" == Epic ]] || mutation_die "Feature linked parent must be an Epic, found ${actual_linked_type:-missing}" ;;
        Subfeature) [[ "$actual_linked_type" == Feature ]] || mutation_die "Subfeature linked parent must be a Feature, found ${actual_linked_type:-missing}" ;;
        Bug) [[ "$actual_linked_type" == Subfeature ]] || mutation_die "Bug linked parent must be a Subfeature, found ${actual_linked_type:-missing}" ;;
      esac
      ;;
  esac

  printf '%s\n' "$actual_status"
}

validate_completed_descendant() {
  local descendant_file=$1
  local descendant_key=$2
  local expected_type=$3
  local expected_parent=$4
  local actual_type actual_status actual_stage actual_stage_type
  local parent_count actual_parent invalid_direction_count actual_phase

  actual_type="$(jq -r '.fields.issuetype.name // empty' "$descendant_file")"
  actual_status="$(jq -r '.fields.status.name // empty' "$descendant_file")"
  actual_stage="$(jq -r '.fields.parent["key"] // empty' "$descendant_file")"
  actual_stage_type="$(jq -r '.fields.parent.fields.issuetype.name // empty' "$descendant_file")"
  actual_phase="$(read_card_lifecycle_phase "$descendant_file")"

  [[ "$actual_type" == "$expected_type" ]] || mutation_die "Feature closure child $descendant_key must be a $expected_type, found ${actual_type:-missing}"
  [[ "$actual_stage" == "$stage_parent" && "$actual_stage_type" == Stage ]] || mutation_die "Feature closure child $descendant_key has an invalid native Stage Parent"

  parent_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null)] | length' "$descendant_file")"
  invalid_direction_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null and .type.outward != "is child of")] | length' "$descendant_file")"
  [[ "$parent_count" == 1 && "$invalid_direction_count" == 0 ]] || mutation_die "Feature closure child $descendant_key has an invalid linked parent cardinality or direction"
  actual_parent="$(jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[] | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue["key"]' "$descendant_file")"
  [[ "$actual_parent" == "$expected_parent" ]] || mutation_die "Feature closure child $descendant_key has the wrong linked parent"
  [[ "$actual_status" == Done ]] || mutation_die "cannot close Feature while linked $expected_type $descendant_key is not Done"
  [[ "$actual_phase" == Complete ]] || mutation_die "cannot close Feature while linked $expected_type $descendant_key Lifecycle Phase is ${actual_phase:-missing}"
}

validate_feature_closure() {
  local feature_file=$1
  local subfeatures_file="$tmp_dir/feature-subfeatures.tsv"
  local duplicate_key subfeature_key nested_type direction
  local subfeature_file bugs_file bug_key bug_type bug_direction bug_file

  jq -r --arg link_type "$jira_link_type" '
    .fields.issuelinks[]?
    | select(.type.name == $link_type and .inwardIssue != null)
    | [.inwardIssue["key"], (.inwardIssue.fields.issuetype.name // ""), (.type.inward // "")]
    | @tsv
  ' "$feature_file" > "$subfeatures_file"

  [[ -s "$subfeatures_file" ]] || mutation_die 'cannot close Feature without at least 1 linked Subfeature'
  duplicate_key="$(cut -f1 "$subfeatures_file" | sort | uniq -d | sed -n '1p')"
  [[ -z "$duplicate_key" ]] || mutation_die "Feature has a duplicate linked child: $duplicate_key"

  while IFS=$'\t' read -r subfeature_key nested_type direction; do
    valid_jira_key "$subfeature_key" || mutation_die 'Feature has a linked child with an invalid Jira key'
    [[ "$nested_type" == Subfeature ]] || mutation_die "Feature may contain only Subfeatures, found ${nested_type:-missing} $subfeature_key"
    [[ "$direction" == 'is parent of' ]] || mutation_die "Feature child $subfeature_key has an invalid linked direction"

    subfeature_file="$tmp_dir/$subfeature_key.json"
    read_card_key "$subfeature_key" "$subfeature_file"
    validate_completed_descendant "$subfeature_file" "$subfeature_key" Subfeature "$card_key"

    bugs_file="$tmp_dir/$subfeature_key-bugs.tsv"
    jq -r --arg link_type "$jira_link_type" '
      .fields.issuelinks[]?
      | select(.type.name == $link_type and .inwardIssue != null)
      | [.inwardIssue["key"], (.inwardIssue.fields.issuetype.name // ""), (.type.inward // "")]
      | @tsv
    ' "$subfeature_file" > "$bugs_file"

    duplicate_key="$(cut -f1 "$bugs_file" | sort | uniq -d | sed -n '1p')"
    [[ -z "$duplicate_key" ]] || mutation_die "Subfeature $subfeature_key has a duplicate linked child: $duplicate_key"
    while IFS=$'\t' read -r bug_key bug_type bug_direction; do
      [[ -n "$bug_key" ]] || continue
      valid_jira_key "$bug_key" || mutation_die "Subfeature $subfeature_key has a linked child with an invalid Jira key"
      [[ "$bug_type" == Bug ]] || mutation_die "Subfeature $subfeature_key may contain only Bugs, found ${bug_type:-missing} $bug_key"
      [[ "$bug_direction" == 'is parent of' ]] || mutation_die "Bug $bug_key has an invalid linked direction"
      bug_file="$tmp_dir/$bug_key.json"
      read_card_key "$bug_key" "$bug_file"
      validate_completed_descendant "$bug_file" "$bug_key" Bug "$subfeature_key"
      if jq -e --arg link_type "$jira_link_type" 'any(.fields.issuelinks[]?; .type.name == $link_type and .inwardIssue != null)' "$bug_file" >/dev/null; then
        mutation_die "Bug $bug_key cannot have a linked child"
      fi
    done < "$bugs_file"
  done < "$subfeatures_file"
}

read_comments() {
  local target=$1
  if ! acli jira workitem comment list --key "$card_key" --paginate --json > "$target"; then
    mutation_die "failed to read Jira mutation records for card: $card_key"
  fi
  validate_json "$target" || mutation_die "Jira returned invalid comment JSON for card: $card_key"
}

comments_text() {
  local comments_file=$1
  jq -r '.. | strings' "$comments_file"
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
  if ! acli jira workitem comment create --key "$card_key" --body-file "$body_file" --json > "$output_file"; then
    mutation_die "failed to record Jira mutation evidence for card: $card_key"
  fi
}

intent_marker="CLOWDER_JIRA_MUTATION_INTENT v1 id=$mutation_id sha256=$request_digest"
completion_marker="CLOWDER_JIRA_MUTATION_COMPLETION v1 id=$mutation_id sha256=$request_digest"
intent_prefix="CLOWDER_JIRA_MUTATION_INTENT v1 id=$mutation_id "
completion_prefix="CLOWDER_JIRA_MUTATION_COMPLETION v1 id=$mutation_id "

before_file="$tmp_dir/card-before.json"
comments_file="$tmp_dir/comments.json"
comments_lines="$tmp_dir/comments.txt"
read_card "$before_file"
observed_status="$(validate_card_structure "$before_file")"
observed_phase="$(read_card_lifecycle_phase "$before_file")"
if [[ "$from_status" == 'To Do' && "$to_status" == Done ]]; then
  validate_feature_closure "$before_file"
fi
read_comments "$comments_file"
comments_text "$comments_file" > "$comments_lines"

intent_count="$(count_line "$comments_lines" "$intent_marker")"
completion_count="$(count_line "$comments_lines" "$completion_marker")"
intent_prefix_count="$(count_prefix "$comments_lines" "$intent_prefix")"
completion_prefix_count="$(count_prefix "$comments_lines" "$completion_prefix")"

if ((intent_prefix_count > 0 && intent_count == 0)); then
  mutation_die 'mutation ID already exists with a different request digest'
fi
if ((completion_prefix_count > 0 && completion_count == 0)); then
  mutation_die 'mutation ID already exists with a different request digest'
fi
((intent_count <= 1)) || mutation_die 'Jira contains duplicate mutation intent records'
((completion_count <= 1)) || mutation_die 'Jira contains duplicate mutation completion records'
if ((completion_count == 1 && intent_count != 1)); then
  mutation_die 'Jira mutation completion exists without its intent record'
fi

mode=applied
needs_transition=false
needs_phase_update=false
needs_completion=true

if ((completion_count == 1)); then
  [[ "$observed_status" == "$to_status" ]] || mutation_die "completed mutation Status drifted: expected $to_status, found $observed_status"
  [[ "$observed_phase" == "$to_phase" ]] || mutation_die "completed mutation Lifecycle Phase drifted: expected $to_phase, found ${observed_phase:-missing}"
  mode=replayed
  needs_completion=false
elif ((intent_count == 1)); then
  mode=recovered
  if [[ "$observed_status" == "$to_status" ]]; then
    needs_transition=false
  elif [[ "$observed_status" == "$from_status" ]]; then
    needs_transition=true
  else
    mutation_die "partial mutation Status is ambiguous: expected $from_status or $to_status, found $observed_status"
  fi
  if [[ "$observed_phase" == "$to_phase" ]]; then
    needs_phase_update=false
  elif [[ "$observed_phase" == "$from_phase" ]]; then
    needs_phase_update=true
  else
    mutation_die "partial mutation Lifecycle Phase is ambiguous: expected ${from_phase:-missing} or $to_phase, found ${observed_phase:-missing}"
  fi
else
  [[ "$observed_status" == "$from_status" ]] || mutation_die "Jira Status differs from request: expected $from_status, found $observed_status"
  [[ "$observed_phase" == "$from_phase" ]] || mutation_die "Jira Lifecycle Phase differs from request: expected ${from_phase:-missing}, found ${observed_phase:-missing}"
  [[ "$observed_status" == "$to_status" ]] || needs_transition=true
  [[ "$observed_phase" == "$to_phase" ]] || needs_phase_update=true
  intent_body="$tmp_dir/intent.txt"
  {
    printf '%s\n' "$intent_marker"
    printf 'Operation: %s\n' "$operation"
    printf 'Actor: %s\n' "$actor"
    printf 'Card: %s\n' "$card_key"
    printf 'Work Type: %s\n' "$work_type"
    printf 'Native Stage Parent: %s\n' "${stage_parent:-none}"
    printf 'Linked Child Parent: %s\n' "${linked_parent:-none}"
    printf 'Status Transition: %s to %s\n' "$from_status" "$to_status"
    printf 'Lifecycle Phase Transition: %s to %s\n' "${from_phase:-none}" "$to_phase"
    printf 'Lifecycle Phase Label: %s to %s\n' "${from_label:-none}" "$to_label"
    printf 'Reason: %s\n' "$reason"
    jq -r '.transition.evidence[] | "Evidence: " + .' "$request_file"
    printf 'Next Action: %s\n' "$next_action"
  } > "$intent_body"
  post_comment "$intent_body" "$tmp_dir/intent-result.json"

  read_comments "$comments_file"
  comments_text "$comments_file" > "$comments_lines"
  [[ "$(count_line "$comments_lines" "$intent_marker")" == 1 ]] || mutation_die 'durable Jira mutation intent could not be verified'
fi

if [[ "$needs_phase_update" == true ]]; then
  pre_phase_file="$tmp_dir/card-pre-phase.json"
  read_card "$pre_phase_file"
  pre_phase_status="$(validate_card_structure "$pre_phase_file")"
  pre_phase="$(read_card_lifecycle_phase "$pre_phase_file")"
  if [[ "$pre_phase_status" != "$from_status" && "$pre_phase_status" != "$to_status" ]]; then
    mutation_die "Jira Status changed after intent: expected $from_status or $to_status, found $pre_phase_status"
  fi
  if [[ "$pre_phase" == "$to_phase" ]]; then
    needs_phase_update=false
  elif [[ "$pre_phase" != "$from_phase" ]]; then
    mutation_die "Jira Lifecycle Phase changed after intent: expected ${from_phase:-missing} or $to_phase, found ${pre_phase:-missing}"
  fi

  if [[ "$needs_phase_update" == true ]]; then
    edit_args=(jira workitem edit --key "$card_key")
    if [[ -n "$from_label" ]]; then
      edit_args+=(--remove-labels "$from_label")
    fi
    edit_args+=(--labels "$to_label" --yes --json)
    if ! acli "${edit_args[@]}" > "$tmp_dir/phase-result.json"; then
      mutation_die 'Jira Lifecycle Phase update failed after durable intent was recorded. Retry the same request to resume safely'
    fi
  fi

  post_phase_file="$tmp_dir/card-post-phase.json"
  read_card "$post_phase_file"
  post_phase_status="$(validate_card_structure "$post_phase_file")"
  post_phase="$(read_card_lifecycle_phase "$post_phase_file")"
  [[ "$post_phase_status" == "$from_status" || "$post_phase_status" == "$to_status" ]] || mutation_die "Jira Status changed during Lifecycle Phase update: found $post_phase_status"
  [[ "$post_phase" == "$to_phase" ]] || mutation_die "Jira Lifecycle Phase verification failed: expected $to_phase, found ${post_phase:-missing}"
fi

if [[ "$needs_transition" == true ]]; then
  pre_transition_file="$tmp_dir/card-pre-transition.json"
  read_card "$pre_transition_file"
  pre_transition_status="$(validate_card_structure "$pre_transition_file")"
  pre_transition_phase="$(read_card_lifecycle_phase "$pre_transition_file")"
  [[ "$pre_transition_phase" == "$to_phase" ]] || mutation_die "Jira Lifecycle Phase changed before Status transition: expected $to_phase, found ${pre_transition_phase:-missing}"
  if [[ "$pre_transition_status" == "$to_status" ]]; then
    needs_transition=false
  elif [[ "$pre_transition_status" != "$from_status" ]]; then
    mutation_die "Jira Status changed after intent: expected $from_status or $to_status, found $pre_transition_status"
  fi
  if [[ "$needs_transition" == true ]]; then
    if ! acli jira workitem transition --key "$card_key" --status "$to_status" --yes --json > "$tmp_dir/transition-result.json"; then
      mutation_die 'Jira transition failed after durable intent was recorded. Retry the same request to resume safely'
    fi
  fi
fi

after_file="$tmp_dir/card-after.json"
read_card "$after_file"
after_status="$(validate_card_structure "$after_file")"
after_phase="$(read_card_lifecycle_phase "$after_file")"
[[ "$after_status" == "$to_status" ]] || mutation_die "Jira transition verification failed: expected $to_status, found $after_status"
[[ "$after_phase" == "$to_phase" ]] || mutation_die "Jira Lifecycle Phase verification failed: expected $to_phase, found ${after_phase:-missing}"

if [[ "$needs_completion" == true ]]; then
  completion_body="$tmp_dir/completion.txt"
  {
    printf '%s\n' "$completion_marker"
    printf '%s\n' 'Result: passed'
    printf 'Operation: %s\n' "$operation"
    printf 'Actor: %s\n' "$actor"
    printf 'Card: %s\n' "$card_key"
    printf 'Verified Status: %s\n' "$after_status"
    printf 'Verified Lifecycle Phase: %s\n' "$after_phase"
    printf 'Verified Lifecycle Phase Label: %s\n' "$to_label"
    printf 'Verified Work Type: %s\n' "$work_type"
    printf 'Verified Native Stage Parent: %s\n' "${stage_parent:-none}"
    printf 'Verified Linked Child Parent: %s\n' "${linked_parent:-none}"
    printf 'Next Action: %s\n' "$next_action"
  } > "$completion_body"
  post_comment "$completion_body" "$tmp_dir/completion-result.json"

  read_comments "$comments_file"
  comments_text "$comments_file" > "$comments_lines"
  [[ "$(count_line "$comments_lines" "$intent_marker")" == 1 ]] || mutation_die 'durable Jira mutation intent no longer verifies'
  [[ "$(count_line "$comments_lines" "$completion_marker")" == 1 ]] || mutation_die 'durable Jira mutation completion could not be verified'
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
receipt_tmp="$tmp_dir/receipt.json"
from_phase_json="$(jq -c '.["lifecycle-phase"].from' "$request_file")"
if [[ -n "$from_label" ]]; then
  from_label_json="$(jq -n --arg value "$from_label" '$value')"
else
  from_label_json=null
fi
jq -n \
  --arg generated_at "$generated_at" \
  --arg repository "$github_repository" \
  --arg jira_project "$jira_project" \
  --arg mutation_id "$mutation_id" \
  --arg request_digest "$request_digest" \
  --arg operation "$operation" \
  --arg mode "$mode" \
  --arg actor "$actor" \
  --arg from_status "$from_status" \
  --arg to_status "$to_status" \
  --argjson from_phase "$from_phase_json" \
  --arg to_phase "$to_phase" \
  --argjson from_label "$from_label_json" \
  --arg to_label "$to_label" \
  --argjson card "$(jq -c '.card' "$request_file")" \
  --argjson transition "$(jq -c '.transition' "$request_file")" \
  --argjson lifecycle_phase "$(jq -c '.["lifecycle-phase"]' "$request_file")" \
  '{
    "schema-version": 1,
    kind: "clowder-jira-mutation-receipt",
    result: "passed",
    "generated-at": $generated_at,
    repository: $repository,
    "jira-project": $jira_project,
    "mutation-id": $mutation_id,
    "request-sha256": $request_digest,
    operation: $operation,
    mode: $mode,
    actor: $actor,
    card: $card,
    transition: $transition,
    "lifecycle-phase": $lifecycle_phase,
    before: {status: $from_status, "lifecycle-phase": $from_phase, label: $from_label},
    after: {status: $to_status, "lifecycle-phase": $to_phase, label: $to_label},
    "durable-records": {intent: "jira-comment", completion: "jira-comment"}
  }' > "$receipt_tmp"

if ! ln "$receipt_tmp" "$receipt_file"; then
  mutation_die "receipt path was created concurrently: $receipt_file"
fi

if [[ "$json" == true ]]; then
  jq -n --arg receipt "$receipt_file" --arg mode "$mode" --arg card "$card_key" '{ok: true, receipt: $receipt, mode: $mode, card: $card}'
else
  info "Jira mutation passed: $mutation_id ($mode)"
  info "receipt: $receipt_file"
fi
