# Quality Gates

## Ready for Development

- Approved PRD revision.
- Complete Technical Design.
- Approved qualifying ADRs.
- Complete Test Plan.
- Valid Feature identity mapping.
- Resolved blocking dependencies.
- Confirmed configured tools and environments.

## Ready for Review

- Accepted behavior implemented.
- Focused and complete applicable automated checks pass.
- Formatting, linting, type checking, and build checks pass when configured.
- Sensitive-file and data-protection checks pass when configured.
- Developer inspected the diff.
- Pull-request description and evidence are current.

## Ready for Merge

- Required CI checks pass on the final pull-request head.
- Reviewer conclusion is independent and current.
- Tester conclusion is independent and current.
- The configured review-evidence policy is satisfied. `clowder-attestation` uses the versioned Reviewer decision. `github-approval` additionally requires an approved GitHub review.
- Findings are resolved or explicitly accepted.
- Migration and rollback notes are current for R2 and R3 Features.
- HITL approved the reviewed code head and the exact allowed attestation changes leading to the final pull-request head.
- The onboarded clone has the reviewed Clowder direct-push guard configured for the base branch.
- A schema-version `1` Ready for Merge receipt was generated after the successful gate, published unchanged as a pull-request comment, and verified before merge.

Coverage is evidence, not the definition of correctness. The Test Plan selects the applicable automated, manual, exploratory, browser, security, performance, recovery, and operational checks.
