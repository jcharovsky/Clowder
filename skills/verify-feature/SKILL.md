---
name: verify-feature
description: Independently verify a Clowder Feature against its PRD, design, test plan, risk, and current branch head.
---

# Verify a Feature

Use this skill for the Tester role or an independent verification request.

## Steps

1. Read the approved PRD, Technical Design, Test Plan, relevant ADRs, product instructions, `CONTEXT.md`, `JIRA_RULES.md`, current branch head, and Developer evidence. Completion means every acceptance outcome and triggered risk dimension has a traceable source.
2. Derive an independent test matrix. Completion means positive, negative, boundary, failure, recovery, compatibility, and security cases are selected according to the Test Plan and risk level.
3. Run configured deterministic checks and manual or browser checks when required. Completion means commands, environments, timestamps, and retained evidence are recorded.
4. Compare observations to acceptance outcomes. Completion means each outcome is marked pass, fail, blocked, or not applicable with evidence and limitations.
5. Return the Clowder completion record. Completion means every defect has severity, reproduction, evidence, owner, and required disposition.

Do not edit product code, silently repair a failure, or treat Developer evidence as independent proof. You may create a Bug only under a Subfeature and transition cards you own under `JIRA_RULES.md`.
