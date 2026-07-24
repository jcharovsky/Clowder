# Development Workflow

Clowder delivers 1 independently shippable Feature through durable artifacts and explicit gates.

## Lifecycle

1. Product Manager validates the Jira request, provenance, urgency, and duplicates.
2. Product Manager creates or refines 1 independently shippable Feature.
3. Product Manager authors `PRD.md`, then waits for HITL approval.
4. Architect authors `TECHNICAL_DESIGN.md` and qualifying ADRs.
5. Tester authors `TEST_PLAN.md` with acceptance traceability.
6. Orchestrator validates the Ready for Development gate.
7. Developer creates a vertical slice in the Feature worktree with tests.
8. Developer runs local checks and prepares evidence.
9. Tester independently verifies the reviewed code head and hands the card to Reviewer only after Testing completes.
10. Reviewer inspects the same reviewed code head after accepting the handoff.
11. Developer remediates accepted findings and refreshes evidence.
12. HITL approves the reviewed code head and the exact attestation changes prepared for the pull request. The approval records a deterministic attestation revision over the final pull-request body, independent evidence, and non-self-referential manifest state.
13. Orchestrator passes the Ready for Merge gate with `--receipt` targeting a temporary path outside the product repository. It publishes the exact JSON receipt as a pull-request comment and verifies the durable comment before recommending merge.
14. HITL merges through the approved pull request.
15. Product Manager verifies the published receipt, merge, final CI, and linked children, then records closure evidence and transitions the parent Feature directly from `To Do` to `Done` without an intermediate player Status.

If Feature setup encounters an existing branch, worktree, or artifact directory, the Orchestrator runs `scripts/recover-feature.sh` before retrying. The command is read-only. It classifies the durable state and prints exact preservation-first actions. Completed or stale worktrees are removed only after their branch, commits, and artifacts are recoverable.

## Mapping

Every Feature maps to 1 Jira card, Feature directory, PRD, Technical Design, Test Plan, branch, worktree, and pull request. Changes to approved inputs invalidate affected downstream evidence.

Jira Status is the canonical player or queue assignment. A board column is only Jira's UI projection of that Status, so changing the Status moves the card to its corresponding column. Clowder does not operate on columns or Status Categories. `To Do` is an unowned queue and `Done` is terminal. The 5 player Statuses each identify exactly 1 Active Owner. Lifecycle Phase records Clowder process progression as the card's sole Jira label. Multiword phases use hyphens. Lifecycle Phase may advance without a Status change, and a handoff may update both dimensions.

Jira uses exactly 5 Clowder work types: Stage, Epic, Feature, Subfeature, and Bug. Clowder does not use Task, Story, Sub-task, or any smaller tracked work type. A Stage is the native Parent scope. An Epic groups Features. A Feature is independently shippable. Subfeatures and Bugs are serial child execution cards that share the Feature branch, worktree, and pull request.

Every Epic, Feature, Subfeature, and Bug has the same Stage in Jira's native Parent field. This Parent relationship is direct and is not inherited. Linked Work Items use the custom `Child` relation, with a maximum of 1 linked parent per card, to express `Epic → Feature → Subfeature → Bug`. A Bug is always linked to a Subfeature, never directly to a Feature.

All player roles may create valid cards and mutate cards they own. Every card creation, summary or description edit, linked `Child` relationship change, Lifecycle Phase change, and Status transition uses `jira-mutate.sh`. The adapter validates card type, Stage Parent, linked-parent cardinality, Bug placement, Status, Lifecycle Phase, actor authority, and exact source state before it records durable intent. It performs the minimum Jira calls, rereads the target state, and emits a successful receipt. `To Do` cards are dispatched from the queue to a first player. For player-owned cards, the current Jira Status identifies the single Active Owner. Only 1 player role executes a child card at a time. The parent Feature remains in `To Do` until every linked child Subfeature and Bug is complete and the Feature gates pass.

The Jira adapter is idempotent and recoverable across card creation, metadata edit, linked-parent replacement, label edit, and Status transition failure boundaries. It is not atomic at the Jira API layer because ACLI exposes separate read, comment, create, edit, link, and transition calls. Exactly 1 Active Owner and exclusive use of the adapter are required safety invariants.

## Gates

Use `scripts/check-feature.sh --gate ready-for-development`, `ready-for-review`, and `ready-for-merge`. Review, testing, and merge approvals reference the same reviewed code head. Commits after that head may change only `feature.yaml`, `PULL_REQUEST.md`, `evidence/reviewer.md`, and `evidence/tester.md`. The final pull-request head must pass required CI. Any other later change invalidates the merge gate. The Ready for Merge gate applies `github.review-evidence`. Schema-version `1` projects default to `clowder-attestation`, while `github-approval` adds an authenticated GitHub approval requirement. Its optional `--receipt PATH` output is created only after success, must be outside the product repository, and must be published unchanged as a pull-request comment before merge.

Onboarding configures `.clowder/hooks/pre-push` as the repository hooks path. The guard rejects direct updates and deletions of the configured base branch from that clone. HITL merges through GitHub only after the Ready for Merge gate passes. This local control is bypassable and does not claim server enforcement.

## Human decisions

HITL decides product behavior, qualifying ADRs, residual risk, pull requests, merge, deployment, and destructive actions. At session start, HITL selects 1 Git authorization mode when no mode has already been supplied. Every role follows that mode for the current repository and session. YOLO mode does not change that authority.
