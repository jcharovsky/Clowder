---
name: orchestrate-feature
description: Coordinate 1 Clowder Feature through gates, role handoffs, clarification, and durable evidence.
---

# Orchestrate a Feature

Use this skill when a user gives the Orchestrator a Jira request or asks to resume a Feature.

## Steps

1. Resolve the product repository, `.clowder/project.yaml`, Git authorization mode, Jira identity, current branch, worktree, Feature manifest, pull request, and CI state. When an existing branch, worktree, or artifact directory blocks setup, run `scripts/recover-feature.sh` and use its preservation-first actions. Completion means the current durable state, authorization mode, recovery classification, and missing prerequisites are listed with exact paths or links.
2. Select the next valid Lifecycle Phase from the methodology. Completion means no downstream role is dispatched before its prerequisites and every blocked prerequisite has an owner.
3. Read `CONTEXT.md` and `JIRA_RULES.md`, then validate every active card. Completion means each card has an allowed work type, direct Stage Parent, valid linked `Child` parent and direction, at most 1 linked parent, exactly 1 canonical Lifecycle Phase label, canonical Status, exactly 1 Active Owner when its Status is a player Status, and no Feature-level Bug. `To Do` is the unowned queue and `Done` is terminal.
4. Run `scripts/check-feature.sh` for the relevant gate. Completion means the command result is retained and any failure has a concrete remediation.
5. Dispatch exactly the role that owns the Lifecycle Phase. Keep exactly 1 player role active, including during Review and Testing. Include primary sources, expected outputs, gate, risk, Git authorization mode, and the task-based model and reasoning choice. Completion means the role has a bounded work package, the previous player's accepted thread is closed, and no specialist work is performed in the Orchestrator thread.
6. Execute every Jira card creation, summary or description edit, linked `Child` relationship change, Lifecycle Phase change, and Status handoff through Clowder `scripts/jira-mutate.sh`, with request and receipt paths outside the product repository. The responsible role must supply expected source and target state, reason, evidence, and next action. Completion means the adapter has reread Jira, verified exactly 1 durable intent and completion record, emitted a successful receipt, and left no invalid metadata, label, ownership, relationship, Status, or handoff.
7. Route `CLARIFICATION_REQUIRED` through HITL. Completion means the answer is recorded in the owning durable artifact and the role resumes with superseded outputs marked stale.
8. Re-read primary sources and validate the completion record. Completion means the receiving Lifecycle Phase accepts evidence from current files, Git, CI, Jira, or the pull request rather than trusting a summary.
9. For a successful Ready for Merge gate, use `--receipt` with a temporary path outside the product repository. Publish the exact receipt as a pull-request comment, re-read the comment through GitHub, and retain its URL for closure. Completion means the durable comment matches the receipt and exists before merge. A failed gate produces and publishes no receipt.
10. Stop at human gates. Completion means the Orchestrator presents a concrete reviewable decision and waits for HITL where approval is required.

## Routing

Use a deterministic script when semantic judgment is unnecessary. Use Luna for narrow, reversible work, Terra for routine multi-step work, Sol for ambiguity or consequential review, and Astra only after explicit escalation approval.

Run `scripts/route-task.sh` and include its result in the dispatch record. A route is a heuristic, not evidence that a missing product decision has been resolved.

## Handoff

Require `STATUS`, `SOURCES`, `OUTPUTS`, `EVIDENCE`, `DECISIONS`, `ASSUMPTIONS`, `RISKS`, `QUESTIONS`, and `NEXT_GATE`. A transcript never replaces a primary artifact.
