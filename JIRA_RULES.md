# Clowder Jira Rules

This is the authoritative Jira contract for every Clowder agent. Read it before creating, editing, linking, transitioning, or closing a Jira card. The Orchestrator validates it at every handoff.

## Card Types

Clowder uses exactly 5 Jira work types:

- **Stage.** The native Parent scope for all cards in 1 planning scope.
- **Epic.** A group of related Features inside a Stage.
- **Feature.** An independently shippable product outcome with 1 PRD, 1 Technical Design, 1 Test Plan, 1 branch, 1 worktree, and 1 pull request.
- **Subfeature.** A bounded technical or product part of a Feature. It shares the Feature branch, worktree, and pull request.
- **Bug.** A defect attached to exactly 1 Subfeature.

Clowder does not use Task, Story, Sub-task, or any smaller tracked work type. Acceptance criteria, checklists, and implementation steps remain content inside a card.

## 2 Relationships

Each Epic, Feature, Subfeature, and Bug has the native Stage Parent. Applicable cards also have the linked decomposition relationship below.

### Native Stage Parent

Set Jira's native **Parent** field directly on every Epic, Feature, Subfeature, and Bug. All 4 cards reference the same Stage. This relationship is not hereditary.

```text
Stage
├── Epic
├── Feature
├── Subfeature
└── Bug
```

### Linked Decomposition Parent

Use the custom linked-work-item relation named **Child**, with reciprocal labels `is parent of` and `is child of`.

```text
Epic
└── Feature
    └── Subfeature
        └── Bug
```

The linked hierarchy has 1 parent maximum per card and any number of children:

- An Epic has no linked decomposition parent.
- A Feature has exactly 1 linked Epic parent.
- A Subfeature has exactly 1 linked Feature parent.
- A Bug has exactly 1 linked Subfeature parent.

In Jira's UI, the relation can be created from either card. From the parent, choose `is parent of` and select the child. From the child, choose `is child of` and select the parent. The resulting relationship must have the parent and child endpoints described above.

For `acli`, the tested creation form is `--out PARENT --in CHILD --type Child`. Verify the resulting endpoints after every automated link operation because Jira exposes reciprocal labels and endpoint names separately.

A Feature-level Bug is invalid. If a defect spans multiple Subfeatures, create a dedicated cross-cutting Subfeature under the Feature, then attach the Bug to that Subfeature.

## Card Creation

Every player role can create Jira cards. Creation authority is distributed, but every creation must satisfy the same contract:

- The work type is 1 of the 5 Clowder types.
- The card has its native Stage Parent immediately.
- The card has its required linked decomposition parent, except for Stage and Epic.
- The card receives an initial Status immediately. `To Do` is the unowned queue for newly created cards and unfinished parent cards. Before execution begins, the Orchestrator dispatches the card to a player Status.
- The card receives exactly 1 Lifecycle Phase label immediately. A new intake card uses `Intake`. A card created during established work uses the canonical label for its current phase.
- The card description records the outcome, reason, and source handoff.

Normal creation responsibilities are:

- The Product Manager creates or refines Stages, Epics, and Features.
- The Architect creates technical Subfeatures under Features.
- The Developer, Tester, or Reviewer creates Bugs under Subfeatures when a defect is discovered.
- Any role may create another valid card when the current work requires it, subject to the same parent, Status, and handoff checks.

Every card creation uses the `create` operation of `scripts/jira-mutate.sh`. The adapter creates the card in `To Do`, applies exactly 1 Lifecycle Phase label, sets the native Stage Parent when required, creates the linked parent when required, and verifies the resulting hierarchy before returning the new card key.

## Status and Handoffs

The connected Jira workflow has exactly these Status values. The board is configured in Jira with 7 same-named columns in the same order:

```text
To Do | Product Manager | Architect | Developer | Tester | Reviewer | Done
```

Jira Status is canonical. A column is only its UI projection. Clowder reads and changes Status, which causes Jira to move the card to the mapped column. Clowder does not operate on columns directly. The 5 player Statuses each name 1 Active Owner. `To Do` is an unowned queue, and `Done` is terminal with no Active Owner.

Jira owns the column mapping, Status definitions, and Status Categories. Jira configuration maps `To Do → To Do`, each player Status → `In Progress`, and `Done → Done`. Clowder enforces the canonical Status names during work. It does not inspect, recreate, or change columns or Status Categories.

- The current Active Owner may transition the card to a valid receiving role.
- The current Active Owner records the handoff reason, evidence, and next action.
- A Reviewer returning work to development transitions `Reviewer → Developer` and records the findings.
- A queued card is dispatched by the Orchestrator to its first player. A receiving role does not self-claim a player-owned card before the handoff is recorded.
- Exactly 1 player role owns and executes a child card at a time. Tester completes and hands off before Reviewer begins on the same card.
- The Orchestrator validates the transition, starts or resumes the receiving role, and rejects invalid ownership or relationship changes.
- The Orchestrator is never an Active Owner and never appears as a Jira Status.
- HITL communicates through the Orchestrator and never owns or directly edits a card.
- The Product Manager may close a completed parent Feature directly from `To Do` to `Done` after verifying all linked children are `Done`, the pull request is merged, and every Feature gate passed. This closure authority does not make the Product Manager an Active Owner and does not introduce an intermediate player Status.

## Lifecycle Phase Labels

Clowder stores Lifecycle Phase in Jira's native **Labels** field. It does not use a custom Lifecycle Phase field. Every Clowder card has exactly 1 label, and no Jira label is used for another purpose.

| Lifecycle Phase | Jira label |
| --- | --- |
| Intake. | `Intake`. |
| Discovery. | `Discovery`. |
| Feature Definition. | `Feature-Definition`. |
| PRD. | `PRD`. |
| Design. | `Design`. |
| Test Planning. | `Test-Planning`. |
| Ready for Development. | `Ready-for-Development`. |
| Orchestration. | `Orchestration`. |
| Development. | `Development`. |
| Developer Verification. | `Developer-Verification`. |
| Testing. | `Testing`. |
| Review. | `Review`. |
| Remediation. | `Remediation`. |
| Ready for Merge. | `Ready-for-Merge`. |
| Production. | `Production`. |
| Complete. | `Complete`. |
| Needs Information. | `Needs-Information`. |
| Rejected. | `Rejected`. |

Jira labels cannot contain spaces, so multiword phase names use hyphens. Phase labels preserve the capitalization shown above. A missing label is valid only as the declared source of a 1-time bootstrap mutation. An unknown label or more than 1 label makes the card invalid.

Lifecycle Phase and Status are independent. A role may advance Lifecycle Phase without changing Status. A Status handoff may also change Lifecycle Phase. A phase-only mutation on a player-owned card is authorized by that player. For an unowned `To Do` card, the Orchestrator records an accepted role outcome without becoming the Active Owner.

## Deterministic Jira State Mutation

Every Jira card creation, summary or description edit, linked `Child` relationship change, Lifecycle Phase change, and Status transition uses `scripts/jira-mutate.sh`. Direct ACLI create, edit, link, and transition calls are invalid Clowder mutations, except explicit cleanup of disposable integration-test cards.

The schema-version `1` request supports 4 operations:

- `create` creates any allowed work type in `To Do`, applies its initial Lifecycle Phase, native Stage Parent, and linked parent, then returns the Jira key.
- `edit` compares and replaces the card summary and plain-text description while preserving a creation recovery marker managed by Clowder.
- `relationship` compares and replaces the linked `Child` parent. The final hierarchy must satisfy the work-type contract.
- `transition` compares and changes Lifecycle Phase, Status, or both. A phase-only request uses the same source and target Status.

Every request carries a stable mutation ID, actor, exact expected state, reason, evidence, and next action. Request and receipt paths remain outside the product repository, and each receipt path is new. The adapter validates hierarchy, ownership, Lifecycle Phase, and operation-specific source state before recording intent. It performs the minimum Jira calls, rereads the card, verifies the target state and durable completion comment, then emits a receipt with `applied`, `recovered`, or `replayed` mode.

Creation embeds a request-digest-bound recovery marker in the Jira description. An ignored recovery journal under `.clowder/runtime/jira-creation/`, keyed by mutation ID, retains the created Jira key and prevents an ambiguous failed create call from being repeated before Jira search indexing completes. Linked-parent replacement deletes the verified source link before creating the verified target link. A retry safely resumes from the temporary no-parent state. Summary and description edits accept only the declared source or target value during recovery.

Retries with the same mutation ID and request digest are safe. Reusing a mutation ID with different content, stale source state, unauthorized actor, hierarchy defect, or ambiguous partial state is rejected. A failed or ambiguous operation creates no success receipt.

For direct Feature closure, the wrapper also rereads every linked Subfeature and Bug. It verifies Status `Done`, Lifecycle Phase `Complete`, the direct Stage Parent, the linked parent, type, direction, and cardinality before recording intent.

**This is a recoverable serial transaction, not an atomic Jira compare-and-swap.** ACLI exposes reads, comments, creates, edits, links, and Status transitions as separate calls. Safety therefore depends on Clowder's exactly 1 Active Owner invariant and exclusive use of this adapter.

## Role Authority

| Role | Jira authority |
| --- | --- |
| Product Manager. | Create and refine scope cards, assign Stage Parents, create or correct linked hierarchy, update owned Lifecycle Phases, reconcile product metadata, and close a completed parent Feature directly from `To Do` to `Done`. |
| Architect. | Create and decompose Subfeatures, update owned Lifecycle Phases, correct technical decomposition, and hand cards to implementation. |
| Developer. | Mutate owned card state, create implementation Bugs under Subfeatures, and hand work to Tester. |
| Tester. | Mutate owned card state, create reproducible Bugs under Subfeatures, and hand verified results to Developer or Reviewer. |
| Reviewer. | Mutate owned card state, create review Bugs under Subfeatures, and return remediation to Developer. |
| Orchestrator. | Validate card types, native Parents, linked-parent cardinality, Status ownership, Lifecycle Phase, handoffs, and gate readiness. It may perform an administrative repair, but never owns a card. |

## Enforcement Checklist

Before accepting a Jira mutation or handoff, the Orchestrator verifies:

- The card type is allowed.
- The native Parent is the current Stage.
- The linked parent matches the card type.
- The card has no second linked parent.
- A Bug is linked to a Subfeature, never directly to a Feature.
- A player Status identifies exactly 1 Active Owner. `To Do` and `Done` have no Active Owner.
- The Labels field contains exactly 1 canonical Lifecycle Phase label and nothing else.
- The transition is allowed from the current Status.
- The handoff contains evidence and a receiving action.
- Every Jira creation, metadata edit, relationship change, Lifecycle Phase change, or Status transition has a successful `jira-mutate.sh` receipt whose mutation ID and request digest match the durable Jira records.
- Parent cards remain open until their linked child work is complete and the Feature gates pass.
