#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/clowder-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

assert_contains() {
  local haystack=$1
  local needle=$2
  [[ "$haystack" == *"$needle"* ]] || { printf 'expected output to contain: %s\n%s\n' "$needle" "$haystack" >&2; exit 1; }
}

jq -e '.properties.jira.required | (index("status-field") != null and index("lifecycle-phase-field") != null)' "$ROOT/schemas/project.schema.json" >/dev/null || { printf '%s\n' 'project schema omits required Jira state fields' >&2; exit 1; }
jq -e '.properties.github.properties["review-evidence"].enum == ["clowder-attestation", "github-approval"]' "$ROOT/schemas/project.schema.json" >/dev/null || { printf '%s\n' 'project schema omits the GitHub review-evidence policy' >&2; exit 1; }
jq -e '.properties.feature.properties["lifecycle-phase"].enum | index("ready-for-merge") != null' "$ROOT/schemas/feature.schema.json" >/dev/null || { printf '%s\n' 'Feature schema omits the Lifecycle Phase enum' >&2; exit 1; }
jq -e '.properties.approvals.properties.merge.required | index("attestation-revision") != null' "$ROOT/schemas/feature.schema.json" >/dev/null || { printf '%s\n' 'Feature schema omits the merge attestation revision' >&2; exit 1; }
jq -e '.properties.artifacts.required | index("retrospective") == null' "$ROOT/schemas/feature.schema.json" >/dev/null || { printf '%s\n' 'Feature schema incorrectly treats the post-merge retrospective as a product artifact' >&2; exit 1; }
jq -e '(.sourceCommit | test("^[0-9a-f]{40}$")) and all(.skills[]; .path | test("^skills/(engineering|productivity)/[a-z0-9-]+$"))' "$ROOT/skill-lock.json" >/dev/null || { printf '%s\n' 'skill lock lacks exact upstream commit and path provenance' >&2; exit 1; }
while IFS= read -r skill_name; do
  bundled_skill="$ROOT/skills/$skill_name"
  [[ -d "$bundled_skill" ]] || { printf 'reviewed upstream skill is not bundled: %s\n' "$skill_name" >&2; exit 1; }
  expected_files="$(jq -c --arg name "$skill_name" '.skills[$name].files | keys | sort' "$ROOT/skill-lock.json")"
  actual_files="$(ruby -r json -e '
    root = ARGV.fetch(0)
    files = Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) || File.symlink?(path) }
    puts JSON.generate(files.map { |path| path.delete_prefix("#{root}/") }.sort)
  ' "$bundled_skill")"
  [[ "$actual_files" == "$expected_files" ]] || { printf 'bundled upstream skill file set differs from its lock: %s\n' "$skill_name" >&2; exit 1; }
  while IFS= read -r relative_skill_file; do
    expected_hash="$(jq -r --arg name "$skill_name" --arg file "$relative_skill_file" '.skills[$name].files[$file]' "$ROOT/skill-lock.json")"
    actual_hash="$(shasum -a 256 "$bundled_skill/$relative_skill_file" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || { printf 'bundled upstream skill hash differs from its lock: %s/%s\n' "$skill_name" "$relative_skill_file" >&2; exit 1; }
  done < <(jq -r --arg name "$skill_name" '.skills[$name].files | keys[]' "$ROOT/skill-lock.json")
done < <(jq -r '.skills | keys[]' "$ROOT/skill-lock.json")
[[ -f "$ROOT/skills/clowder-help/SKILL.md" ]] || { printf '%s\n' 'Clowder Help skill is not packaged' >&2; exit 1; }
grep -Fq 'Matt Pocock' "$ROOT/THIRD_PARTY_NOTICES.md" || { printf '%s\n' 'Matt Pocock attribution is missing' >&2; exit 1; }
grep -Fq 'https://github.com/mattpocock/skills' "$ROOT/THIRD_PARTY_NOTICES.md" || { printf '%s\n' 'Matt Pocock Skills repository attribution is missing' >&2; exit 1; }
if grep -Eq '^[[:space:]]+retrospective:' "$ROOT/templates/feature-manifest-template.yaml"; then
  printf '%s\n' 'Feature manifest incorrectly declares the post-merge retrospective as a product artifact' >&2
  exit 1
fi
[[ -f "$ROOT/templates/RETROSPECTIVE_TEMPLATE.md" ]] || { printf '%s\n' 'Clowder pilot retrospective template is missing' >&2; exit 1; }
[[ -f "$ROOT/schemas/ready-for-merge-receipt.schema.json" ]] || { printf '%s\n' 'Ready for Merge receipt schema is missing' >&2; exit 1; }
jq -e '
  .properties.kind.const == "clowder-ready-for-merge-receipt" and
  .properties.result.const == "passed" and
  (.required | sort) == (["schema-version", "kind", "result", "generated-at", "repository", "jira-feature", "pull-request", "review-evidence", "reviewed-code-head", "final-pull-request-head", "attestation-revision", "required-checks"] | sort)
' "$ROOT/schemas/ready-for-merge-receipt.schema.json" >/dev/null || { printf '%s\n' 'Ready for Merge receipt schema does not define the public contract' >&2; exit 1; }

repo="$fixture_root/repo"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null

onboard_output="$("$ROOT/scripts/onboard.sh" --repo "$repo" --name Fixture --jira-project FIX)"
assert_contains "$onboard_output" 'onboarding complete'
first_config="$(shasum -a 256 "$repo/.clowder/project.yaml" | awk '{print $1}')"
"$ROOT/scripts/onboard.sh" --repo "$repo" --name Changed --jira-project OTHER >/dev/null
second_config="$(shasum -a 256 "$repo/.clowder/project.yaml" | awk '{print $1}')"
[[ "$first_config" == "$second_config" ]] || { printf '%s\n' 'onboard overwrote existing configuration' >&2; exit 1; }
[[ "$(cat "$repo/.clowder/.gitignore")" == 'runtime/' ]] || { printf '%s\n' 'runtime state is not ignored' >&2; exit 1; }
[[ "$(source "$ROOT/scripts/lib.sh"; yaml_scalar "$repo/.clowder/project.yaml" jira.status-field)" == 'status' ]] || { printf '%s\n' 'Jira status field is not configured' >&2; exit 1; }
[[ "$(source "$ROOT/scripts/lib.sh"; yaml_scalar "$repo/.clowder/project.yaml" jira.lifecycle-phase-field)" == labels ]] || { printf '%s\n' 'Lifecycle Phase label field is not configured' >&2; exit 1; }
board_columns="$(ruby -r yaml -r json -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts JSON.generate(data.dig("jira", "required-columns"))' "$repo/.clowder/project.yaml")"
[[ "$board_columns" == '["To Do","Product Manager","Architect","Developer","Tester","Reviewer","Done"]' ]] || { printf '%s\n' 'Jira board columns are not configured' >&2; exit 1; }
work_types="$(ruby -r yaml -r json -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts JSON.generate(data.dig("jira", "required-work-types"))' "$repo/.clowder/project.yaml")"
[[ "$work_types" == '["Stage","Epic","Feature","Subfeature","Bug"]' ]] || { printf '%s\n' 'Jira work types are not configured' >&2; exit 1; }
[[ "$(source "$ROOT/scripts/lib.sh"; yaml_scalar "$repo/.clowder/project.yaml" jira.native-parent-field)" == 'parent' ]] || { printf '%s\n' 'Jira native Parent field is not configured' >&2; exit 1; }
[[ "$(source "$ROOT/scripts/lib.sh"; yaml_scalar "$repo/.clowder/project.yaml" jira.child-link-type)" == 'Child' ]] || { printf '%s\n' 'Jira Child link type is not configured' >&2; exit 1; }
[[ "$(source "$ROOT/scripts/lib.sh"; yaml_scalar "$repo/.clowder/project.yaml" github.review-evidence)" == 'clowder-attestation' ]] || { printf '%s\n' 'single-account review evidence is not configured' >&2; exit 1; }
[[ "$(git -C "$repo" config --local --get core.hooksPath)" == '.clowder/hooks' ]] || { printf '%s\n' 'Clowder hooks path is not configured' >&2; exit 1; }
[[ "$(git -C "$repo" config --local --get clowder.baseBranch)" == 'main' ]] || { printf '%s\n' 'Clowder guarded base branch is not configured' >&2; exit 1; }
[[ -x "$repo/.clowder/hooks/pre-push" ]] || { printf '%s\n' 'Clowder direct-push guard is not executable' >&2; exit 1; }
cmp -s "$ROOT/templates/pre-push-hook" "$repo/.clowder/hooks/pre-push" || { printf '%s\n' 'Clowder direct-push guard differs from its template' >&2; exit 1; }
recovery_output="$("$ROOT/scripts/recover-feature.sh" --repo "$repo" --json FIX-99 portable-recovery)"
[[ "$(jq -r '.state' <<<"$recovery_output")" == 'clean' ]] || { printf '%s\n' 'Feature recovery classifier did not recognize a clean state' >&2; exit 1; }
[[ "$(jq -r '.safe_to_retry' <<<"$recovery_output")" == 'true' ]] || { printf '%s\n' 'Feature recovery classifier did not authorize a clean retry' >&2; exit 1; }
if (cd "$repo" && printf '%s\n' 'refs/heads/main local refs/heads/main remote' | .clowder/hooks/pre-push origin example.invalid >/dev/null 2>&1); then
  printf '%s\n' 'Clowder direct-push guard allowed a base-branch update' >&2
  exit 1
fi
(cd "$repo" && printf '%s\n' 'refs/heads/feat/test local refs/heads/feat/test remote' | .clowder/hooks/pre-push origin example.invalid >/dev/null)

doctor_output="$("$ROOT/scripts/doctor.sh" --repo "$repo" --offline 2>&1)"
assert_contains "$doctor_output" 'doctor passed'
assert_contains "$doctor_output" 'Jira integration is configured as offline'
assert_contains "$doctor_output" 'github.repository is still a placeholder'
mv "$repo/.clowder/hooks/pre-push" "$repo/.clowder/hooks/pre-push.saved"
missing_guard_output="$("$ROOT/scripts/doctor.sh" --repo "$repo" --offline --json || true)"
assert_contains "$missing_guard_output" 'Clowder direct-push guard is missing or symbolic'
mv "$repo/.clowder/hooks/pre-push.saved" "$repo/.clowder/hooks/pre-push"
mkdir -p "$fixture_root/empty-home"
missing_install_output="$(env HOME="$fixture_root/empty-home" CODEX_HOME="$fixture_root/missing-codex-home" "$ROOT/scripts/doctor.sh" --repo "$repo" --offline --json)"
assert_contains "$missing_install_output" 'Clowder role is not installed: clowder-product-manager.toml'
assert_contains "$missing_install_output" 'Clowder skill is not installed: clowder-orchestrate-feature/SKILL.md'
assert_contains "$missing_install_output" 'reviewed upstream skill is not installed: triage'
live_doctor_output="$("$ROOT/scripts/doctor.sh" --repo "$repo" --json || true)"
assert_contains "$live_doctor_output" 'approvals.product-owner is still a placeholder'
assert_contains "$live_doctor_output" 'quality.required-checks must name at least 1 required CI check'
assert_contains "$live_doctor_output" 'quality.commands must configure at least 1 executable quality gate'

invalid_config_repo="$fixture_root/invalid-config-repo"
mkdir -p "$invalid_config_repo"
git -C "$invalid_config_repo" init -b main >/dev/null
"$ROOT/scripts/onboard.sh" --repo "$invalid_config_repo" --name 'Invalid Config' --jira-project BAD >/dev/null
source "$ROOT/scripts/lib.sh"
update_yaml_values "$invalid_config_repo/.clowder/project.yaml" schema-version 2
invalid_config_output="$("$ROOT/scripts/doctor.sh" --repo "$invalid_config_repo" --offline --json || true)"
assert_contains "$invalid_config_output" '$.schema-version: expected constant 1'
update_yaml_values "$invalid_config_repo/.clowder/project.yaml" schema-version 1 github.review-evidence invalid-policy
invalid_review_evidence_output="$("$ROOT/scripts/doctor.sh" --repo "$invalid_config_repo" --offline --json || true)"
assert_contains "$invalid_review_evidence_output" 'github.review-evidence must be clowder-attestation or github-approval'

install_home="$fixture_root/codex-home"
mkdir -p "$install_home"
install_output="$(env HOME="$fixture_root/empty-home" "$ROOT/scripts/install.sh" --codex-home "$install_home")"
assert_contains "$install_output" 'Clowder installation complete.'
[[ -f "$install_home/agents/clowder-product-manager.toml" ]] || { printf '%s\n' 'role install missing' >&2; exit 1; }
[[ -f "$install_home/skills/clowder-orchestrate-feature/SKILL.md" ]] || { printf '%s\n' 'skill install missing' >&2; exit 1; }
[[ -f "$install_home/skills/clowder-help/SKILL.md" ]] || { printf '%s\n' 'Clowder Help skill install missing' >&2; exit 1; }
[[ -f "$install_home/skills/triage/SKILL.md" ]] || { printf '%s\n' 'packaged upstream skill install missing' >&2; exit 1; }
cmp -s "$ROOT/skills/triage/SKILL.md" "$install_home/skills/triage/SKILL.md" || { printf '%s\n' 'installed upstream skill differs from its packaged source' >&2; exit 1; }
installed_doctor_output="$(env HOME="$fixture_root/empty-home" CODEX_HOME="$install_home" CLOWDER_UPSTREAM_SKILLS_ROOT="$install_home/skills" "$ROOT/scripts/doctor.sh" --repo "$repo" --offline --json)"
[[ "$(jq -r '.ok' <<<"$installed_doctor_output")" == true ]] || { printf '%s\n' 'Doctor rejected a complete packaged-skill installation' >&2; exit 1; }

conflict_home="$fixture_root/conflict-codex-home"
mkdir -p "$conflict_home/skills/triage"
printf '%s\n' 'conflicting skill' > "$conflict_home/skills/triage/SKILL.md"
if conflict_output="$(env HOME="$fixture_root/empty-home" "$ROOT/scripts/install.sh" --codex-home "$conflict_home" 2>&1)"; then
  printf '%s\n' 'installer overwrote or accepted a conflicting upstream skill' >&2
  exit 1
fi
assert_contains "$conflict_output" 'conflicting installed skill: triage'
[[ ! -e "$conflict_home/agents/clowder-product-manager.toml" ]] || { printf '%s\n' 'installer changed files before reporting a skill conflict' >&2; exit 1; }
env HOME="$fixture_root/empty-home" "$ROOT/scripts/install.sh" --codex-home "$conflict_home" --force >/dev/null
cmp -s "$ROOT/skills/triage/SKILL.md" "$conflict_home/skills/triage/SKILL.md" || { printf '%s\n' 'forced installation did not replace the conflicting upstream skill' >&2; exit 1; }

live_repo="$fixture_root/live-repo"
mkdir -p "$live_repo"
git -C "$live_repo" init -b main >/dev/null
git -C "$live_repo" config user.name 'Clowder Test'
git -C "$live_repo" config user.email 'clowder-test@example.invalid'
"$ROOT/scripts/onboard.sh" --repo "$live_repo" --name 'Live Fixture' --jira-project LIVE >/dev/null
ruby -r yaml -e '
  file = ARGV.fetch(0)
  data = YAML.safe_load(File.read(file), aliases: true)
  data["jira"]["integration"] = "acli"
  data["github"]["repository"] = "owner/repository"
  data["quality"]["commands"]["unit"] = "true"
  data["quality"]["required-checks"] = ["test"]
  data["approvals"].keys.each { |key| data["approvals"][key] = "Fixture Owner" }
  File.write(file, data.to_yaml)
' "$live_repo/.clowder/project.yaml"
git -C "$live_repo" add .
git -C "$live_repo" commit -m 'chore: initialize live doctor fixture.' >/dev/null
probe_bin="$fixture_root/probe-bin"
probe_log="$fixture_root/probe.log"
upstream_skills_root="$fixture_root/upstream-skills"
mkdir -p "$probe_bin"
: > "$probe_log"
while IFS= read -r skill_name; do
  while IFS= read -r relative_skill_file; do
    mkdir -p "$upstream_skills_root/$skill_name/$(dirname -- "$relative_skill_file")"
    : > "$upstream_skills_root/$skill_name/$relative_skill_file"
  done < <(jq -r --arg name "$skill_name" '.skills[$name].files | keys[]' "$ROOT/skill-lock.json")
done < <(jq -r '.skills | keys[]' "$ROOT/skill-lock.json")
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "codex %s\\n" "$*" >> "${CLOWDER_PROBE_LOG:?}"' \
  'printf "%s\\n" '\''{"overallStatus":"ok"}'\'' ' > "$probe_bin/codex"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "supacode %s\\n" "$*" >> "${CLOWDER_PROBE_LOG:?}"' \
  'exit 0' > "$probe_bin/supacode"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "acli %s\\n" "$*" >> "${CLOWDER_PROBE_LOG:?}"' \
  'exit 0' > "$probe_bin/acli"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "gh %s\\n" "$*" >> "${CLOWDER_PROBE_LOG:?}"' \
  'if [[ "${1:-}" == api ]]; then printf "%s\\n" '\''{"required_status_checks":{"strict":true,"contexts":["test"]},"required_pull_request_reviews":{"required_approving_review_count":1},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'\''; fi' \
  'exit 0' > "$probe_bin/gh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'file="${!#}"' \
  'if [[ "$file" != "${CLOWDER_UPSTREAM_SKILLS_ROOT:?}/"* ]]; then command -p shasum "$@"; exit; fi' \
  'relative="${file#"${CLOWDER_UPSTREAM_SKILLS_ROOT:?}/"}"' \
  'skill_name="${relative%%/*}"' \
  'skill_file="${relative#*/}"' \
  'if [[ -n "${CLOWDER_FORCE_STALE_FILE:-}" && "$file" == "$CLOWDER_FORCE_STALE_FILE" ]]; then printf "%064d  %s\\n" 0 "$file"; exit 0; fi' \
  'hash="$(jq -r --arg name "$skill_name" --arg file "$skill_file" '\''.skills[$name].files[$file]'\'' "${CLOWDER_SKILL_LOCK:?}")"' \
  'printf "%s  %s\\n" "$hash" "$file"' > "$probe_bin/shasum"
chmod +x "$probe_bin/codex" "$probe_bin/supacode" "$probe_bin/acli" "$probe_bin/gh" "$probe_bin/shasum"
env PATH="$probe_bin:$PATH" CODEX_HOME="$install_home" CLOWDER_PROBE_LOG="$probe_log" CLOWDER_SKILL_LOCK="$ROOT/skill-lock.json" CLOWDER_UPSTREAM_SKILLS_ROOT="$upstream_skills_root" "$ROOT/scripts/doctor.sh" --repo "$live_repo" >/dev/null
grep -Fq 'codex doctor --json' "$probe_log" || { printf '%s\n' 'doctor did not probe Codex health' >&2; exit 1; }
grep -Fq 'acli jira project view --key LIVE --json' "$probe_log" || { printf '%s\n' 'doctor did not probe Jira project access' >&2; exit 1; }
grep -Fq 'acli jira workitem search --jql project = LIVE AND' "$probe_log" || { printf '%s\n' 'doctor did not validate the Jira Lifecycle Phase label field' >&2; exit 1; }
grep -Fq 'status in ("To Do", "Product Manager", "Architect", "Developer", "Tester", "Reviewer", "Done")' "$probe_log" || { printf '%s\n' 'doctor did not validate canonical Jira Status values' >&2; exit 1; }
grep -Fq 'issuetype in ("Stage", "Epic", "Feature", "Subfeature", "Bug")' "$probe_log" || { printf '%s\n' 'doctor did not validate Jira work types' >&2; exit 1; }
grep -Fq 'labels is not EMPTY' "$probe_log" || { printf '%s\n' 'doctor did not use Jira labels for Lifecycle Phase' >&2; exit 1; }
grep -Fq 'gh repo view owner/repository --json nameWithOwner' "$probe_log" || { printf '%s\n' 'doctor did not probe GitHub repository access' >&2; exit 1; }
if grep -Fq 'gh api repos/owner/repository/branches/main/protection' "$probe_log"; then
  printf '%s\n' 'doctor still requires paid GitHub branch protection' >&2
  exit 1
fi
auxiliary_skill_file="$upstream_skills_root/triage/AGENT-BRIEF.md"
stale_skill_output="$(env PATH="$probe_bin:$PATH" CODEX_HOME="$install_home" CLOWDER_PROBE_LOG="$probe_log" CLOWDER_SKILL_LOCK="$ROOT/skill-lock.json" CLOWDER_UPSTREAM_SKILLS_ROOT="$upstream_skills_root" CLOWDER_FORCE_STALE_FILE="$auxiliary_skill_file" "$ROOT/scripts/doctor.sh" --repo "$live_repo" --json || true)"
assert_contains "$stale_skill_output" 'reviewed upstream skill hash is stale: triage'
unreviewed_skill_file="$upstream_skills_root/triage/UNREVIEWED.md"
: > "$unreviewed_skill_file"
unreviewed_skill_output="$(env PATH="$probe_bin:$PATH" CODEX_HOME="$install_home" CLOWDER_PROBE_LOG="$probe_log" CLOWDER_SKILL_LOCK="$ROOT/skill-lock.json" CLOWDER_UPSTREAM_SKILLS_ROOT="$upstream_skills_root" "$ROOT/scripts/doctor.sh" --repo "$live_repo" --json || true)"
assert_contains "$unreviewed_skill_output" 'reviewed upstream skill hash is stale: triage'
rm -f -- "$unreviewed_skill_file"

grep -Fq 'Do not apply the upstream triage labels or state machine' "$ROOT/.codex/agents/product-manager.toml" || { printf '%s\n' 'Product Manager lacks the Jira skill adaptation' >&2; exit 1; }
grep -Fq 'request a completed parent Feature transition directly from `To Do` to `Done`' "$ROOT/.codex/agents/product-manager.toml" || { printf '%s\n' 'Product Manager lacks direct parent Feature closure authority' >&2; exit 1; }
grep -Fq 'verify the published Ready for Merge receipt' "$ROOT/.codex/agents/product-manager.toml" || { printf '%s\n' 'Product Manager closure does not verify the durable merge receipt' >&2; exit 1; }
grep -Fq 'publish the exact Ready for Merge receipt as a pull-request comment' "$ROOT/scripts/clowder-orchestrator" || { printf '%s\n' 'Orchestrator does not persist the Ready for Merge receipt' >&2; exit 1; }
grep -Fq 'Require the Clowder `scripts/jira-mutate.sh` request and receipt contract for every Jira card creation, summary or description edit, linked `Child` relationship change, Lifecycle Phase change, and Status transition' "$ROOT/scripts/clowder-orchestrator" || { printf '%s\n' 'Orchestrator does not require deterministic Jira state mutations' >&2; exit 1; }
grep -Fq 'Publish the exact receipt as a pull-request comment' "$ROOT/skills/orchestrate-feature/SKILL.md" || { printf '%s\n' 'Orchestration skill does not preserve the Ready for Merge receipt' >&2; exit 1; }
grep -Fq 'Execute every Jira card creation, summary or description edit, linked `Child` relationship change, Lifecycle Phase change, and Status handoff through Clowder `scripts/jira-mutate.sh`' "$ROOT/skills/orchestrate-feature/SKILL.md" || { printf '%s\n' 'Orchestration skill does not require deterministic Jira state mutations' >&2; exit 1; }
grep -Fq 'Apply the Git authorization mode supplied by the Orchestrator instead of the skill' "$ROOT/.codex/agents/developer.toml" || { printf '%s\n' 'Developer lacks the session Git authorization adaptation' >&2; exit 1; }
grep -Fq 'At session start, establish whether Git mode is commit and push freely' "$ROOT/scripts/clowder-orchestrator" || { printf '%s\n' 'Orchestrator does not establish the session Git authorization mode' >&2; exit 1; }
grep -Fq 'do not spawn its parallel Standards and Spec subagents' "$ROOT/.codex/agents/reviewer.toml" || { printf '%s\n' 'Reviewer lacks the sequential review adaptation' >&2; exit 1; }
for role_file in "$ROOT"/.codex/agents/*.toml; do
  grep -Fq 'scripts/jira-mutate.sh' "$role_file" || { printf 'role does not require deterministic Jira state mutations: %s\n' "$role_file" >&2; exit 1; }
done

dry_run="$("$ROOT/scripts/start-feature.sh" --repo "$repo" --dry-run FIX-1 safe-feature)"
assert_contains "$dry_run" 'branch=feat/FIX-1-safe-feature'
assert_contains "$dry_run" 'action=would-create-worktree-and-artifacts'
if "$ROOT/scripts/start-feature.sh" --repo "$repo" --dry-run OTHER-1 wrong-project >/dev/null 2>&1; then
  printf '%s\n' 'Jira key from another configured project was accepted' >&2
  exit 1
fi

unsafe_output="$("$ROOT/scripts/start-feature.sh" --repo "$repo" --dry-run FIX-1 'bad;rm')"
assert_contains "$unsafe_output" 'branch=feat/FIX-1-bad-rm'
[[ "$unsafe_output" != *';'* ]] || { printf '%s\n' 'unsafe shell syntax survived slug normalization' >&2; exit 1; }

feature_dir="$repo/docs/features/FIX-1-safe-feature"
mkdir -p "$feature_dir/evidence"
cp "$ROOT/templates/PRD_TEMPLATE.md" "$feature_dir/PRD.md"
cp "$ROOT/templates/TECHNICAL_DESIGN_TEMPLATE.md" "$feature_dir/TECHNICAL_DESIGN.md"
cp "$ROOT/templates/TEST_PLAN_TEMPLATE.md" "$feature_dir/TEST_PLAN.md"
cp "$ROOT/templates/feature-manifest-template.yaml" "$feature_dir/feature.yaml"
ruby -r yaml -e '
  file = ARGV.fetch(0)
  data = YAML.safe_load(File.read(file), aliases: true)
  data["feature"]["jira-key"] = "FIX-1"
  data["feature"]["slug"] = "safe-feature"
  data["feature"]["name"] = "FIX-1-safe-feature"
  data["feature"]["branch"] = "main"
  data["feature"]["worktree"] = ARGV.fetch(1)
  File.write(file, data.to_yaml)
' "$feature_dir/feature.yaml" "$repo"
[[ "$(source "$ROOT/scripts/lib.sh"; yaml_scalar "$feature_dir/feature.yaml" feature.lifecycle-phase)" == 'intake' ]] || { printf '%s\n' 'Feature lifecycle phase is not initialized' >&2; exit 1; }
update_yaml_values "$feature_dir/feature.yaml" feature.slug 'safe--feature'
invalid_slug_output="$("$ROOT/scripts/check-feature.sh" --repo "$repo" --feature "$feature_dir" --gate feature-created --json || true)"
assert_contains "$invalid_slug_output" '$.feature.slug is invalid'
update_yaml_values "$feature_dir/feature.yaml" feature.slug safe-feature
update_yaml_values "$feature_dir/feature.yaml" feature.risk R4
invalid_feature_output="$("$ROOT/scripts/check-feature.sh" --repo "$repo" --feature "$feature_dir" --gate feature-created --json || true)"
assert_contains "$invalid_feature_output" '$.feature.risk: expected one of R1, R2, R3'
update_yaml_values "$feature_dir/feature.yaml" feature.risk R1
update_yaml_values "$feature_dir/feature.yaml" schema-version 2
invalid_feature_schema_output="$("$ROOT/scripts/check-feature.sh" --repo "$repo" --feature "$feature_dir" --gate feature-created --json || true)"
assert_contains "$invalid_feature_schema_output" '$.schema-version: expected constant 1'
update_yaml_values "$feature_dir/feature.yaml" schema-version 1
pr_output="$("$ROOT/scripts/prepare-pr.sh" --repo "$repo" --feature "$feature_dir" --output -)"
assert_contains "$pr_output" 'Jira Feature: FIX-1'
printf '%s\n' '# Reviewed pull-request body' > "$feature_dir/PULL_REQUEST.md"
preserved_pr_output="$("$ROOT/scripts/prepare-pr.sh" --repo "$repo" --feature "$feature_dir" --output -)"
assert_contains "$preserved_pr_output" '# Reviewed pull-request body'
update_yaml_values "$repo/.clowder/project.yaml" approvals.product-owner 'Test Owner' approvals.architecture-owner 'Test Architect'
prd_revision="$(shasum -a 256 "$feature_dir/PRD.md" | awk '{print $1}')"
if "$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$feature_dir" --approval prd --by 'Wrong Owner' --revision "$prd_revision" >/dev/null 2>&1; then
  printf '%s\n' 'approval from an unconfigured decision-maker was accepted' >&2
  exit 1
fi
"$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$feature_dir" --approval prd --by 'Test Owner' --revision "$prd_revision" >/dev/null
outside_feature="$fixture_root/outside-feature"
cp -R "$feature_dir" "$outside_feature"
if "$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$outside_feature" --approval prd --by 'Test Owner' --revision "$prd_revision" >/dev/null 2>&1; then
  printf '%s\n' 'approval script wrote outside the configured Feature root' >&2
  exit 1
fi
approval_status="$(ruby -r yaml -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts data["approvals"]["prd"]["status"]' "$feature_dir/feature.yaml")"
[[ "$approval_status" == approved ]] || { printf '%s\n' 'approval was not recorded' >&2; exit 1; }
if "$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$feature_dir" --approval prd --by 'Test Owner' --revision stale >/dev/null 2>&1; then
  printf '%s\n' 'stale artifact approval was not rejected' >&2
  exit 1
fi
architecture_revision="$(source "$ROOT/scripts/lib.sh"; approval_revision "$repo" "$feature_dir" architecture)"
"$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$feature_dir" --approval architecture --by 'Test Architect' --revision "$architecture_revision" >/dev/null
printf '%s\n' 'architecture change' >> "$feature_dir/TECHNICAL_DESIGN.md"
if "$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$feature_dir" --approval architecture --by 'Test Architect' --revision "$architecture_revision" >/dev/null 2>&1; then
  printf '%s\n' 'stale architecture approval was not rejected' >&2
  exit 1
fi
git -C "$repo" config user.name 'Clowder Test'
git -C "$repo" config user.email 'clowder-test@example.invalid'
git -C "$repo" add .
git -C "$repo" commit -m 'test: create review approval fixture.' >/dev/null
review_head="$(git -C "$repo" rev-parse HEAD)"
"$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$feature_dir" --approval testing --by 'Tester' --revision "$review_head" >/dev/null
"$ROOT/scripts/record-approval.sh" --repo "$repo" --feature "$feature_dir" --approval review --by 'Reviewer' --revision "$review_head" >/dev/null
review_status="$(ruby -r yaml -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts data["approvals"]["review"]["head"]' "$feature_dir/feature.yaml")"
manifest_reviewed_head="$(ruby -r yaml -e 'data = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts data["feature"]["head-revision"]' "$feature_dir/feature.yaml")"
[[ "$review_status" == "$review_head" && "$manifest_reviewed_head" == "$review_head" ]] || { printf '%s\n' 'review approval was not recorded against the reviewed code head' >&2; exit 1; }

orchestrator_output="$("$ROOT/scripts/clowder-orchestrator" --repo "$repo" --print)"
assert_contains "$orchestrator_output" 'dangerously-bypass-approvals-and-sandbox'
assert_contains "$orchestrator_output" 'gpt-5.6-luna'
assert_contains "$orchestrator_output" 'agents.max_concurrent_threads_per_session=2'
assert_contains "$orchestrator_output" 'CONTEXT.md'
assert_contains "$orchestrator_output" 'JIRA_RULES.md'

handoff_output="$("$ROOT/scripts/check-handoff.sh" --file "$TEST_DIR/fixtures/handoffs/completed.json" --json)"
assert_contains "$handoff_output" '"ok": true'
"$ROOT/scripts/check-handoff.sh" --file "$TEST_DIR/fixtures/handoffs/clarification-required.json" >/dev/null
"$ROOT/scripts/check-handoff.sh" --file "$TEST_DIR/fixtures/handoffs/blocked.json" >/dev/null
"$ROOT/scripts/check-handoff.sh" --file "$TEST_DIR/fixtures/handoffs/failed.json" >/dev/null

script_route="$("$ROOT/scripts/route-task.sh" --repo "$repo" --description 'schema validation' --deterministic --json)"
assert_contains "$script_route" '"route": "script"'
luna_route="$("$ROOT/scripts/route-task.sh" --repo "$repo" --description 'mechanical link update' --json)"
assert_contains "$luna_route" '"route": "luna"'
sol_route="$("$ROOT/scripts/route-task.sh" --repo "$repo" --description 'architecture review' --scope cross-module --json)"
assert_contains "$sol_route" '"route": "sol"'
sol_case_route="$("$ROOT/scripts/route-task.sh" --repo "$repo" --description 'Security audit' --json)"
assert_contains "$sol_case_route" '"route": "sol"'
if "$ROOT/scripts/route-task.sh" --repo "$repo" --description 'critical design challenge' --exception --json >/dev/null 2>&1; then
  printf '%s\n' 'unconfigured Astra route was accepted' >&2
  exit 1
fi
route_config_snapshot="$fixture_root/route-project.yaml"
cp "$repo/.clowder/project.yaml" "$route_config_snapshot"
update_yaml_values "$repo/.clowder/project.yaml" models.astra gpt-test-astra
astra_route="$("$ROOT/scripts/route-task.sh" --repo "$repo" --description 'critical design challenge' --exception --json)"
assert_contains "$astra_route" '"route": "astra"'
assert_contains "$astra_route" '"model": "gpt-test-astra"'
cp "$route_config_snapshot" "$repo/.clowder/project.yaml"

clowder_output="$("$ROOT/scripts/clowder" --repo "$repo" --no-ui --offline)"
assert_contains "$clowder_output" 'model_reasoning_effort'

mock_bin="$fixture_root/mock-bin"
mock_log="$fixture_root/mock.log"
mock_focus_state="$fixture_root/mock-focus.state"
mkdir -p "$mock_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\\n" "$*" >> "${CLOWDER_MOCK_LOG:?}"' \
  'if [[ "${1:-}" == tab && "${2:-}" == focus ]]; then' \
  '  if [[ -e "${CLOWDER_MOCK_FOCUS_STATE:?}" ]]; then exit 0; fi' \
  '  : > "$CLOWDER_MOCK_FOCUS_STATE"' \
  '  exit 1' \
  'fi' \
  'exit 0' > "$mock_bin/supacode"
chmod +x "$mock_bin/supacode"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "codex %s\\n" "$*" >> "${CLOWDER_MOCK_LOG:?}"' \
  'exit 0' > "$mock_bin/codex"
chmod +x "$mock_bin/codex"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$mock_bin/uuidgen"
chmod +x "$mock_bin/uuidgen"

launch_env=(PATH="$mock_bin:$PATH" CLOWDER_MOCK_LOG="$mock_log" CLOWDER_MOCK_FOCUS_STATE="$mock_focus_state")
first_ui="$(env "${launch_env[@]}" "$ROOT/scripts/clowder" --repo "$repo" --offline)"
assert_contains "$first_ui" 'created Supacode Orchestrator tab'
second_ui="$(env "${launch_env[@]}" "$ROOT/scripts/clowder" --repo "$repo" --offline)"
assert_contains "$second_ui" 'focused Supacode Orchestrator tab'
grep -q '^repo open ' "$mock_log"
grep -q '^tab new ' "$mock_log"
resolved_launcher_repo="$(git -C "$repo" rev-parse --show-toplevel)"
launcher_worktree_id="$(source "$ROOT/scripts/lib.sh"; supacode_repo_identifier "$resolved_launcher_repo")"
grep -Fq "tab new --worktree $launcher_worktree_id" "$mock_log" || { printf '%s\n' 'launcher did not target the requested Supacode worktree when creating a tab' >&2; exit 1; }
grep -Fq "tab focus --worktree $launcher_worktree_id" "$mock_log" || { printf '%s\n' 'launcher did not target the requested Supacode worktree when focusing a tab' >&2; exit 1; }

env "${launch_env[@]}" "$ROOT/scripts/clowder-orchestrator" --repo "$repo" >/dev/null
grep -q 'dangerously-bypass-approvals-and-sandbox' "$mock_log"

detached_repo="$fixture_root/detached"
mkdir -p "$detached_repo"
git -C "$detached_repo" init -b main >/dev/null
"$ROOT/scripts/onboard.sh" --repo "$detached_repo" --name Detached --jira-project DET >/dev/null
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "$1" == -C && "$3" == branch && "$4" == --show-current ]]; then exit 0; fi' \
  'exec /usr/bin/git "$@"' > "$mock_bin/git"
chmod +x "$mock_bin/git"
if env PATH="$mock_bin:$PATH" "$ROOT/scripts/check-feature.sh" --repo "$detached_repo" --gate feature-created >/dev/null 2>&1; then
  printf '%s\n' 'detached worktree was not rejected' >&2
  exit 1
fi

stale_manifest="$feature_dir/feature.yaml"
ruby -r yaml -e '
  file = ARGV.fetch(0)
  data = YAML.safe_load(File.read(file), aliases: true)
  data["feature"]["head-revision"] = "stale-head"
  File.write(file, data.to_yaml)
' "$stale_manifest"
stale_check="$("$ROOT/scripts/check-feature.sh" --repo "$repo" --feature "$feature_dir" --gate feature-created --json || true)"
assert_contains "$stale_check" 'manifest reviewed head differs from current HEAD'
mkdir -p "$repo/src" "$repo/docs/features/OTHER-1-other"
printf '%s\n' 'implementation' > "$repo/src/hello.txt"
printf '%s\n' 'other Feature' > "$repo/docs/features/OTHER-1-other/PRD.md"
scope_check="$("$ROOT/scripts/check-feature.sh" --repo "$repo" --feature "$feature_dir" --gate feature-created --json || true)"
[[ "$scope_check" != *'changed file is outside Feature scope: src/hello.txt'* ]] || { printf '%s\n' 'product implementation was incorrectly rejected as out of scope' >&2; exit 1; }
assert_contains "$scope_check" 'changed file belongs to another Feature'

space_repo="$fixture_root/path with spaces/repo [fixture]"
mkdir -p "$space_repo"
git -C "$space_repo" init -b main >/dev/null
"$ROOT/scripts/onboard.sh" --repo "$space_repo" --name 'Space Fixture' --jira-project SPC >/dev/null
"$ROOT/scripts/doctor.sh" --repo "$space_repo" --offline >/dev/null
space_repo_id="$(source "$ROOT/scripts/lib.sh"; supacode_repo_identifier "$space_repo")"
assert_contains "$space_repo_id" '%2F'
assert_contains "$space_repo_id" '%20'
worktree_mock_bin="$fixture_root/worktree-mock-bin"
mkdir -p "$worktree_mock_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "worktree /tmp/worktree path with spaces" "HEAD deadbeef" "branch refs/heads/feat/SPC-1-path-safe" ""' > "$worktree_mock_bin/git"
chmod +x "$worktree_mock_bin/git"
parsed_worktree="$(PATH="$worktree_mock_bin:$PATH" bash -c 'source "$1/scripts/lib.sh"; worktree_for_branch /fake feat/SPC-1-path-safe' _ "$ROOT")"
[[ "$parsed_worktree" == '/tmp/worktree path with spaces' ]] || { printf '%s\n' 'worktree path parsing lost spaces' >&2; exit 1; }
space_dry_run="$("$ROOT/scripts/start-feature.sh" --repo "$space_repo" --dry-run SPC-1 path-safe)"
assert_contains "$space_dry_run" 'branch=feat/SPC-1-path-safe'
collision_parent="$fixture_root/collision-worktrees"
mkdir -p "$collision_parent/SPC-3-path-collision"
if "$ROOT/scripts/start-feature.sh" --repo "$space_repo" --worktree-dir "$collision_parent" --dry-run SPC-3 path-collision >/dev/null 2>&1; then
  printf '%s\n' 'existing worktree target was not rejected' >&2
  exit 1
fi

supacode_repo="$fixture_root/supacode-repo"
mkdir -p "$supacode_repo"
git -C "$supacode_repo" init -b main >/dev/null
"$ROOT/scripts/onboard.sh" --repo "$supacode_repo" --name 'Supacode Fixture' --jira-project SPC >/dev/null
supacode_mock_bin="$fixture_root/supacode-mock-bin"
supacode_state="$fixture_root/supacode-worktree.state"
mkdir -p "$supacode_mock_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == -C && "$3" == rev-parse && "$4" == --show-toplevel ]]; then printf "%s\\n" "${FAKE_SUPACODE_REPO:?}"; exit 0; fi' \
  'if [[ "$1" == -C && "$3" == branch && "$4" == --list ]]; then exit 0; fi' \
  'if [[ "$1" == -C && "$3" == worktree && "$4" == list ]]; then [[ -f "${FAKE_SUPACODE_STATE:?}" ]] || exit 0; printf "worktree %s\\nbranch refs/heads/feat/SPC-2-supacode-feature\\n\\n" "$(cat "${FAKE_SUPACODE_STATE:?}")"; exit 0; fi' \
  'if [[ "$1" == -C && "$3" == rev-parse ]]; then printf "%s\\n" deadbeef; exit 0; fi' \
  'exec /usr/bin/git "$@"' > "$supacode_mock_bin/git"
chmod +x "$supacode_mock_bin/git"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == repo && "$2" == open ]]; then exit 0; fi' \
  'if [[ "$1" == repo && "$2" == list ]]; then printf "%s\\n" "${FAKE_SUPACODE_ID:?}"; exit 0; fi' \
  'if [[ "$1" == repo && "$2" == worktree-new ]]; then' \
  '  location=""; name=""' \
  '  while (($# > 0)); do case "$1" in --location) location="$2"; shift 2 ;; --name) name="$2"; shift 2 ;; *) shift ;; esac; done' \
  '  mkdir -p "$location/$name"' \
  '  printf "%s\\n" "$location/$name" > "${FAKE_SUPACODE_STATE:?}"' \
  '  exit 0' \
  'fi' \
  'exit 1' > "$supacode_mock_bin/supacode"
chmod +x "$supacode_mock_bin/supacode"
supacode_id="$(source "$ROOT/scripts/lib.sh"; supacode_repo_identifier "$supacode_repo")"
supacode_output="$(env PATH="$supacode_mock_bin:$PATH" FAKE_SUPACODE_REPO="$supacode_repo" FAKE_SUPACODE_ID="$supacode_id" FAKE_SUPACODE_STATE="$supacode_state" "$ROOT/scripts/start-feature.sh" --repo "$supacode_repo" SPC-2 supacode-feature)"
assert_contains "$supacode_output" 'created Feature SPC-2-supacode-feature'
supacode_feature="$(cat "$supacode_state")/docs/features/SPC-2-supacode-feature"
[[ -f "$supacode_feature/feature.yaml" ]] || { printf '%s\n' 'Supacode worktree artifacts missing' >&2; exit 1; }

mkdir -p "$repo/docs/features/FIX-2-existing"
if "$ROOT/scripts/start-feature.sh" --repo "$repo" --dry-run FIX-2 existing; then
  printf '%s\n' 'duplicate Feature directory was not rejected' >&2
  exit 1
fi

approval_repo="$fixture_root/approval-repo"
mkdir -p "$approval_repo"
git -C "$approval_repo" init -b main >/dev/null
git -C "$approval_repo" config user.name 'Clowder Test'
git -C "$approval_repo" config user.email 'clowder-test@example.invalid'
"$ROOT/scripts/onboard.sh" --repo "$approval_repo" --name 'Approval Fixture' --jira-project APR >/dev/null
source "$ROOT/scripts/lib.sh"
update_yaml_values "$approval_repo/.clowder/project.yaml" quality.commands.unit 'test "${CLOWDER_QUALITY_OK:-}" = yes'
ruby -r yaml -e '
  file = ARGV.fetch(0)
  data = YAML.safe_load(File.read(file), aliases: true)
  data["github"]["repository"] = "owner/repository"
  data["github"]["review-evidence"] = "clowder-attestation"
  data["quality"]["required-checks"] = ["test"]
  data["approvals"]["product-owner"] = "Product Owner"
  data["approvals"]["architecture-owner"] = "Architecture Owner"
  data["approvals"]["residual-risk-owner"] = "Residual Risk Owner"
  data["approvals"]["merge-owner"] = "Fixture HITL"
  File.write(file, data.to_yaml)
' "$approval_repo/.clowder/project.yaml"
git -C "$approval_repo" add .
git -C "$approval_repo" commit -m 'chore: initialize approval fixture.' >/dev/null
approval_setup="$("$ROOT/scripts/start-feature.sh" --repo "$approval_repo" --local APR-1 approval-head)"
approval_worktree="$(printf '%s\n' "$approval_setup" | sed -n 's/^clowder: worktree: //p')"
approval_feature="$approval_worktree/docs/features/APR-1-approval-head"
printf '%s\n' '# Product Requirements Document' 'Approved behavior.' > "$approval_feature/PRD.md"
printf '%s\n' '# Technical Design' 'Approved design.' > "$approval_feature/TECHNICAL_DESIGN.md"
printf '%s\n' '# Test Plan' 'Approved verification.' > "$approval_feature/TEST_PLAN.md"
printf '%s\n' '# Developer Verification Evidence' '| Field | Value |' '| --- | --- |' '| Status | Verified |' > "$approval_feature/evidence/developer.md"
printf '%s\n' '# Reviewer Evidence' '| Field | Value |' '| --- | --- |' '| Status | Approved |' > "$approval_feature/evidence/reviewer.md"
printf '%s\n' '# Tester Evidence' '| Field | Value |' '| --- | --- |' '| Status | Approved |' > "$approval_feature/evidence/tester.md"
git -C "$approval_worktree" add .
git -C "$approval_worktree" commit -m 'feat: add approval fixture.' >/dev/null
approved_head="$(git -C "$approval_worktree" rev-parse HEAD)"
prd_hash="$(source "$ROOT/scripts/lib.sh"; sha256_file "$approval_feature/PRD.md")"
architecture_hash="$(source "$ROOT/scripts/lib.sh"; approval_revision "$approval_worktree" "$approval_feature" architecture)"
"$ROOT/scripts/record-approval.sh" --repo "$approval_worktree" --approval prd --by 'Product Owner' --revision "$prd_hash" >/dev/null
"$ROOT/scripts/record-approval.sh" --repo "$approval_worktree" --approval architecture --by 'Architecture Owner' --revision "$architecture_hash" >/dev/null
"$ROOT/scripts/record-approval.sh" --repo "$approval_worktree" --approval testing --by 'Fixture Tester' --revision "$approved_head" >/dev/null
"$ROOT/scripts/record-approval.sh" --repo "$approval_worktree" --approval review --by 'Fixture Reviewer' --revision "$approved_head" >/dev/null
update_yaml_values "$approval_feature/feature.yaml" feature.pull-request 'https://github.com/owner/repository/pull/1'
git -C "$approval_worktree" add "$approval_feature/feature.yaml"
git -C "$approval_worktree" commit -m 'docs: record review attestations.' >/dev/null
configured_gate_output="$("$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-review --json || true)"
assert_contains "$configured_gate_output" 'configured unit check failed'
gate_mock_bin="$fixture_root/gate-mock-bin"
gate_mock_log="$fixture_root/gate-mock.log"
mkdir -p "$gate_mock_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "gh %s\\n" "$*" >> "${CLOWDER_GATE_MOCK_LOG:?}"' \
  'jq -n --arg head "${CLOWDER_GATE_HEAD:-different-head}" --arg review "${CLOWDER_GATE_REVIEW_DECISION:-APPROVED}" '\''{state:"OPEN",isDraft:false,headRefOid:$head,reviewDecision:$review,statusCheckRollup:[{name:"test",status:"COMPLETED",conclusion:"SUCCESS"}]}'\'' ' > "$gate_mock_bin/gh"
chmod +x "$gate_mock_bin/gh"
merge_gate_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$merge_gate_output" 'pull request head does not match current HEAD'
grep -Fq 'gh pr view https://github.com/owner/repository/pull/1' "$gate_mock_log" || { printf '%s\n' 'merge gate did not inspect the configured pull request' >&2; exit 1; }
attestation_head="$(git -C "$approval_worktree" rev-parse HEAD)"
missing_pull_request_body_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$attestation_head" CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$missing_pull_request_body_output" 'missing Feature artifact: PULL_REQUEST.md'
printf '%s\n' '# Feature Pull Request' 'HITL merge approval: Approved.' > "$approval_feature/PULL_REQUEST.md"
"$ROOT/scripts/record-approval.sh" --repo "$approval_worktree" --approval merge --by 'Fixture HITL' --revision "$approved_head" >/dev/null
recorded_attestation_revision="$(source "$ROOT/scripts/lib.sh"; yaml_scalar "$approval_feature/feature.yaml" approvals.merge.attestation-revision)"
[[ -n "$recorded_attestation_revision" ]] || { printf '%s\n' 'merge approval did not bind the attestation set' >&2; exit 1; }
git -C "$approval_worktree" add "$approval_feature/PULL_REQUEST.md" "$approval_feature/feature.yaml"
git -C "$approval_worktree" commit -m 'docs: add approved merge attestations.' >/dev/null
attestation_head="$(git -C "$approval_worktree" rev-parse HEAD)"
local_review_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$attestation_head" CLOWDER_GATE_REVIEW_DECISION=REVIEW_REQUIRED CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$local_review_output" '"ok": true'
change_requested_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$attestation_head" CLOWDER_GATE_REVIEW_DECISION=CHANGES_REQUESTED CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$change_requested_output" 'pull request has unresolved GitHub change requests'
approval_config="$approval_worktree/.clowder/project.yaml"
approval_config_backup="$fixture_root/approval-project.yaml"
cp "$approval_config" "$approval_config_backup"
update_yaml_values "$approval_config" github.review-evidence github-approval
strict_missing_review_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$attestation_head" CLOWDER_GATE_REVIEW_DECISION=REVIEW_REQUIRED CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$strict_missing_review_output" 'pull request does not have an approved GitHub review'
cp "$approval_config_backup" "$approval_config"
attestation_gate_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$attestation_head" CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$attestation_gate_output" '"ok": true'
ready_for_merge_receipt="$fixture_root/APR-1-ready-for-merge.json"
receipt_gate_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$attestation_head" CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --receipt "$ready_for_merge_receipt" --json || true)"
assert_contains "$receipt_gate_output" '"ok": true'
[[ -f "$ready_for_merge_receipt" ]] || { printf '%s\n' 'successful Ready for Merge gate did not create a receipt' >&2; exit 1; }
jq -e \
  --arg reviewed "$approved_head" \
  --arg final "$attestation_head" \
  --arg attestation "$recorded_attestation_revision" \
  '."schema-version" == 1 and
   .kind == "clowder-ready-for-merge-receipt" and
   .result == "passed" and
   .repository == "owner/repository" and
   ."jira-feature" == "APR-1" and
   ."pull-request" == "https://github.com/owner/repository/pull/1" and
   ."review-evidence" == "clowder-attestation" and
   ."reviewed-code-head" == $reviewed and
   ."final-pull-request-head" == $final and
   ."attestation-revision" == $attestation and
   ."required-checks" == [{"name":"test","result":"passed"}] and
   (."generated-at" | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
  "$ready_for_merge_receipt" >/dev/null || { printf '%s\n' 'Ready for Merge receipt does not match the public contract' >&2; exit 1; }
unsafe_receipt_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$attestation_head" "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --receipt "$approval_worktree/ready-for-merge.json" --json || true)"
assert_contains "$unsafe_receipt_output" 'receipt path must be outside the product repository'
assert_contains "$unsafe_receipt_output" 'configured quality commands were skipped because deterministic validation failed'
[[ "$unsafe_receipt_output" != *'configured unit check failed'* ]] || { printf '%s\n' 'configured quality command ran before receipt-path validation' >&2; exit 1; }
printf '%s\n' 'post-approval evidence mutation' >> "$approval_feature/evidence/reviewer.md"
git -C "$approval_worktree" add "$approval_feature/evidence/reviewer.md"
git -C "$approval_worktree" commit -m 'docs: mutate approved attestation.' >/dev/null
mutated_attestation_head="$(git -C "$approval_worktree" rev-parse HEAD)"
mutated_attestation_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$mutated_attestation_head" CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$mutated_attestation_output" 'merge attestation revision is stale'
mkdir -p "$approval_worktree/src"
printf '%s\n' 'unreviewed product change' > "$approval_worktree/src/post-review.txt"
git -C "$approval_worktree" add src/post-review.txt
git -C "$approval_worktree" commit -m 'feat: add unreviewed product change.' >/dev/null
changed_head="$(git -C "$approval_worktree" rev-parse HEAD)"
post_review_change_output="$(env PATH="$gate_mock_bin:$PATH" CLOWDER_GATE_MOCK_LOG="$gate_mock_log" CLOWDER_GATE_HEAD="$changed_head" CLOWDER_QUALITY_OK=yes "$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-merge --json || true)"
assert_contains "$post_review_change_output" 'non-attestation change after reviewed head: src/post-review.txt'
update_yaml_values "$approval_worktree/.clowder/project.yaml" project.name 'Tampered Configuration'
tampered_command_marker="$fixture_root/tampered-command-executed"
update_yaml_values "$approval_worktree/.clowder/project.yaml" quality.commands.unit "touch \"$tampered_command_marker\""
git -C "$approval_worktree" add .clowder/project.yaml
git -C "$approval_worktree" commit -m 'chore: tamper with project configuration.' >/dev/null
committed_scope_output="$("$ROOT/scripts/check-feature.sh" --repo "$approval_worktree" --gate ready-for-review --json || true)"
assert_contains "$committed_scope_output" 'Clowder project configuration is outside Feature scope: .clowder/project.yaml'
[[ ! -e "$tampered_command_marker" ]] || { printf '%s\n' 'quality command from out-of-scope project configuration was executed' >&2; exit 1; }

"$TEST_DIR/jira-mutate.sh"
"$TEST_DIR/jira-entity-mutate.sh"

printf '%s\n' 'portable script tests passed'
