# Clowder Architecture

**Status:** Authoritative current-state architecture for Clowder `0.1.0`.

Clowder is a local development methodology and thin Codex orchestration layer. It coordinates 1 Product Manager, Architect, Developer, Tester, and Reviewer around 1 independently shippable Feature at a time. Jira, Git, GitHub, CI, and versioned Feature artifacts remain the durable sources of truth.

This document explains the finished system. Historical plans, pilots, and audits are not architectural authorities.

## 1. Scope and Boundaries

Clowder provides:

- A gated development methodology from Jira intake through merge and closure.
- Native Codex role definitions, 3 Clowder-specific skills, and 16 bundled upstream skills.
- Deterministic scripts for onboarding, setup, validation, Jira mutation, approvals, recovery, and pull-request preparation.
- Versioned templates and schemas for project configuration, Feature artifacts, handoffs, Jira mutations, and merge receipts.
- Supacode integration for the visible Orchestrator terminal and Feature worktrees.
- Task-based model and reasoning routing.

Clowder does not provide:

- A custom agent runtime or an OpenAI Agents SDK service.
- A persistent orchestration database.
- Parallel player execution on the same work item.
- Automatic product decisions, merges, deployments, or production mutations.
- Operating-system isolation between roles.
- Server-enforced GitHub branch protection.

## 2. System Topology

Clowder uses a native hub-and-spoke runtime:

```text
HITL
  │ decisions and approvals
  ▼
Codex Orchestrator
  ├── Product Manager
  ├── Architect
  ├── Developer
  ├── Tester
  └── Reviewer
        │
        ▼
Deterministic Clowder Scripts
        │
        ├── Jira and ACLI
        ├── Git and Feature Worktrees
        ├── GitHub and CI
        └── Supacode
```

The **HITL** communicates with specialist roles through the **Orchestrator**. A specialist returns a clarification request to the Orchestrator. The Orchestrator deduplicates the question, asks HITL, records the answer in the owning artifact, and resumes the same role.

The **Orchestrator** coordinates the workflow, validates contracts, selects the next role, chooses a task route, and enforces gates. It never owns a Jira card and does not perform specialist work.

The **5 player roles** own semantic work and Jira cards during their stages. Exactly 1 player is active at a time. Tester completes before Reviewer begins. Remediation returns ownership to Developer, then affected Testing and Review repeat serially.

**Deterministic scripts** perform work whose outcome is objectively checkable. Scripts never become Jira owners and never replace semantic approval.

**Supacode** provides repository, worktree, terminal, and tab management. Supacode tabs and agent transcripts are coordination surfaces, not durable records.

## 3. Core Invariants

Clowder enforces these invariants:

- Each Orchestrator session manages at most 1 active Feature.
- Exactly 1 player owns and executes a child card at a time.
- An idle or retained agent thread does not authorize concurrent work.
- The Orchestrator closes an accepted role thread before dispatching the next player.
- Each independently shippable Feature maps to 1 Jira Feature, Feature directory, PRD, Technical Design, Test Plan, branch, active worktree, and pull request.
- Subfeatures and Bugs share their Feature branch, worktree, artifacts, and pull request.
- Every Jira card has exactly 1 canonical Status and exactly 1 canonical Lifecycle Phase label.
- Every Epic, Feature, Subfeature, and Bug has the same direct native Stage Parent.
- Every linked card has at most 1 decomposition parent.
- A Bug is linked to a Subfeature, never directly to a Feature.
- Every supported Jira write passes through the recoverable Jira mutation adapter.
- Downstream work never begins before its gate passes.
- A changed approved input invalidates every dependent approval and evidence record.
- Chat, summaries, and memory never replace primary evidence.

## 4. Canonical Development Unit

The independently shippable unit is the **Feature**.

Each Feature owns:

- 1 Jira Feature card.
- 1 Feature directory.
- 1 `PRD.md`.
- 1 `TECHNICAL_DESIGN.md`.
- 1 `TEST_PLAN.md`.
- 1 `feature.yaml` manifest.
- 1 Feature branch.
- 1 active worktree.
- 1 pull request.

A broad request can produce several Features. A duplicate, obsolete, rejected, or already-delivered request can produce 0 Features. A Subfeature that needs its own release boundary, worktree, branch, or pull request becomes a separate Feature.

The worktree is allocated after the Feature identity is stable and before Feature artifacts are authored. Product code remains blocked until the Ready for Development gate passes.

## 5. Jira Domain Model

Clowder uses exactly 5 Jira work types:

```text
Native Stage Parent

Stage
├── Epic
├── Feature
├── Subfeature
└── Bug

Linked Child Decomposition

Epic
└── Feature
    └── Subfeature
        └── Bug
```

The native **Parent** field assigns every Epic, Feature, Subfeature, and Bug directly to the same Stage. Stage membership is never inherited through linked work items.

The custom linked-work-item relation named **Child** represents logical decomposition. Its reciprocal labels are `is parent of` and `is child of`. A parent may have several children, while each linked child has at most 1 parent.

Clowder does not create Task, Story, Sub-task, or smaller work types. Acceptance criteria, checklists, and implementation steps remain content inside a card.

### 5.1 Status and Ownership

The connected Jira workflow has 7 canonical Status values and 7 same-named board columns:

```text
To Do | Product Manager | Architect | Developer | Tester | Reviewer | Done
```

Jira Status is canonical. The board column is its user-interface projection.

- `To Do` is the unowned queue and holds unfinished parent Features.
- The 5 player Statuses identify the single Active Owner.
- `Done` is terminal and unowned.
- The Orchestrator and HITL never appear as Status values.

Jira maps `To Do` to the `To Do` Status Category, the 5 player Statuses to `In Progress`, and `Done` to `Done`. Clowder operates on Status and does not inspect or mutate board columns or Status Categories.

The Product Manager may close a completed parent Feature directly from `To Do` to `Done`. Closure requires a merged pull request, passed Feature gates, a verified Ready for Merge receipt comment, and every linked Subfeature and Bug at Status `Done` with Lifecycle Phase `Complete`.

### 5.2 Lifecycle Phase

Lifecycle Phase records process progression independently from Status. It is stored as the card's sole Jira label.

| Lifecycle Phase | Jira Label | Primary Authority |
| --- | --- | --- |
| Intake. | `Intake`. | Product Manager. |
| Discovery. | `Discovery`. | Product Manager. |
| Feature Definition. | `Feature-Definition`. | Product Manager. |
| PRD. | `PRD`. | Product Manager. |
| Design. | `Design`. | Architect. |
| Test Planning. | `Test-Planning`. | Tester. |
| Ready for Development. | `Ready-for-Development`. | Orchestrator gate. |
| Orchestration. | `Orchestration`. | Orchestrator coordination. |
| Development. | `Development`. | Developer. |
| Developer Verification. | `Developer-Verification`. | Developer. |
| Testing. | `Testing`. | Tester. |
| Review. | `Review`. | Reviewer. |
| Remediation. | `Remediation`. | Developer. |
| Ready for Merge. | `Ready-for-Merge`. | Orchestrator gate. |
| Production. | `Production`. | HITL with Product Manager coordination. |
| Complete. | `Complete`. | Product Manager. |
| Needs Information. | `Needs-Information`. | Current player or Orchestrator for an unowned card. |
| Rejected. | `Rejected`. | Product Manager with HITL when consequential. |

Multiword labels use hyphens because Jira labels cannot contain spaces. Clowder reserves the complete Labels field for Lifecycle Phase and rejects missing, unknown, or multiple labels outside an explicit bootstrap mutation.

Status and Lifecycle Phase are independent. A role may advance Lifecycle Phase without changing ownership, while a handoff may change both. `Blocked` is a reasoned condition attached to the current state, not another terminal Status or Lifecycle Phase.

## 6. Roles and Authority

| Role | Owns | Does Not Own |
| --- | --- | --- |
| Product Manager. | Intake, discovery, product intent, Stage and Epic organization, Feature definition, PRD, dependencies, Jira hierarchy intent, and closure. | Technical architecture, implementation approval, merge, or deployment. |
| Architect. | Technical Design, interfaces, state, failure behavior, security design, test seams, Subfeature decomposition, and qualifying ADRs. | Product acceptance, code approval, merge, or deployment. |
| Developer. | Feature implementation, developer-owned tests, local checks, implementation evidence, and remediation. | Self-approval, independent Testing, independent Review, merge, or deployment. |
| Tester. | Test planning, independent behavior verification, failure and recovery checks, manual and browser checks, and reproducible defect evidence. | Product code changes, silent remediation, merge, or deployment. |
| Reviewer. | Independent Spec and Standards review, architecture conformance, security, privacy, data behavior, maintainability, and test sufficiency. | Product code changes, silent remediation, merge, or deployment. |
| Orchestrator. | Contract enforcement, task routing, gate validation, role dispatch, clarification routing, and handoff coordination. | Jira ownership, product intent, architecture, implementation, review approval, merge, or deployment. |
| HITL. | Product scope, consequential architecture decisions, residual risk, pull requests, merge, deployment, destructive actions, and Git authorization mode. | Jira card ownership or direct specialist execution. |

Every player may create a valid Jira card when its work requires one. Product Manager normally creates Stage, Epic, and Feature cards. Architect normally creates Subfeatures. Developer, Tester, and Reviewer normally create Bugs under Subfeatures.

Only Developer writes product code. Product Manager and Architect may write their assigned Feature artifacts. Tester and Reviewer may write only their assigned evidence. Every Git action remains subject to the current session's authorization mode.

HITL gives direction and approvals through the Orchestrator. HITL never becomes the Active Owner and does not directly mutate a Clowder Jira card.

## 7. Runtime Execution

### 7.1 Installation and Onboarding

`scripts/install.sh` installs pinned Node.js dependencies, 5 role definitions, 3 native Clowder skills, and 16 bundled upstream skills into a selected Codex home. It can copy or link native role and skill files. Integrity-locked upstream skills are copied. A conflicting installed upstream skill requires explicit replacement through `--force`. The installer prints the reviewed `Clowder` alias instead of editing shell configuration.

`scripts/onboard.sh` prepares a consumer repository without overwriting existing product files. It creates the project configuration, ignored runtime directory, Feature and ADR directories, product instructions, pull-request template, and local pre-push guard. It configures the clone's Git hooks path and base branch. It never commits, pushes, changes Jira, or changes GitHub.

`scripts/doctor.sh` validates the consumer configuration, schemas, required files, installed roles and skills, bundled and installed upstream skill integrity, tool availability, Supacode, Codex, Jira, GitHub, CI check names, configured quality commands, and local branch guard. Offline mode converts unavailable live integration checks into warnings.

### 7.2 Launch

The `Clowder` alias invokes `scripts/clowder` from an onboarded repository or managed worktree.

The launcher:

1. Resolves the target Git repository.
2. Runs the Clowder doctor.
3. Focuses the deterministic Supacode Orchestrator tab when it exists.
4. Creates that tab when it does not exist.
5. Starts `scripts/clowder-orchestrator` in the selected repository.

Direct mode starts Codex without Supacode. No-UI mode prints the reviewed Codex command without starting a session.

The Orchestrator starts with the project-configured model and reasoning effort, which default to `gpt-5.6-luna` and `xhigh`. It grants Codex the product repository as its working directory and Clowder as an additional readable and writable directory.

### 7.3 Native Agent Runtime

Clowder uses Codex native custom agents. No specialist is permanently running. The Orchestrator spawns the required role for the current phase, resumes the same thread after clarification, accepts its completion record, then closes it before the next player begins.

The Codex configuration permits 2 concurrent threads for clarification and orderly closure. This capacity does not permit 2 active players.

## 8. Development Lifecycle

The canonical lifecycle is:

1. **Intake:** Product Manager validates provenance, urgency, duplicates, and the desired outcome.
2. **Discovery:** Product Manager resolves product ambiguity and collects evidence, with Architect support when needed.
3. **Feature Definition:** Product Manager establishes the independently shippable boundary and stable identity.
4. **PRD:** Product Manager writes observable behavior and waits for HITL approval of the exact revision.
5. **Design:** Architect writes the Technical Design and qualifying ADRs.
6. **Test Planning:** Tester writes acceptance-traceable verification scope.
7. **Ready for Development:** Orchestrator validates artifacts, approvals, dependencies, mapping, tools, and environment.
8. **Orchestration:** Orchestrator chooses the next executable card, route, and player.
9. **Development:** Developer implements vertical slices and developer-owned tests.
10. **Developer Verification:** Developer runs applicable checks, inspects the diff, and prepares evidence.
11. **Testing:** Tester independently verifies the reviewed code head.
12. **Review:** Reviewer evaluates Spec and Standards sequentially on the same reviewed code head.
13. **Remediation:** Developer fixes accepted findings, then affected Testing and Review repeat.
14. **Ready for Merge:** Orchestrator verifies final-head CI, approvals, allowed attestation changes, findings, documentation, and rollback expectations.
15. **Production:** HITL merges and controls any deployment or production action.
16. **Complete:** Product Manager verifies closure evidence and moves the parent Feature directly to `Done`.

`Needs Information` pauses progression without transferring ownership to HITL. `Rejected` records a durable terminal product decision.

## 9. Durable Artifacts and Sources of Truth

| Concern | Durable Authority |
| --- | --- |
| Work identity, hierarchy, ownership, and Lifecycle Phase. | Jira plus `JIRA_RULES.md`. |
| Product behavior and acceptance outcomes. | Approved `PRD.md`. |
| Feature-level technical structure. | Approved `TECHNICAL_DESIGN.md`. |
| Long-lived consequential decisions. | Versioned ADRs. |
| Verification scope. | `TEST_PLAN.md`. |
| Feature identity, paths, revisions, and approvals. | `feature.yaml`. |
| Implementation. | Git branch and commits. |
| Developer, Tester, and Reviewer conclusions. | Versioned evidence files. |
| Pull-request intent and evidence summary. | Versioned `PULL_REQUEST.md` and the GitHub pull request. |
| Automated verification. | CI checks on the exact final pull-request head. |
| Ready for Merge. | Schema-version `1` receipt published unchanged as a pull-request comment. |
| Human decisions. | Revision-bound approval records and pull-request decisions. |

The default Feature directory is:

```text
docs/features/JIRA-123-feature-name/
├── JIRA_FEATURE.md
├── PRD.md
├── TECHNICAL_DESIGN.md
├── TEST_PLAN.md
├── PULL_REQUEST.md
├── feature.yaml
└── evidence/
    ├── developer.md
    ├── tester.md
    └── reviewer.md
```

The Feature manifest records identity, Lifecycle Phase, risk, branch, worktree, pull request, base revision, head revision, artifact paths, and revision-bound approvals.

## 10. Clarification and Handoff Protocol

A specialist returns `CLARIFICATION_REQUIRED` when a missing answer can materially change product behavior, architecture, scope, risk, or acceptance.

The request records:

- The decision required.
- Why it matters.
- Known facts.
- Options and trade-offs.
- A recommendation.
- A safe default when one exists.
- Blocked artifacts or phases.

The Orchestrator checks existing authoritative sources before asking HITL. The owning role records the answer in the durable artifact before work resumes. Outputs based on superseded assumptions become stale.

Every role completion record contains exactly these fields:

```text
STATUS
SOURCES
OUTPUTS
EVIDENCE
DECISIONS
ASSUMPTIONS
RISKS
QUESTIONS
NEXT_GATE
```

The receiving role rereads primary sources. A summary never substitutes for source artifacts, Git revisions, Jira state, CI, or pull-request evidence.

## 11. Deterministic Control Plane

| Command | Responsibility |
| --- | --- |
| `scripts/clowder`. | Validate the target and focus or create the Supacode Orchestrator tab. |
| `scripts/clowder-orchestrator`. | Start the primary YOLO Codex session with the current project model and instructions. |
| `scripts/install.sh`. | Install dependencies, custom roles, native skills, and integrity-locked upstream skills. |
| `scripts/onboard.sh`. | Create missing consumer configuration and local safeguards. |
| `scripts/doctor.sh`. | Validate local product configuration and live integration readiness. |
| `scripts/start-feature.sh`. | Create the Feature branch, worktree, and required artifacts without committing or changing external systems. |
| `scripts/recover-feature.sh`. | Classify setup state and print preservation-first recovery actions without mutation. |
| `scripts/check-feature.sh`. | Evaluate named Feature gates, current revisions, scope, checks, approvals, pull-request state, CI, and attestations. |
| `scripts/check-handoff.sh`. | Validate a completion record against the handoff schema. |
| `scripts/jira-mutate.sh`. | Dispatch every supported Jira write through a verified request and receipt contract. |
| `scripts/record-approval.sh`. | Record artifact or head-bound human and role decisions. |
| `scripts/prepare-pr.sh`. | Render the versioned pull-request body without contacting GitHub. |
| `scripts/route-task.sh`. | Choose a deterministic, Luna, Terra, Sol, or approved Astra route without invoking a model. |
| `scripts/verify-jira-lifecycle-labels.sh`. | Verify Jira Labels access and canonical Lifecycle Phase behavior. |
| `scripts/validate-schema.mjs`. | Evaluate YAML or JSON against the complete Draft 2020-12 schemas. |
| `dev/scripts/update-skill-lock.sh`. | Refresh reviewed upstream skill hashes from an exact clean commit. |
| `dev/scripts/validate.sh`. | Validate Clowder itself through syntax, static analysis, formats, schemas, Bats, and portable integration tests. |

## 12. Jira Mutation Architecture

All Jira card creation, summary or description editing, linked-parent replacement, Lifecycle Phase changes, and Status transitions use `scripts/jira-mutate.sh`. Direct ACLI mutations are invalid except explicit cleanup of disposable integration-test cards.

Each schema-version `1` request includes:

- A stable mutation ID and request digest.
- The acting role.
- The exact expected source state.
- The intended target state.
- A reason, evidence, and next action.
- A new receipt path outside the product repository.

The adapter validates authority, project identity, work type, Stage Parent, linked-parent direction and cardinality, Bug placement, Status, sole phase label, and operation-specific source state. It records durable intent, performs the minimum ACLI calls, rereads Jira, verifies the durable completion comment and target state, then emits a receipt.

Retries return `applied`, `recovered`, or `replayed` without duplicating successful work. Mutation-ID conflicts, stale source state, invalid hierarchy, invalid actor, ambiguous partial state, unsafe receipt paths, or failed verification produce no success receipt.

The adapter is a recoverable serial transaction, not an atomic server-side compare-and-swap. Jira exposes its reads, comments, creates, edits, links, and transitions as separate operations. The exactly 1 Active Owner invariant and exclusive adapter use are therefore required safety controls.

## 13. Feature Setup and Recovery

`start-feature.sh` validates the Jira key, slug, project identity, branch name, base branch, existing artifacts, worktree target, and branch registration. It creates the Feature worktree and required artifacts, but never commits, pushes, opens a pull request, or changes Jira.

When setup state already exists, the Orchestrator runs the read-only recovery classifier. It distinguishes clean, branch-only, partial-artifacts, orphaned-directory, stale-registration, active-complete, completed-merged-dirty, completed-merged, completed-on-base, and base-present-branch-diverged states.

Recovery actions preserve branches, commits, and artifacts before cleanup. Destructive cleanup requires explicit HITL authority and exact validated targets.

Session loss is recoverable because Jira, the Feature directory, Git, the pull request, CI, mutation receipts, and approval records contain the durable state. A replacement Orchestrator reconstructs the workflow from those sources rather than relying on transcript memory.

## 14. Git, Worktrees, and Pull Requests

Every Feature uses a short-lived branch and worktree. The default branch shape is `feat/JIRA-123-feature-name`, with the prefix configurable per product.

A draft pull request may open after the 1st authorized commit. It remains a draft until Developer Verification passes and the independent stages can begin.

At the start of each repository session, the Orchestrator establishes exactly 1 Git authorization mode:

1. Commit and push freely.
2. Commit freely, with permission required before each push.
3. Permission required before each commit and each push.

The selected mode applies only to the current repository and session. The Orchestrator passes it unchanged to every role. YOLO mode never implies Git authority.

The local pre-push guard rejects direct updates or deletions of the configured base branch from the onboarded clone. It is bypassable through Git options, another clone, or GitHub, so it is defense in depth rather than server enforcement.

Testing and Review approve the same **reviewed code head**. Later commits may change only:

- `feature.yaml`.
- `PULL_REQUEST.md`.
- `evidence/tester.md`.
- `evidence/reviewer.md`.

Any other later change invalidates Testing, Review, residual-risk, and merge approvals. Required CI runs against the final pull-request head.

`github.review-evidence` selects 1 of 2 policies:

- `clowder-attestation` uses the fresh Clowder Reviewer decision, exact attestation binding, final-head CI, HITL merge approval, and absence of unresolved GitHub change requests.
- `github-approval` retains those controls and also requires an approved GitHub review from a permitted separate identity.

The Ready for Merge gate emits a receipt only after success. The Orchestrator publishes that exact JSON as a pull-request comment and rereads it before recommending merge. HITL performs the merge. Clowder never auto-merges.

## 15. Quality and Approval Model

### 15.1 Risk Levels

| Risk | Description | Minimum Posture |
| --- | --- | --- |
| R1. | Local, reversible, familiar, and low blast radius. | Static checks, focused automated tests, regression coverage, and normal review. |
| R2. | Cross-module, externally integrated, persistent, migrated, visibly user-facing, or operationally meaningful. | R1 plus applicable integration, contract, end-to-end, failure, manual, observability, and rollback checks. |
| R3. | Security, privacy, authorization, financial, destructive, production, customer-facing, regulated, or difficult to reverse. | R2 plus specialist review, adversarial testing, explicit human approvals, production-shaped staging, and rehearsed recovery. |

The Test Plan selects relevant verification. Candidate layers include formatting, linting, type checking, builds, unit tests, property tests, mutation testing, components, integrations, contracts, systems, browser automation, manual testing, visual checks, accessibility, compatibility, performance, reliability, data behavior, security, privacy, recovery, operations, release verification, and AI-specific evaluations.

Coverage percentage is evidence, not the definition of correctness.

### 15.2 Gates

**Ready for Development** requires an approved PRD, complete Technical Design, approved qualifying ADRs, complete Test Plan, valid Feature mapping, resolved blockers, and confirmed tools and environments.

**Ready for Review** requires implemented acceptance outcomes, current Developer evidence, applicable local checks, formatting, linting, type checking, build results, data-protection checks, diff inspection, and a current pull-request body.

**Ready for Merge** requires final-head CI, current independent Tester and Reviewer conclusions for the same reviewed code head, satisfied review-evidence policy, resolved or accepted findings, current migration and rollback notes when applicable, HITL approval, configured branch guard, and a published verified merge receipt.

PRD and architecture decisions bind exact artifact hashes. Testing, Review, residual-risk, and merge decisions bind the reviewed code head. Merge approval also binds the allowed attestation changes through a deterministic attestation revision.

Deterministic scope, schema, identity, and safety validation completes before any project-configured quality command executes. Invalid or out-of-scope configuration therefore cannot supply a command to a later gate.

## 16. Model and Reasoning Routing

Routing is based on the task, not permanently on the role.

| Route | Default Use |
| --- | --- |
| Script. | Naming, schemas, branch and worktree setup, file presence, state comparison, and configured checks. |
| Luna with `low`. | Narrow, local, reversible, cheaply verified work. |
| Terra with `medium`. | Routine multi-step implementation, documentation, test drafting, and evidence synthesis. |
| Sol with `high`. | Ambiguous, consequential, cross-module, security-sensitive, architectural, diagnostic, or independent review work. |
| Astra with `xhigh`. | HITL-approved exceptional analysis after normal escalation is insufficient and `models.astra` names an available model. |

`route-task.sh` starts with Terra. It selects a script for deterministic work, Luna for narrow mechanical work, and Sol for R3 risk, high ambiguity, cross-module scope, repeated failure, or consequential keywords. Astra is disabled until explicitly configured and requested as an exception.

The Orchestrator defaults to project-configured `gpt-5.6-luna` with `xhigh`. Each specialist dispatch records its own explicit route. Higher reasoning cannot replace missing evidence or a missing human decision.

### 16.1 Context Strategy

Shared methodology, role, safety, and skill instructions remain stable. Dynamic Jira state, approved artifacts, diffs, and evidence are appended as task context. Work packages link primary sources instead of copying complete documents, and raw logs remain outside model context unless a cited excerpt is necessary.

Reviewer and Tester start fresh threads to preserve independent judgment. A role with a clarification resumes its existing thread after the durable answer is recorded. Cached input is a cost optimization, never a reason to retain stale instructions or reuse an implementation thread for independent verification.

## 17. Skills and Integrity

Clowder installs 3 native skills:

- `orchestrate-feature` defines the Orchestrator's Feature coordination loop.
- `verify-feature` defines independent Tester verification.
- `clowder-help` answers questions about Clowder from the current product files.

The role definitions also use 16 bundled skills authored by Matt Pocock as method references. Clowder's Jira contract, authority model, gates, artifact locations, and Git authorization always override conflicting upstream workflow actions.

`skill-lock.json` pins the upstream author, license, exact commit, file paths, and SHA-256 values for every reviewed file. Doctor rejects missing, changed, symbolic, or unexpected files in both the package and discoverable installations. Updating the lock requires a clean upstream checkout at the exact recorded commit and explicit review of every new file. `THIRD_PARTY_NOTICES.md` preserves upstream attribution and license terms.

## 18. Configuration Contract

Each consumer repository stores `.clowder/project.yaml` with schema version `1`.

The configuration defines:

- Product name.
- Jira project, board, integration, work types, fields, columns, and link type.
- Git remote, base branch, and Feature prefix.
- GitHub repository and review-evidence policy.
- Feature and ADR roots.
- Project-specific quality commands and required CI checks.
- Risk rules.
- Human decision-makers for product, architecture, residual risk, and merge approval.
- Orchestrator and routed model names.

The configuration contains no access material. Schemas reject unknown or malformed fields. Doctor rejects placeholders and incomplete live configuration before normal operation.

## 19. Security Model

Clowder runs Codex with approval and sandbox bypass in a trusted local environment. Role boundaries are behavioral instructions, not operating-system isolation. Clowder must therefore run only on trusted repositories and an appropriate trusted machine boundary.

The protection stack is:

- Explicit HITL authority and Git authorization.
- Exactly 1 active player and 1 Developer writer.
- Versioned product artifacts and revision-bound approvals.
- Deterministic schema and gate checks.
- A request-digest-bound Jira mutation adapter.
- Required CI on the exact final pull-request head.
- Independent Testing and Review on the same reviewed code head.
- Attestation integrity between reviewed and final heads.
- A local base-branch pre-push guard.
- HITL-only merge, deployment, production, migration, destructive, and access-material actions.

Access material never belongs in project configuration, templates, prompts, logs, or handoffs. Clowder scripts do not load local secret files or print access material.

The accepted limitations are:

- YOLO execution can access more than a role's behavioral scope.
- The local base-branch guard is bypassable.
- Single-account `clowder-attestation` provides logical role independence, not cryptographic identity separation.
- Jira mutation safety is serial and recoverable, not server-atomic.

## 20. Failure Behavior

Clowder fails closed at gates:

- Missing or stale evidence blocks downstream dispatch.
- Invalid Jira hierarchy, ownership, Status, or Lifecycle Phase blocks mutation and handoff.
- An unavailable Jira or GitHub integration leaves durable state unchanged and blocks the affected gate.
- Product ambiguity produces `CLARIFICATION_REQUIRED` instead of invented behavior.
- A changed approved input marks dependent outputs stale.
- A failed deterministic command retains its output and returns remediation to the owning role.
- A Feature that becomes too large returns to Product Manager for decomposition.
- A Reviewer or Tester defect returns ownership to Developer, followed by new Testing and Review.
- A lost session reconstructs state from durable systems.
- Cleanup never proceeds until recoverability is proven and HITL authorizes destructive action.

## 21. Clowder Verification

Clowder validates itself with:

- Bash syntax checks and ShellCheck `0.11.0`.
- Bats `1.14.0` public-interface tests.
- A portable shell integration suite.
- Complete JSON Schema evaluation through Ajv `8.20.0`.
- YAML parsing through YAML `2.9.1` and Ruby validation where used.
- TOML, JSON, YAML, Markdown, and lock-file checks.
- Fixture repositories covering setup, recovery, dirty state, stale evidence, detached state, duplicate branches, and missing integration state.
- Jira mutation tests covering hierarchy, authority, conflict, replay, partial failure, recovery, closure, and receipt safety.
- Launcher tests covering deterministic Supacode targeting and shell-safe argument construction.
- Role and skill integrity checks through Doctor.
- Live Doctor checks against a configured disposable consumer repository.

`dev/scripts/validate.sh` is the complete local regression entry point. `scripts/doctor.sh` is the consumer-specific readiness entry point. `scripts/clowder --no-ui --offline` is the non-mutating launcher smoke test.

## 22. Source Organization

The Clowder source contains 2 physical categories:

**Product files** include the Orchestrator instructions, operational contracts, Codex role definitions, native and bundled upstream skills, runtime scripts, schemas, templates, package metadata, third-party notices, and the upstream skill lock.

**Development files** live under `dev/` and include this architecture, tests, fixtures, validation tooling, and toolchain locks. Runtime scripts and agents do not depend on this directory.

Generated `.test-worktrees/` and `node_modules/` content is not source. `.test-worktrees/` is disposable. `node_modules/` is recreated with `npm ci`.

This separation does not change the runtime architecture or consumer repository contract.

## 23. Architectural Authority

This document is the authoritative explanation of Clowder's current architecture. The following operational contracts remain authoritative for their exact interfaces:

- [Domain Context](../CONTEXT.md) for canonical terms.
- [Jira Rules](../JIRA_RULES.md) for Jira mutations, relationships, ownership, and closure.
- [Development Workflow](../DEVELOPMENT_WORKFLOW.md) for the execution sequence.
- [Role Contracts](../ROLE_CONTRACTS.md) and `../.codex/agents/` for role authority.
- [Handoff Protocol](../HANDOFF_PROTOCOL.md) for clarification and completion records.
- [Quality Gates](../QUALITY_GATES.md) for gate criteria.
- [Model Routing](../MODEL_ROUTING.md) for model and reasoning selection.
- [Security Model](../SECURITY_MODEL.md) for operational security boundaries.
- [Upstream Skills](../UPSTREAM_SKILLS.md) and `../skill-lock.json` for reviewed skill adaptations and integrity.
- [Third-Party Notices](../THIRD_PARTY_NOTICES.md) for upstream authorship and licensing.

When implementation and documentation disagree, Clowder stops the affected workflow. The discrepancy must be resolved in the implementation and the owning authoritative document before work resumes.

## 24. Evolution Boundary

Clowder remains a script-based native Codex system while its durable external systems and thread controls satisfy the workflow. A custom controller, App Server, or agent SDK becomes justified only when observed requirements include hard per-role operating-system permissions, concurrent Features under 1 supervisor, machine-restart continuity without reconstruction, durable leases or cancellation, a shared multi-user supervision interface, real-time external agent telemetry, or lifecycle guarantees that native Codex threads cannot supply.
