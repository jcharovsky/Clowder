#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/clowder-jira-entity-mutate-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

fail() {
  printf 'jira-entity-mutate test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1
  local needle=$2
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

repo="$fixture_root/repo"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
"$ROOT/scripts/onboard.sh" --repo "$repo" --name 'Jira Entity Mutation Fixture' --jira-project FIX >/dev/null
source "$ROOT/scripts/lib.sh"
update_yaml_values "$repo/.clowder/project.yaml" jira.integration acli

mock_bin="$fixture_root/mock-bin"
mock_state_dir="$fixture_root/jira-state"
mock_comments="$fixture_root/jira-comments.json"
mock_log="$fixture_root/acli.log"
mock_next_key="$fixture_root/next-key"
mock_next_link="$fixture_root/next-link"
mock_fail_link_once="$fixture_root/fail-link-once"
mock_fail_edit_once="$fixture_root/fail-edit-once"
mkdir -p "$mock_bin" "$mock_state_dir"
cp "$TEST_DIR/fixtures/acli-entity-mutation-mock" "$mock_bin/acli"
chmod +x "$mock_bin/acli"
printf '%s\n' 'FIX-30' > "$mock_next_key"
printf '%s\n' '9300' > "$mock_next_link"
printf '%s\n' '{}' > "$mock_comments"
: > "$mock_log"

jq -n '{
  key: "FIX-1",
  fields: {
    summary: "Stage fixture",
    description: "Stage fixture.",
    status: {name: "To Do"},
    labels: ["Intake"],
    issuetype: {name: "Stage"},
    parent: null,
    issuelinks: []
  }
}' > "$mock_state_dir/FIX-1.json"

jq -n '{
  key: "FIX-10",
  fields: {
    summary: "Feature fixture",
    description: "Feature fixture.",
    status: {name: "To Do"},
    labels: ["Design"],
    issuetype: {name: "Feature"},
    parent: {key: "FIX-1", fields: {issuetype: {name: "Stage"}}},
    issuelinks: []
  }
}' > "$mock_state_dir/FIX-10.json"

jq -n '{
  key: "FIX-11",
  fields: {
    summary: "Replacement Feature fixture",
    description: "Replacement Feature fixture.",
    status: {name: "To Do"},
    labels: ["Design"],
    issuetype: {name: "Feature"},
    parent: {key: "FIX-1", fields: {issuetype: {name: "Stage"}}},
    issuelinks: []
  }
}' > "$mock_state_dir/FIX-11.json"

mutation_env=(
  PATH="$mock_bin:$PATH"
  CLOWDER_TEST_JIRA_STATE_DIR="$mock_state_dir"
  CLOWDER_TEST_JIRA_COMMENTS="$mock_comments"
  CLOWDER_TEST_ACLI_LOG="$mock_log"
  CLOWDER_TEST_NEXT_KEY="$mock_next_key"
  CLOWDER_TEST_NEXT_LINK="$mock_next_link"
  CLOWDER_TEST_FAIL_LINK_ONCE="$mock_fail_link_once"
  CLOWDER_TEST_FAIL_EDIT_ONCE="$mock_fail_edit_once"
)
export "${mutation_env[@]}"

create_request="$fixture_root/create-request.json"
create_receipt="$fixture_root/create-receipt.json"
jq -n '{
  "schema-version": 1,
  kind: "clowder-jira-mutation",
  "mutation-id": "FIX-create-subfeature-1",
  operation: "create",
  actor: "Architect",
  card: {
    "work-type": "Subfeature",
    "stage-parent": "FIX-1",
    "linked-parent": "FIX-10"
  },
  create: {
    summary: "Deterministic Jira creation",
    description: "Outcome: provide deterministic creation.\nReason: exercise B-05.\nSource: Architect decomposition.",
    status: "To Do",
    "lifecycle-phase": "Design",
    reason: "The approved design requires this Subfeature.",
    evidence: ["The parent Feature and Stage were verified."],
    "next-action": "Dispatch the Subfeature when development is ready."
  }
}' > "$create_request"

: > "$mock_fail_link_once"
if create_failure_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$create_request" --receipt "$create_receipt" --json 2>&1)"; then
  fail 'creation unexpectedly succeeded when linked-parent creation failed'
fi
assert_contains "$create_failure_output" 'linked-parent creation failed after the card and durable intent were created'
[[ ! -e "$create_receipt" ]] || fail 'partial creation emitted a success receipt'
[[ -f "$mock_state_dir/FIX-30.json" ]] || fail 'partial creation did not retain the created card'
[[ "$(jq '.fields.issuelinks | length' "$mock_state_dir/FIX-30.json")" == 0 ]] || fail 'failed linked-parent creation changed the hierarchy'

create_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$create_request" --receipt "$create_receipt" --json)"
assert_contains "$create_output" '"ok": true'
[[ "$(jq -r '.operation' "$create_receipt")" == create ]] || fail 'creation receipt has the wrong operation'
[[ "$(jq -r '.mode' "$create_receipt")" == recovered ]] || fail 'retried creation was not identified as recovered'
created_card="$(jq -r '.card["key"]' "$create_receipt")"
[[ "$created_card" == FIX-30 ]] || fail 'creation receipt does not contain the created Jira card'
[[ "$(jq -r '.fields.issuetype.name' "$mock_state_dir/FIX-30.json")" == Subfeature ]] || fail 'created card has the wrong work type'
[[ "$(jq -r '.fields.status.name' "$mock_state_dir/FIX-30.json")" == 'To Do' ]] || fail 'created card has the wrong Status'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state_dir/FIX-30.json")" == Design ]] || fail 'created card has the wrong Lifecycle Phase label'
[[ "$(jq -r '.fields.parent["key"]' "$mock_state_dir/FIX-30.json")" == FIX-1 ]] || fail 'created card has the wrong native Stage Parent'
linked_parent="$(jq -r '.fields.issuelinks[] | select(.outwardIssue != null) | .outwardIssue["key"]' "$mock_state_dir/FIX-30.json")"
[[ "$linked_parent" == FIX-10 ]] || fail 'created card has the wrong linked parent'
created_description="$(jq -r '.fields.description' "$mock_state_dir/FIX-30.json")"
[[ "$created_description" == *'CLOWDER_JIRA_CREATION v1 id=FIX-create-subfeature-1 '* ]] || fail 'created card does not retain its recovery marker'
[[ "$(jq '."FIX-30" | length' "$mock_comments")" == 2 ]] || fail 'created card does not retain intent and completion records'

replay_receipt="$fixture_root/create-replay-receipt.json"
replay_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$create_request" --receipt "$replay_receipt" --json)"
assert_contains "$replay_output" '"ok": true'
[[ "$(jq -r '.mode' "$replay_receipt")" == replayed ]] || fail 'creation replay was not identified'
[[ "$(grep -c '^jira workitem create ' "$mock_log")" == 1 ]] || fail 'creation replay duplicated the Jira card'
[[ "$(grep -c '^jira workitem link create ' "$mock_log")" == 2 ]] || fail 'creation recovery or replay used the wrong number of Jira link attempts'
[[ "$(grep -c '^jira workitem search ' "$mock_log")" == 1 ]] || fail 'creation replay depended on Jira search after the journal stored the card key'
[[ "$(jq -r '.card' "$repo/.clowder/runtime/jira-creation/FIX-create-subfeature-1.json")" == FIX-30 ]] || fail 'creation journal does not retain the created Jira key'

copied_create_request="$fixture_root/copied-create-request.json"
cp "$create_request" "$copied_create_request"
copied_replay_receipt="$fixture_root/copied-create-replay-receipt.json"
copied_replay_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$copied_create_request" --receipt "$copied_replay_receipt" --json)"
assert_contains "$copied_replay_output" '"ok": true'
[[ "$(jq -r '.mode' "$copied_replay_receipt")" == replayed ]] || fail 'copied creation request was not safely replayed'
[[ "$(grep -c '^jira workitem search ' "$mock_log")" == 1 ]] || fail 'copied creation request bypassed the mutation-ID journal'

edit_request="$fixture_root/edit-request.json"
edit_receipt="$fixture_root/edit-receipt.json"
jq -n '{
  "schema-version": 1,
  kind: "clowder-jira-mutation",
  "mutation-id": "FIX-edit-subfeature-1",
  operation: "edit",
  actor: "Architect",
  card: {
    key: "FIX-30",
    "work-type": "Subfeature",
    "stage-parent": "FIX-1",
    "linked-parent": "FIX-10"
  },
  edit: {
    from: {
      summary: "Deterministic Jira creation",
      description: "Outcome: provide deterministic creation.\nReason: exercise B-05.\nSource: Architect decomposition."
    },
    to: {
      summary: "Deterministic Jira metadata",
      description: "Outcome: provide deterministic Jira metadata.\nReason: complete the B-05 edit path.\nSource: Architect refinement."
    },
    reason: "The technical decomposition was refined.",
    evidence: ["The Feature design remains approved."],
    "next-action": "Retain the refined Subfeature for dispatch."
  }
}' > "$edit_request"

: > "$mock_fail_edit_once"
if edit_failure_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$edit_request" --receipt "$edit_receipt" --json 2>&1)"; then
  fail 'metadata edit unexpectedly succeeded when ACLI failed'
fi
assert_contains "$edit_failure_output" 'metadata edit failed after durable intent was recorded'
[[ ! -e "$edit_receipt" ]] || fail 'partial metadata edit emitted a success receipt'

edit_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$edit_request" --receipt "$edit_receipt" --json)"
assert_contains "$edit_output" '"ok": true'
[[ "$(jq -r '.operation' "$edit_receipt")" == edit ]] || fail 'edit receipt has the wrong operation'
[[ "$(jq -r '.mode' "$edit_receipt")" == recovered ]] || fail 'retried metadata edit was not identified as recovered'
[[ "$(jq -r '.fields.summary' "$mock_state_dir/FIX-30.json")" == 'Deterministic Jira metadata' ]] || fail 'Jira summary was not edited'
edited_description="$(jq -r '.fields.description' "$mock_state_dir/FIX-30.json")"
[[ "$edited_description" == 'Outcome: provide deterministic Jira metadata.'* ]] || fail 'Jira description was not edited'
[[ "$edited_description" == *'CLOWDER_JIRA_CREATION v1 id=FIX-create-subfeature-1 '* ]] || fail 'metadata edit removed the creation recovery marker'

edit_replay_receipt="$fixture_root/edit-replay-receipt.json"
edit_replay_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$edit_request" --receipt "$edit_replay_receipt" --json)"
assert_contains "$edit_replay_output" '"ok": true'
[[ "$(jq -r '.mode' "$edit_replay_receipt")" == replayed ]] || fail 'edit replay was not identified'
[[ "$(grep -c '^jira workitem edit ' "$mock_log")" == 2 ]] || fail 'metadata recovery or replay used the wrong number of Jira edit attempts'

relationship_request="$fixture_root/relationship-request.json"
relationship_receipt="$fixture_root/relationship-receipt.json"
jq -n '{
  "schema-version": 1,
  kind: "clowder-jira-mutation",
  "mutation-id": "FIX-reparent-subfeature-1",
  operation: "relationship",
  actor: "Architect",
  card: {
    key: "FIX-30",
    "work-type": "Subfeature",
    "stage-parent": "FIX-1"
  },
  relationship: {
    from: "FIX-10",
    to: "FIX-11",
    reason: "The refined decomposition moved this work to the replacement Feature.",
    evidence: ["Both Features belong directly to the same Stage."],
    "next-action": "Retain the corrected decomposition hierarchy."
  }
}' > "$relationship_request"

: > "$mock_fail_link_once"
if relationship_failure_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$relationship_request" --receipt "$relationship_receipt" --json 2>&1)"; then
  fail 'relationship mutation unexpectedly succeeded when target-link creation failed'
fi
assert_contains "$relationship_failure_output" 'linked-parent creation failed after durable intent was recorded'
[[ ! -e "$relationship_receipt" ]] || fail 'partial relationship mutation emitted a success receipt'
[[ "$(jq '[.fields.issuelinks[] | select(.outwardIssue != null)] | length' "$mock_state_dir/FIX-30.json")" == 0 ]] || fail 'partial relationship mutation did not retain the recoverable link gap'

relationship_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$relationship_request" --receipt "$relationship_receipt" --json)"
assert_contains "$relationship_output" '"ok": true'
[[ "$(jq -r '.operation' "$relationship_receipt")" == relationship ]] || fail 'relationship receipt has the wrong operation'
[[ "$(jq -r '.mode' "$relationship_receipt")" == recovered ]] || fail 'retried relationship mutation was not identified as recovered'
linked_parent="$(jq -r '.fields.issuelinks[] | select(.outwardIssue != null) | .outwardIssue["key"]' "$mock_state_dir/FIX-30.json")"
[[ "$linked_parent" == FIX-11 ]] || fail 'relationship mutation did not install the target linked parent'

relationship_replay_receipt="$fixture_root/relationship-replay-receipt.json"
relationship_replay_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$relationship_request" --receipt "$relationship_replay_receipt" --json)"
assert_contains "$relationship_replay_output" '"ok": true'
[[ "$(jq -r '.mode' "$relationship_replay_receipt")" == replayed ]] || fail 'relationship replay was not identified'
[[ "$(grep -c '^jira workitem link delete ' "$mock_log")" == 1 ]] || fail 'relationship replay repeated the Jira link deletion'
[[ "$(grep -c '^jira workitem link create ' "$mock_log")" == 4 ]] || fail 'relationship recovery or replay used the wrong number of Jira link attempts'

stale_edit_request="$fixture_root/stale-edit-request.json"
jq '.["mutation-id"] = "FIX-edit-subfeature-stale-1" | .card["linked-parent"] = "FIX-11"' "$edit_request" > "$stale_edit_request"
stale_edit_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$stale_edit_request" --receipt "$fixture_root/stale-edit-receipt.json" --json 2>&1 || true)"
assert_contains "$stale_edit_output" 'Jira summary differs from the requested source value'
[[ "$(grep -c '^jira workitem edit ' "$mock_log")" == 2 ]] || fail 'stale edit request reached the Jira edit command'

wrong_actor_request="$fixture_root/wrong-actor-relationship.json"
jq '.["mutation-id"] = "FIX-reparent-wrong-actor-1" | .actor = "Reviewer" | .relationship.from = "FIX-11" | .relationship.to = "FIX-10"' \
  "$relationship_request" > "$wrong_actor_request"
wrong_actor_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$wrong_actor_request" --receipt "$fixture_root/wrong-actor-receipt.json" --json 2>&1 || true)"
assert_contains "$wrong_actor_output" 'only the Orchestrator, Product Manager, or Architect may change an unowned To Do hierarchy'
[[ "$(grep -c '^jira workitem link delete ' "$mock_log")" == 1 ]] || fail 'unauthorized relationship request deleted a Jira link'

wrong_parent_create_request="$fixture_root/wrong-parent-create.json"
jq '
  .["mutation-id"] = "FIX-create-bug-wrong-parent-1" |
  .actor = "Tester" |
  .card["work-type"] = "Bug" |
  .card["linked-parent"] = "FIX-11" |
  .create.summary = "Invalid Bug fixture" |
  .create["lifecycle-phase"] = "Testing"
' "$create_request" > "$wrong_parent_create_request"
wrong_parent_create_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$wrong_parent_create_request" --receipt "$fixture_root/wrong-parent-create-receipt.json" --json 2>&1 || true)"
assert_contains "$wrong_parent_create_output" 'Bug linked parent must be a Subfeature'
[[ "$(grep -c '^jira workitem create ' "$mock_log")" == 1 ]] || fail 'invalid creation hierarchy reached the Jira create command'

conflicting_create_request="$fixture_root/conflicting-create.json"
jq '.create.summary = "Conflicting creation payload"' "$create_request" > "$conflicting_create_request"
conflicting_create_output="$("$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$conflicting_create_request" --receipt "$fixture_root/conflicting-create-receipt.json" --json 2>&1 || true)"
assert_contains "$conflicting_create_output" 'mutation ID already exists with a different request digest'
[[ "$(grep -c '^jira workitem create ' "$mock_log")" == 1 ]] || fail 'conflicting creation replay duplicated the Jira card'

printf '%s\n' 'jira entity mutation tests passed'
