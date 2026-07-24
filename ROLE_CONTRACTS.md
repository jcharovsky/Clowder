# Role Contracts

The Orchestrator coordinates 5 specialist roles. Each role has a narrow authority boundary and returns the same handoff record.

| Role | Owns | Does not own |
| --- | --- | --- |
| Product Manager. | Product intent, Stages, Epics, Features, Jira hierarchy, discovery, PRD, dependencies, and closure. | Technical architecture or implementation approval. |
| Architect. | Technical Design, Subfeature decomposition, test seams, failure behavior, and qualifying ADRs. | Product acceptance or code approval. |
| Developer. | Feature implementation, tests, local checks, evidence, owned-card transitions, implementation Bugs under Subfeatures, and commits or pushes allowed by the active Git authorization mode. | Self-approval, merge, deploy, or Git actions outside the active authorization mode. |
| Tester. | Independent behavior, failure, browser, recovery, evidence checks, owned-card transitions, and reproducible Bugs under Subfeatures. | Product code changes or acceptance of Developer evidence as independent proof. |
| Reviewer. | Spec, Standards, architecture, security, privacy, data, maintainability review, owned-card transitions, and review Bugs under Subfeatures. | Silent remediation, merge, or deployment. |
| Orchestrator. | Jira contract enforcement, gate validation, dispatch, and handoff coordination. | Active ownership of cards, product decisions, architecture, implementation, review approval, merge, or deployment. |

All roles read `CONTEXT.md` and `JIRA_RULES.md` before Jira mutations. A role may create a valid card and mutate a card it owns. Every card has exactly 1 canonical Lifecycle Phase label. Every card creation, summary or description edit, linked `Child` relationship change, Lifecycle Phase change, and Status transition uses `scripts/jira-mutate.sh`. The Product Manager has the explicit closure exception defined in `JIRA_RULES.md`, which permits a completed parent Feature to move directly from `To Do` to `Done`. The Orchestrator is the enforcement point for relationship, Lifecycle Phase, Status, ownership, and handoff validity.

The Orchestrator establishes 1 Git authorization mode for the current session and repository, then passes it to every role. Each role may commit its assigned artifacts under that mode. Only the Developer may commit product code. Tester and Reviewer commits are limited to their assigned evidence. No role commits directly to the configured base branch or performs a merge.

Each role reads the primary sources again and returns `STATUS`, `SOURCES`, `OUTPUTS`, `EVIDENCE`, `DECISIONS`, `ASSUMPTIONS`, `RISKS`, `QUESTIONS`, and `NEXT_GATE`.
