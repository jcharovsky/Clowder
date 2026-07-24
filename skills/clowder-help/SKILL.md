---
name: clowder-help
description: Answer questions about installing, configuring, operating, troubleshooting, or extending Clowder from its authoritative product documentation. Use for Clowder help and explanations, not for executing a Feature workflow.
---

# Clowder Help

Help the user understand and operate the installed Clowder version. Treat the current product files as the source of truth rather than relying on memory.

## Locate the Product

1. Resolve the Clowder source directory from `CLOWDER_ROOT`.
2. Confirm that the directory contains `README.md`, `AGENTS.md`, and `scripts/clowder`.
3. If the directory is unavailable, explain that the session lacks Clowder launcher context and identify the missing path instead of inventing an answer.

## Select the Source

Read only the documents needed for the question:

- Read `README.md` and script `--help` output for installation, startup, onboarding, and command usage.
- Read `CONTEXT.md` and `JIRA_RULES.md` for terminology, Jira structure, ownership, Status, Lifecycle Phase, and handoffs.
- Read `DEVELOPMENT_WORKFLOW.md` for the end-to-end methodology and approval sequence.
- Read `ROLE_CONTRACTS.md` and `HANDOFF_PROTOCOL.md` for role boundaries, delegation, and completion records.
- Read `MODEL_ROUTING.md` for model and reasoning selection.
- Read `QUALITY_GATES.md` for test, review, CI, pull-request, and completion requirements.
- Read `SECURITY_MODEL.md` and `AGENTS.md` for permissions, HITL boundaries, and safety rules.
- Read `UPSTREAM_SKILLS.md`, `skill-lock.json`, and `THIRD_PARTY_NOTICES.md` for packaged skills, adaptations, provenance, and licensing.
- Read `dev/ARCHITECTURE.md` only for questions about Clowder internals, design decisions, extension, or maintenance.

## Answer

1. Distinguish a Clowder invariant from a project-specific value in `.clowder/project.yaml`.
2. Prefer a concise direct answer, then provide the exact command or source path when it helps the user act.
3. Use read-only diagnostics when evidence is needed. Request mutation only when the user asks to change configuration or state.
4. State uncertainty or a detected documentation conflict explicitly. Treat executable behavior and validated configuration as stronger evidence than explanatory prose.

This skill provides product help. Use `orchestrate-feature` when the user asks to start or resume Jira Feature work.
