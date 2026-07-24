# Model Routing

Routing is task-based. The role name does not permanently determine the model.

| Route | Use |
| --- | --- |
| Script. | Naming, schema checks, branch and worktree setup, file presence, and configured checks. |
| Luna with `low`. | Narrow, local, reversible, objectively verified edits. |
| Terra with `medium`. | Routine implementation, documentation, test drafting, and evidence synthesis. |
| Sol with `high`. | Ambiguous requirements, architecture, difficult diagnosis, security, and consequential review. |
| Astra with `high` or `xhigh`. | Human-approved exceptional quality-ceiling analysis after Sol is insufficient, only when `models.astra` names a model available in the target runtime. |

The current local project default is `gpt-5.6-luna` with `xhigh` for the Orchestrator. Every role dispatch selects its own task route and may override both values. The custom role files omit model settings so the explicit dispatch choice or project default remains authoritative.

Higher reasoning cannot supply missing product decisions or unavailable evidence. Escalation is bounded to 1 disciplined retry, then returns to planning or asks HITL.
