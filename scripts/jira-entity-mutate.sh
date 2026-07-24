#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path="$PWD"
request_file=""
receipt_file=""
json=false

entity_die() {
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
    *) entity_die "unknown argument: $1" ;;
  esac
done

[[ -n "$request_file" ]] || entity_die 'request path is required'
[[ -n "$receipt_file" ]] || entity_die 'receipt path is required'

repo_path="$(resolve_repo "$repo_path")"
config="$(repo_config "$repo_path")"
[[ -f "$request_file" && ! -L "$request_file" ]] || entity_die "request must be a regular, non-symbolic file: $request_file"
validate_json "$request_file" || entity_die "request is not valid JSON: $request_file"
path_is_within "$request_file" "$repo_path" && entity_die 'request path must be outside the product repository'

receipt_parent="$(dirname -- "$receipt_file")"
[[ -d "$receipt_parent" ]] || entity_die "receipt parent directory does not exist: $receipt_parent"
[[ ! -e "$receipt_file" && ! -L "$receipt_file" ]] || entity_die "receipt path already exists: $receipt_file"
path_is_within "$receipt_file" "$repo_path" && entity_die 'receipt path must be outside the product repository'

require_command jq
require_command acli
jira_integration="$(yaml_scalar "$config" jira.integration 2>/dev/null || true)"
jira_project="$(yaml_scalar "$config" jira.project-key 2>/dev/null || true)"
jira_link_type="$(yaml_scalar "$config" jira.child-link-type 2>/dev/null || true)"
jira_lifecycle_field="$(yaml_scalar "$config" jira.lifecycle-phase-field 2>/dev/null || true)"
github_repository="$(yaml_scalar "$config" github.repository 2>/dev/null || true)"
[[ "$jira_integration" == acli ]] || entity_die 'Jira integration must be configured as acli'
[[ -n "$jira_project" ]] || entity_die 'Jira project key is missing from project configuration'
[[ "$jira_link_type" == Child ]] || entity_die 'Jira child link type must be Child'
[[ "$jira_lifecycle_field" == labels ]] || entity_die 'Jira Lifecycle Phase field must be the native labels field'
[[ -n "$github_repository" ]] || entity_die 'GitHub repository is missing from project configuration'

operation="$(jq -r '.operation // empty' "$request_file")"
[[ "$operation" == create ]] || entity_die "unsupported Jira entity mutation operation: ${operation:-missing}"

if ! jq -e '
  type == "object" and length == 7 and
  .["schema-version"] == 1 and
  .kind == "clowder-jira-mutation" and
  (.["mutation-id"] | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
  .operation == "create" and
  (.actor | IN("Orchestrator", "Product Manager", "Architect", "Developer", "Tester", "Reviewer")) and
  (.card | type == "object" and length == 3) and
  (.create | type == "object" and length == 7) and
  (.create.summary | type == "string" and length > 0 and (contains("\n") | not)) and
  (.create.description | type == "string" and length > 0) and
  .create.status == "To Do" and
  (.create["lifecycle-phase"] | type == "string") and
  (.create.reason | type == "string" and length > 0 and (contains("\n") | not)) and
  (.create.evidence | type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))) and
  (.create["next-action"] | type == "string" and length > 0 and (contains("\n") | not))
' "$request_file" >/dev/null; then
  entity_die 'request does not satisfy the Jira create mutation contract'
fi

mutation_id="$(jq -r '.["mutation-id"]' "$request_file")"
actor="$(jq -r '.actor' "$request_file")"
work_type="$(jq -r '.card["work-type"]' "$request_file")"
stage_parent="$(jq -r '.card["stage-parent"] // empty' "$request_file")"
linked_parent="$(jq -r '.card["linked-parent"] // empty' "$request_file")"
summary="$(jq -r '.create.summary' "$request_file")"
description="$(jq -r '.create.description' "$request_file")"
status="$(jq -r '.create.status' "$request_file")"
phase="$(jq -r '.create["lifecycle-phase"]' "$request_file")"
reason="$(jq -r '.create.reason' "$request_file")"
next_action="$(jq -r '.create["next-action"]' "$request_file")"
[[ "$description" != *CLOWDER_JIRA_CREATION* && "$description" != *CLOWDER_JIRA_MUTATION_* ]] || entity_die 'description contains a reserved Clowder mutation marker'

[[ "$work_type" =~ ^(Stage|Epic|Feature|Subfeature|Bug)$ ]] || entity_die "invalid Jira work type: $work_type"
valid_lifecycle_phase "$phase" || entity_die "invalid Lifecycle Phase: $phase"
phase_label="$(lifecycle_phase_label "$phase")"

case "$work_type" in
  Stage)
    [[ -z "$stage_parent" && -z "$linked_parent" ]] || entity_die 'a Stage cannot have a native or linked parent'
    ;;
  Epic)
    valid_jira_key "$stage_parent" || entity_die 'an Epic requires a valid native Stage Parent'
    [[ -z "$linked_parent" ]] || entity_die 'an Epic cannot have a linked Child parent'
    ;;
  Feature|Subfeature|Bug)
    valid_jira_key "$stage_parent" || entity_die "$work_type requires a valid native Stage Parent"
    valid_jira_key "$linked_parent" || entity_die "$work_type requires a valid linked Child parent"
    ;;
esac
if [[ -n "$stage_parent" ]]; then
  [[ "${stage_parent%%-*}" == "$jira_project" ]] || entity_die 'native Stage Parent belongs to a different configured project'
fi
if [[ -n "$linked_parent" ]]; then
  [[ "${linked_parent%%-*}" == "$jira_project" ]] || entity_die 'linked parent belongs to a different configured project'
fi

request_digest="$(jq -cS . "$request_file" | sha256_stream)"
creation_marker="CLOWDER_JIRA_CREATION v1 id=$mutation_id sha256=$request_digest"
intent_marker="CLOWDER_JIRA_MUTATION_INTENT v1 id=$mutation_id sha256=$request_digest"
completion_marker="CLOWDER_JIRA_MUTATION_COMPLETION v1 id=$mutation_id sha256=$request_digest"

tmp_dir="$(mktemp -d "$receipt_parent/.clowder-jira-entity.XXXXXX")"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

read_card() {
  local card_id=$1
  local target=$2
  if ! acli jira workitem view "$card_id" --fields 'key,summary,description,status,labels,issuetype,parent,issuelinks' --json > "$target"; then
    entity_die "failed to read Jira card: $card_id"
  fi
  validate_json "$target" || entity_die "Jira returned invalid JSON for card: $card_id"
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

card_phase() {
  local card_file=$1
  local count label observed
  jq -e '.fields.labels | type == "array" and all(.[]; type == "string")' "$card_file" >/dev/null || entity_die 'Jira Labels field is missing or invalid'
  count="$(jq '.fields.labels | length' "$card_file")"
  [[ "$count" == 1 ]] || entity_die "Jira card must have exactly 1 Lifecycle Phase label, found $count"
  label="$(jq -r '.fields.labels[0]' "$card_file")"
  observed="$(lifecycle_label_phase "$label" 2>/dev/null || true)"
  [[ -n "$observed" ]] || entity_die "noncanonical Lifecycle Phase label: $label"
  printf '%s\n' "$observed"
}

linked_parent_count() {
  local card_file=$1
  jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null)] | length' "$card_file"
}

linked_parent_key() {
  local card_file=$1
  jq -r --arg link_type "$jira_link_type" '.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null) | .outwardIssue["key"]' "$card_file"
}

if [[ -n "$stage_parent" ]]; then
  stage_file="$tmp_dir/stage.json"
  read_card "$stage_parent" "$stage_file"
  [[ "$(jq -r '.fields.issuetype.name // empty' "$stage_file")" == Stage ]] || entity_die 'native Parent is not a Stage'
  [[ -z "$(jq -r '.fields.parent["key"] // empty' "$stage_file")" ]] || entity_die 'configured Stage has an unexpected native Parent'
fi

if [[ -n "$linked_parent" ]]; then
  linked_parent_file="$tmp_dir/linked-parent.json"
  read_card "$linked_parent" "$linked_parent_file"
  actual_parent_type="$(jq -r '.fields.issuetype.name // empty' "$linked_parent_file")"
  case "$work_type" in
    Feature) expected_parent_type=Epic ;;
    Subfeature) expected_parent_type=Feature ;;
    Bug) expected_parent_type=Subfeature ;;
    *) expected_parent_type='' ;;
  esac
  [[ "$actual_parent_type" == "$expected_parent_type" ]] || entity_die "$work_type linked parent must be a $expected_parent_type, found ${actual_parent_type:-missing}"
  actual_parent_stage="$(jq -r '.fields.parent["key"] // empty' "$linked_parent_file")"
  [[ "$actual_parent_stage" == "$stage_parent" ]] || entity_die "linked parent belongs to a different Stage: ${actual_parent_stage:-missing}"
fi

read_comments() {
  local card_id=$1
  local target=$2
  if ! acli jira workitem comment list --key "$card_id" --paginate --json > "$target"; then
    entity_die "failed to read Jira mutation records for card: $card_id"
  fi
  validate_json "$target" || entity_die "Jira returned invalid comment JSON for card: $card_id"
}

comment_lines() {
  local comments_file=$1
  jq -r '.. | strings' "$comments_file"
}

count_line() {
  local file=$1
  local wanted=$2
  awk -v wanted="$wanted" '$0 == wanted { count += 1 } END { print count + 0 }' "$file"
}

post_comment() {
  local card_id=$1
  local body_file=$2
  local output_file=$3
  if ! acli jira workitem comment create --key "$card_id" --body-file "$body_file" --json > "$output_file"; then
    entity_die "failed to record Jira mutation evidence for card: $card_id"
  fi
}

find_created_card() {
  local search_file="$tmp_dir/search.json"
  local candidate_file candidate_description card_id
  local exact_count=0
  local conflicting_count=0
  local found=''
  local jql="project = $jira_project AND description ~ \"\\\"$mutation_id\\\"\""

  if ! acli jira workitem search --jql "$jql" --fields key --paginate --json > "$search_file"; then
    entity_die 'failed to search Jira for a prior creation attempt'
  fi
  validate_json "$search_file" || entity_die 'Jira returned invalid creation-search JSON'
  jq -e 'type == "array"' "$search_file" >/dev/null || entity_die 'Jira creation search did not return an array'

  while IFS= read -r card_id; do
    valid_jira_key "$card_id" || continue
    candidate_file="$tmp_dir/candidate-$card_id.json"
    read_card "$card_id" "$candidate_file"
    candidate_description="$(plain_description "$candidate_file")"
    if printf '%s\n' "$candidate_description" | grep -Fqx "$creation_marker"; then
      exact_count=$((exact_count + 1))
      found=$card_id
    elif printf '%s\n' "$candidate_description" | grep -Fq "CLOWDER_JIRA_CREATION v1 id=$mutation_id "; then
      conflicting_count=$((conflicting_count + 1))
    fi
  done < <(jq -r '.[] | .["key"] // empty' "$search_file")

  ((conflicting_count == 0)) || entity_die 'mutation ID already exists with a different request digest'
  ((exact_count <= 1)) || entity_die 'Jira contains duplicate cards for the creation mutation'
  printf '%s\n' "$found"
}

journal_dir="$repo_path/.clowder/runtime/jira-creation"
[[ ! -L "$repo_path/.clowder" && ! -L "$repo_path/.clowder/runtime" && ! -L "$journal_dir" ]] || entity_die 'Jira creation journal path cannot contain a symbolic link'
mkdir -p "$journal_dir"
[[ -d "$journal_dir" ]] || entity_die 'failed to create the Jira creation journal directory'
attempt_file="$journal_dir/$mutation_id.json"
created_card=''
if [[ -e "$attempt_file" || -L "$attempt_file" ]]; then
  [[ -f "$attempt_file" && ! -L "$attempt_file" ]] || entity_die 'creation attempt journal must be a regular, non-symbolic file'
  validate_json "$attempt_file" || entity_die 'creation attempt journal is invalid'
  [[ "$(jq -r '.["request-sha256"] // empty' "$attempt_file")" == "$request_digest" ]] || entity_die 'mutation ID already exists with a different request digest'
  created_card="$(jq -r '.card // empty' "$attempt_file")"
  if [[ -n "$created_card" ]]; then
    valid_jira_key "$created_card" || entity_die 'creation attempt journal contains an invalid Jira key'
    [[ "${created_card%%-*}" == "$jira_project" ]] || entity_die 'creation attempt journal contains a card from another project'
  else
    created_card="$(find_created_card)"
  fi
else
  created_card="$(find_created_card)"
fi
mode=applied
if [[ -n "$created_card" ]]; then
  mode=recovered
fi

if [[ -z "$created_card" ]]; then
  if [[ -e "$attempt_file" ]]; then
    entity_die 'a prior creation attempt is unresolved and Jira does not yet expose the card. Retry after Jira indexing or reconcile the attempt manually'
  fi

  attempt_tmp="$tmp_dir/attempt.json"
  jq -n --arg mutation_id "$mutation_id" --arg request_digest "$request_digest" \
    '{"schema-version": 1, kind: "clowder-jira-creation-attempt", "mutation-id": $mutation_id, "request-sha256": $request_digest}' > "$attempt_tmp"
  ln "$attempt_tmp" "$attempt_file" || entity_die 'creation attempt journal path was created concurrently'

  description_file="$tmp_dir/create-description.txt"
  {
    printf '%s\n\n' "$description"
    printf '%s\n' "$creation_marker"
  } > "$description_file"

  create_args=(jira workitem create --project "$jira_project" --type "$work_type" --summary "$summary" --description-file "$description_file" --label "$phase_label")
  [[ -z "$stage_parent" ]] || create_args+=(--parent "$stage_parent")
  create_args+=(--json)
  if ! acli "${create_args[@]}" > "$tmp_dir/create-result.json"; then
    created_card="$(find_created_card)"
    [[ -n "$created_card" ]] || entity_die 'Jira card creation has an ambiguous result. The attempt journal prevents an unsafe duplicate retry'
    mode=recovered
  else
    validate_json "$tmp_dir/create-result.json" || entity_die 'Jira returned invalid card-creation JSON'
    created_card="$(jq -r '.["key"] // .issue["key"] // .workItem["key"] // empty' "$tmp_dir/create-result.json")"
    valid_jira_key "$created_card" || entity_die 'Jira card creation did not return a valid Jira key'
    [[ "${created_card%%-*}" == "$jira_project" ]] || entity_die 'Jira created the card in a different project'
  fi
fi

journal_tmp="$tmp_dir/attempt-with-card.json"
jq -n \
  --arg mutation_id "$mutation_id" \
  --arg request_digest "$request_digest" \
  --arg card "$created_card" \
  '{"schema-version": 1, kind: "clowder-jira-creation-attempt", "mutation-id": $mutation_id, "request-sha256": $request_digest, card: $card}' \
  > "$journal_tmp"
if [[ -e "$attempt_file" ]]; then
  mv -- "$journal_tmp" "$attempt_file"
else
  ln "$journal_tmp" "$attempt_file" || entity_die 'creation attempt journal path was created concurrently'
fi

validate_created_card() {
  local card_file=$1
  local require_link=$2
  local actual_type actual_status actual_stage actual_summary actual_description actual_phase
  local parent_count actual_linked_parent invalid_direction_count

  actual_type="$(jq -r '.fields.issuetype.name // empty' "$card_file")"
  actual_status="$(jq -r '.fields.status.name // empty' "$card_file")"
  actual_stage="$(jq -r '.fields.parent["key"] // empty' "$card_file")"
  actual_summary="$(jq -r '.fields.summary // empty' "$card_file")"
  actual_description="$(plain_description "$card_file")"
  actual_phase="$(card_phase "$card_file")"

  [[ "$actual_type" == "$work_type" ]] || entity_die "created Jira work type differs from request: expected $work_type, found ${actual_type:-missing}"
  [[ "$actual_status" == "$status" ]] || entity_die "created Jira Status differs from request: expected $status, found ${actual_status:-missing}"
  [[ "$actual_phase" == "$phase" ]] || entity_die "created Jira Lifecycle Phase differs from request: expected $phase, found ${actual_phase:-missing}"
  [[ "$actual_summary" == "$summary" ]] || entity_die 'created Jira summary differs from request'
  printf '%s\n' "$actual_description" | grep -Fqx "$creation_marker" || entity_die 'created Jira description is missing its exact recovery marker'
  [[ "$actual_description" == "$description"$'\n\n'* ]] || entity_die 'created Jira description differs from request'

  if [[ "$work_type" == Stage ]]; then
    [[ -z "$actual_stage" ]] || entity_die "created Stage has an unexpected native Parent: $actual_stage"
  else
    [[ "$actual_stage" == "$stage_parent" ]] || entity_die "created card has the wrong native Stage Parent: ${actual_stage:-missing}"
  fi

  invalid_direction_count="$(jq --arg link_type "$jira_link_type" '[.fields.issuelinks[]? | select(.type.name == $link_type and .outwardIssue != null and .type.outward != "is child of")] | length' "$card_file")"
  [[ "$invalid_direction_count" == 0 ]] || entity_die 'created card has an invalid linked-parent direction'
  parent_count="$(linked_parent_count "$card_file")"
  if [[ -z "$linked_parent" ]]; then
    [[ "$parent_count" == 0 ]] || entity_die "$work_type has an unexpected linked Child parent"
  elif [[ "$require_link" == true ]]; then
    [[ "$parent_count" == 1 ]] || entity_die "$work_type must have exactly 1 linked Child parent, found $parent_count"
    actual_linked_parent="$(linked_parent_key "$card_file")"
    [[ "$actual_linked_parent" == "$linked_parent" ]] || entity_die "created card has the wrong linked Child parent: $actual_linked_parent"
  else
    [[ "$parent_count" == 0 || "$parent_count" == 1 ]] || entity_die "$work_type has ambiguous linked Child parents"
    if [[ "$parent_count" == 1 ]]; then
      actual_linked_parent="$(linked_parent_key "$card_file")"
      [[ "$actual_linked_parent" == "$linked_parent" ]] || entity_die "created card has an unexpected linked Child parent: $actual_linked_parent"
    fi
  fi
}

before_link_file="$tmp_dir/card-before-link.json"
read_card "$created_card" "$before_link_file"
validate_created_card "$before_link_file" false

comments_file="$tmp_dir/comments.json"
comments_lines="$tmp_dir/comments.txt"
read_comments "$created_card" "$comments_file"
comment_lines "$comments_file" > "$comments_lines"
intent_count="$(count_line "$comments_lines" "$intent_marker")"
completion_count="$(count_line "$comments_lines" "$completion_marker")"
((intent_count <= 1)) || entity_die 'Jira contains duplicate mutation intent records'
((completion_count <= 1)) || entity_die 'Jira contains duplicate mutation completion records'
if ((completion_count == 1 && intent_count != 1)); then
  entity_die 'Jira mutation completion exists without its intent record'
fi
if ((completion_count == 1)); then
  mode=replayed
fi

if ((intent_count == 0)); then
  intent_body="$tmp_dir/intent.txt"
  {
    printf '%s\n' "$intent_marker"
    printf '%s\n' 'Operation: create'
    printf 'Actor: %s\n' "$actor"
    printf 'Created Card: %s\n' "$created_card"
    printf 'Work Type: %s\n' "$work_type"
    printf 'Native Stage Parent: %s\n' "${stage_parent:-none}"
    printf 'Linked Child Parent: %s\n' "${linked_parent:-none}"
    printf 'Initial Status: %s\n' "$status"
    printf 'Initial Lifecycle Phase: %s\n' "$phase"
    printf 'Reason: %s\n' "$reason"
    jq -r '.create.evidence[] | "Evidence: " + .' "$request_file"
    printf 'Next Action: %s\n' "$next_action"
  } > "$intent_body"
  post_comment "$created_card" "$intent_body" "$tmp_dir/intent-result.json"
fi

if [[ -n "$linked_parent" ]]; then
  current_parent_count="$(linked_parent_count "$before_link_file")"
  if [[ "$current_parent_count" == 0 ]]; then
    if ! acli jira workitem link create --out "$linked_parent" --in "$created_card" --type "$jira_link_type" --yes > "$tmp_dir/link-result.txt"; then
      entity_die 'Jira linked-parent creation failed after the card and durable intent were created. Retry the same request to resume safely'
    fi
  fi
fi

after_file="$tmp_dir/card-after.json"
read_card "$created_card" "$after_file"
validate_created_card "$after_file" true

if ((completion_count == 0)); then
  completion_body="$tmp_dir/completion.txt"
  {
    printf '%s\n' "$completion_marker"
    printf '%s\n' 'Result: passed'
    printf '%s\n' 'Operation: create'
    printf 'Actor: %s\n' "$actor"
    printf 'Created Card: %s\n' "$created_card"
    printf 'Verified Work Type: %s\n' "$work_type"
    printf 'Verified Native Stage Parent: %s\n' "${stage_parent:-none}"
    printf 'Verified Linked Child Parent: %s\n' "${linked_parent:-none}"
    printf 'Verified Status: %s\n' "$status"
    printf 'Verified Lifecycle Phase: %s\n' "$phase"
    printf 'Next Action: %s\n' "$next_action"
  } > "$completion_body"
  post_comment "$created_card" "$completion_body" "$tmp_dir/completion-result.json"
fi

read_comments "$created_card" "$comments_file"
comment_lines "$comments_file" > "$comments_lines"
[[ "$(count_line "$comments_lines" "$intent_marker")" == 1 ]] || entity_die 'durable Jira mutation intent could not be verified'
[[ "$(count_line "$comments_lines" "$completion_marker")" == 1 ]] || entity_die 'durable Jira mutation completion could not be verified'

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
receipt_tmp="$tmp_dir/receipt.json"
card_json="$(jq -c --arg card_id "$created_card" '.card + {key: $card_id}' "$request_file")"
jq -n \
  --arg generated_at "$generated_at" \
  --arg repository "$github_repository" \
  --arg jira_project "$jira_project" \
  --arg mutation_id "$mutation_id" \
  --arg request_digest "$request_digest" \
  --arg mode "$mode" \
  --arg actor "$actor" \
  --argjson card "$card_json" \
  --argjson change "$(jq -c '.create' "$request_file")" \
  '{
    "schema-version": 1,
    kind: "clowder-jira-mutation-receipt",
    result: "passed",
    "generated-at": $generated_at,
    repository: $repository,
    "jira-project": $jira_project,
    "mutation-id": $mutation_id,
    "request-sha256": $request_digest,
    operation: "create",
    mode: $mode,
    actor: $actor,
    card: $card,
    change: $change,
    before: null,
    after: {
      summary: $change.summary,
      description: $change.description,
      status: $change.status,
      "lifecycle-phase": $change["lifecycle-phase"],
      "stage-parent": $card["stage-parent"],
      "linked-parent": $card["linked-parent"]
    },
    "durable-records": {intent: "jira-comment", completion: "jira-comment", recovery: "jira-description"}
  }' > "$receipt_tmp"

ln "$receipt_tmp" "$receipt_file" || entity_die "receipt path was created concurrently: $receipt_file"

if [[ "$json" == true ]]; then
  jq -n --arg receipt "$receipt_file" --arg mode "$mode" --arg card "$created_card" '{ok: true, receipt: $receipt, mode: $mode, card: $card}'
else
  info "Jira mutation passed: $mutation_id ($mode)"
  info "receipt: $receipt_file"
fi
