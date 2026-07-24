#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

project_key="${1:-CT}"
valid_jira_key "${project_key}-1" || die "invalid Jira project key: $project_key"
require_command acli

acli jira auth status >/dev/null 2>&1 || die 'Atlassian CLI is not authenticated'
acli jira project view --key "$project_key" --json >/dev/null 2>&1 || die "Jira project is unavailable: $project_key"
acli jira workitem search --jql "project = $project_key AND labels is not EMPTY" --count >/dev/null 2>&1 || die "Jira Labels field is unavailable in project: $project_key"

cat <<'EOF'
clowder: Jira Lifecycle Phase uses the native Labels field.
clowder: Each Clowder card must contain exactly 1 label from this set:
  Intake
  Discovery
  Feature-Definition
  PRD
  Design
  Test-Planning
  Ready-for-Development
  Orchestration
  Development
  Developer-Verification
  Testing
  Review
  Remediation
  Ready-for-Merge
  Production
  Complete
  Needs-Information
  Rejected
EOF

info "Jira Lifecycle Phase label access verified for $project_key"
