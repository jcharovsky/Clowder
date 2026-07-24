# Upstream Skills

Clowder packages a reviewed subset of skills authored by **Matt Pocock** from the [Matt Pocock Skills Repository](https://github.com/mattpocock/skills). Upstream skills are method references, not independent workflow authorities. The Clowder role definitions and Jira contract supersede conflicting upstream actions. The upstream copyright and MIT License are preserved in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Clowder bundles and installs these skills:

- Upstream source: `https://github.com/mattpocock/skills`.
- Upstream commit: `c55ee46073ed923f86ce59a5eb3b6d895095d1b7`.
- Review date: 2026-09-19.

- `triage`.
- `grilling`.
- `grill-with-docs`.
- `to-spec`.
- `to-tickets`.
- `codebase-design`.
- `domain-modeling`.
- `prototype`.
- `implement`.
- `tdd`.
- `diagnosing-bugs`.
- `resolving-merge-conflicts`.
- `code-review`.
- `handoff`.
- `wizard`.
- `writing-for-agents`.

## Runtime Adaptations

The role definitions in `.codex/agents/` are the operational wrappers around the pinned upstream skills.

| Skill | Clowder Adaptation |
| --- | --- |
| `triage`. | Reuse claim verification and durable brief practices. Do not apply its label categories, tracker state machine, comments, closure behavior, or GitHub-specific setup. Use the canonical Jira work types, Statuses, Lifecycle Phase, hierarchy, and handoff contract. |
| `grilling` and `grill-with-docs`. | Use their decision-tree method. A spawned role returns `CLARIFICATION_REQUIRED` through the Orchestrator and never questions HITL directly. Artifacts change only within the active role's authority. |
| `to-spec`. | Create the versioned `PRD.md` first. Do not publish directly to Jira. Wait for the configured PRD approval before downstream publication or handoff. |
| `to-tickets`. | Create only Stage, Epic, Feature, Subfeature, and Bug cards. Preserve the direct native Stage Parent, linked `Child` hierarchy, single linked parent, Bug placement, and 1 active player rule. Do not create Task, Story, Sub-task, or `ready-for-agent` labels. |
| `codebase-design` and `domain-modeling`. | Reuse their design vocabulary and decision discipline. The Clowder templates, artifact locations, Jira contract, and approval boundaries remain authoritative. |
| `prototype`. | Use only to answer an assigned design question. Do not create a branch or commit automatically. The normal Feature scope and authorization gates still apply. |
| `implement`. | Reuse specification-led implementation, TDD, and local-check practices. Do not perform its self-review. Replace its automatic commit behavior with the active session Git authorization mode. Tester and Reviewer are independent later roles. |
| `tdd` and `diagnosing-bugs`. | Reuse their test and diagnosis loops at approved seams. Questions and material scope changes return through the Orchestrator. |
| `resolving-merge-conflicts`. | Resolve by primary-source intent. Keep staging, continuation, authorization, and commit as separate actions under the active Git authorization mode. Do not inherit its unconditional prohibition on aborting. |
| `code-review`. | Reuse the separate Standards and Spec axes. Use the configured base, Jira, and approved PRD as sources. Run both axes sequentially inside the Reviewer role, without its parallel subagents or issue-tracker setup requirement. |
| `handoff`. | Reserve it for transfers to another harness, repository, directory, or human collaborator. Routine role transitions use `HANDOFF_PROTOCOL.md`. |
| `wizard`. | Keep it outside normal Feature execution. Use only for an approved human-operated procedure that obeys local sensitive-data rules. |
| `writing-for-agents`. | Use only when maintaining agent-facing Clowder instructions. |

Clowder also packages the native `orchestrate-feature`, `verify-feature`, and `clowder-help` skills. Installation places the 16 upstream skills under their original names and the 3 native skills under Clowder names in the selected Codex home. A conflicting installed upstream skill requires the explicit `--force` option before replacement.

## Integrity Contract

`skill-lock.json` version 2 pins the author, license, exact upstream commit, upstream path, and SHA-256 value of every reviewed file that supplies behavior or guidance, including referenced Markdown, scripts, templates, and agent metadata. A changed, missing, symbolic-link, or unexpected visible file in either the package or a discoverable installation makes the live Doctor fail. A new upstream file is not trusted automatically. It must be reviewed and added to the explicit file manifest in `dev/scripts/update-skill-lock.sh`.

The bundled upstream files match commit `c55ee46073ed923f86ce59a5eb3b6d895095d1b7` byte for byte. Lock refresh requires a clean checkout at the supplied full commit and rejects a mismatched checkout. Review `skill-lock.json` before changing the commit, source path, file manifest, or hash.
