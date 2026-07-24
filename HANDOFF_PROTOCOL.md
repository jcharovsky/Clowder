# Handoff Protocol

Roles communicate through the Orchestrator. A role may request human input only when the answer can materially change product behavior, architecture, risk, scope, or acceptance.

## Clarification

```text
CLARIFICATION_REQUIRED

Decision:
Why it matters:
Known facts:
Options and trade-offs:
Recommendation:
Safe default, if any:
Blocked artifacts or Lifecycle Phases:
```

The Orchestrator verifies that the answer is not already authoritative, deduplicates equivalent questions, asks HITL, records the answer in the owning artifact, and resumes the same role thread. Outputs based on a superseded assumption become stale.

## Completion record

```text
STATUS: completed | clarification-required | blocked | failed
SOURCES: exact artifact paths, links, versions, and Git revisions
OUTPUTS: created or changed artifacts
EVIDENCE: checks, observations, and retained evidence
DECISIONS: decisions made within delegated authority
ASSUMPTIONS: assumptions that remain relevant
RISKS: unresolved or newly discovered risks
QUESTIONS: decisions required from another role or HITL
NEXT_GATE: recommended next Lifecycle Phase and unmet prerequisites
```

The receiving role rereads the primary sources. A summary never replaces primary evidence.

## Jira Handoff

When a handoff creates, links, or transitions a Jira card, include these fields in `EVIDENCE` or `OUTPUTS`:

- Card key, work type, current Status, current Lifecycle Phase, exact phase label, and Active Owner.
- Direct native Stage Parent key.
- Linked `Child` parent key and verified direction, when the card is not a Stage or Epic.
- Source owner, receiving role, reason, evidence, expected next Status, and expected next Lifecycle Phase.
- Any card created, link created, link removed, Lifecycle Phase change, or Status transition performed.
- The `jira-mutate.sh` receipt path, mutation ID, request digest, mode, and successful result for every card creation, metadata edit, relationship change, Lifecycle Phase change, or Status transition.
- For Feature closure, the verified Ready for Merge receipt comment URL and its exact final pull-request head.

The responsible role authorizes the mutation through a schema-version `1` Jira mutation request. The request declares the exact operation-specific source and target state. For an unowned `To Do` card, the Orchestrator validates the acting role and accepted outcome. The Orchestrator accepts the mutation or handoff only after `scripts/jira-mutate.sh` verifies current state, performs or safely replays the operation, verifies its durable Jira completion comment, and emits a successful receipt. A missing, reversed, duplicate, invalid, stale, or conflicting relationship or mutation leaves the handoff rejected until corrected.
