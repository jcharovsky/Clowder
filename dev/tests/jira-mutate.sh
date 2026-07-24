#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/clowder-jira-mutate-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

fail() {
  printf 'jira-mutate test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1
  local needle=$2
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

schema="$ROOT/schemas/jira-mutation-receipt.schema.json"
[[ -f "$schema" ]] || fail 'Jira mutation receipt schema is missing'
request_schema="$ROOT/schemas/jira-mutation-request.schema.json"
[[ -f "$request_schema" ]] || fail 'Jira mutation request schema is missing'
jq -e '
  .properties.kind.const == "clowder-jira-mutation" and
  .properties.operation.enum == ["transition", "create", "edit", "relationship"] and
  (.required | index("mutation-id") != null) and
  (.required | index("card") != null) and
  ([.oneOf[].properties.operation.const] == ["transition", "create", "edit", "relationship"]) and
  (."$defs" | has("existing-card") and has("create-card") and has("relationship-card")) and
  .properties["lifecycle-phase"]."$ref" == "#/$defs/lifecycle-phase-transition"
' "$request_schema" >/dev/null || fail 'Jira mutation request schema does not define the public contract'
jq -e '
  .properties.kind.const == "clowder-jira-mutation-receipt" and
  .properties.result.const == "passed" and
  .properties.mode.enum == ["applied", "recovered", "replayed"] and
  .properties.operation.enum == ["transition", "create", "edit", "relationship"] and
  ([.oneOf[].properties.operation.const] == ["transition", "create", "edit", "relationship"]) and
  (.required | index("request-sha256") != null) and
  (.required | index("before") != null) and
  (.required | index("after") != null) and
  (."$defs"["observed-state"].required | index("lifecycle-phase") != null) and
  (."$defs"["observed-state"].required | index("label") != null)
' "$schema" >/dev/null || fail 'Jira mutation receipt schema does not define the public contract'

repo="$fixture_root/repo"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
"$ROOT/scripts/onboard.sh" --repo "$repo" --name 'Jira Mutation Fixture' --jira-project FIX >/dev/null
source "$ROOT/scripts/lib.sh"
update_yaml_values "$repo/.clowder/project.yaml" jira.integration acli

mock_bin="$fixture_root/mock-bin"
mock_state_dir="$fixture_root/jira-state"
mock_state="$mock_state_dir/FIX-20.json"
mock_comments="$fixture_root/jira-comments.json"
mock_log="$fixture_root/acli.log"
mock_fail_once="$fixture_root/fail-transition-once"
mock_fail_label_once="$fixture_root/fail-label-once"
mock_fail_completion_once="$fixture_root/fail-completion-once"
mkdir -p "$mock_bin" "$mock_state_dir"
cp "$TEST_DIR/fixtures/acli-mutation-mock" "$mock_bin/acli"
chmod +x "$mock_bin/acli"

reset_jira() {
  jq -n '{
    key: "FIX-20",
    fields: {
      summary: "Deterministic handoff fixture",
      status: {name: "Tester"},
      labels: ["Testing"],
      issuetype: {name: "Subfeature"},
      parent: {key: "FIX-1", fields: {issuetype: {name: "Stage"}}},
      issuelinks: [{
        id: "9001",
        type: {name: "Child", inward: "is parent of", outward: "is child of"},
        outwardIssue: {key: "FIX-10", fields: {issuetype: {name: "Feature"}}}
      }]
    }
  }' > "$mock_state"
  printf '%s\n' '[]' > "$mock_comments"
  : > "$mock_log"
  rm -f -- "$mock_fail_once" "$mock_fail_once.used" "$mock_fail_label_once" "$mock_fail_label_once.used" "$mock_fail_completion_once" "$mock_fail_completion_once.used"
}

write_request() {
  local target=$1
  local mutation_id=$2
  local linked_parent=${3:-FIX-10}
  local reason=${4:-Independent testing passed.}
  jq -n \
    --arg mutation_id "$mutation_id" \
    --arg linked_parent "$linked_parent" \
    --arg reason "$reason" \
    '{
      "schema-version": 1,
      kind: "clowder-jira-mutation",
      "mutation-id": $mutation_id,
      operation: "transition",
      actor: "Tester",
      card: {
        key: "FIX-20",
        "work-type": "Subfeature",
        "stage-parent": "FIX-1",
        "linked-parent": $linked_parent
      },
      transition: {
        from: "Tester",
        to: "Reviewer",
        reason: $reason,
        evidence: ["Tester evidence at docs/features/FIX-10/evidence/tester.md."],
        "next-action": "Review the verified Feature."
      },
      "lifecycle-phase": {
        from: "Testing",
        to: "Review"
      }
    }' > "$target"
}

reset_feature_closure_jira() {
  jq -n '{
    key: "FIX-20",
    fields: {
      summary: "Feature closure fixture",
      status: {name: "To Do"},
      labels: ["Production"],
      issuetype: {name: "Feature"},
      parent: {key: "FIX-1", fields: {issuetype: {name: "Stage"}}},
      issuelinks: [
        {
          id: "9101",
          type: {name: "Child", inward: "is parent of", outward: "is child of"},
          outwardIssue: {key: "FIX-5", fields: {issuetype: {name: "Epic"}, status: {name: "To Do"}}}
        },
        {
          id: "9102",
          type: {name: "Child", inward: "is parent of", outward: "is child of"},
          inwardIssue: {key: "FIX-21", fields: {issuetype: {name: "Subfeature"}, status: {name: "Developer"}}}
        }
      ]
    }
  }' > "$mock_state_dir/FIX-20.json"
  jq -n '{
    key: "FIX-21",
    fields: {
      summary: "Subfeature closure fixture",
      status: {name: "Developer"},
      labels: ["Development"],
      issuetype: {name: "Subfeature"},
      parent: {key: "FIX-1", fields: {issuetype: {name: "Stage"}}},
      issuelinks: [
        {
          id: "9102",
          type: {name: "Child", inward: "is parent of", outward: "is child of"},
          outwardIssue: {key: "FIX-20", fields: {issuetype: {name: "Feature"}, status: {name: "To Do"}}}
        },
        {
          id: "9103",
          type: {name: "Child", inward: "is parent of", outward: "is child of"},
          inwardIssue: {key: "FIX-22", fields: {issuetype: {name: "Bug"}, status: {name: "Developer"}}}
        }
      ]
    }
  }' > "$mock_state_dir/FIX-21.json"
  jq -n '{
    key: "FIX-22",
    fields: {
      summary: "Bug closure fixture",
      status: {name: "Developer"},
      labels: ["Development"],
      issuetype: {name: "Bug"},
      parent: {key: "FIX-1", fields: {issuetype: {name: "Stage"}}},
      issuelinks: [{
        id: "9103",
        type: {name: "Child", inward: "is parent of", outward: "is child of"},
        outwardIssue: {key: "FIX-21", fields: {issuetype: {name: "Subfeature"}, status: {name: "Developer"}}}
      }]
    }
  }' > "$mock_state_dir/FIX-22.json"
  printf '%s\n' '[]' > "$mock_comments"
  : > "$mock_log"
  rm -f -- "$mock_fail_once" "$mock_fail_once.used" "$mock_fail_label_once" "$mock_fail_label_once.used" "$mock_fail_completion_once" "$mock_fail_completion_once.used"
}

write_feature_closure_request() {
  local target=$1
  local mutation_id=$2
  jq -n --arg mutation_id "$mutation_id" '{
    "schema-version": 1,
    kind: "clowder-jira-mutation",
    "mutation-id": $mutation_id,
    operation: "transition",
    actor: "Product Manager",
    card: {
      key: "FIX-20",
      "work-type": "Feature",
      "stage-parent": "FIX-1",
      "linked-parent": "FIX-5"
    },
    transition: {
      from: "To Do",
      to: "Done",
      reason: "All Feature completion gates passed.",
      evidence: ["The verified Ready for Merge receipt is published on the merged pull request."],
      "next-action": "Retain the completed Feature as durable Jira state."
    },
    "lifecycle-phase": {
      from: "Production",
      to: "Complete"
    }
  }' > "$target"
}

mutation_env=(
  PATH="$mock_bin:$PATH"
  CLOWDER_TEST_JIRA_STATE_DIR="$mock_state_dir"
  CLOWDER_TEST_JIRA_COMMENTS="$mock_comments"
  CLOWDER_TEST_ACLI_LOG="$mock_log"
  CLOWDER_TEST_FAIL_ONCE="$mock_fail_once"
  CLOWDER_TEST_FAIL_LABEL_ONCE="$mock_fail_label_once"
  CLOWDER_TEST_FAIL_COMPLETION_ONCE="$mock_fail_completion_once"
)

reset_jira
request="$fixture_root/request.json"
receipt="$fixture_root/receipt.json"
write_request "$request" 'FIX-20-tester-reviewer-1'
success_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$receipt" --json)"
assert_contains "$success_output" '"ok": true'
[[ "$(jq -r '.kind' "$receipt")" == clowder-jira-mutation-receipt ]] || fail 'successful transition receipt has the wrong kind'
[[ "$(jq -r '.result' "$receipt")" == passed ]] || fail 'successful transition receipt did not pass'
[[ "$(jq -r '.mode' "$receipt")" == applied ]] || fail 'successful transition receipt has the wrong mode'
[[ "$(jq -r '.operation' "$receipt")" == transition ]] || fail 'successful transition receipt has the wrong operation'
[[ "$(jq -r '.before.status' "$receipt")" == Tester ]] || fail 'successful transition receipt has the wrong initial Status'
[[ "$(jq -r '.after.status' "$receipt")" == Reviewer ]] || fail 'successful transition receipt has the wrong final Status'
[[ "$(jq -r '.before["lifecycle-phase"]' "$receipt")" == Testing ]] || fail 'successful transition receipt has the wrong initial Lifecycle Phase'
[[ "$(jq -r '.after["lifecycle-phase"]' "$receipt")" == Review ]] || fail 'successful transition receipt has the wrong final Lifecycle Phase'
[[ "$(jq -r '.before.label' "$receipt")" == Testing ]] || fail 'successful transition receipt has the wrong initial phase label'
[[ "$(jq -r '.after.label' "$receipt")" == Review ]] || fail 'successful transition receipt has the wrong final phase label'
[[ "$(jq -r '.fields.status.name' "$mock_state")" == Reviewer ]] || fail 'successful transition did not update Jira Status'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Review ]] || fail 'successful transition did not replace the Jira Lifecycle Phase label'
[[ "$(jq 'length' "$mock_comments")" == 2 ]] || fail 'successful transition did not retain intent and completion records'
[[ "$(grep -c '^jira workitem transition ' "$mock_log")" == 1 ]] || fail 'successful transition count is not 1'
[[ "$(grep -c '^jira workitem edit ' "$mock_log")" == 1 ]] || fail 'successful phase label update count is not 1'

replay_receipt="$fixture_root/replay-receipt.json"
replay_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$replay_receipt" --json)"
assert_contains "$replay_output" '"ok": true'
[[ "$(jq -r '.mode' "$replay_receipt")" == replayed ]] || fail 'completed mutation was not identified as a replay'
[[ "$(grep -c '^jira workitem transition ' "$mock_log")" == 1 ]] || fail 'replay repeated the Jira transition'
[[ "$(grep -c '^jira workitem edit ' "$mock_log")" == 1 ]] || fail 'replay repeated the Jira phase update'
[[ "$(jq 'length' "$mock_comments")" == 2 ]] || fail 'replay duplicated Jira records'

conflict_request="$fixture_root/conflict-request.json"
write_request "$conflict_request" 'FIX-20-tester-reviewer-1' 'FIX-10' 'A conflicting reason.'
conflict_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$conflict_request" --receipt "$fixture_root/conflict-receipt.json" --json 2>&1 || true)"
assert_contains "$conflict_output" 'mutation ID already exists with a different request digest'
[[ "$(grep -c '^jira workitem transition ' "$mock_log")" == 1 ]] || fail 'conflicting replay mutated Jira'

reset_jira
bad_hierarchy_request="$fixture_root/bad-hierarchy-request.json"
write_request "$bad_hierarchy_request" 'FIX-20-bad-hierarchy-1' 'FIX-99'
bad_hierarchy_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$bad_hierarchy_request" --receipt "$fixture_root/bad-hierarchy-receipt.json" --json 2>&1 || true)"
assert_contains "$bad_hierarchy_output" 'linked Child parent differs from request'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'invalid hierarchy produced a Jira intent record'
if grep -q '^jira workitem transition ' "$mock_log"; then
  fail 'invalid hierarchy transitioned Jira'
fi

reset_jira
jq '.fields.status.name = "Developer"' "$mock_state" > "$mock_state.next"
mv -- "$mock_state.next" "$mock_state"
stale_owner_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$fixture_root/stale-owner-receipt.json" --json 2>&1 || true)"
assert_contains "$stale_owner_output" 'Jira Status differs from request: expected Tester, found Developer'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'stale ownership produced a Jira intent record'

reset_jira
jq '.fields.labels = ["misc"]' "$mock_state" > "$mock_state.next"
mv -- "$mock_state.next" "$mock_state"
unknown_label_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$fixture_root/unknown-label-receipt.json" --json 2>&1 || true)"
assert_contains "$unknown_label_output" 'noncanonical Lifecycle Phase label: misc'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'unknown Jira label produced a mutation intent'

reset_jira
jq '.fields.labels = ["Testing", "Review"]' "$mock_state" > "$mock_state.next"
mv -- "$mock_state.next" "$mock_state"
multiple_labels_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$fixture_root/multiple-labels-receipt.json" --json 2>&1 || true)"
assert_contains "$multiple_labels_output" 'must have exactly 1 Lifecycle Phase label, found 2'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'multiple Jira labels produced a mutation intent'

reset_jira
wrong_actor_request="$fixture_root/wrong-actor-request.json"
jq '.actor = "Reviewer"' "$request" > "$wrong_actor_request"
wrong_actor_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$wrong_actor_request" --receipt "$fixture_root/wrong-actor-receipt.json" --json 2>&1 || true)"
assert_contains "$wrong_actor_output" 'actor must match the current player Status'
[[ ! -s "$mock_log" ]] || fail 'invalid actor reached Jira'

reset_jira
jq '.fields.issuelinks[0].type.outward = "is parent of"' "$mock_state" > "$mock_state.next"
mv -- "$mock_state.next" "$mock_state"
reversed_link_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$fixture_root/reversed-link-receipt.json" --json 2>&1 || true)"
assert_contains "$reversed_link_output" 'linked Child relationship has an invalid parent direction'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'reversed hierarchy produced a Jira intent record'

reset_jira
jq '.fields.issuelinks += [{
  id: "9002",
  type: {name: "Child", inward: "is parent of", outward: "is child of"},
  outwardIssue: {key: "FIX-11", fields: {issuetype: {name: "Feature"}}}
}]' "$mock_state" > "$mock_state.next"
mv -- "$mock_state.next" "$mock_state"
duplicate_parent_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$fixture_root/duplicate-parent-receipt.json" --json 2>&1 || true)"
assert_contains "$duplicate_parent_output" 'Subfeature must have exactly 1 linked Child parent, found 2'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'duplicate hierarchy produced a Jira intent record'

reset_jira
unsafe_request="$repo/unsafe-request.json"
cp "$request" "$unsafe_request"
unsafe_request_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$unsafe_request" --receipt "$fixture_root/unsafe-request-receipt.json" --json 2>&1 || true)"
assert_contains "$unsafe_request_output" 'request path must be outside the product repository'
[[ ! -s "$mock_log" ]] || fail 'unsafe request path reached Jira'
[[ ! -e "$fixture_root/unsafe-request-receipt.json" ]] || fail 'unsafe request emitted a receipt'

reset_jira
unsafe_receipt="$repo/unsafe-receipt.json"
unsafe_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$request" --receipt "$unsafe_receipt" --json 2>&1 || true)"
assert_contains "$unsafe_output" 'receipt path must be outside the product repository'
[[ ! -s "$mock_log" ]] || fail 'unsafe receipt path reached Jira'
[[ ! -e "$unsafe_receipt" ]] || fail 'unsafe receipt was created in the product repository'

reset_jira
label_recovery_request="$fixture_root/label-recovery-request.json"
label_recovery_receipt="$fixture_root/label-recovery-receipt.json"
write_request "$label_recovery_request" 'FIX-20-label-recovery-1'
: > "$mock_fail_label_once"
failed_label_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$label_recovery_request" --receipt "$label_recovery_receipt" --json 2>&1 || true)"
assert_contains "$failed_label_output" 'Jira Lifecycle Phase update failed after durable intent was recorded'
[[ ! -e "$label_recovery_receipt" ]] || fail 'failed phase update emitted a success receipt'
[[ "$(jq -r '.fields.status.name' "$mock_state")" == Tester ]] || fail 'failed phase update changed Jira Status'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Testing ]] || fail 'failed phase update changed the Jira label'
[[ "$(jq 'length' "$mock_comments")" == 1 ]] || fail 'failed phase update did not retain exactly 1 intent record'

label_recovery_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$label_recovery_request" --receipt "$label_recovery_receipt" --json)"
assert_contains "$label_recovery_output" '"ok": true'
[[ "$(jq -r '.mode' "$label_recovery_receipt")" == recovered ]] || fail 'retried phase update was not identified as recovered'
[[ "$(jq -r '.fields.status.name' "$mock_state")" == Reviewer ]] || fail 'phase recovery did not finish the Status transition'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Review ]] || fail 'phase recovery did not update the Jira label'

reset_jira
recovery_request="$fixture_root/recovery-request.json"
recovery_receipt="$fixture_root/recovery-receipt.json"
write_request "$recovery_request" 'FIX-20-tester-reviewer-recovery-1'
: > "$mock_fail_once"
failed_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$recovery_request" --receipt "$recovery_receipt" --json 2>&1 || true)"
assert_contains "$failed_output" 'Jira transition failed after durable intent was recorded'
[[ ! -e "$recovery_receipt" ]] || fail 'failed transition emitted a success receipt'
[[ "$(jq -r '.fields.status.name' "$mock_state")" == Tester ]] || fail 'failed transition changed Jira Status'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Review ]] || fail 'phase update did not survive the failed Status transition'
[[ "$(jq 'length' "$mock_comments")" == 1 ]] || fail 'failed transition did not retain exactly 1 intent record'

recovery_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$recovery_request" --receipt "$recovery_receipt" --json)"
assert_contains "$recovery_output" '"ok": true'
[[ "$(jq -r '.mode' "$recovery_receipt")" == recovered ]] || fail 'retried partial mutation was not identified as recovered'
[[ "$(jq -r '.fields.status.name' "$mock_state")" == Reviewer ]] || fail 'recovered transition did not update Jira Status'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Review ]] || fail 'recovered transition lost the Jira phase label'
[[ "$(jq 'length' "$mock_comments")" == 2 ]] || fail 'recovered transition did not retain exactly 1 completion record'
[[ "$(grep -c '^jira workitem transition ' "$mock_log")" == 2 ]] || fail 'recovery did not make exactly 1 failed and 1 successful transition attempt'

reset_jira
completion_recovery_request="$fixture_root/completion-recovery-request.json"
completion_recovery_receipt="$fixture_root/completion-recovery-receipt.json"
write_request "$completion_recovery_request" 'FIX-20-completion-recovery-1'
: > "$mock_fail_completion_once"
failed_completion_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$completion_recovery_request" --receipt "$completion_recovery_receipt" --json 2>&1 || true)"
assert_contains "$failed_completion_output" 'failed to record Jira mutation evidence'
[[ ! -e "$completion_recovery_receipt" ]] || fail 'missing completion record emitted a success receipt'
[[ "$(jq -r '.fields.status.name' "$mock_state")" == Reviewer ]] || fail 'transition did not survive completion-record failure'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Review ]] || fail 'phase update did not survive completion-record failure'
[[ "$(jq 'length' "$mock_comments")" == 1 ]] || fail 'completion-record failure did not retain exactly 1 intent record'

completion_recovery_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$completion_recovery_request" --receipt "$completion_recovery_receipt" --json)"
assert_contains "$completion_recovery_output" '"ok": true'
[[ "$(jq -r '.mode' "$completion_recovery_receipt")" == recovered ]] || fail 'completion-record retry was not identified as recovered'
[[ "$(grep -c '^jira workitem transition ' "$mock_log")" == 1 ]] || fail 'completion-record recovery repeated the Jira transition'
[[ "$(grep -c '^jira workitem edit ' "$mock_log")" == 1 ]] || fail 'completion-record recovery repeated the Jira phase update'
[[ "$(jq 'length' "$mock_comments")" == 2 ]] || fail 'completion-record recovery did not retain exactly 1 completion record'

reset_jira
phase_only_request="$fixture_root/phase-only-request.json"
phase_only_receipt="$fixture_root/phase-only-receipt.json"
write_request "$phase_only_request" 'FIX-20-phase-only-1'
jq '.transition.to = "Tester" | .["lifecycle-phase"].to = "Needs Information" | .transition.reason = "Testing needs a product decision." | .transition["next-action"] = "Wait for the decision through the Orchestrator."' \
  "$phase_only_request" > "$phase_only_request.next"
mv -- "$phase_only_request.next" "$phase_only_request"
phase_only_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$phase_only_request" --receipt "$phase_only_receipt" --json)"
assert_contains "$phase_only_output" '"ok": true'
[[ "$(jq -r '.fields.status.name' "$mock_state")" == Tester ]] || fail 'phase-only mutation changed Jira Status'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Needs-Information ]] || fail 'phase-only mutation did not use the canonical hyphenated label'
if grep -q '^jira workitem transition ' "$mock_log"; then
  fail 'phase-only mutation called the Jira Status transition command'
fi
[[ "$(grep -c '^jira workitem edit ' "$mock_log")" == 1 ]] || fail 'phase-only mutation did not make exactly 1 Jira label edit'

reset_jira
bootstrap_request="$fixture_root/bootstrap-request.json"
bootstrap_receipt="$fixture_root/bootstrap-receipt.json"
write_request "$bootstrap_request" 'FIX-20-bootstrap-phase-1'
jq '.fields.labels = []' "$mock_state" > "$mock_state.next"
mv -- "$mock_state.next" "$mock_state"
jq '.["lifecycle-phase"].from = null' "$bootstrap_request" > "$bootstrap_request.next"
mv -- "$bootstrap_request.next" "$bootstrap_request"
bootstrap_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$bootstrap_request" --receipt "$bootstrap_receipt" --json)"
assert_contains "$bootstrap_output" '"ok": true'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state")" == Review ]] || fail 'bootstrap mutation did not initialize the Jira phase label'

reset_jira
no_op_request="$fixture_root/no-op-request.json"
write_request "$no_op_request" 'FIX-20-no-op-1'
jq '.transition.to = "Tester" | .["lifecycle-phase"].to = "Testing"' "$no_op_request" > "$no_op_request.next"
mv -- "$no_op_request.next" "$no_op_request"
no_op_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$no_op_request" --receipt "$fixture_root/no-op-receipt.json" --json 2>&1 || true)"
assert_contains "$no_op_output" 'Status or Lifecycle Phase must change'
[[ ! -s "$mock_log" ]] || fail 'no-op request reached Jira'

reset_feature_closure_jira
closure_request="$fixture_root/closure-request.json"
write_feature_closure_request "$closure_request" 'FIX-20-feature-closure-1'
open_subfeature_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$closure_request" --receipt "$fixture_root/open-subfeature-receipt.json" --json 2>&1 || true)"
assert_contains "$open_subfeature_output" 'cannot close Feature while linked Subfeature FIX-21 is not Done'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'invalid Feature closure recorded Jira intent'

jq '.fields.status.name = "Done" | .fields.labels = ["Complete"] | .fields.issuelinks[1].inwardIssue.fields.status.name = "Done"' \
  "$mock_state_dir/FIX-21.json" > "$mock_state_dir/FIX-21.json.next"
mv -- "$mock_state_dir/FIX-21.json.next" "$mock_state_dir/FIX-21.json"
jq '.fields.issuelinks[1].inwardIssue.fields.status.name = "Done"' \
  "$mock_state_dir/FIX-20.json" > "$mock_state_dir/FIX-20.json.next"
mv -- "$mock_state_dir/FIX-20.json.next" "$mock_state_dir/FIX-20.json"
open_bug_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$closure_request" --receipt "$fixture_root/open-bug-receipt.json" --json 2>&1 || true)"
assert_contains "$open_bug_output" 'cannot close Feature while linked Bug FIX-22 is not Done'
[[ "$(jq 'length' "$mock_comments")" == 0 ]] || fail 'invalid descendant Bug closure recorded Jira intent'

jq '.fields.status.name = "Done" | .fields.labels = ["Complete"]' "$mock_state_dir/FIX-22.json" > "$mock_state_dir/FIX-22.json.next"
mv -- "$mock_state_dir/FIX-22.json.next" "$mock_state_dir/FIX-22.json"
jq '.fields.issuelinks[0].outwardIssue.fields.status.name = "Done"' \
  "$mock_state_dir/FIX-21.json" > "$mock_state_dir/FIX-21.json.next"
mv -- "$mock_state_dir/FIX-21.json.next" "$mock_state_dir/FIX-21.json"
closure_receipt="$fixture_root/closure-receipt.json"
closure_output="$(env "${mutation_env[@]}" "$ROOT/scripts/jira-mutate.sh" --repo "$repo" --request "$closure_request" --receipt "$closure_receipt" --json)"
assert_contains "$closure_output" '"ok": true'
[[ "$(jq -r '.fields.status.name' "$mock_state_dir/FIX-20.json")" == Done ]] || fail 'valid Feature closure did not transition to Done'
[[ "$(jq -r '.fields.labels | join(",")' "$mock_state_dir/FIX-20.json")" == Complete ]] || fail 'valid Feature closure did not update the Lifecycle Phase label'
[[ "$(jq -r '.mode' "$closure_receipt")" == applied ]] || fail 'valid Feature closure has the wrong receipt mode'

printf '%s\n' 'jira mutation tests passed'
