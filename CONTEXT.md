# Clowder Domain Context

This glossary defines the Jira concepts used by Clowder. Operational rules and validation requirements live in [`JIRA_RULES.md`](JIRA_RULES.md).

## Stage

A Stage is the native Jira Parent for every card in 1 Clowder planning scope. Stage membership is direct and is not inherited through linked work items.

## Epic

An Epic groups Features within a Stage. An Epic is not independently implemented through a Feature branch or pull request.

## Feature

A Feature is the independently shippable product outcome. It owns the PRD, Technical Design, Test Plan, branch, worktree, and pull request.

## Subfeature

A Subfeature is a bounded technical or product part of a Feature. It shares the Feature branch, worktree, and pull request, and is not independently released.

## Bug

A Bug is a defect card attached to the smallest relevant Subfeature. A Bug is never directly attached to a Feature.

## Native Parent

The Jira Parent field that assigns an Epic, Feature, Subfeature, or Bug directly to its Stage.

## Child Link

The custom Jira linked-work-item relation whose reciprocal labels are `is parent of` and `is child of`. It expresses logical decomposition between Epic, Feature, Subfeature, and Bug cards.

## Jira Status

The canonical execution owner or queue for a card. Jira maps it to a same-named board column. Clowder operates on Status, not the column.

## Status Category

Jira's native grouping for Status values. Jira configuration uses `To Do` for `To Do`, `In Progress` for the 5 player Statuses, and `Done` for `Done`. Clowder does not operate on this field.

## Lifecycle Phase

Clowder's process progression, stored as the only value in Jira's native Labels field. Multiword phase labels use hyphens. Lifecycle Phase is separate from Jira Status.

## Active Owner

The single player role named by the current Jira Status. The Orchestrator coordinates the handoff but never becomes the card owner.
